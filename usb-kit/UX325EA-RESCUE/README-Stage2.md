# ASUS ZenBook 13 OLED UX325EA — STAGE 2
## Display brightness, ASUS Fn hotkeys, keyboard backlight, and experimental Iris Xe acceleration

**Prepared:** 18 November 2026  
**Starting point:** The Stage 1 OpenCore USB boots the existing macOS volume **macOS**, with a visible 1920×1080 internal OLED display. Screen-brightness hotkeys and keyboard-backlight controls are not working.  
**Purpose:** A *post-baseline implementation and validation plan*, expanded with a full Stage 2F experimental 1080p60/Metal path, OpenCore configuration preflight, and measurable acceptance tests. This document is **not a verified hardware-specific patch, executable EFI, or promise of 60 FPS in every app**.

> **Hard rule:** Do not overwrite the working EFI or modify the internal SSD's EFI. A USB boot profile can be recovered from, but **WhateverXe Graphics is installed into macOS itself**, so reverting graphics can also require its official uninstall procedure.

---

## 0. What is verified vs. not verified

**Verified from the user's test:** The current USB boots macOS and the internal OLED produces a usable picture. The reported brightness-related functions do not work.

**Verified from ASUS UX325EA manual:** F4 = screen brightness down; F5 = up; F7 = keyboard-backlight level; Fn+Esc toggles function key behavior (on supported firmware); F6 toggles touchpad. Source: https://dlcdnets.asus.com/pub/ASUS/nb/UX325EA/0409_E19336_UX325_425EA_Win11_A.pdf

**Verified from project documentation:** BrightnessKeys catches ACPI video brightness events, not every manufacturer-specific key by magic. AsusSMC requires a compatible ASUS ATK interface and appropriate DSDT/ACPI patches. WhateverXe graphics requires a compatible macOS build, kext/graphics-package pairing, an AMFI signing configuration, and a conditional DVMT setup.

**Not verified on this individual laptop:** The actual ASUS ATK/WMI ACPI namespace and method names; a model-specific keyboard backlight write method; whether the Samsung OLED exposes functional native macOS brightness control; working accelerated Metal on this 96-EU Tiger Lake-U configuration; the current exact Sonoma build; the actual DVMT allocation; actual OpenCore `Kernel -> Block` and `Kernel -> Add` entries. Do not invent those details.

### Goals / acceptance criteria

| Feature | Current reported state | Completion test |
|---|---|---|
| Reliable USB boot | Working | 3 consecutive cold boots, no EFI errors |
| OLED picture, 1920×1080 | Working | Bright, stable image with no black-screen regression |
| OLED brightness slider | Unknown | Moving slider visibly and reliably changes panel luminance |
| Fn+F4/F5 | Broken | Changes *actual panel luminance* after hotkey key event |
| Fn+F7 | Broken | Cycles physical keyboard backlight without losing typing |
| ASUS Fn lock | Unknown | Fn+Esc function mode behavior tested |
| Iris Xe graphics acceleration | Not established | Graphics driver attaches and accelerates a Metal-capable app, without stability regressions |
| Sleep/wake, display wake | Unknown | Repeated sleep/wake preserves panel, trackpad, Wi-Fi, keyboard |
| Other hardware | Stage 1 drivers in place | Functional regression tests documented |

---

## 1. Preserve the verified Stage 1 profile

Before changing anything:

1. **Do not change the USB EFI yet.** Take a second fresh backup of the exact EFI that was *actually booted successfully* (not an older archive).
2. On the USB data partition, add the following names, preserving your original rescue folders:

```
UX325EA-RESCUE/
├── BACKUPS/
│   ├── Original-EFI.zip
│   ├── Original-config.plist
│   └── Stage1-WORKING-EFI-2026-11-18.zip   # new snapshot
├── STAGING/
│   ├── EFI-BASELINE.zip
│   ├── EFI-STAGE2-HOTKEYS.zip
│   ├── EFI-STAGE2-WEX-EXPERIMENTAL.zip
│   └── EFI-LAST-KNOWN-GOOD.zip
├── RELEASES/
│   ├── WhateverXe-RELEASE.zip
│   ├── WhateverXe-Graphics.pkg
│   └── AMFIAnchor-RELEASE.zip
├── LOGS/
│   ├── stage2-initial-diagnostics/
│   ├── hotkeys/
│   └── graphics/
└── README-Stage2.md
```

3. Keep a **separately accessible** recovery method (ideally a second USB with the tested EFI). Staging ZIPs stored on the same USB **cannot boot on their own**.
4. Save a personal-data backup separately, preferably independent of the PC711 SSD.
5. If dual-booting Windows/BitLocker, retain its recovery key before BIOS or NVRAM changes.
6. **Never use Control+Enter in the OpenCore picker** when testing: that changes the default boot target. Do not reset NVRAM unless diagnosing an identified NVRAM problem.

**Config principle:** `Kernel -> Add -> Enabled=false` prevents an injected WhateverXe kext from loading. `Kernel -> Block` is primarily for blocking existing kernel drivers, and should not be used as an unexplained alternative toggle. Inspect and remove any ineffective/contradictory WhateverXe block entry in the *experimental copy*, while leaving the known-good EFI intact.

---

## 2. Collect read-only diagnostics before fixing anything

Run the companion `UX325EA_Stage2_Diagnostics.sh` from a writable location after booting macOS. It writes a **local report**, and does not modify EFI, NVRAM, SIP or installed software. Review any report before sharing because logs can contain machine identifiers.

Essential manual commands in Terminal:

```bash
sw_vers
system_profiler SPDisplaysDataType
csrutil status
pmset -g
kmutil showloaded | grep -Ei 'WhateverXe|AsusSMC|BrightnessKeys|VirtualSMC|AMFIAnchor|AppleALC'
ioreg -r -c AppleBacklightDisplay -l
ioreg -r -c AMFIAnchor -l
```

Record in a text file:

- macOS build (`sw_vers -buildVersion`), not merely “Sonoma”.
- Whether the **System Settings → Displays → Brightness** slider appears, and whether sliding it changes *physical light output* (not just colors/gamma).
- Whether pressing bare F4/F5, Fn+F4/F5, Fn+F7, and Fn+Esc changes anything.
- Whether Windows (if installed) or firmware can adjust the physical keyboard backlight. This isolates macOS mapping from possible hardware/firmware issues.
- Which display service actually appears in IORegistry. The presence of SSDT-PNLF alone is not evidence that a brightness backend is attached.
- Whether the brightness key itself emits an event (use **Karabiner-EventViewer**, if installed, or an equivalent HID event viewer) versus showing no event at all.
- Whether `AsusSMC`, `BrightnessKeys`, and `VirtualSMC` are actually loaded and attached to relevant devices, not just marked Enabled in `config.plist`.
- Existing config's UEFI picker, ACPI hotkey patches and `Kernel -> Add`/`Kernel -> Block` entries.

### Diagnosis decision tree: screen brightness

**A. The macOS brightness slider exists AND visibly changes panel brightness**  
Then the *panel brightness backend* works. Focus first on F4/F5 HID input, Fn-lock mode, ACPI notifications, and possibly key remapping. Do not install experimental graphics merely to repair keystrokes.

**B. The brightness slider exists but does NOT change panel light output**  
A recognized logical control is not sufficient. Investigate the display driver/backlight implementation and actual OLED panel method. Do not falsely mark it fixed because a slider moves.

**C. The brightness slider is missing**  
Inspect iGPU/backlight attachment, connector type, the actual `_PNLF` ACPI implementation, and the graphics path. BrightnessKeys cannot independently create a functional physical OLED brightness controller.

**D. The slider works and the F4/F5 keys show correct events but nothing changes**  
Look for a macOS keyboard-mapping/hotkey conflict rather than changing DSDT first.

### Diagnosis decision tree: keyboard backlight

**A. Fn+F7 adjusts the light before boot/under Windows but not in macOS:** Strong evidence that an ASUS EC/WMI/ATK method or macOS hotkey mapping is missing. Confirm the ACPI command pathway before patching.

**B. Fn+F7 emits an HID key event but no backlight change:** Map the event to a *verified* ASUS keyboard-light action. A generic macOS brightness key does not necessarily control ASUS hardware.

**C. No key event reaches macOS:** Inspect AsusSMC/PS2/ATK/WMI and the corresponding ACPI event/notify path. Compare against the real ACPI dump; do not guess `_Qxx` numbers.

**D. Hardware never illuminates anywhere:** Stop software experimentation and separately verify model configuration / hardware capability.

---

## 3. Stage 2A — repair Fn+F4/F5 screen-brightness keys first

1. Preserve `SSDT-PNLF.aml` and `SSDT-XOSI.aml` as-is initially. Confirm the ACPI patch list contains only the expected `_OSI -> XOSI` mapping, without duplicated or contradictory renames.
2. Confirm the **latest BrightnessKeys 1.0.3 you already have** is a compatible build, truly loads, and receives ACPI display notifications. Its documented function is ACPI Video Extensions support. It does not guarantee ASUS vendor-specific ACPI events.
3. Try Fn+Esc, bare F4/F5, and Fn+F4/F5. Note which key combination emits a HID event and what macOS action, if any, follows.
4. **If native display brightness already works**, route actual F4/F5 events to macOS brightness down/up using the smallest possible mapping adjustment; no ACPI changes unless HID events are absent.
5. **If native brightness does not work**, retain the keyboard mapping result and proceed to the experimental graphics/backlight validation, not random brightness-key kext additions.
6. For missing ACPI notifications: compare BIOS DSDT device paths (`ATKD`, `WMI`, `EC`, `GFX0`/`IGPU`, display device), the exact `_Qxx` methods and video Notify calls with the BrightnessKeys / AsusSMC instructions. Build an **SSDT hotpatch only after** you have recorded the actual device and method names; compile, validate, test on USB, one patch at a time.
7. Do not apply ThinkPad-specific `_Qxx` examples, generic PWM register edits or arbitrary OLED EDID overrides to this ASUS machine.

**Acceptance:** Real luminance changes at multiple steps, keys work across reboots, screen never blanks, and color/refresh remain unchanged. If the native panel method does not work, document it as **unsupported/not yet repaired**, not “done.”

---

## 4. Stage 2B — repair Fn+F7 keyboard illumination

1. Confirm the UX325EA hardware's Fn+F7 is the keyboard-light control (ASUS manual). Verify physical illumination under a known-working OS/firmware where available.
2. Check `VirtualSMC.kext` and `AsusSMC.kext` really load. Ensure AsusSMC is not duplicated and `AsusNBFnKeys` is not simultaneously competing with it.
3. Use **IORegistryExplorer and an ACPI dump** to establish whether this exact BIOS exposes a compatible **ATK / `ATKD` interface**, or uses a different **ASUS WMI / EC** path. AsusSMC's published prerequisites explicitly require ATK device support and correct ACPI patching.
4. Inspect the actual DSDT for the keyboard-backlight read/write or notification methods, *without inventing paths or EC registers*. Compare with the AsusSMC Wiki's installation/patch guidance. AsusSMC's older example key layout **does not match the UX325EA's newer F7 layout**; do not copy its F3/F4 keyboard-light mapping.
5. If a matching ATK method exists, build one model-specific **SSDT hotpatch**, with original method names and reversible rename only when required. Avoid permanent DSDT replacement.
6. If this model uses unsupported WMI paths, stop and report the unsupported path instead of claiming AsusSMC alone fixes the light.
7. Recheck Fn+F7, Fn lock, sleep/wake brightness retention, and battery discharge behavior after each patch.
8. Treat `AsusSMCDaemon` as conditional per the project's documented use cases rather than installing it blindly to fix all hotkeys.

**Acceptance:** Fn+F7 actually changes the keyboard LEDs, at least off and on, and the control persists after cold boot and wake. A macOS OSD appearing is not sufficient unless the physical light changes.

References:
- https://github.com/hieplpvip/AsusSMC
- https://github.com/hieplpvip/AsusSMC/wiki
- https://github.com/acidanthera/BrightnessKeys

---

## 5. Stage 2C — experimental Iris Xe GPU acceleration (separate USB EFI)

**Never start this stage before saving the bootable baseline.** You have an i7-1165G7 Tiger Lake-U **96 EU** GPU (0x9A49 as reported). The current WhateverXe published hardware test matrix explicitly tests Tiger Lake-U 48 and 80 EU, **not this 96-EU model**, and OLED brightness has panel-specific limitations. Treat accelerated graphics as an experiment, not guaranteed support.

### 5.1 OS compatibility gate

- Check `sw_vers -productVersion` and `sw_vers -buildVersion`.
- The current upstream docs specify **Sonoma 14.8.9** for their Sonoma compatibility track. If yours is not the required build, do not force the current graphics package into it. A system update is a separate, backed-up operation; do not upgrade the OS only to discover there is no working recovery route.
- Verify the exact current WhateverXe and WhateverXe-Graphics releases from their official pages at execution time. For this planning date, the listed matching releases are **WhateverXe 0.8.3** and **WhateverXe Graphics 0.4.4**.

### 5.2 Build experimental EFI without changing baseline

Copy the *known-working* EFI into a working directory and alter **only this copy**:

1. Keep `Lilu.kext` at **1.7.2 or later**, loaded before its plugins.
2. Keep `WhateverXe.kext` from the project's matching **RELEASE** ZIP, and set its **`Kernel -> Add -> Enabled = true`** in the experimental config; remove any contradictory block entry. **Do not use WhateverGreen alongside it.**
3. Follow the project's **current main-branch instructions as read on 18 November 2026**: add **`AMFIAnchor.kext` and `AMFIAnchorInjector.kext`**, with the former after Lilu and the latter after AMFIAnchor. The project says to **remove the old AMFIPass 1.4.1 Mod entry** when migrating. If OCLP is separately present, refer to its separate AMFIPass ordering instructions; never load duplicate or conflicting trust injectors. Re-read upstream instructions before use because signing schemes have changed over time.
4. For both AMFIAnchor entries, use `PlistPath = Contents/Info.plist`; AMFIAnchor executable `Contents/MacOS/AMFIAnchor`; the injector has a **blank ExecutablePath**, and the documented Darwin limits are `MinKernel=20.0.0`, `MaxKernel=25.99.99`.
5. In experimental config only, set `NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> csr-active-config` as **Data** `03080000` (`0x803`). **This reduces System Integrity Protection**; record that it is an intentional exception, not a general security recommendation. Do not blindly clear NVRAM.
6. In experimental config only, use the documented WEX flags **`-allow3d -disablegfxfirmware`**. Remove **`-wexoff`**. Keep `-v keepsyms=1 debug=0x100 alcid=11` only if it is known to support this machine's current diagnosis. Reassess and omit other inherited flags (`-novpanic`, `npci=0x2000`, `igfxonln=1`, `-dbgenhdbg`, `alcverbs=1`) unless a reproducible issue requires them.
7. **DVMT**: If BIOS DVMT Pre-Allocated is **96 MB**, no special DVMT framebuffer patch is needed per upstream WEX. If firmware is fixed at **60 MB**, upstream instructs `-igfxdvmt` and `DeviceProperties > Add > PciRoot(0x0)/Pci(0x2,0x0)` data properties `framebuffer-patch-enable=01000000`, `framebuffer-stolenmem=0000C003`. Do **not** apply this branch without verifying real DVMT or forcing hidden BIOS settings.
8. Preserve the current `SSDT-PNLF` until confirming its real ACPI attachment. Do not replace it with an unrelated OLED patch.
9. Run the OpenCore 1.0.8-bundled **ocvalidate** and `plutil -lint`, inspect kext dependency order and confirm every referenced file exists.
10. Create `EFI-STAGE2-WEX-EXPERIMENTAL.zip` on USB *data* partition and install the **experimental copy** as active USB EFI **only when** a separate bootable recovery path is available.

### 5.3 First experimental boot

- Boot the ASUS explicitly via the USB firmware boot picker, then select macOS without changing the persistent default.
- If the panel blacks out, freezes, kernel-panics, or never reaches the desktop, **do not install the Graphics pkg**. Recover from the separate baseline USB/EFI and collect photo + verbose logs.
- If the macOS desktop becomes stable, run `ioreg -r -c AMFIAnchor -l` and inspect **`InstallStatus=1`** and a matching anchor in `LoadedAnchors`, as specified by the project. Confirm actual kext loading, don't assume `Enabled` means loaded.

### 5.4 Install Graphics package inside the already-running macOS

- Download `WhateverXe-Graphics-*.pkg` from https://github.com/b00t0x/WhateverXe-Graphics/releases . Verify the real release and source, inspect its package and trust model, and understand its effects before installing.
- If a previous Xe system patch exists, restore it using the *original* rollback procedure first.
- Run the compatible official installer against the **existing installed macOS**, not simply copy the `.pkg` to EFI/OC/Kexts. The project's README says it installs under `/Library`, rebuilds AuxKC, and requires reboot.
- The package is **unsigned and not notarized**; this is explicitly disclosed upstream. Its installed payloads rely on the project's AMFIAnchor signing/trust chain. Only install if you trust those release artifacts and accept the security tradeoff.
- Reboot with the same experimental USB EFI; confirm Metal-capable app performance, no panel blanking, and that the internal display stays visible after login.

### 5.5 Validate acceleration and OLED brightness separately

Run `system_profiler SPDisplaysDataType`, examine GPU driver properties, and launch a known Metal-based application to confirm the GPU actually performs accelerated work. A 1920x1080/60 Hz screen, moving windows, or “Iris Xe” name alone does **not** establish acceleration.

Then separately test:

- OLED physical brightness and actual change in luminance at low / middle / high steps.
- No severe flicker, banding, blank screen, ghosting or unusable color when brightness changes.
- Display off/on and resume; system sleep/wake (experimental and not qualified for this laptop); three cold boots.
- USB-C external display only after internal panel is stable; upstream warns about display reconnection instability.
- Video playback, streaming DRM limitations, browser scrolling and other GPU-heavy tasks.

**Important:** Full Metal functionality and native OLED brightness are *different tests*. An accelerated GPU does not automatically yield a working OLED brightness method.

### 5.6 Rollback if a graphics problem occurs

1. Boot using a **separate known-working recovery EFI**. Do not assume that replacing USB EFI alone undoes a Graphics `.pkg` already installed in macOS.
2. If Graphics had been installed and causes persistent issues, follow the release's official `uninstall.sh` procedure from https://github.com/b00t0x/WhateverXe-Graphics ; the documented invocation is `sudo bash uninstall.sh` after downloading/checking the official file. It rebuilds AuxKC and leaves EFI untouched.
3. Reboot and restore the **Stage 1 USB EFI** and its original SIP/security configuration as appropriate.
4. Keep kernel panic logs and OS build info for debugging; never risk losing the internal OLED display merely to chase benchmark FPS.

---

## 6. Stage 2D — full Fn/function-key audit

| Input | ASUS intended function | Test / dependency |
|---|---|---|
| F1 | Mute | AppleALC + keyboard event |
| F2 | Volume down | AppleALC + keyboard event |
| F3 | Volume up | AppleALC + keyboard event |
| F4 | Screen brightness down | Backlight service + BrightnessKeys/vendor ACPI mapping |
| F5 | Screen brightness up | Same |
| F6 | Touchpad toggle | ASUS EC/ACPI event + VoodooI2C path; avoid making touchpad unrecoverable |
| F7 | Keyboard backlight | ASUS EC/ATK/WMI control, not generic display dimming |
| F8 | Display mode | Only meaningful with an external display; use tested macOS mapping |
| F9 | Lock screen | Check macOS event/remap; no claim Windows-specific action is automatic |
| F10 | Camera on/off | Determine whether actual camera privacy gate is hardware/ACPI controlled |
| F11 | Screenshot | Mac shortcut mapping may differ |
| F12 | MyASUS | Windows application; optional replacement in macOS, not natively portable |
| Fn+Esc | Fn lock | Test the firmware toggle and note mode |

Do **not** promise the entire F1–F12 row behaves identically to Windows. Make each test independent and mark outcomes as **Working / Not working / Not applicable / Unsupported / Untested**.

---

## 7. Stage 2E — remaining practical hardware checks

Only after brightness and graphics have a stable result:

- **Battery and power:** Battery %, charging/discharging, sleep and wake, power draw at idle, charger reattachment, thermal behavior. Keep `SMCProcessor.kext` disabled if it previously caused panics.
- **Audio:** Stereo speakers, headset jack, internal mic, volume keys and output switching; confirm layout 11 actually works rather than relying on name alone.
- **Wi-Fi AX201/Bluetooth:** SSID scans, real-world throughput, reconnection after wake, Bluetooth pairing/reconnect; no claim of Windows-equivalent speed without measurements.
- **Trackpad/NumberPad:** Multi-finger gestures, palm rejection, click, external mouse; distinguish ASUS proprietary illuminated NumberPad from normal I2C touchpad functionality. ASUS manual warns that NumberPad special features are Windows-dependent.
- **USB-C/USB-A:** Connect/disconnect drive, USB hub, charging, display; keep USB mapping independent of GPU changes.
- **SSD PC711:** Read/write, SMART where exposed, sleep/resume; avoid enabling NVMeFix without evidence.
- **Webcam/microphone:** Test in a permissioned app. Camera hotkey privacy states may require platform-specific control.
- **Reliability:** 3 cold boots, 3 restarts, 2 display sleep/wakes, and a longer daily-use session with timestamps and logs; record every failure.

Do not introduce unnecessary new kexts just to increase the inventory count.

---

## 8. Testing checkpoints and stop conditions

### Checkpoint A: Stage 1 remains bootable

- [ ] The unchanged rescue USB boots and shows the OLED.
- [ ] ZIP of *boot-tested* Stage 1 EFI stored both on and off USB.
- [ ] A second recovery route is physically available.

### Checkpoint B: Brightness diagnosis complete

- [ ] Fn lock tested.
- [ ] Physical Fn+F4/F5/F7 events observed or documented as missing.
- [ ] Screen brightness slider existence and real effect recorded.
- [ ] AsusSMC ATK/WMI path checked against real ACPI.

### Checkpoint C: Hotkey corrections

- [ ] Each SSDT patch points to actual machine ACPI objects.
- [ ] `ocvalidate` and `plutil -lint` pass.
- [ ] Keys affect real hardware, not only an OSD.
- [ ] No regression in USB boot, touchpad or battery.

### Checkpoint D: Experimental graphics

- [ ] macOS build matches published WEX requirements.
- [ ] Matching RELEASE ZIP and Graphics pkg, plus required AMFIAnchor trust scheme.
- [ ] WEX enabled and `-wexoff` removed in experimental config only.
- [ ] Display still works on pre-package EFI boot.
- [ ] Package installation and Metal test completed *only if previous checks pass*.
- [ ] Rollback procedure verified.

### Stop immediately if:

- Internal OLED blanks or becomes unreadable, the boot enters a panic loop, touchpad/keyboard both stop working, disk errors appear, or the laptop repeatedly fails resume. Revert the **single most recent change**; do not stack additional patches on an unstable configuration.

---

## 9. Suggested implementation work order for a local coding/ACPI agent

**Task:** Improve the actual working ASUS UX325EA USB EFI for hotkeys and experimental graphics, while preserving its baseline and creating a reversible, independently validated experimental profile.

**Required inputs:** Actual EFI ZIP, redacted config.plist, `sw_vers` output, ioreg diagnostics, native ACPI tables/DSDT dump and current-key event log. Never fabricate machine-specific ACPI paths, methods, I/O offsets, firmware DVMT values or kext versions.

**Strict workflow:**

1. Inventory the supplied EFI, determine active and disabled kexts, ACPI injection, `Kernel -> Block` behavior, patch order and duplicates.
2. Produce a change-only diff and **separate** hotkey and graphics branches based on known-good EFI. Never overwrite the original or the only bootable USB.
3. Diagnose brightness: visible macOS slider and key events. If slider works, fix mapping before touching graphics.
4. Diagnose keyboard lighting by native ACPI ATK/WMI methods, model-specific DSDT and AsusSMC support. Propose an SSDT only for confirmed device paths, with source `.dsl`, compiled `.aml`, and explanation of each byte-level rename if needed.
5. Validate and test each patch separately with an explicit rollback ZIP.
6. For graphics, require exact macOS build, verified matching WEX / Graphics / AMFIAnchor / injector and explicit SIP/security acknowledgment. Never load WhateverGreen and WhateverXe simultaneously; never install Graphics until the experimental WEX EFI boots to usable desktop.
7. Run `ocvalidate` using the exact OpenCore version, `plutil -lint`, file existence checks and dependency-order checks. Static validation does not imply a successful boot.
8. Output: `EFI-STAGE2-HOTKEYS.zip`, `EFI-STAGE2-WEX-EXPERIMENTAL.zip`, `CHANGES.md`, `TEST-RESULTS.md`, `ROLLBACK.md`; **only** create these artifacts when based on real input files and actual tests.

**Do not:** blindly change BIOS, overwrite macOS, change serial/MLB/ROM, reset NVRAM without evidence, use software dimmers as proof of real OLED brightness, or claim 100% compatibility without machine testing.

---

## 10. Authoritative references (checked 18 November 2026)

1. ASUS UX325EA user manual / key layout: https://dlcdnets.asus.com/pub/ASUS/nb/UX325EA/0409_E19336_UX325_425EA_Win11_A.pdf
2. WhateverXe: https://github.com/b00t0x/WhateverXe/blob/main/README.md
3. WhateverXe releases: https://github.com/b00t0x/WhateverXe/releases
4. WhateverXe Graphics package and rollback: https://github.com/b00t0x/WhateverXe-Graphics/blob/main/README.md
5. WhateverXe Graphics releases: https://github.com/b00t0x/WhateverXe-Graphics/releases
6. AMFIAnchor installation, kext order and verification: https://github.com/b00t0x/AMFIAnchor/blob/main/README.md
7. AsusSMC supported features and required ATK ACPI: https://github.com/hieplpvip/AsusSMC
8. BrightnessKeys scope: https://github.com/acidanthera/BrightnessKeys
9. OpenCore config / Kernel Add and Block: https://github.com/acidanthera/OpenCorePkg/tree/master/Docs

**Bottom line:** Your successful Stage 1 USB is the recovery baseline. First identify whether OLED brightness exists as a functional macOS service, then fix display key events; separately map Fn+F7 to the verified ASUS EC/ATK/WMI method; only then experiment with accelerated Iris Xe using a **separate** EFI, compatible macOS and the project's signed graphics trust chain. Without the actual EFI and ACPI dump, no safe model-specific patch can be claimed to be complete.

---

## 11. Place this Stage 2 plan on your existing flash drive

The companion `UX325EA_Stage2_Copy_Plan_To_USB.sh` copies this document and the read-only diagnostics helper **only** to the rescue folder on the **already mounted USB data partition**. It does **not** enable new drivers, alter the active EFI, reformat the flash drive or install WhateverXe Graphics.

1. Extract the Stage 2 package ZIP. Plug the USB into a running Mac and confirm its mounted data volume is `/Volumes/Install macOS Sonoma` (if different, edit `DATA_VOLUME` in the copy script after verifying the real volume).
2. In Terminal, navigate to the extracted folder and run `bash UX325EA_Stage2_Copy_Plan_To_USB.sh`.
3. Confirm `UX325EA-RESCUE/README-Stage2.md` and `UX325EA-RESCUE/STAGING/UX325EA_Stage2_Diagnostics.sh` exist on the USB data partition.
4. Eject the USB normally. The EFI partition remains the Stage 1 bootable baseline until you explicitly prepare and test a separate new EFI.


---

## 12. STAGE 2F — FULL EXPERIMENTAL GRAPHICS PROFILE, 1080p60 TARGET

**Purpose:** Extend—not replace—Sections 5–11 with an explicit implementation sequence for a maximum-feature **experimental** WhateverXe setup. The ASUS manufacturer specification identifies the UX325EA OLED FHD panel as **1920×1080, 60 Hz**. This is a panel refresh target; **60 FPS means an application is delivering 60 completed frames per second**, which depends on software workload, driver stability and GPU capability. A reported 60 Hz mode does not prove Metal acceleration.

**Sources as of 2026-11-18**:
- ASUS Egypt UX325EA display specification: https://www.asus.com/eg-en/laptops/for-home/zenbook/zenbook-13-oled-ux325-11th-gen-intel/techspec/
- WEX compatibility and installation: https://github.com/b00t0x/WhateverXe
- WEX physical PCI/device selection: https://github.com/b00t0x/WhateverXe/blob/main/docs/device-selection.md
- WEX Graphics package installation/uninstallation: https://github.com/b00t0x/WhateverXe-Graphics
- AMFIAnchor official loading guidance: https://github.com/b00t0x/AMFIAnchor/blob/main/README.md
- OpenCore picker hotkeys: https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Configuration.tex

### 12.1 Preserve a real rollback chain before touching active EFI

**Profiles** (each backup must be an actual copy of `EFI/` from a boot-tested device, not an empty folder or config alone):

| Profile | Description | Storage | Risk |
|---|---|---|---|
| `STAGE1-ORIGINAL` | Unmodified EFI currently booting macOS and lighting the OLED | Separate USB or other bootable recovery media + ZIP on computer | Recovery baseline |
| `STAGE2-KEYBOARD` | Working EFI plus **only** tested display/keyboard hotkey correction | Offline staging first | Low/medium |
| `STAGE2-WEX-PREPKG` | Stage 1 EFI + experimental WEX/security changes; no macOS graphics package yet | Offline staging, then experiment USB EFI | High |
| `STAGE2-WEX-FULL` | Same experiment EFI + WEX Graphics installed **inside macOS** | On-system experiment, requires on-system rollback | High |

1. Back up all personal data before modifying the installed macOS graphics stack. Prepare a recovery route that **does not depend on the experimental USB EFI**.
2. Save a copy of the **real USB EFI partition** and the exact macOS build. Do not overwrite `Original-EFI.zip` if it is an older snapshot; add a dated working snapshot.
3. Record the macOS volume, available disk space, FileVault unlock route, BIOS settings, and any Windows BitLocker recovery key.
4. Retain the actual original USB installer's separate recovery data; a `*.zip` in the data partition is not a bootable rescue profile by itself.
5. No firmware DVMT changes, GPU spoof, USB remapping, new SSD drivers or ACPI overwrites until an independent hardware diagnostic requires them.

### 12.2 Exact staged OpenCore configuration targets

**Only apply these to an isolated copy of `config.plist`; do not batch-edit the live baseline.** The corresponding `EFI/OC/Kexts` contents must be present; a configuration line alone is insufficient.

| Location in OpenCore config | Setting / intended value | Why |
|---|---|---|
| `Kernel > Add` | `Lilu.kext` **Enabled=true**, load before plugins | WEX/AMFIAnchor use Lilu |
| `Kernel > Add` | `WhateverXe.kext` **Enabled=true**, `BundlePath=WhateverXe.kext` | Enable experimental GPU driver |
| `Kernel > Add` | `AMFIAnchor.kext` **Enabled=true** | Current upstream graphics package signing-trust mechanism |
| `Kernel > Add` | `AMFIAnchorInjector.kext` **Enabled=true**, blank `ExecutablePath` | Trust the correct graphics signing anchor |
| `Kernel > Add` | `WhateverGreen.kext` **Disabled/absent** | Must never run together with WEX |
| `Kernel > Add` | Legacy **AMFIPass 1.4.1 Mod** **Disabled/removed** | Superseded by AMFIAnchor for this WEX path; ordinary AMFIPass remains only if separately required for OCLP, after anchors |
| `Kernel > Block` | No active WhateverXe block entry | Prevent contradictory enable/block design |
| `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82 > boot-args` | Add `-allow3d -disablegfxfirmware`; remove `-wexoff` | WEX documented flags and enabling condition |
| Same `NVRAM > Add` path | `csr-active-config`: **Data** bytes `03 08 00 00` | WEX Graphics documented SIP setting; **reduces macOS system protections** |
| `DeviceProperties > Add > PciRoot(0x0)/Pci(0x2,0x0)` | **Do not inject `AAPL,ig-platform-id` or override `device-id` by default** | WEX selects supported `0x9A49` from the real PCI ID automatically |
| `ACPI > Add` | Keep already tested `SSDT-PNLF.aml` and other matching tables | Only adjust after checking DSDT and IORegistry |
| `Misc > Boot > PollAppleHotKeys` | **Experimental option:** `false`, with recovery implications | Affects **OpenCore picker boot modifier shortcuts only**, not macOS Fn/display keys |
| `UEFI > Input > KeySupport` | Keep the known-working `true` value unless picker keyboard is broken | Pre-boot keyboard input is a separate subsystem |

**Important upstream detail:** current WEX code explicitly supports physical PCI ID **`9A49`**. The legacy Intel graphics workaround `AAPL,ig-platform-id` is **not** required by WEX. A manual `device-id=499A0000` would represent the *same* physical ID in little-endian Data, but is redundant and is **not recommended** for the first experimental boot. Neither a platform-ID spoof nor a `device-id` override can manufacture missing driver support or force 60 FPS.

#### Boot arguments: two different stages, do not mix their goals

**Stage 2F.1 — initial minimal-diff boot:** start with the *actual Stage 1 boot arguments*, change only the graphics-specific items:

- Remove `-wexoff`.
- Add `-allow3d`.
- Keep existing `-disablegfxfirmware`.
- Keep the other **proven-working** baseline arguments on this first boot, even if some are questionable; the point is to isolate WEX activation from unrelated keyboard/PCI changes. This is **not** a recommendation to keep them indefinitely.

Based on your *reported* baseline, the resulting initial test string would be:

```text
-v keepsyms=1 debug=0x100 -disablegfxfirmware -igfxdvmt -novpanic alcid=11 -dbgenhdbg -vi2c-force-polling npci=0x2000 alcverbs=1 igfxonln=1 -allow3d
```

**This is a minimal-change diagnostic string, not a cleaned or guaranteed-correct final configuration.** It preserves `-igfxdvmt` temporarily even though its correct use depends on measured firmware DVMT. It preserves potentially unnecessary settings temporarily rather than changing too many variables.

**Stage 2F.2 — cleaned candidate only after reproducible successful boots:**

```text
-v keepsyms=1 debug=0x100 -allow3d -disablegfxfirmware alcid=11
```

Keep `-vi2c-force-polling` *only if removing it causes a verified trackpad failure*; keep other original flags only if needed to fix a reproducible issue. Remove **one flag per test boot**, not all at once. Do not interpret `-novpanic` as a guaranteed protection against kernel panics. `alcid=11` is only needed if the installed audio setup actually requires it.

**Not a boot-argument requirement:** Do not add `igfxonln=1`, `-yTileDisable`, `amfi=0x80`, `ipc_control_port_options=0`, or `-wexoff` as general optimization flags. Their presence is not a route to a verified 60 FPS.

### 12.3 DVMT allocation decision, with exact documented properties

Do **not** assume your BIOS DVMT allocation from physical RAM size or reported VRAM. Check actual firmware setup, GPU register diagnostics or trusted existing hardware inventory first.

| Verified firmware condition | Action |
|---|---|
| DVMT Pre-Allocated is **96 MB** | No WEX DVMT patch or `-igfxdvmt` required |
| DVMT fixed at **60 MB** | Add `-igfxdvmt` plus the two documented properties below |
| Unknown / other allocation | **Do not invent a value**; stop the memory-patch branch until identified |

For **verified 60 MB only**, set these on the actual iGPU PCI path (commonly `PciRoot(0x0)/Pci(0x2,0x0)`), typed as **Data** in OpenCore:

```text
framebuffer-patch-enable   Data   01000000
framebuffer-stolenmem      Data   0000C003
```

These properties **do not increase BIOS-allocated DVMT**. Avoid hidden BIOS-variable editors or arbitrary `setup_var` commands: an incorrect firmware write can make the laptop unbootable.

### 12.4 AMFIAnchor ordering, security, and executable paths

Use the *official releases*, not unrelated or unsigned third-party reuploads. These are direct OpenCore `Kernel > Add` records, ordered by dependency:

```text
Lilu.kext                  BundlePath=Lilu.kext                  ExecutablePath=Contents/MacOS/Lilu
AMFIAnchor.kext            BundlePath=AMFIAnchor.kext            ExecutablePath=Contents/MacOS/AMFIAnchor
AMFIAnchorInjector.kext    BundlePath=AMFIAnchorInjector.kext    ExecutablePath=(empty string)
WhateverXe.kext            BundlePath=WhateverXe.kext            ExecutablePath=Contents/MacOS/WhateverXe
```

- `PlistPath=Contents/Info.plist` for all entries.
- `AMFIAnchor` and `AMFIAnchorInjector` documented `MinKernel=20.0.0`, `MaxKernel=25.99.99`.
- A separate OCLP AMFIPass, when applicable, goes **after** both anchor entries. For the original vanilla WEX experiment, do **not** add it.
- Check actual kext `CFBundleIdentifier` values against OpenCore settings and confirm no duplicates.
- **Security note:** `csr-active-config=03080000` is a reduced-SIP configuration; the anchor trusts the project's signing CA. This is a trade-off, not a security improvement. Keep your primary working OS install and backup strategy in mind.
- Do not combine the existing-system `.pkg` with `AutoPkg-Assets.pkg`, or switch to installer-only `csr-active-config=030A0000`. The **existing macOS macOS** uses the ordinary WEX Graphics `.pkg` installation flow.

### 12.5 Disable `PollAppleHotKeys` as a controlled picker-only trial

The user's requested switch is:

```text
Misc > Boot > PollAppleHotKeys = false
```

Do this in the **experimental EFI copy only** if desired. OpenCore documents it as a **boot-time modifier-key** handler (`Shift+Enter` safe mode, recovery-related combos). Switching it off can make these shortcuts less reliable on PS/2 keyboards. It **does not** fix macOS display brightness keys, keyboard lighting, ASUS WMI notifications or improve graphics frame rate.

**Acceptance tests after switching:** picker keyboard still responds; macOS boots normally; recovery entry remains manually selectable; you know how to restore baseline EFI even if Shift+Enter stops working. Keep `KeySupport=true` if the known-good picker depends on it. If the goal is fixing in-macOS Fn keys, return to Sections 2–4; leave picker options alone.

### 12.6 Exact execution sequence — WEX without and then with graphics package

**Experiment 1 — preflight (no reboot):**

1. Copy the working EFI to a folder that is *not* the active USB EFI, e.g. `~/Desktop/UX325EA-WEX-STAGING/EFI/`.
2. Put matching **RELEASE** versions of WEX 0.8.3 and AMFIAnchor/AMFIAnchorInjector into the staged copy. Confirm Lilu is 1.7.2 or later. Confirm WEX Graphics 0.4.4 is locally downloaded **but do not install it yet**.
3. Apply the **Stage 2F.1** minimal-diff changes and the upstream trust configuration to the staged plist; no forced platform ID.
4. Run `plutil -lint ".../config.plist"` and **`ocvalidate` shipped with the exact OpenCore release used by that EFI**. Verify referenced kext folders and executable files exist.
5. Run the package's **read-only checker** on the staged file:

```bash
python3 UX325EA_Stage2_Graphics_Preflight.py "/path/to/UX325EA-WEX-STAGING/EFI/OC/config.plist"
```

6. Inspect its warnings, especially accidental WEG/WEX collision, `-wexoff`, stale platform ID, AMFIAnchor order, and DVMT flags.

**Experiment 2 — boot only WEX kext:**

7. Keep **another physically bootable** known-good EFI. Copy the validated experimental `EFI` into the experiment USB EFI partition; do not touch the internal macOS EFI. Keep the two EFI profiles clearly labelled.
8. Use the ASUS firmware boot menu (**Esc**) to choose the experimental USB, select macOS normally, and do not use Control+Enter to make it permanent.
9. If the OLED goes black, panics or shows artifacts, **stop here**. Do **not** install graphics `.pkg`. Restore the baseline USB and collect verbose/photo logs.
10. If macOS reaches a usable desktop: verify `kmutil showloaded` for WEX/Lilu/AMFIAnchor and `ioreg -r -c AMFIAnchor -l` for `InstallStatus=1` with the expected signing anchor. If no trust registration, fix that first.

**Experiment 3 — install accelerated Graphics inside macOS (changes macOS):**

11. **Only if Sonoma version/build matches the published requirement** (currently 14.8.9), open the **official WEX Graphics 0.4.4 `.pkg`** while booted from the experimental WEX EFI. The pkg is **not notarized**, installs under `/Library`, and rebuilds AuxKC.
12. Resolve all installer errors; do not reboot until the installer reports completion. Record relevant lines from `/var/log/install.log` if it fails.
13. Restart with the **same** experiment USB EFI. If the desktop stays visible, test Metal functionality and display timing; do not treat the accelerated result as permanent until you have validated sleep, wake, hotkeys and cold starts.
14. If there is a black screen after package installation, restore a recovery boot environment, then use the official graphics `uninstall.sh` and restart. Reverting the EFI alone is **not** enough to undo installed drivers inside macOS.

### 12.7 Measure actual 60 Hz timing and 60 FPS output

**Goal 1: Display mode.** ASUS states this OLED FHD panel is **60 Hz**. Do not add unsupported custom EDID or framebuffer clock values merely to make a utility display "60".

Run:

```bash
system_profiler SPDisplaysDataType
swift UX325EA_Display_Mode_Report.swift
```

The included Swift helper queries **CoreGraphics-reported active display modes**, including pixel dimensions and reported refresh in Hz. Some display backends report `0.0` refresh when timing information is unavailable; **this does not indicate a 0 Hz display**. Verify mode through additional driver/EDID evidence if necessary.

**Goal 2: Genuine graphics acceleration.** In `System Information > Graphics/Displays`, note the displayed driver/GPU and Metal support, if shown. Use a known working native Metal test app/benchmark and log whether it actually initializes Metal, renders consistently and avoids CPU-only software fallback. An Intel Xe name and smooth pointer movement are not sufficient.

**Goal 3: Actual 60 FPS.** Test a repeatable GPU workload at **1920×1080** using its in-app frame counter or a development Metal frame-time instrument. Log at least three controlled test runs, their average and 1% low FPS, measured frame times and visible artifacts. Frame time at 60 FPS is approximately **16.67 milliseconds**, but workloads can run below 60 FPS even with a 60 Hz screen. Don't claim “native stable 60 FPS” without measured results.

**Goal 4: Screen visibility and panel health.** At minimum, test internal OLED at login and desktop, brightness at low/mid/high, a full-screen video, video playback pause/resume, display sleep/off/on, and 3 cold boots. If the panel blacks out after WEX activation, **reverse the last graphics change**, don't experiment with random CDClock hex values.

**Goal 5: Codec and power behavior.** Where apps support it, test H.264 decode/encode, HEVC playback, Safari and Chrome scrolling/video, power draw and temperature changes (from available reliable sensors), and check for spikes in `WindowServer` CPU usage. Record DRM streaming limitations instead of inventing fixes.

**Goal 6: External displays only after OLED is stable.** Check hot-plug, USB-C/HDMI, monitor reconnect and sleep/wake, but keep a recovery path: WEX documents unstable USB-C/DP reconnection for some Tiger Lake setups.

### 12.8 Hardware-brightness and keyboard backlight after acceleration

Even if Metal acceleration succeeds, the OLED brightness slider and Fn keys can still fail independently. Use this path:

1. Test *physical* luminance via the Displays brightness slider. If it works, test Fn-lock and visible key events for bare F4/F5 vs. Fn+F4/F5; fix HID mapping **without ACPI guessing**.
2. If the slider is missing or ineffective, check whether the working display is attached to a backlight service. Inspect PNLF and the actual eDP panel interface in IORegistry/ACPI. No generic SSDT is guaranteed on this OLED.
3. For Fn+F7, verify ASUS keyboard lighting operates in firmware or Windows; investigate ATKD/WMI/EC methods using an **actual extracted DSDT**. Only create SSDTs with existing method names verified from that machine.
4. Do not map keyboard illumination to macOS screen dimming. The former is an ASUS EC operation; the latter is GPU/panel luminance.
5. Re-test F1–F12, USB, audio, battery, touchpad, Wi-Fi, SSD and Mac wake behavior after every graphics-package installation.

### 12.9 Final result checklist / go-no-go

- [ ] Backup of actual successful USB EFI, plus a **second bootable** rescue path.
- [ ] Exact macOS Sonoma build supports the selected WEX release.
- [ ] WEX 0.8.3 and matching WEX Graphics 0.4.4 from official source; AMFIAnchor + injector correct.
- [ ] `Kernel > Add` WEX active, no duplicate WEG, no unexplained WEX `Kernel > Block`.
- [ ] `-allow3d -disablegfxfirmware` present, `-wexoff` absent, only measured/needed DVMT options.
- [ ] No synthetic `AAPL,ig-platform-id`; genuine `0x9A49` used unless source-backed override is required.
- [ ] `PollAppleHotKeys=false` tested as a picker choice **only**; recovery remains operable.
- [ ] `plutil`, matching `ocvalidate`, file existence and relative kext ordering passed.
- [ ] Experimental kext-only boot reaches desktop **before** Graphics pkg installation.
- [ ] AMFIAnchor registered; graphics pkg installed without error; uninstall path ready.
- [ ] CoreGraphics/driver timing supports a reported 1920×1080 60 Hz path or independent verified timing evidence.
- [ ] Genuine Metal test succeeds; FPS measured using real app frame delivery and observed frame times.
- [ ] Display remains lit through boot, login, idle, fullscreen, off/on, repeated cold boots, and sleep/wake tests.
- [ ] OLED physical brightness and Fn+F4/F5 tested separately; Fn+F7 controls actual keyboard lighting.
- [ ] All other previously working components are not regressed.

### 12.10 Recovery from experimental package changes (if test fails)

1. Stop further changes. Use physically independent known-good boot media, not the failed active USB configuration.
2. If **no** Graphics `.pkg` was installed: restore Stage 1 EFI and the Stage 1 SIP setting as appropriate. Confirm macOS boots.
3. If `.pkg` **was** installed: use the official `WhateverXe-Graphics/uninstall.sh` from the exact upstream GitHub project to remove its added drivers and rebuild AuxKC. The documented command is `sudo bash uninstall.sh` **after** inspecting and obtaining that trusted script. Reboot.
4. Restore the known-good EFI, record the actual failed setting and preserve logs. Never blindly delete Apple graphics bundles, downgrade system snapshots, or rewrite BIOS variables.
5. If the original EFI cannot boot after installing graphics, use independent recovery media or a tested system backup. **USB EFI rollback alone cannot remove a package that changed `/Library` on macOS.**

---

## 13. New bundled helper files (read-only)

| File | Use | What it changes |
|---|---|---|
| `UX325EA_Stage2_Graphics_Preflight.py` | Parse staged OpenCore config, detect WEX/WEG conflicts, suspicious boot args, AMFIAnchor status, iGPU properties, SIP data, pre-boot hotkey setting | **Nothing** |
| `UX325EA_Display_Mode_Report.swift` | Report CoreGraphics active display dimensions and advertised refresh | **Nothing** |
| `UX325EA_Stage2_Diagnostics.sh` | Record safe inventory from running macOS | Writes local diagnostic files only |
| `UX325EA_Stage2_Copy_Plan_To_USB.sh` | Copy plan and helpers to existing USB rescue **data** partition | Writes rescue documentation only; not active EFI |

**Usage:** extract the complete ZIP; run the checker against a **staged** `config.plist`. It never adjusts your boot arguments or installs WEX. After testing with verified hardware and the true working EFI, make the manual EFI change in your local working directory using a verified plist editor. Do not treat this plan as a prebuilt bootable EFI.
