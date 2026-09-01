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

`sink_chain()` reads an environment variable and pastes its value into the pipeline
description verbatim, so an arbitrary chain can be injected there — not just a single
element:

```cpp
const char* sink_env = getenv("LIVI_GST_SINK");                     // gst_video.cc:259
return std::string(sink_env && *sink_env ? sink_env : "waylandsink")
     + " name=sink sync=false";
```

That is enough to insert the missing converter without touching the decoder, so the codec
devices stay visible and the hardware decoder is still selected.

`/etc/systemd/system/livi-kiosk.service.d/livi-pi3.conf`:

```ini
[Service]
Environment="LIVI_GST_SINK=video/x-raw ! videoconvert n-threads=4 ! waylandsink"
```

The bare `video/x-raw` capsfilter is the part that matters, and it is easy to leave out.
Injecting `videoconvert` alone does **not** work: negotiation still settles on DMABuf and
fails identically, with the decoder producing nothing at all. Pinning the caps to plain
system memory — which is what the decoder actually delivers — is what makes the two ends
agree. Both variants were measured; only the one with the capsfilter negotiates.

`Environment=` must be quoted as a whole, or systemd splits the value on whitespace and
`n-threads=4` is parsed as a second assignment. `n-threads` also needs a videoconvert that
carries the property; the GStreamer 1.28.4 bundled in the v8.3.0 AppImage does:

```bash
strings .../gstreamer-1.0/libgstvideoconvertscale.so | grep -x n-threads
```

Resulting pipeline, verified on a Pi 3B+ with wired Android Auto:

```
[gst_video] codec=h264 decoder=v4l2h264dec (hw) | appsrc ! h264parse ! queue
            ! v4l2h264dec name=dec ! queue leaky=downstream
            ! video/x-raw ! videoconvert n-threads=4 ! waylandsink
[gst_video] decoded format=I420 1280x720 mem=memory:SystemMemory
[Session] ★ phone picked video codec: H264 (offered: h264)
```

No `not-negotiated` errors, and the phone is never offered HEVC, because `p.h264.hw` stays
true with the codec nodes visible.

### What it costs, and what is left

Decoding is back on the VideoCore IV, but the frames still take a copy out of the decoder's
CMA buffer and a colour conversion on the way to the sink. Measured during a session,
already thermally capped at 1.2 GHz:

| | |
|---|---|
| `livi-gst-host` | ~190 % CPU (about two cores) |
| All four cores | ~90 % busy, 10 % idle |
| SoC temperature | 62.8 → 66.6 °C over four minutes |
| `vcgencmd get_throttled` | `0x80008` — soft temperature limit active |
| Memory | 561 MB of 855 MB used, no swap pressure |

So the HEVC-in-software problem is traded for an RGB conversion, which is much cheaper but
not free. `patches/0003-pi3-dmabuf-capture.patch` removes both the copy and the conversion
by making the decoder export dmabuf, which `waylandsink` accepts as I420 directly.

### Earlier workaround, kept as a fallback

Hiding the V4L2 codec devices makes `decoder_for()` fall through to `avdec_h264` /
`avdec_h265`, which take the software branch and get `videoconvert` for free:

```ini
[Service]
InaccessiblePaths=/dev/video10 /dev/video11 /dev/video12
```

Note that `chmod` alone is not enough — an ACL on those device nodes still grants the session
user access. `InaccessiblePaths=` is scoped to the service and is trivially reversible.

This draws a picture, but it gives up hardware decoding and triggers the codec problem
below. Use it only if the injection above stops negotiating.

## Side effect of the fallback: the phone starts choosing HEVC

`src/main/services/projection/services/CodecCapabilityService.ts`:

```ts
const h265Cap = p.h265.hw || (p.h265.sw && !p.h264.hw) ? { hw: true, sw: true } : undefined
```

The heuristic is "if there is no H.264 hardware decoder we are on software anyway, so we may
as well offer HEVC". Reasonable on a desktop, wrong on a Pi 3: hiding the hardware decoder
sets `p.h264.hw = false`, LIVI advertises HEVC, and the phone picks it — the most expensive
codec to decode in software, on the weakest CPU.

There is no setting to force H.264, and `avdec_h265` cannot be removed independently of
`avdec_h264` (same libav plugin). The `LIVI_GST_SINK` fix above avoids this entirely: with
the codec nodes visible, `p.h264.hw` is true and HEVC is never advertised.

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
