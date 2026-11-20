# WhateverXe 0.8.3 — UX325EA patch (v4.6)

`0001-UX325EA-v4.6-full.patch` applies to
[WhateverXe](https://github.com/b00t0x/WhateverXe) **0.8.3** (`git apply` or `patch -p1`).
It produces `EFI/OC/Kexts/WhateverXe-UX325-v4.kext`. Every change is opt-in by boot-arg:
without them the driver behaves exactly like upstream 0.8.3.

| Boot-arg | What it does |
|---|---|
| `-wex-tgl-edp-timing` | Routes `AppleIntelFramebuffer::setupDisplayTiming` and pre-fills its output timing with the requested mode, so a failed AGDC link-modeset query can no longer leave `hwSetMode()` running on uninitialized stack memory. Publishes `WEXTGLEDPTimingFirst*/Last`. |
| `-wex-tgl-edp-lanes` | Caches the eDP sink's `MAX_LINK_RATE` (DPCD 0x001 / 0x2201). Before Apple's lane computation it lowers the port rate and link clock to that value when the sink's lane count still carries the mode (`WEXTGLEDPRateFixLast`). If the computation fails anyway, it clamps the lane count to the sink's lanes (`WEXTGLEDPLaneFixLast`). |
| `-wex-tgl-edp-bl` | **Real OLED brightness.** Routes `AppleIntelFramebufferController::hwSetBacklight`. The donor framebuffer only drives the PCH PWM (0xC8258), which an OLED ignores. The patch sets the panel's own brightness over DPCD: Intel's HDR/OLED interface (0x340–0x357: enable 0x344 bit 4, nits in 0x354/0x355, as Linux `intel_dp_aux_backlight.c`), range 0..EDID max luminance (CTA HDR metadata, 616 nits on the ATNA33XC11), otherwise VESA eDP AUX brightness. Publishes `WEXTGLEDPBacklightCaps/Last/Reapply` and `WEXTGLEDPPanelDPCD`. |
| `-wex-tgl-edp-bl-vesa` | Forces the VESA registers even when the Intel interface is present (diagnosis). |
| `-wex-tgl-edp-bl-zero` | Brightness 0 = panel black (MacBook behaviour). Without it the lowest level keeps 0.5 % of the maximum (3 nits). |

Always active with `-wex-tgl-edp-bl` (no extra boot-arg):

* **v4.4 – panel off at shutdown.** A priority sleep/wake handler writes nits 0 (DPCD 0x354) on
  power-off/restart, so the OLED goes black instead of showing stale (green) pixels while the
  system powers down. `WEXTGLEDPBacklightHistory` keeps the last 24 brightness writes.
* **v4.6 – clean loading screen.** WhateverXe copies the boot/login console image back into the
  framebuffer. That image is 8-bit XRGB, the framebuffer is 30-bit ARGB2101010, so a raw copy
  showed yellow/green noise. The copy now converts each pixel to 10 bits per colour when the
  framebuffer is 30-bit. `WEXFramebufferInit` = {calls, copies, zero fills, converted, ms, vram}.

v4.3 also re-sends the last requested brightness at panel power-on (DPCD `SET_POWER` D0) when
macOS asked for it while the panel was still unpowered — on lid open the panel otherwise stayed
at the 0 nits written on lid close. Every off/on change is logged as `UX325 panel brightness`.

The upstream `AppleIntelPanel::setDisplay` hook adds its 16-bit brightness curve only for
`SSDT-PNLF` with `_UID` **19** (0x13): that is what gives macOS its "brightness" parameter
(Control Centre slider, native keys and bezel).

Files:
- `harness.cpp` + `extract.py` — standalone checks of the timing / lane functions (13 checks, ASan/UBSan):
  `python3 extract.py WhateverXe/kern_xe.cpp extracted.inc timing && clang++ -std=c++17 -fsanitize=address,undefined harness.cpp -o harness && ./harness`
- `test4/harness4.cpp` — OLED brightness: Intel nits / VESA selection, EDID maximum, floor vs `-zero`,
  skipped write while the panel is off + re-send at power-on (9 checks):
  `python3 ../extract.py WhateverXe/kern_xe.cpp extracted.inc all` + `kern_edp_aux_backlight.hpp` from the source, then build like above.
- `LICENSE-WhateverXe.txt` — WhateverXe license (BSD-3-Clause); the patch is under the same license.

Build: put MacKernelSDK and Lilu 1.7.2 (DEBUG) in the repo root, then `python3 tools/build.py --release`.
WhateverXe's own test suite: 216 passed; the same 5 tests fail with and without the patch on a
non-Intel build machine (they need the Sonoma donor binaries).

Root-cause write-ups: [../../docs/IRIS-XE-BLACK-SCREEN-FIX.md](../../docs/IRIS-XE-BLACK-SCREEN-FIX.md),
[../../docs/OLED-BRIGHTNESS-KEYS-SLEEP.md](../../docs/OLED-BRIGHTNESS-KEYS-SLEEP.md)
