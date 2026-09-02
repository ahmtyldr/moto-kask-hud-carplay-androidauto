#!/usr/bin/env bash
# Builds the single-file installer: one .run you copy to the Pi and execute.
#
#     scp livi-pi3-kurulum.run livi@<pi>:
#     ssh livi@<pi> 'bash livi-pi3-kurulum.run'
#
# The file is a shell stub with a tar.gz payload appended: the stub extracts
# the payload (dist-headless + install.sh + units + quiet-boot) to a temp dir
# and runs install.sh, which handles everything — dependencies, Node 24, user,
# udev, sudoers, audio bridge, services, quiet boot. No other file is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/release/livi-pi3-kurulum.run}"
mkdir -p "$(dirname "$OUT")"

[ -f "$HERE/dist-headless/livi-headless.cjs" ] || {
  echo "dist-headless yok — once build-headless-bundle.sh calistir" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$HERE/dist-headless" "$STAGE/dist-headless"
cp "$HERE/install.sh" "$HERE/quiet-boot.sh" \
   "$HERE/livi-headless.service" "$HERE/livi-splash.service" "$STAGE/"

cat > "$OUT" <<'STUB'
#!/bin/bash
# LIVI Pi 3 headless — tek dosyalik kurulum. Kullanim: bash <bu-dosya>
# Root olarak DEGIL, normal kullanici olarak calistirin (sudo'yu kendisi kullanir).
set -euo pipefail
echo "== LIVI headless kurulumu =="
LINE=$(awk '/^__ARSIV__$/{print NR+1; exit}' "$0")
TMP=$(mktemp -d /tmp/livi-kurulum.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
tail -n +"$LINE" "$0" | tar xzf - -C "$TMP"
bash "$TMP/install.sh" "$TMP/dist-headless"
echo
echo "== Kurulum bitti. Baslatmak icin: sudo systemctl start livi-headless =="
echo "== Sessiz acilis icin bir kez yeniden baslatin: sudo reboot =="
exit 0
__ARSIV__
STUB

tar -czf - -C "$STAGE" . >> "$OUT"
chmod +x "$OUT"
echo "uretildi: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
