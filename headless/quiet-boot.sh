#!/usr/bin/env bash
# Appliance boot: nothing on screen until the idle screen takes over.
#
# The stock cmdline sends the kernel console to tty1, which is the HDMI screen,
# so fsck output, kernel messages and systemd's "Starting ..." lines are printed
# over the display a rider is meant to look at. quiet/loglevel=0 alone do not
# stop them — systemd's status output and anything at KERN_ERR still lands
# there. Moving the console to tty3 keeps the messages (readable over SSH with
# journalctl, or on tty3 with a keyboard) but off the panel.
#
# Idempotent: safe to run repeatedly, keeps one .pre-quiet backup.
set -euo pipefail

CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || { echo "$CMDLINE yok" >&2; exit 1; }

[ -f "$CMDLINE.pre-quiet" ] || sudo cp "$CMDLINE" "$CMDLINE.pre-quiet"

# cmdline.txt must stay a single line — build it as one and write it back whole.
line=$(tr -d '\n' < "$CMDLINE")
line=${line//console=tty1/console=tty3}
# LIVI's own installer leaves a Plymouth theme behind, so the stock boot shows
# its logo before anything of ours appears. Drop the splash entirely: this build
# has its own idle screen and a second brand flashing past first looks like a
# glitch. plymouth.enable=0 covers the case where something re-adds `splash`.
line=${line// splash/}
for opt in quiet loglevel=0 logo.nologo vt.global_cursor_default=0 \
           systemd.show_status=0 rd.systemd.show_status=0 plymouth.enable=0; do
  case " $line " in
    *" $opt "*) ;;
    *) line="$line $opt" ;;
  esac
done
printf '%s\n' "$line" | sudo tee "$CMDLINE" >/dev/null

# A login prompt on the panel would defeat the point; the unit is administered
# over SSH. mask, not disable, so nothing pulls it back in.
sudo systemctl mask getty@tty1.service >/dev/null 2>&1 || true

# plymouth-quit-wait holds multi-user.target until the splash is torn down, which
# is dead time on a unit that shows no splash at all.
sudo systemctl mask plymouth-quit-wait.service >/dev/null 2>&1 || true

echo "yeni cmdline:"
cat "$CMDLINE"
echo
echo "yedek: $CMDLINE.pre-quiet — geri almak icin uzerine kopyalayin"
echo "yeniden baslatinca ekranda sadece bekleme ekrani gorunur."
