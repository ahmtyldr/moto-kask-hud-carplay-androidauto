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

# Offline-friendly: when every runtime dependency is already present (a
# reinstall, or a restore in the field with no internet), skip apt entirely.
DEPS_OK=1
for c in gst-launch-1.0 hostapd bluetoothctl pipewire node; do
  command -v "$c" >/dev/null || DEPS_OK=0
done
node --version 2>/dev/null | grep -qE 'v(2[4-9]|[3-9][0-9])' || DEPS_OK=0
if [ "$DEPS_OK" = "1" ]; then
  echo "==> runtime dependencies: hepsi mevcut, apt atlaniyor (cevrimdisi uyumlu)"
else
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

# Node 24+: Trixie's repo is older, so pull NodeSource automatically — the
# single-file installer must not stop halfway and hand the user a URL.
if ! node --version 2>/dev/null | grep -qE 'v(2[4-9]|[3-9][0-9])'; then
  echo "==> Node 24 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo apt-get install -y nodejs
fi
node --version | grep -qE 'v(2[4-9]|[3-9][0-9])' || { echo "Node 24 kurulamadi" >&2; exit 1; }
fi

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
# v8.3.0 ships the privileged helper as Python (livi-helper.py), not livi-helperd.
sudo chmod 0755 "$DEST/resources/driver/helper/livi-helper.py"
# Optional LVGL idle screen (headless/statusui); absent is fine.
if [ -f "$DEST/statusui/livi-statusui" ]; then
  sudo chmod 0755 "$DEST/statusui/livi-statusui"
fi

# AudioOutput.ts runs <resources>/gstreamer/<platform>/bin/gst-launch-1.0 and, if
# that path is missing, logs "Bundled GStreamer not found" and returns — there is
# no system fallback the way the video path has one, so audio stays silent while
# everything else works. The AppImage ships that tree; this package does not.
# A directory of symlinks satisfies both the existsSync() probe and gstEnv(),
# which derives LD_LIBRARY_PATH, GST_PLUGIN_PATH and the scanner path from it.
echo "==> GStreamer bridge for audio output"
GST_ROOT="$DEST/resources/gstreamer/linux-arm64"
ARCHLIB=/usr/lib/aarch64-linux-gnu
SCANNER=$(find "$ARCHLIB" /usr/libexec -name gst-plugin-scanner 2>/dev/null | head -1)
if [ -n "$SCANNER" ] && command -v gst-launch-1.0 >/dev/null; then
  sudo mkdir -p "$GST_ROOT/bin" "$GST_ROOT/libexec/gstreamer-1.0"
  sudo ln -sf "$(command -v gst-launch-1.0)" "$GST_ROOT/bin/gst-launch-1.0"
  # Debian does not always ship gst-device-monitor-1.0; a dangling symlink makes
  # the device enumerator spawn ENOENT on every start.
  if command -v gst-device-monitor-1.0 >/dev/null; then
    sudo ln -sf "$(command -v gst-device-monitor-1.0)" "$GST_ROOT/bin/gst-device-monitor-1.0"
  fi
  sudo ln -sfn "$ARCHLIB" "$GST_ROOT/lib"
  sudo ln -sf "$SCANNER" "$GST_ROOT/libexec/gstreamer-1.0/gst-plugin-scanner"
  sudo chown -R livi:livi "$DEST/resources/gstreamer"
else
  echo "!!! gst-launch-1.0 / gst-plugin-scanner bulunamadi — ses calismaz" >&2
fi

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

# The idle screen needs the connector cycled before it starts (see statusUi.ts:
# kmssink leaves the planes empty and LVGL's flip path shows nothing without a
# fresh modeset). Root-only sysfs writes, so a dedicated helper plus sudoers.
sudo tee /usr/local/bin/livi-display-reset >/dev/null <<'EOF'
#!/bin/sh
echo off > /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null
sleep 0.3
echo detect > /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null
EOF
sudo chmod 755 /usr/local/bin/livi-display-reset
echo "livi ALL=(root) NOPASSWD: /usr/local/bin/livi-display-reset" | sudo tee /etc/sudoers.d/011-livi-display >/dev/null
sudo chmod 440 /etc/sudoers.d/011-livi-display
sudo visudo -cf /etc/sudoers.d/011-livi-display

echo "==> passwordless sudo for the Wi-Fi AP helper"
# Same shape as LIVI's own sudoers template: python3 + the helper script path.
# The trailing * covers the helper's own arguments.
PY="$(command -v python3)"
sudo tee /etc/sudoers.d/010-livi-headless >/dev/null <<EOF
livi ALL=(root) NOPASSWD: $PY /opt/livi/resources/driver/helper/livi-helper.py*
EOF
sudo chmod 0440 /etc/sudoers.d/010-livi-headless
sudo visudo -cf /etc/sudoers.d/010-livi-headless

# pulsesink reaches PipeWire over the user runtime socket. A system service has
# neither XDG_RUNTIME_DIR nor the pulse path, so playback dies with "Connection
# refused" even though the sink is there and unmuted. Linger keeps the user
# session — and pipewire-pulse with it — alive with nobody logged in.
# GStreamer's plugin registry and Node's compile cache live here. Without a
# persistent registry GStreamer rescans every plugin on each boot — 6.8 s of a
# 18 s startup, measured on a Pi 3B+ — and because the Pi has no RTC the clock
# is behind at boot, so the registry looks stale and is rebuilt every time.
# The service therefore runs with GST_REGISTRY_UPDATE=no, which means the
# registry has to be primed here, once, while the clock is correct.
sudo install -d -o livi -g livi /var/cache/livi

echo "==> user audio session (linger + runtime socket)"
sudo loginctl enable-linger livi
LIVI_UID=$(id -u livi)

echo "==> service"
sudo cp "$UNIT_SRC" /etc/systemd/system/$SERVICE
# livi-splash (the early idle screen) is deliberately NOT installed: it only
# works with a bundle whose StatusUi adopts an already-running screen, and
# shipping the pair mismatched left an immortal DRM master that blocked every
# video pipeline with "negotiation problem" while session and audio ran fine.
# Re-enable it only together with a bundle built from patch 0004 with adoption.
sudo systemctl disable --now livi-splash.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/livi-splash.service

# The boot partition is checked on every start (~1.3 s) for no real benefit on
# an appliance that never writes to it outside an update. Check it on demand
# instead: `sudo fsck.vfat /dev/mmcblk0p1` with the unit stopped.
sudo sed -i -E 's|^(\S+\s+/boot/firmware\s+vfat\s+\S+\s+[0-9]+\s+)[0-9]+|\10|' /etc/fstab
sudo mkdir -p /etc/systemd/system/$SERVICE.d
sudo tee /etc/systemd/system/$SERVICE.d/audio.conf >/dev/null <<EOF
[Service]
Environment=XDG_RUNTIME_DIR=/run/user/$LIVI_UID
Environment=PULSE_RUNTIME_PATH=/run/user/$LIVI_UID/pulse
Environment=PULSE_SERVER=unix:/run/user/$LIVI_UID/pulse/native
EOF
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE

# Production boot: nothing on the panel until the idle screen. Keeps a
# .pre-quiet backup of cmdline.txt; skip with LIVI_SKIP_QUIET_BOOT=1.
if [ "${LIVI_SKIP_QUIET_BOOT:-0}" != "1" ]; then
  QB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/quiet-boot.sh"
  [ -f "$QB" ] && bash "$QB"
fi

echo
echo "installed. start it with:"
echo "    sudo systemctl start $SERVICE"
echo "    journalctl -u $SERVICE -f"
echo
echo "config lives at /home/livi/.config/LIVI/config.json (written on first run)."
