#!/bin/bash
# LIVI first-boot provisioning (runs once as root from cmdline.txt systemd.run)
set +e
exec > >(tee /boot/firmware/firstrun.log) 2>&1
echo "=== LIVI firstrun $(date) ===" 
# ---------------------------------------------------------- credentials
# Secrets live in livi-setup.env next to this script on the FAT boot
# partition. That file is gitignored; copy livi-setup.env.example and fill
# it in before first boot. Keeping them out of this script means the script
# itself is safe to publish.
ENV_FILE="/boot/firmware/livi-setup.env"
if [ -r "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
else
  echo "!!! $ENV_FILE missing — cannot configure Wi-Fi or the user account."
  echo "!!! Copy livi-setup.env.example to livi-setup.env and fill it in."
  exit 1
fi
: "${WIFI_SSID:?WIFI_SSID not set in $ENV_FILE}"
: "${WIFI_PSK:?WIFI_PSK not set in $ENV_FILE}"
: "${LIVI_PW_HASH:?LIVI_PW_HASH not set in $ENV_FILE}"


# ---------------------------------------------------------------- user account
# Create the user here rather than leaving it to userconf.service: in
# kernel-command-line.target the normal boot services do not run, so their
# ordering against livi-firstinstall.service is not guaranteed.
LIVI_PW_HASH="$LIVI_PW_HASH"

if [ -x /usr/lib/userconf-pi/userconf ]; then
  /usr/lib/userconf-pi/userconf livi "$LIVI_PW_HASH"
else
  # Fallback: no userconf helper in this image
  if ! id -u livi >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,video,render,input,plugdev,audio,dialout livi
  fi
  echo "livi:$LIVI_PW_HASH" | chpasswd -e
fi

# userconf.service must not reprocess this on the next boot
rm -f /boot/firmware/userconf.txt

install -m 0440 /dev/stdin /etc/sudoers.d/010-livi-nopasswd <<'EOF'
livi ALL=(ALL) NOPASSWD: ALL
EOF

# ------------------------------------------------------------------- wifi + ssh
mkdir -p /etc/NetworkManager/system-connections
install -m 0600 /dev/stdin /etc/NetworkManager/system-connections/preconfigured.nmconnection <<EOF
[connection]
id=preconfigured
uuid=88a019a9-d0d4-4586-a18e-86df0fb0a119
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID
hidden=false

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF

# Wi-Fi is soft-blocked until a country is set; AP mode later needs it too.
raspi-config nonint do_wifi_country TR
rfkill unblock wifi

systemctl enable ssh
systemctl start ssh

# ------------------------------------------------------- memory: 1 GB is tight
# Electron on a Pi 3B+ needs headroom. zram (compressed RAM) is the fast tier,
# the enlarged swapfile on USB is the slow safety net.
sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile 2>/dev/null
sed -i 's/^#\?CONF_MAXSWAP=.*/CONF_MAXSWAP=4096/' /etc/dphys-swapfile 2>/dev/null

# ----------------------------------------------------------- LIVI auto-install
install -m 0755 /dev/stdin /usr/local/bin/livi-install.sh <<'INSTALLER'
#!/bin/bash
set -uo pipefail
# Belt and braces: the installer depends on these regardless of how it was started.
export USER="${USER:-livi}"
export LOGNAME="${LOGNAME:-livi}"
export HOME="${HOME:-/home/livi}"
LOG=/home/livi/livi-install.log

# /boot/firmware is a root-owned vfat mount, so this service (User=livi) cannot
# create a file there — that is why every earlier run produced no readable log
# even though the installer was clearly running. Write to $HOME, then mirror the
# file across with sudo, which livi is allowed to do.
# Start a fresh log each run; the previous one stays as .prev. Appending across
# retries made this file unreadably long.
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.prev"
exec > >(tee "$LOG") 2>&1

flush_log() {
  sleep 1                                   # let tee drain into $LOG
  sudo cp -f "$LOG" /boot/firmware/livi-install.log 2>/dev/null || true
  sync
}
trap flush_log EXIT

echo "=== LIVI install started $(date) ==="
flush_log

# Wait for real internet, not just an IP lease.
online=no
for i in $(seq 1 60); do
  if curl -fsS -m 5 -o /dev/null https://raw.githubusercontent.com/f-io/LIVI/main/README.md; then
    online=yes
    break
  fi
  echo "  waiting for network ($i/60)"
  sleep 5
done

# Always record what the network actually looked like: this log lands on the FAT
# boot partition, so it can be read from any computer if the install fails.
echo "--- network diagnostics (online=$online) ---"
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>&1 || true
nmcli -t -f NAME,DEVICE,STATE connection show --active 2>&1 || true
echo "--- visible wifi networks ---"
nmcli -t -f SSID,SIGNAL device wifi list 2>&1 | head -20 || true
ip -brief addr 2>&1 || true
flush_log

if [ "$online" != "yes" ]; then
  echo "!!! no internet after 5 minutes — cannot install LIVI."
  echo "!!! Check the Wi-Fi SSID/password above, or plug in an ethernet cable."
  sync
  exit 1
fi

# Earlier attempts were cut mid-install by power loss; recover any half-configured
# packages before touching apt, otherwise every later apt call fails.
echo "--- repairing any interrupted dpkg state ---"
sudo dpkg --configure -a 2>&1 || true
sudo apt-get -f install -y 2>&1 || true
sync

sudo apt-get update
# zram-tools: compressed swap in RAM, the single biggest win on a 1 GB board
sudo apt-get install -y zram-tools
echo -e "ALGO=zstd\nPERCENT=60\nPRIORITY=100" | sudo tee /etc/default/zramswap >/dev/null
sudo systemctl enable zramswap
sudo dphys-swapfile swapoff 2>/dev/null
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

cd /home/livi

# Pin the installer to the same tag as the AppImage it installs.
#
# The README's command pulls the installer from main, but the release channel
# still ships v8.3.0. Those two disagree: the v8.3.0 AppImage bundles a sudoers
# template containing a __PYTHON__ placeholder, and main's common.sh dropped the
# substitution for it (the helper moved from python to the Rust livi-helperd).
# The result is a sudoers file with a bare "__PYTHON__ *livi-helper.py" command,
# which visudo rejects, aborting the install. v8.3.0's own common.sh still does
# the substitution, so taking both from the tag keeps them consistent.
export LIVI_INSTALLER_BRANCH=v8.3.0
curl -fL -o install.sh \
  "https://raw.githubusercontent.com/f-io/LIVI/${LIVI_INSTALLER_BRANCH}/scripts/install/headless/install.sh"
chmod +x install.sh

# Fully unattended: every prompt in common.sh falls through when these are set.
export LIVI_CHANNEL=release
export LIVI_MFI=no
export LIVI_SPLASH=yes
export LIVI_HDMI_PR=no
echo "--- identity / environment ---"
echo "USER=[${USER:-<unset>}] LOGNAME=[${LOGNAME:-<unset>}] HOME=[${HOME:-<unset>}]"
flush_log

echo "--- running LIVI headless installer ---"
flush_log
./install.sh < /dev/null
rc=$?
echo "--- installer exit code: $rc ---"
flush_log

if [ $rc -ne 0 ]; then
  echo "!!! LIVI installer exited with $rc — leaving the service enabled to retry on next boot"
  exit $rc
fi

sudo touch /var/lib/livi-installed
sudo systemctl disable livi-firstinstall.service
echo "=== LIVI install finished $(date) — rebooting into kiosk ==="
sleep 3
sudo systemctl reboot
INSTALLER

install -m 0644 /dev/stdin /etc/systemd/system/livi-firstinstall.service <<'UNIT'
[Unit]
Description=LIVI first-boot installer
# network.target only: waiting on network-online.target here would block boot
# forever if Wi-Fi never associates. The script does its own connectivity wait.
After=network.target
ConditionPathExists=!/var/lib/livi-installed

[Service]
# Type=simple so multi-user.target (and the login prompt) is NOT held back by
# this service. The install runs in the background while the console stays usable.
Type=simple
User=livi
# The LIVI installer substitutes $USER into udev rules and sudoers drop-ins, so
# these must be present even though systemd normally derives them from User=.
Environment=USER=livi
Environment=LOGNAME=livi
Environment=HOME=/home/livi
WorkingDirectory=/home/livi
ExecStart=/usr/local/bin/livi-install.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable livi-firstinstall.service

# ------------------------------------------------ remove ourselves from cmdline
sed -i 's| systemd.run=/boot/firmware/firstrun.sh||; s| systemd.run_success_action=reboot||; s| systemd.unit=kernel-command-line.target||' /boot/firmware/cmdline.txt

echo "=== LIVI firstrun done $(date) ==="
# Flush the FAT partition so the log survives the reboot that follows.
sync
exit 0
