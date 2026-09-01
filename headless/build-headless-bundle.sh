#!/bin/bash
# Builds the headless LIVI bundle (patches 0002+0003+0004) in an arm64 container.
# v8.3.0 reality (verified via source): helper is PYTHON at
# resources/driver/helper/livi-helper.py (no Rust livi-helperd at this tag),
# protos live in src/main/services/projection/driver/aa/protos/ and are looked
# up at <resources>/aa/protos/aap_protobuf at runtime.
# Expects the moto-kask repo mounted at /host; output -> /host/headless/dist-headless.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "### [1/6] apt deps"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential python3 pkg-config \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libusb-1.0-0-dev libudev-dev >/dev/null

echo "### [2/6] node 24 + pnpm"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs >/dev/null
corepack enable
corepack prepare pnpm@11.24.0 --activate 2>/dev/null || corepack prepare pnpm@latest --activate
node --version; pnpm --version

echo "### [3/6] clone LIVI v8.3.0 + patches"
cd /root
git clone -q --depth 1 --branch v8.3.0 https://github.com/f-io/LIVI.git 2>/dev/null
cd LIVI
for p in 0002 0003 0004 0005 0006; do
  echo "  applying $p"
  git apply /host/patches/${p}-*.patch
done

echo "### [4/6] pnpm install (electron binary indirilmez)"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
pnpm install --frozen-lockfile 2>&1 | tail -2

echo "### [5/6] native modules (Node ABI)"
( cd native/gst-video && npx node-gyp rebuild 2>&1 | tail -1 )
( cd native/crypto    && npx node-gyp rebuild 2>&1 | tail -1 )

echo "### [6/6] bundle + assemble"
node scripts/build-headless.mjs

DRIVER_SRC=src/main/services/projection/driver
DIST=/host/headless/dist-headless
rm -rf "$DIST"
mkdir -p "$DIST/native" "$DIST/resources/driver" "$DIST/resources/aa/protos" "$DIST/statusui" "$DIST/node_modules"
cp out-headless/livi-headless.cjs                       "$DIST/"
cp out-headless/livi-headless.cjs.map                   "$DIST/" 2>/dev/null || true
cp native/gst-video/build/Release/*.node                "$DIST/native/"
cp native/crypto/build/Release/*.node                   "$DIST/native/"
# v8.3.0 helper: whole python helper dir -> <resources>/driver/helper/
cp -r "$DRIVER_SRC/helper"                              "$DIST/resources/driver/"
rm -rf "$DIST/resources/driver/helper/__tests__"
cp -r "$DRIVER_SRC/shared" "$DIST/resources/driver/"
cp -r "$DRIVER_SRC/bt" "$DIST/resources/driver/"
cp -r "$DRIVER_SRC/cp" "$DIST/resources/driver/"
find "$DIST/resources/driver" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
rm -rf "$DIST/resources/driver/shared/__pycache__"
# AA protobuf tree -> <resources>/aa/protos/aap_protobuf (+ oaa, same tree)
cp -r "$DRIVER_SRC/aa/protos/." "$DIST/resources/aa/protos/"
# probably installer-only, but cheap to carry
cp scripts/install/packages.txt "$DIST/resources/" 2>/dev/null || true
cp -rL node_modules/usb                                  "$DIST/node_modules/"
cp -rL node_modules/@node-usb "$DIST/node_modules/" 2>/dev/null || true
cp -rL node_modules/node-gyp-build "$DIST/node_modules/" 2>/dev/null || true
cp -rL node_modules/bindings "$DIST/node_modules/" 2>/dev/null || true
# gst-video as a REAL package: gstHost.ts finds the livi-gst-host binary via
# require.resolve('gst-video') -> <pkg>/build/Release/livi-gst-host. Without
# this the codec probe returns null and every codec reports unsupported.
mkdir -p "$DIST/node_modules/gst-video/build/Release"
cp native/gst-video/package.json native/gst-video/index.js "$DIST/node_modules/gst-video/"
cp native/gst-video/build/Release/gst_video.node "$DIST/node_modules/gst-video/build/Release/"
cp native/gst-video/build/Release/livi-gst-host  "$DIST/node_modules/gst-video/build/Release/" 2>/dev/null || echo "UYARI: livi-gst-host binari yok!"
cp /host/headless/statusui/build/livi-statusui          "$DIST/statusui/"

echo "=== SONUC ==="
find "$DIST" -name '*.proto' | wc -l | xargs echo "proto dosyasi:"
du -sh "$DIST"
ls -la "$DIST" "$DIST/resources/driver/helper" | head -25
echo "BUILD OK"
