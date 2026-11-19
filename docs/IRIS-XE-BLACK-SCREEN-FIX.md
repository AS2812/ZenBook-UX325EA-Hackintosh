# Iris Xe black screen on the ZenBook UX325EA — root cause and fix

Machine: ASUS ZenBook 13 OLED UX325EA, i7‑1165G7, Iris Xe 0x9A49 (96 EU), Samsung OLED
eDP 1.4 panel. macOS Sonoma 14.8.9, WhateverXe 0.8.3, WhateverXe Graphics 0.4.4 (Sonoma
AppleIntelTGLGraphicsFramebuffer 16.0.32 donor).

## Symptom

As soon as WhateverXe loaded, the internal OLED went black. The GPU itself was healthy
(accelerator attached, EDID read, five `FB0: Complete modeset` lines), but nothing appeared
on the panel. One earlier attempt panicked with `divide error` in
`AppleIntelFramebufferController::SetupTimings` (called from `hwSetMode`).

## Evidence collected (one‑boot test guard + WhateverXe diagnostic properties)

| Test | Finding |
|---|---|
| DPCD capabilities | rev 0x14, `MAX_LINK_RATE` 0x0A (2.7 Gbps), `MAX_LANE_COUNT` 0xC2 (**2 lanes**), extended caps present, eDP 1.4 `SUPPORTED_LINK_RATES` = 1.62 / 2.7 / 5.4 Gbps. Firmware left `LANE_COUNT_SET` = 0x82 (2 lanes). |
| Link training | Apple wrote `LINK_BW_SET` 0x14 + `LANE_COUNT_SET` 0x84 (**4 lanes, 5.4 Gbps**). Lanes 0/1 reached CR_DONE, lanes 2/3 never did; training looped at maximum swing. |
| `setupOptimalLaneCount` | returned `0xE00002C7` with sink lanes = 2, lanes = 4, rate = 0x14, bpp = 24. Apple's formula gives **1 lane** for a 140 MHz mode, so its input pixel clock had to be wrong. |
| Timing records | the `IODetailedTimingInformationV2` seen by `setColorMode` / `enablePipe` contained kernel heap pointers and leftover text from WhateverXe's own property‑name buffers. Encoding and depth were 0. It was **uninitialized stack memory**. |
| Test with lanes clamped to 2 | mode‑sets finished twice as fast, then `IOAccelDisplayPipeTransaction time out after 300ms` → WindowServer stopped checking in → userspace watchdog panic. The pipe ran on garbage timings. |

## Root cause (Sonoma TGL framebuffer disassembly)

```
AppleIntelFramebuffer::setDisplayMode(int, int)
    validateDisplayMode(mode, &desc, &src)            // src = real timing
    setupDisplayTiming(src, &out)                      // out = stack buffer -0xF8(%rbp)
    ...
    AppleIntelFramebufferController::hwSetMode(fb, &out)
```

`setupDisplayTiming(src, out)` builds an AGDC request and calls the registered receiver
(`controller+0x1BF8`, event 0xC). On error it prints
`kAGDCRegisterLinkModesetCallback failed` / `returned invalid index` and **returns without
touching `out`**. Its normal path is `memmove(out, src, 0xA0)`; its override path writes
bytes 0x0C–0x95. On this machine the receiver fails every time. As a result `hwSetMode`,
`setupClocks` (`path+0x118 = timing->pixelClock`), `computeLaneCount`,
`SetupDPSSTTimings` (M/N) and `enablePipe` all run on stack garbage.

Second problem: `AppleIntelPort::getDPCDInfo()` raises the cached sink max rate
(`port[0x0F]`) to the top entry of the eDP 1.4 rate table (27000 × 200 kHz → 0x14), but
`linkTraining()` only ever programs `LINK_BW_SET` and never `LINK_RATE_SET` (0x115). This
panel limits `LINK_BW_SET` to its `MAX_LINK_RATE` 0x0A.

## Fix (WhateverXe patch, `src/WhateverXe-UX325/0001-UX325EA-eDP-timing-and-link-rate.patch`)

1. **`-wex-tgl-edp-timing`** routes `AppleIntelFramebuffer::setupDisplayTiming` and copies
   `src` into `out` (0xA0 bytes) before calling the original. All three paths now leave a
   complete, valid timing. A marker word tells the failure path apart from the normal path;
   results are published as `WEXTGLEDPTimingFirst*/Last`.
2. **`-wex-tgl-edp-lanes`**:
   - `wrapTGLReadAUX` caches the eDP sink's own `MAX_LINK_RATE` (0x001, plus 0x2201 when
     extended caps are present).
   - Right before `setupOptimalLaneCount`, after `setupPort()` has just derived `port+0x128`
     (rate) and `port+0x140` (link clock), the wrapper lowers both to the sink maximum. It
     does this only if the sink's lane count still carries the mode by Apple's own
     `computeLaneCount` rule.
   - `enableClocks` (PLL, via `port[0x114]`), `SetupDPSSTTimings` (`fb+0x4358 ← port+0x140`)
     and `linkTraining` all read these fields afterwards, so they stay consistent.
   - If Apple's lane computation still fails, the lane count is clamped to the sink's lane
     count as a fallback.

Both switches are opt-in boot-args. Without them the driver behaves exactly like upstream
0.8.3.

## Result on hardware

```
WEXTGLEDPTimingLast  : 5 mode-sets, AGDC query failed 5/5, timing rescued 5/5
                       pixel clock 140 120 000 Hz, 1920 x 1080
WEXTGLEDPRateFixLast : rate 0x14 -> 0x0A applied (bpp 30, x = 15540 < 16008)
TGLOptimalLanes      : native result 0, 2 lanes, rate 0x0A  (fallback clamp not needed)
system_profiler      : Intel Iris Xe Graphics, VRAM 1536 MB, Metal supported,
                       1920 x 1080 @ 60 Hz, 30-bit (ARGB2101010), no IOAccel time-outs
```

## Verification

- WhateverXe test suite: identical results to unmodified 0.8.3 (216 pass standalone;
  225 pass with the Sonoma donor binaries). The only test change: the mock `XE` in
  `tests/tgl_bootstrap_aux_fixture.cpp` gets the new fields.
- `harness.cpp`: 13 checks under AddressSanitizer/UBSan, compiled from the real patched
  functions against an emulation of the donor's `computeLaneCount` and the three
  `setupDisplayTiming` paths. It covers the failure, normal and override paths, 24/30/36 bpp,
  garbage timing, flag off, non‑eDP ports, extended caps and unknown rate codes.
  ```sh
  python3 extract.py /path/to/WhateverXe/kern_xe.cpp extracted.inc
  clang++ -std=c++17 -fsanitize=address,undefined harness.cpp -o harness && ./harness
  ```

## Building the patched kext

```sh
git clone https://github.com/b00t0x/WhateverXe && cd WhateverXe && git checkout 0.8.3
git apply /path/to/0001-UX325EA-eDP-timing-and-link-rate.patch
# MacKernelSDK + Lilu 1.7.2 DEBUG in the repo root, then:
python3 tools/build.py --release
```
