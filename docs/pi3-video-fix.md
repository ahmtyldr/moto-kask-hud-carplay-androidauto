# Running LIVI on a Raspberry Pi 3B+

LIVI's README states that the Pi 3 is unsupported because it needs OpenGL ES 3.x and
VideoCore IV only provides ES 2.0. That reasoning does not hold up: the real blocker is a
single missing element in the GStreamer pipeline. This documents what actually fails, why,
and the workaround.

Verified on: Raspberry Pi 3B+ Rev 1.3, Raspberry Pi OS Trixie (2026-06-18, arm64 Lite),
LIVI v8.3.0, wireless Android Auto.

## The GPU is not the problem

The embedded compositor comes up fine on VideoCore IV:

```
Creating GLES2 renderer
Using OpenGL ES 2.0 Mesa 26.2.0-1~bpo13+0~rpt3
GL vendor: Broadcom
GL renderer: VC4 V3D 2.1
livi: new output -> screen 'main' at x=0 (1280x720)
```

This is consistent with the source: `native/livi-compositor/meson.build` builds wlroots with
`renderers=gles2`, and the video shader in `native/gst-video/src/gst_video.cc` is
`#version 100`, i.e. GLSL ES 1.00. Nothing in the tree requires ES 3.x — the only mentions of
"OpenGL ES 3.x" anywhere in the repository are two lines of README prose.

The UI is responsive, the wireless AA session establishes, audio and metadata flow:

```
#3  androidauto wifi ACTIVE  main:h264 cluster:h264  ip=10.10.0.39
[AaEventBridge] AAStack connected
[Session] ★ phone picked video codec: H264
[VideoChannel] stream started, session=0
```

Only the picture never appears.

## The actual failure

With `LIVI_GST_DEBUG=1` the pipeline and its error become visible:

```
[gst_video] codec=h264 decoder=v4l2h264dec (hw) | appsrc ! h264parse ! queue
            ! v4l2h264dec name=dec ! queue ! waylandsink name=sink sync=false

[gst_video] ERROR from src: Internal data stream error.
streaming stopped, reason not-negotiated (-4)
```

`waylandsink` advertises two sets of caps:

- `video/x-raw(memory:DMABuf)` — NV12, I420, YV12 and most other YUV formats
- `video/x-raw` (system memory) — **only** BGRA, BGRx, RGBx, RGBA, RGB, RGB16

On a Pi 3 the `bcm2835-codec` V4L2 decoder delivers `I420` in system memory:

```
[gst_video] decoded format=I420 1280x720 mem=memory:SystemMemory
```

System memory + YUV is in neither caps set, so negotiation fails and no frame is produced.

## Why Pi 4/5 are unaffected

`native/gst-video/src/gst_video.cc`, in `livi_create_player()`:

```cpp
std::string presink;
#if !defined(__APPLE__) && !defined(_WIN32)
  if (!is_hw_decoder(decoder)) presink = "videoconvert ! ";
#endif

std::string cal;
#if defined(__APPLE__)
  cal = "glupload ! glcolorconvert ! glshader name=cal ! ";
#endif
```

A colour converter is inserted **only for software decoders**. On a Pi 4/5 the hardware
decoder exports DMABuf, which `waylandsink` accepts directly as NV12, so the conversion is
unnecessary and correctly omitted. The GL conversion branch is macOS-only, so on Linux there
is no fallback path at all.

## Workaround

Hide the V4L2 codec devices from the kiosk service so `decoder_for()` falls through to
`avdec_h264` / `avdec_h265`. Those take the software branch and get `videoconvert` for free.

`/etc/systemd/system/livi-kiosk.service.d/livi-pi3.conf`:

```ini
[Service]
InaccessiblePaths=/dev/video10 /dev/video11 /dev/video12
```

Note that `chmod` alone is not enough — an ACL on those device nodes still grants the session
user access. `InaccessiblePaths=` is scoped to the service and is trivially reversible.

Resulting pipeline, which works:

```
[gst_video] codec=h265 decoder=avdec_h265 (sw) | ... ! videoconvert ! waylandsink
[gst_video] decoded format=I420 1280x720 mem=memory:SystemMemory
```

## Side effect: the phone starts choosing HEVC

`src/main/services/projection/services/CodecCapabilityService.ts`:

```ts
const h265Cap = p.h265.hw || (p.h265.sw && !p.h264.hw) ? { hw: true, sw: true } : undefined
```

The heuristic is "if there is no H.264 hardware decoder we are on software anyway, so we may
as well offer HEVC". Reasonable on a desktop, wrong on a Pi 3: hiding the hardware decoder
sets `p.h264.hw = false`, LIVI advertises HEVC, and the phone picks it — the most expensive
codec to decode in software, on the weakest CPU.

There is no setting to force H.264, and `avdec_h265` cannot be removed independently of
`avdec_h264` (same libav plugin).

Practical mitigation: drop `projectionFps` from 60 to 30 in `config.json`. That roughly halves
the decode load and was clearly noticeable. Dropping the stream to 800x480 produced corrupted
video (stale codec data against the new resolution) and was reverted; 1280x720@30 is the
usable setting.

## Suggested upstream fix

Either would resolve this properly and keep hardware decoding:

1. Insert `videoconvert` when the hardware decoder does not deliver DMABuf, rather than
   keying the decision purely on `is_hw_decoder()`.
2. Set `capture-io-mode=dmabuf` on the v4l2 decoders so they export DMABuf on the Pi 3 too.

Fix (1) or (2) also removes the codec problem: with the hardware decoder visible,
`p.h264.hw` is true, HEVC is not advertised, and the phone selects H.264.

## Other things worth knowing

- The README's install command pulls the installer from `main`, but the `release` channel
  installs v8.3.0. They are incompatible: the v8.3.0 AppImage bundles a sudoers template
  containing a `__PYTHON__` placeholder, and `main`'s `common.sh` dropped the substitution for
  it (the helper moved from Python to the Rust `livi-helperd`). The install aborts with
  `expected a fully-qualified path name`. Pin the installer to the tag:
  `export LIVI_INSTALLER_BRANCH=v8.3.0`.
- `~/LIVI/LIVI.log` (as documented) does not exist under the kiosk service; the real log is
  `~/.config/LIVI/log/LIVI.log`. Native `stderr` from `gst_video.cc` goes nowhere unless the
  service redirects it.
- Thermal, not power, was the limiting factor once a decent supply was used: the Pi 3B+ soft
  temperature limit at 60 °C drops the clock from 1400 to 1200 MHz (`throttled=0x80008`)
  during sustained software decoding. A heatsink is worth more than any config tweak.
