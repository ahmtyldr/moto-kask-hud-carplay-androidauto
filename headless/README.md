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

## Installing — the single-file way

`make-release.sh` packs the proven bundle, the installer, both units and the
quiet-boot script into one self-extracting file. That file is the product:

```bash
headless/make-release.sh                 # → headless/release/livi-pi3-kurulum.run
scp headless/release/livi-pi3-kurulum.run livi@<pi>:
ssh livi@<pi> 'bash livi-pi3-kurulum.run'
sudo reboot                              # sessiz acilis icin bir kez
```

The installer is offline-friendly: when every dependency is already present
(a reinstall, or a field restore) it skips apt entirely; on a fresh card it
pulls the packages and Node 24 itself. Verified end to end on a Pi 3B+: boots
in 16 s to the idle screen, the phone reconnects wirelessly on its own, video
plays. `LIVI_SKIP_QUIET_BOOT=1` leaves the boot console alone.

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

Verified on a Raspberry Pi 3B+ (2026-09-01): wireless and wired Android Auto,
hardware H.264 decode with zero-copy dmabuf to `kmssink`, audio out of the
3.5 mm jack, navigation and media metadata, the idle screen handing the display
over and taking it back, and mouse navigation through the phone's focus ring.

```
[CodecCapability] GStreamer codecs: h264(hw=true sw=true) h265(hw=false sw=true)
[gst_video] codec=h264 decoder=v4l2h264dec (hw) | ... ! kmssink force-modesetting=true
[gst_video] decoded format=DMA_DRM drm=YU12 1280x720 mem=memory:DMABuf
[wifi_ap] AP up — SSID='livi'  IP=10.10.0.1  channel=36
[input] evdev bridge armed (rotary mode: mouse+wheel=focus, left=select, right=back)
```

Measured during a session, against the Electron build's numbers from
`docs/pi3-video-fix.md`:

| | Electron + videoconvert | Headless + dmabuf |
|---|---|---|
| CPU | ~90 % of four cores | **~16 %** |
| Memory | 561 MB of 855 | **279 MB** |
| Temperature | 63 → 67 °C, throttling | **53 °C** |

Not yet verified: CarPlay (the stack comes up — iAP2 profiles, `:7000`, wired
watcher — but no dongle or iPhone has been connected).

## Idle screen (optional)

Without it the screen is blank until a phone connects. `statusui/` holds a
~300-line LVGL program that draws a spinner and "Cihaz bekleniyor" straight on
KMS while idle; `patches/0004-headless-status-ui.patch` wires its lifecycle
into the event-sink seam (spawned at boot, SIGTERMed when video starts so
kmssink can take the display, respawned on disconnect). Build and shipping:
[statusui/README.md](statusui/README.md). If the binary is not in the package,
everything behaves exactly as before.

## Input

`patches/0005-headless-input-bridge.patch` reads evdev directly and feeds
LIVI's own `projection-touch`/`projection-command` IPC listeners through the
shim's ipcMain. What that input has to *be* was decided by the hardware, not by
taste — measured on a Pi 3B+ with Android Auto:

| Input | Result |
|---|---|
| Touch | Works, but there is no cursor to aim with — kmssink owns the display and nothing can composite an overlay over the video |
| D-Pad keys | Reach the phone (`[INPUT] → dpad keycode 20 press+release`) and do nothing, in either announcement mode |
| Rotary ticks | Move Android Auto's own focus ring — **but only once the head unit stops announcing a touchscreen** |

Hence `patches/0006-aa-controller-input-mode.patch`: with
`LIVI_AA_TOUCHSCREEN=0` the Service Discovery Response omits the touchscreen,
the phone treats the unit as controller-driven, and it draws the focus ring
itself. That is what makes a headless unit navigable without a cursor.

Navigation is therefore one-dimensional, like a BMW/Mazda controller: mouse
right/down and wheel step the focus forward, left/up step back, left button
selects, right is Back, middle is Home. `LIVI_INPUT_MODE=touch` restores
absolute touch (for a touchscreen, or CarPlay, which negotiates input
separately); `LIVI_INPUT_BRIDGE=0` disables the bridge.

## Appliance boot

The stock cmdline sends the kernel console to tty1 — the HDMI panel — so fsck
output, kernel messages and systemd's "Starting ..." lines are printed over the
screen the rider looks at; `quiet` and `loglevel=0` do not stop them on their
own. `quiet-boot.sh` moves the console to tty3, turns off systemd's status output,
masks the tty1 login prompt and drops the splash — LIVI's installer leaves its
own Plymouth theme behind, and a second brand flashing past before our idle
screen reads as a glitch. The panel stays blank until the idle screen takes it:

```bash
./quiet-boot.sh && sudo reboot
```

Messages are not lost, only moved: `journalctl` over SSH, or tty3 with a
keyboard. The script keeps `cmdline.txt.pre-quiet`; copy it back to undo.

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
