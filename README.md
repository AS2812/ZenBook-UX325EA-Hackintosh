# ASUS ZenBook 13 OLED (UX325EA) — macOS Sonoma Hackintosh with Iris Xe acceleration

OpenCore EFI, helper tools and a **patched WhateverXe driver** that gives the
ZenBook 13 OLED (UX325EA, Intel Core i7‑1165G7, Iris Xe 96 EU, Samsung OLED panel)
**full Metal graphics acceleration on macOS Sonoma 14.8.9**, together with working
Wi‑Fi, Apple ID, Fn hotkeys, keyboard backlight, NumberPad and trackpad gestures.

Before the patch the internal OLED stayed **black** as soon as the Tiger Lake graphics
driver loaded. The cause turned out to be a bug in Apple's own Tiger Lake framebuffer
driver: it programmed the panel from uninitialized memory. See
[docs/IRIS-XE-BLACK-SCREEN-FIX.md](docs/IRIS-XE-BLACK-SCREEN-FIX.md) for the
full investigation.

> ⚠️ **Do not use the `PlatformInfo` values as-is.** The serial number, MLB, UUID and
> ROM in every `config*.plist` are placeholders (`W00000000001`, …). Generate your own
> with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) / `macserial` (model
> `MacBookPro16,2`) before booting, or Apple ID / iMessage will not work.

---

## Hardware

| Component | Model | Driver / method | Status |
|---|---|---|---|
| CPU | Intel Core i7‑1165G7 (Tiger Lake) | SSDT‑PLUG, CpuTscSync, `revcpu`/RestrictEvents | ✅ |
| GPU | Intel Iris Xe 0x9A49 (96 EU) | **WhateverXe 0.8.3 + UX325EA patch**, AMFIAnchor, WhateverXe Graphics 0.4.4 | ✅ Metal, 1536 MB, 1920×1080 @ 60 Hz, 30‑bit |
| Display | Samsung OLED eDP 1.4 (ATNA33XC11), 2 lanes | patched link setup (2 × 2.7 Gbps) | ✅ |
| Brightness | OLED (no PWM backlight) | ZenBookHelper overlay dimming on Fn+F4/F5 | ✅ (no native slider yet) |
| Wi‑Fi | Intel AX201 | AirportItlwm 2.3.0 (native Wi‑Fi menu) | ✅ |
| Bluetooth | Intel AX201 | IntelBluetoothFirmware 2.4.0 + BlueToolFixup | driver installed |
| Audio | Realtek ALC294 | AppleALC 1.9.8, `alcid=11` | driver installed |
| Keyboard, Fn keys | PS/2 + ASUS ATK | VoodooPS2, AsusSMC, BrightnessKeys, **SSDT‑KBL** | ✅ |
| Keyboard backlight | EC | **SSDT‑KBL** (Fn+F7 cycles 0→3) | ✅ |
| Trackpad + NumberPad | ELAN I2C HID (04F3:3134) | VoodooI2C/HID + **ZenBookHelper** | ✅ tap, two‑finger, right click, NumberPad LEDs, calculator |
| SD card reader | Realtek PCIe | RealtekCardReader | driver installed |
| NVMe | SK hynix PC711 | PC711Probe (MSI‑X fix) | ✅ |
| Battery | EC | SMCBatteryManager, ECEnabler | driver installed |
| Apple ID / iCloud | — | valid SMBIOS + Wi‑Fi as built‑in `en0` | ✅ (with your own SMBIOS) |

**Not possible on macOS:** Windows Hello IR face login, Thunderbolt 4 hot‑plug of PCIe
devices (docks / eGPU).
**Not yet tested with the GPU driver:** sleep/wake, external HDMI/USB‑C monitors.

Software: OpenCore **1.0.8**, macOS **Sonoma 14.8.9 (23J631)** — WhateverXe 0.8.3 needs
exactly this build. `SecureBootModel=Disabled`, `DmgLoading=Any`. Dual boot with Windows on
the same SSD is supported (the sync script never touches `\EFI\Microsoft`).

---

## Repository layout

```
EFI/                       OpenCore EFI (copy to the USB / SSD EFI partition)
  OC/config.plist          daily profile = GPU acceleration ON  (same as config-gpu.plist)
  OC/config-gpu.plist      GPU profile
  OC/config-stable.plist   safe profile: framebuffer-only (-wexoff), no acceleration
  OC/Kexts/WhateverXe-UX325.kext   patched WhateverXe build (source: src/WhateverXe-UX325)
usb-kit/                   tools that live on the USB's data partition
  fix-hardware.sh          one script: apply fixes, --audit, --gpu-test/--gpu-keep/--gpu-off/--gpu-report
  sync-efi-to-ssd.sh       copy the EFI to the internal SSD (boot without USB), Windows-safe
  GPU-OFF.command          double-click from any Mac: back to the safe profile
  ZenBookHelper.app        brightness overlay, NumberPad, trackpad click modes, Wi-Fi watchdog
  UX325EA-RESCUE/GPU/gpu-guard.sh   one-boot GPU test guard with automatic rollback + diagnostics
  README.txt               end-user guide and full change log
src/
  ACPI/                    SSDT-KBL (Fn hotkeys, keyboard backlight), SSDT-PNLF
  ZenBookHelper/           Objective-C source + build script (universal, stable code signature)
  WhateverXe-UX325/        patch against WhateverXe 0.8.3, unit-test harness, license
docs/IRIS-XE-BLACK-SCREEN-FIX.md   root-cause analysis of the black screen
extras/config-gpu-debug.plist      GPU profile with verbose boot + display tracing
```

---

## Install

1. Create a macOS Sonoma 14.8.9 installer USB and copy `EFI/` to its EFI partition.
2. **Generate your own SMBIOS** (`MacBookPro16,2`) and put it into `PlatformInfo > Generic`
   of all three `config*.plist` files.
3. BIOS: disable Secure Boot, set SATA mode to AHCI, disable Fast Boot.
4. For the first boot copy `config-stable.plist` over `config.plist` (no GPU acceleration),
   install macOS, then copy `usb-kit/` to the USB's data partition.
5. Run the fixes as your normal user:
   ```sh
   sh "/Volumes/<USB>/fix-hardware.sh"
   ```
   Switch on *Input Monitoring* and *Accessibility* for **ZenBookHelper** when asked, restart.
6. Enable GPU acceleration:
   - download **WhateverXe Graphics 0.4.4** from the
     [WhateverXe releases](https://github.com/b00t0x/WhateverXe/releases) and place the
     `.pkg` in `usb-kit/UX325EA-RESCUE/GPU/` (not included: it contains Apple binaries);
   - `sh fix-hardware.sh --gpu-test` → restart. The guard boots the GPU profile **once**;
     if the screen stays black it records diagnostics and restarts into the safe profile
     automatically. If the screen works, click **Keep**, then run `--gpu-keep`.
7. Optional: `sudo sh sync-efi-to-ssd.sh --dry-run`, then without `--dry-run`, to boot
   without the USB.

Rollback at any time: `fix-hardware.sh --gpu-off`, or double-click `GPU-OFF.command` from
another Mac.

> Always **Eject** the USB before unplugging it. An unclean unplug can damage the
> data partition's file system.

---

## The GPU fix in one paragraph

With WhateverXe on this laptop, `AppleIntelFramebuffer::setDisplayMode()` passes
`hwSetMode()` a stack buffer that only `setupDisplayTiming()` fills. That function asks the
AGDC graphics policy for a link mode (event 0xC). On this machine the query fails every
time, and the function returns **without writing the timing**. Apple's driver then programs
the pipe from leftover stack memory. The result: garbage pixel clock → failed lane
computation → 4‑lane training on a 2‑lane panel, a divide‑error panic in `SetupTimings`,
and `IOAccelDisplayPipeTransaction time out` followed by a WindowServer watchdog panic.
The patch pre‑fills the output with the real mode timing (`-wex-tgl-edp-timing`). It also
caps the link rate at the panel's own `MAX_LINK_RATE`, because Apple writes `LINK_BW_SET`
with the eDP 1.4 rate‑table maximum (`-wex-tgl-edp-lanes`). Verified on hardware: all
5 mode‑sets rescued, 140.12 MHz 1920×1080, 2 lanes × 2.7 Gbps, Metal working.

---

## Credits

- [OpenCore](https://github.com/acidanthera/OpenCorePkg), Lilu, VirtualSMC, AppleALC,
  RestrictEvents, FeatureUnlock, CpuTscSync, DebugEnhancer, NVMeFix — Acidanthera
- [WhateverXe](https://github.com/b00t0x/WhateverXe), AMFIAnchor — b00t0x (BSD‑3‑Clause;
  see `src/WhateverXe-UX325/LICENSE-WhateverXe.txt`)
- [OpenIntelWireless](https://github.com/OpenIntelWireless) — AirportItlwm, IntelBluetoothFirmware
- [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C), VoodooPS2 — VoodooI2C / Acidanthera
- AsusSMC, BrightnessKeys, ECEnabler, RealtekCardReader(Friend), PC711Probe — their respective authors
- [Dortania guides](https://dortania.github.io/OpenCore-Install-Guide/)

Third-party kexts and drivers keep their own licenses. This project is not affiliated with
Apple, ASUS or Intel. Use at your own risk.
