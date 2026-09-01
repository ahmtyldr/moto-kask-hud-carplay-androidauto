# Headless LIVI — projection without Electron

Boots straight into CarPlay / Android Auto and puts the picture on screen. No
Chromium, no React, no settings UI.

## Why this works at all

LIVI's video never went through Chromium. The pipeline is
`appsrc → parser → decoder → waylandsink`, so the renderer only ever drew the
menus. Dropping it costs the settings screens, not the picture.

And the projection core barely touches Electron. Of 199 files under `src/main`
only 42 import it, and inside `services/projection/driver` just 6 do — mostly for
`app.getPath()`. What they reach for beyond that (`BrowserWindow`, `dialog`,
`shell`, `screen`) is UI surface an appliance never calls.

So this is a shim, not a rewrite: `electron` is aliased to a ~270-line Node
implementation and **the 54,454 lines of LIVI TypeScript are used unmodified**.

| | Electron build | Headless |
|---|---|---|
| Artifact | 308 MB AppImage | **16 MB** |
| Bundle | — | 990 KB |
| Runtime | Electron (~400 MB RSS) | Node |
| Lines written | — | ~425 |
| Lines of LIVI changed | — | **0** |

## What is in the patch

`patches/0002-headless-no-electron.patch` adds four files and edits nothing:

| File | Role |
|---|---|
| `src/main/headless/electronShim.ts` | Electron API on plain Node |
| `src/main/headless/bootstrapPaths.ts` | Publishes `process.resourcesPath` |
| `src/main/headless/index.ts` | Entry point: the projection chain only |
| `scripts/build-headless.mjs` | esbuild bundle with the `electron` alias |

Two details that are easy to miss and break things silently:

- **`process.resourcesPath` is an Electron invention.** Nine call sites read it
  to locate `livi-helperd`, the Android Auto protobuf definitions and
  `packages.txt`. Unset, the codec probe fails with *"path must be of type
  string"* and every codec reports unsupported.
- **The `.proto` files are read from disk at runtime**, not bundled. All 254 of
  them must ship under `resources/aa/protos/aap_protobuf/`. Without them Android
  Auto cannot parse a single message.

## Building

Needs a Linux arm64 environment (a container is fine). Node 24, Rust, and the
GStreamer dev headers.

```bash
git clone https://github.com/f-io/LIVI.git && cd LIVI
git checkout v8.3.0
git apply /path/patches/0002-headless-no-electron.patch
pnpm install --frozen-lockfile

# native addons against the NODE ABI, not Electron's
( cd native/gst-video && npx node-gyp rebuild )
( cd native/crypto   && npx node-gyp rebuild )

node scripts/build-headless.mjs
```

No Rust: at v8.3.0 the privileged helper is still Python
(`src/main/services/projection/driver/helper/livi-helper.py`; the Rust
`livi-helperd` only exists on `main`). helperSupervisor.ts resolves it at
`<resources>/driver/helper/livi-helper.py` and runs it with the system
`python3`. Then assemble:

```
dist-headless/
├── livi-headless.cjs
├── native/{gst_video,livi_crypto}.node
├── node_modules/{usb,@node-usb}
├── statusui/livi-statusui          ← optional idle screen
└── resources/
    ├── driver/helper/livi-helper.py (whole helper/ dir)
    ├── aa/protos/aap_protobuf/     ← 254 .proto files
    └── packages.txt
```

`build-headless-bundle.sh` (bu klasörde) akışın tamamını arm64 konteynerde
koşturur — klon, yamalar, native derleme, bundle ve assemble dahil:

```bash
docker run --rm -i --platform linux/arm64 \
  -v "$(git rev-parse --show-toplevel)":/host \
  debian:trixie bash < headless/build-headless-bundle.sh
```

## Installing

```bash
./install.sh /path/to/dist-headless
sudo systemctl start livi-headless
journalctl -u livi-headless -f
```

`install.sh` also lays down the udev rules. Those matter: a phone re-enumerates
under Google's vendor id (`18d1`) when it switches to AOAP, and without a rule
for that id the handshake dies with `LIBUSB_ERROR_ACCESS` after the phone has
already been detected.

## Status

Verified in an arm64 container: builds, starts, probes codecs, opens the CarPlay
listener on :7000, scans USB, shuts down cleanly.

```
[headless] resources: /opt/livi/resources
[CodecCapability] GStreamer codecs: h264(hw=false sw=true) h265(hw=false sw=true)
[CpManager] listening on :7000 (dual-stack)
[headless] projection armed — waiting for a phone
```

**Not yet verified on real hardware.** `hw=false` above is the container having
no V4L2 devices; on a Pi the probe should find `v4l2h264dec`. Whether a phone
actually connects and paints a frame is untested.

## Idle screen (optional)

Without it the screen is blank until a phone connects. `statusui/` holds a
~300-line LVGL program that draws a spinner and "Cihaz bekleniyor" straight on
KMS while idle; `patches/0004-headless-status-ui.patch` wires its lifecycle
into the event-sink seam (spawned at boot, SIGTERMed when video starts so
kmssink can take the display, respawned on disconnect). Build and shipping:
[statusui/README.md](statusui/README.md). If the binary is not in the package,
everything behaves exactly as before.

## Input (optional)

`patches/0005-headless-input-bridge.patch` reads evdev directly and feeds
LIVI's own `projection-touch`/`projection-command` IPC listeners through the
shim's ipcMain: mouse = touch/drag, wheel = knob, right-click = Back, keyboard
arrows/Enter = D-Pad/Select, Space = play/pause, V = voice assistant. No
pointer is drawn (kmssink owns the display), so wheel/keyboard — which AA
answers with its own focus ring — is the usable idiom; a cursor overlay would
need the DRM cursor plane from the gst host. Disable with `LIVI_INPUT_BRIDGE=0`.

## Configuration

There is no UI. `~/.config/LIVI/config.json` is written on first run and holds
all 110 settings — wireless AA/CP, hotspot band and channel, stream resolution
and fps, safe areas. Edit it and restart the service.

A settings page served to the driver's phone is the obvious next step; LIVI
already carries the IPC layer it would attach to.

## Licence

LIVI is GPL-3.0-or-later and so is anything built from it. **Selling a device
with this software obliges you to give every buyer the complete corresponding
source, including your own changes**, and §6 requires the information needed to
install modified versions on the device.
