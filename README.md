# ASUS ZenBook 13 OLED (UX325EA) — macOS Sonoma Hackintosh with Iris Xe acceleration

OpenCore EFI, ACPI patches, helper tools and **patched drivers** for the ZenBook 13 OLED
(UX325EA, Intel Core i7‑1165G7, Iris Xe 96 EU, Samsung OLED). It gives **full Metal graphics
acceleration on macOS Sonoma 14.8.9** and **real OLED brightness**, with the Control Centre slider
and native keys. It also makes these work: Wi‑Fi, Bluetooth, sleep with the lid or the power
button, every Fn key (including after sleep), the keyboard backlight, the NumberPad and
trackpad gestures.

Before these patches:
* the internal OLED stayed **black** as soon as the Tiger Lake graphics driver loaded (a bug in
  Apple's own framebuffer driver, see [docs/IRIS-XE-BLACK-SCREEN-FIX.md](docs/IRIS-XE-BLACK-SCREEN-FIX.md));
* the brightness keys did nothing (an OLED has no PWM backlight);
* volume and mute died after every sleep.

See [docs/OLED-BRIGHTNESS-KEYS-SLEEP.md](docs/OLED-BRIGHTNESS-KEYS-SLEEP.md).

> ⚠️ **Do not use the `PlatformInfo` values as-is.** The serial number, MLB, UUID and
> ROM in every `config*.plist` are placeholders (`W00000000001`, …). Generate your own
> with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) / `macserial` (model
> `MacBookPro16,2`) before booting, or Apple ID / iMessage will not work.

---

## Hardware

| Component | Model | Driver / method | Status |
|---|---|---|---|
| CPU | Intel Core i7‑1165G7 (Tiger Lake) | SSDT‑PLUG, CpuTscSync, `revcpu`/RestrictEvents | ✅ |
| GPU | Intel Iris Xe 0x9A49 (96 EU) | **WhateverXe 0.8.3 + UX325EA patch v4.3**, AMFIAnchor, WhateverXe Graphics 0.4.4 | ✅ Metal, 1536 MB, 1920×1080 @ 60 Hz, 30‑bit |
| Display | Samsung OLED eDP 1.4 (ATNA33XC11), 2 lanes | patched link setup (2 × 2.7 Gbps) | ✅ |
| Brightness | OLED, Intel DPCD nits interface | patch `-wex-tgl-edp-bl` + **SSDT‑PNLF `_UID` 19** | ✅ real panel brightness, Control Centre slider, Fn+F4/F5, bezel, 0 = black |
| Wi‑Fi | Intel AX201 | AirportItlwm 2.3.0 (native Wi‑Fi menu) + helper watchdog | ✅ |
| Bluetooth | Intel AX201 | IntelBluetoothFirmware 2.4.0 + BlueToolFixup, NVRAM fix, `-btlfxallowanyaddr`, USB map | ✅ (cold boot after Windows) |
| Audio | Realtek ALC294 | AppleALC 1.9.8, `alcid=11`; helper enforces mute | ✅ speakers, headphones; mute/unmute with bezel |
| Microphone (built‑in) | digital mic on Intel's audio DSP | — | ❌ not possible on macOS (use headset jack / Bluetooth / USB mic) |
| Keyboard, Fn keys | PS/2 + ASUS ATK | VoodooPS2, AsusSMC, **BrightnessKeys‑UX325**, **SSDT‑KBL**, **SSDT‑WAKE** | ✅ brightness, volume, mute — also after sleep |
| Keyboard backlight | EC | **SSDT‑KBL** (Fn+F7 cycles 0→3) | ✅ |
| Trackpad + NumberPad | ELAN I2C HID (04F3:3134) | VoodooI2C/HID + **ZenBookHelper** | ✅ tap, two‑finger menu, gestures, NumberPad + calculator |
| Sleep / wake | S3 | power button → sleep (helper), lid, password after wake | ✅ power button; lid: fix in v10.0 (driver v4.3 + helper 8.15) |
| Shut Down | — | `SSDT-WAKE` (XHCI PME off) | ✅ apps close, then off |
| Webcam | USB (HS06, internal) | USB map | ✅ |
| SD card reader | Realtek PCIe | RealtekCardReader(Friend) | driver installed |
| NVMe | SK hynix PC711 | PC711Probe | ✅ |
| Battery | EC | SMCBatteryManager, ECEnabler | ✅ |
| Apple ID / iCloud | — | valid SMBIOS + Wi‑Fi as built‑in `en0` | ✅ (with your own SMBIOS) |

**Not possible on macOS:** built‑in microphone (Intel DSP), Windows Hello IR face login,
Thunderbolt 4 hot‑plug of PCIe devices (docks / eGPU).
**Not tested:** external HDMI / USB‑C monitors.

Software: OpenCore **1.0.8**, macOS **Sonoma 14.8.9 (23J631)** — WhateverXe 0.8.3 needs
exactly this build. `SecureBootModel=Disabled`, `DmgLoading=Any`. Dual boot with Windows on
the same SSD is supported (the sync script never touches `\EFI\Microsoft`).

---

## Repository layout

```
EFI/OC/config.plist          daily profile: GPU acceleration + every fix (= config-gpu.plist)
EFI/OC/config-gpu.plist      the same (used by fix-hardware.sh --gpu-keep / the GPU guard)
EFI/OC/config-stable.plist   safe profile: same fixes, no acceleration (-wexoff), verbose boot
EFI/OC/ACPI/                 SSDT-KBL (Fn keys, keyboard light), SSDT-PNLF (_UID 19),
                             SSDT-WAKE (volume/mute route, ATK queue, wake/shutdown hooks), ...
EFI/OC/Kexts/WhateverXe-UX325-v4.kext   patched WhateverXe (src/WhateverXe-UX325)
EFI/OC/Kexts/BrightnessKeys-UX325.kext  BrightnessKeys 1.0.3 + volume/mute codes (src/BrightnessKeys-UX325)
EFI/OC/Kexts/USBMap-UX325EA.kext        codeless USB map: Bluetooth (HS10) + webcam (HS06) internal
usb-kit/                     tools for the USB's data partition
  fix-hardware.sh            apply fixes, --test (guided test + report), --audit, --diagnose, --gpu-*
  sync-efi-to-ssd.sh         copy the EFI to the internal SSD (boot without USB), Windows-safe
  ZenBookHelper.app          power button, mute, NumberPad, wake brightness, Wi-Fi watchdog
  UX325EA-RESCUE/GPU/gpu-guard.sh   one-boot GPU test guard with automatic rollback
  README.txt                 end-user guide and full change log
src/                         ACPI sources, driver patches + test harnesses, helper source, USB map
docs/                        root-cause write-ups
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
   Switch on *Input Monitoring* and *Accessibility* for **ZenBookHelper** when asked, then restart.
6. GPU acceleration: download **WhateverXe Graphics 0.4.4** from the
   [WhateverXe releases](https://github.com/b00t0x/WhateverXe/releases) and place the `.pkg` in
   `usb-kit/UX325EA-RESCUE/GPU/` (not included: it contains Apple binaries). Then run
   `sh fix-hardware.sh --gpu-test` and restart. The guard boots the GPU profile **once**: if the
   screen stays black, it records diagnostics and returns to the safe profile by itself. If the
   screen works, click **Keep**.
7. Test everything from the USB: `sh fix-hardware.sh --test` guides brightness, slider, volume,
   mute, two-finger menu, lid and power-button sleep, Wi-Fi, and saves a report. When it says
   **EVERYTHING WORKS**:
   ```sh
   sudo sh "/Volumes/<USB>/sync-efi-to-ssd.sh" --launcher-full
   ```
   This copies the setup to the internal SSD and leaves `\EFI\Microsoft` untouched. Shut down,
   unplug the USB and power on: Apple logo → macOS, like a real Mac. Hold **Option (Alt)** at
   power-on for the boot menu (Windows, recovery).

Rollback at any time: `fix-hardware.sh --gpu-off`, or double-click `GPU-OFF.command` from
another Mac.

> Always **Eject** the USB before unplugging it. An unclean unplug can damage the
> data partition's file system.

---

## Credits

- [OpenCore](https://github.com/acidanthera/OpenCorePkg), Lilu, VirtualSMC, AppleALC,
  RestrictEvents, FeatureUnlock, CpuTscSync, DebugEnhancer, NVMeFix, BrightnessKeys, VoodooPS2 — Acidanthera
- [WhateverXe](https://github.com/b00t0x/WhateverXe), AMFIAnchor — b00t0x (BSD‑3‑Clause;
  see `src/WhateverXe-UX325/LICENSE-WhateverXe.txt`)
- [OpenIntelWireless](https://github.com/OpenIntelWireless) — AirportItlwm, IntelBluetoothFirmware
- [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C) — VoodooI2C / Acidanthera
- AsusSMC, ECEnabler, RealtekCardReader(Friend), PC711Probe — their respective authors
- [Dortania guides](https://dortania.github.io/OpenCore-Install-Guide/)

Third-party kexts and drivers keep their own licenses. This project is not affiliated with
Apple, ASUS or Intel. Use at your own risk.
