#!/usr/bin/env bash
# Installs the headless LIVI appliance onto a Raspberry Pi running Debian Trixie.
#
# Expects the built package (dist-headless/) beside this script, or a path to it
# as $1. Builds are produced by scripts/build-headless.mjs in the patched LIVI
# tree — see headless/README.md.
set -euo pipefail

PKG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dist-headless}"
DEST=/opt/livi
SERVICE=livi-headless.service
UNIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$SERVICE"

[ -f "$PKG/livi-headless.cjs" ] || { echo "package not found at $PKG" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as a regular user; sudo is used internally" >&2; exit 1; }

echo "==> runtime dependencies"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  nodejs \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-libav gstreamer1.0-tools \
  libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
  bluez libspa-0.2-bluetooth pipewire pipewire-pulse wireplumber \
  hostapd dnsmasq-base iw rfkill avahi-daemon \
  libusb-1.0-0

node --version | grep -qE 'v(2[4-9]|[3-9][0-9])' || {
  echo "Node 24+ required; got $(node --version)" >&2
  echo "install from https://deb.nodesource.com/setup_24.x" >&2
  exit 1
}

echo "==> user and groups"
id livi >/dev/null 2>&1 || sudo useradd -m -s /bin/bash livi
for g in video render input plugdev audio bluetooth; do
  getent group "$g" >/dev/null && sudo usermod -aG "$g" livi
done

echo "==> files -> $DEST"
sudo rm -rf "$DEST"
sudo mkdir -p "$DEST"
sudo cp -r "$PKG"/. "$DEST"/
sudo chown -R livi:livi "$DEST"
sudo chmod 0755 "$DEST/resources/driver/livi-helperd"

echo "==> USB access for phones (AOAP re-enumerates under Google's vendor id)"
sudo tee /etc/udev/rules.d/51-livi-usb.rules >/dev/null <<'EOF'
# Google AOAP accessory mode — every Android phone lands here for Android Auto
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", GROUP="plugdev"
# Apple, for wired CarPlay
SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", MODE="0660", GROUP="plugdev"
# Carlinkit dongle (LIVI matches vid 1314, pid 1520/1521)
SUBSYSTEM=="usb", ATTR{idVendor}=="1314", MODE="0660", GROUP="plugdev"
# Common Android vendors in normal mode
SUBSYSTEM=="usb", ATTR{idVendor}=="339b", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2a70", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0660", GROUP="plugdev"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb

echo "==> passwordless sudo for the Wi-Fi AP helper"
sudo tee /etc/sudoers.d/010-livi-headless >/dev/null <<'EOF'
livi ALL=(root) NOPASSWD: /opt/livi/resources/driver/livi-helperd
EOF
sudo chmod 0440 /etc/sudoers.d/010-livi-headless

echo "==> service"
sudo cp "$UNIT_SRC" /etc/systemd/system/$SERVICE
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE

echo
echo "installed. start it with:"
echo "    sudo systemctl start $SERVICE"
echo "    journalctl -u $SERVICE -f"
echo
echo "config lives at /home/livi/.config/LIVI/config.json (written on first run)."
