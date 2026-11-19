# WhateverXe 0.8.3 — UX325EA eDP patch

`0001-UX325EA-eDP-timing-and-link-rate.patch` applies to
[WhateverXe](https://github.com/b00t0x/WhateverXe) **0.8.3** (`git apply` or `patch -p1`).

| Boot-arg | What it does |
|---|---|
| `-wex-tgl-edp-timing` | Routes `AppleIntelFramebuffer::setupDisplayTiming` and pre-fills its output timing with the requested mode, so a failed AGDC link-modeset query can no longer leave `hwSetMode()` running on uninitialized stack memory. Publishes `WEXTGLEDPTimingFirst*/Last`. |
| `-wex-tgl-edp-lanes` | Caches the eDP sink's `MAX_LINK_RATE` (DPCD 0x001 / 0x2201). Before Apple's lane computation it lowers the port rate and link clock to that value when the sink's lane count still carries the mode (`WEXTGLEDPRateFixLast`). If the computation fails anyway, it clamps the lane count to the sink's lanes as a fallback (`WEXTGLEDPLaneFixLast`). |

Without these boot-args the driver behaves exactly like upstream 0.8.3.

Files:
- `harness.cpp` + `extract.py` — standalone checks of the patched functions (ASan/UBSan):
  `python3 extract.py WhateverXe/kern_xe.cpp extracted.inc && clang++ -std=c++17 -fsanitize=address,undefined harness.cpp -o harness && ./harness`
- `LICENSE-WhateverXe.txt` — WhateverXe license (BSD-3-Clause); the patch is under the same license.

Build: put MacKernelSDK and Lilu 1.7.2 (DEBUG) in the repo root, then run `python3 tools/build.py --release`.
The build reproduces `EFI/OC/Kexts/WhateverXe-UX325.kext` (identical `__text`/`__const`/`__cstring`/`__data`; only LC_UUID differs).

Root-cause write-up: [../../docs/IRIS-XE-BLACK-SCREEN-FIX.md](../../docs/IRIS-XE-BLACK-SCREEN-FIX.md)
