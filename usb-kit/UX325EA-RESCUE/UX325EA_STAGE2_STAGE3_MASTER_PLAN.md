# ASUS ZenBook 13 OLED UX325EA — Stage 2 + Stage 3 Complete Hardware Plan

**Revision:** 2026-11-18 · **Target:** existing macOS Sonoma volume `macOS`, i7-1165G7 / Intel Iris Xe (PCI 0x9A49), 13.3-inch 1920×1080 60 Hz OLED, Intel AX201, SK hynix PC711, OpenCore USB.

**This is an implementation and verification plan, not a prebuilt, verified EFI.** The existing USB boots successfully according to the user; the screenshot is an agent report, not independent proof that graphics, Wi‑Fi, brightness, or sleep works. Actual machine tests are required.

## 0. Non-negotiable outcomes and limitations

| Requested outcome | What is achievable / how success is established |
| --- | --- |
| 1920×1080 at **60 Hz** | ASUS specifies 60 Hz physical display. Validate macOS output mode and stable panel operation. |
| **Smooth 60 FPS** and GPU power | Only if WhateverXe actually attaches and graphics-package acceleration works, and the specific app reaches 60 FPS. A 60 Hz setting, 1536 MB VRAM label, or `Metal 3` text is not a reliable performance measurement. |
| No more experimental instability | Cannot promise: WhateverXe documentation does **not** list this 96-EU Tiger Lake-U model among tested hardware; laptop sleep/wake and external-display reconnection remain limited. Keep an unaccelerated fallback. |
| OLED screen brightness | Fix backlight *control backend* before merely mapping F4/F5. Gamma/color dimming is not the same as physically changing panel luminance. |
| Keyboard light Fn+F7 | ASUS EC/ATK/WMI/DSDT-specific; must identify actual supported methods and test physical LEDs. |
| Fastest working Wi-Fi | AX201 can use 5 GHz; OpenIntelWireless supports VHT 80/160 MHz but its documented HE/802.11ax mode is disabled. Test real link rate and throughput; do not promise 867 Mbps. |
| No loss of boot | Preserve independently bootable USB EFI + data backup; never overwrite internal SSD EFI until all requested tests pass. |

**Safety rule:** Do not run the screenshot's `sudo /Users/<user>/deploy_master_zenbook_hardware.sh` until the whole script has been inspected line-by-line. The screenshot describes purging WindowServer preferences, editing NVRAM/EFI on the internal SSD and automatic reboot; none is justified without identifying its exact effects. Do **not** use `Control+Enter` to set a permanent OpenCore default during testing.

### Corrected security/trust instructions — SUPERSEDES older Stage 2

**As checked against the official WhateverXe and WhateverXe-Graphics project README on 2026-11-18**, the documented existing-installation path uses **AMFIPass 1.4.1 Mod** from the WEX project, **not** standard upstream AMFIPass and **not** the AMFIAnchor + AMFIAnchorInjector method prescribed in the older Stage 2 draft. Do not mix the two trust chains. Re-read the current upstream README at execution time if it changes. The package's modified graphics components require the corresponding signing chain. Reduced SIP (`csr-active-config` Data `03080000`) is a meaningful security trade-off, *not* a harmless performance tweak.

Official project instructions: https://github.com/b00t0x/WhateverXe ; https://github.com/b00t0x/WhateverXe-Graphics

## 1. Status definitions and go/no-go gates

- **PASS:** measured, repeated on the real UX325EA, with logs and no regressions.
- **FAIL:** reproducible defect with a corresponding log or observation.
- **UNVERIFIED:** kext present, config setting set, or script claims success but no working hardware test.
- **UNSUPPORTED:** relevant driver/firmware pathway is demonstrably absent or published upstream support is missing; record as limitation rather than labeling PASS.

**G0 — safe source:** current USB EFI and installed OS boot the desktop; make an additional complete user-data backup.

**G1 — safe recovery:** separate independently bootable fallback USB tested; archived EFI ZIPs on the *same* USB do not count as independently bootable.

**G2 — OS compatibility:** capture exact `sw_vers` and build; whateverXe's Sonoma track requires 14.8.9 per current README. Do not install package on an incompatible build.

**G3 — preflight:** no WhateverGreen/WhateverXe conflict, no duplicate kext, valid paths and `ocvalidate` pass, matched unsigned packages from official releases.

**G4 — WEX kext boot:** experimental USB reaches usable desktop **before** installing WhateverXe Graphics.

**G5 — Graphics package:** install to **existing macOS**, reboot using experimental USB, verify accelerated Metal *and* 60 Hz/stability by actual testing.

**G6 — functional regressions:** screen, keyboard, audio, Wi-Fi, Bluetooth, trackpad, SSD, battery, USB, sleep, shutdown, macOS updates remain usable.

**G7 — deployment:** only after several successful cold boots and wake tests consider using the tested EFI on the internal disk. Do not automate blind copying.

## 2. Safe USB structure and boot profiles

Keep the **USB EFI system partition** exactly as it is while preparing files on its non-EFI data partition:

```text
/Volumes/Install macOS Sonoma/UX325EA-RESCUE/
  BACKUPS/
    STAGE1-WORKING-EFI-EXACT-BOOTED.zip
    STAGE1-CONFIG.plist
    MACOS-DATA-BACKUP-LOCATION.txt
  STAGING/
    PROFILE-A-BASELINE/      # Recovery (not automatically bootable from data directory)
    PROFILE-B-HOTKEYS/      # Keyboard/backlight changes only
    PROFILE-C-WEX/          # Experimental graphics kext only
    PROFILE-D-WEX-PKG/      # Graphics package installed in OS; same EFI profile as C if unchanged
  OFFICIAL-DOWNLOADS/       # Original, hash-recorded vendor releases
  DIAGNOSTICS/
  TEST-RESULTS/
  ROLLBACK.md
```

**Important:** Only one `EFI/OC/config.plist` is active on a given EFI partition. A directory called `PROFILE-C` is not automatically a selectable OpenCore boot entry. To keep both rescue and experiment independently bootable, prepare **two physical USBs**, or a validated advanced multi-boot arrangement. Test rescue *before* experimenting. Never rely on access to an unbootable ZIP if the display goes black.

**Never** delete `Original-EFI.zip`, original BIOS settings, FileVault recovery key, or the Windows/BitLocker recovery key if Windows is dual-booted.

## 3. Read-only baseline inventory (run on the booted macOS)

Do not assume `en0` is Wi-Fi. Get interface from hardware-port inventory.

```bash
sw_vers
system_profiler SPDisplaysDataType
system_profiler SPAirPortDataType
networksetup -listallhardwareports
networkQuality -v
csrutil status
pmset -g
pmset -g assertions
kmutil showloaded | grep -Ei 'WhateverXe|WhateverGreen|AMFIPass|AsusSMC|BrightnessKeys|VirtualSMC|AppleALC|itlwm|IntelBluetooth'
ioreg -r -c AppleBacklightDisplay -l
system_profiler SPUSBDataType
```

Record exact OpenCore release, active `NVRAM -> boot-args`, macOS version/build, GPU device ID, active kext bundles and versions, firmware DVMT setting if known, router band/channel/channel width, Wi-Fi TX rate, ISP plan rate, FileVault status, sleep/wake failures. Some commands output private identifiers/SSID: redact before sharing.

Run bundled `UX325EA_Stage3_ReadOnly_Diagnostics.sh` for one folder of snapshots. It **never modifies the boot EFI, OS, NVRAM, SIP or router**. The macOS `python3` developer-tools prompt shown in the screenshot means the requested Python tool is not yet installed; don't click Install just to run a shell script, and don't presume that a script needing Python has executed.

## 4. Inspect the screenshot's deployment script before ANY execution

The screenshot **claims** the script will: purge stale WindowServer settings, remove `-wexoff` from NVRAM boot-args, copy the USB's updated EFI to the internal SSD, and reboot. These claims do **not** demonstrate safety or successful GPU acceleration.

Read, do not run:

```bash
SCRIPT="$HOME/deploy_master_zenbook_hardware.sh"
ls -l "$SCRIPT"
shasum -a 256 "$SCRIPT"
file "$SCRIPT"
sed -n '1,260p' "$SCRIPT"
grep -nE 'sudo|rm |diskutil|mount|bless|nvram|csr|reboot|shutdown|installer|kmutil|defaults|cp |rsync|dd |sudo' "$SCRIPT"
```

If file is longer, review **all** remaining lines as well, including functions and downloaded helper scripts. Red flags: deleting WindowServer preferences without a backup; `rm -rf` targeting unknown paths; `sudo nvram -c`; `diskutil eraseDisk`; `csrutil disable`; hidden BIOS settings; patching `/System/Library/Extensions`; copying EFI over the only working EFI; any **automatic reboot**; downloading binaries from unknown sources; writing to the wrong disk (`disk2s1` is not a stable identifier).

**Preferred deployment:** review a diff between baseline and experimental EFI; verify destination using `diskutil info` with volume UUID and size; perform an explicit verified copy only after all gates pass, followed by `sync`/safe eject. Do not combine GPU install + EFI overwrite + NVRAM reset + reboot into one unverified command.

## 5. OpenCore / EFI preflight

On a **copied staging EFI**:

1. Match `OpenCore.efi`, `BOOTx64.efi`, `OpenRuntime.efi`, any other OpenCore drivers, `config.plist` schema and the **exact matching OpenCore `ocvalidate`** release. Run `plutil -lint` and `ocvalidate`; fix every parse/dependency error.
2. Inspect `Kernel -> Add` for correct `BundlePath`, `ExecutablePath`, `PlistPath`, `Enabled` and load order. Lilu loads before Lilu plugins; VirtualSMC before its plugin kexts; VoodooI2C parent and plugins follow documented relationships. Don't infer functionality solely from index numbers.
3. Disable WhateverXe in baseline through **`Kernel -> Add -> Enabled=false`**; investigate/remove stale contradictory WEX `Kernel -> Block` rules in the *experimental copy*. Do not enable WhateverGreen at the same time as WEX.
4. Preserve SSD-specific `PC711Probe` and disabled `NVMeFix` until you have verified storage stability and its vendor notes; do not change storage drivers in a GPU experiment.
5. Preserve `SSDT-AWAC`, `SSDT-EC-USBX-LAPTOP`, `SSDT-PLUG-DRTNIA`, `SSDT-PNLF`, `SSDT-XOSI`, `SSDT-RHUB` as currently **working**. Their names alone do not prove that the ACPI methods match your BIOS; dump and review before applying any new hotkey fixes.
6. Use the USB-backed **read-only Python preflight** if Python is installed; it checks file references, conflicts, core properties and arguments but cannot certify hardware compatibility.

### `PollAppleHotKeys` / `KeySupport` — do NOT confuse with macOS hotkeys

- `Misc -> Boot -> PollAppleHotKeys` affects modifier shortcuts in **the OpenCore picker** (including `Shift+Enter` safe mode), not the ASUS backlight or brightness keys inside macOS.
- `UEFI -> Input -> KeySupport` affects preboot keyboard input. Change it only if the OpenCore picker has a known key-input fault.
- Do **not** disable both merely because Fn+F4/F5/F7 fail inside macOS. Keep tested preboot recovery keys working.

## 6. Controlled WhateverXe graphics acceleration (experimental EFI only)

**Hardware:** Intel Core i7-1165G7 specifies Iris Xe 96 EU, device ID `0x9A49` (Intel). The WEX project currently reports hardware tests for Tiger Lake-U 48/80 EU, not 96 EU. Your Samsung OLED eDP arrangement has not been proven in their test matrix.

### 6.1 Official build pairing and security

- Use an **exact compatible WEX + WEX Graphics pair** from official release pages, not a randomly named package. The prior Stage 2 target was WEX 0.8.3 and Graphics 0.4.4; verify the actual assets and revision date immediately before installation.
- `Lilu.kext` should meet WEX version requirement (its current README references 1.7.2 development headers; use the corresponding supported runtime version).
- Add **AMFIPass 1.4.1 Mod supplied/linked by WEX**. The user's earlier list shows `AMFIPass 1.4.1` only; inspect its source/signature because an Info.plist version does not prove it is the required **Mod** build.
- **Do not simultaneously load** upstream AMFIPass, AMFIAnchor/AMFIAnchorInjector and Mod AMFIPass on the basis of the old Stage 2 plan. Follow one current upstream trust chain.
- For the documented existing-installation path only, set **`csr-active-config` to binary Data `03080000`** (`0x803`), not a text string. Understand this weakens SIP protections; revert when reverting the experiment where possible.
- The unsigned/not-notarized Graphics package writes under `/Library`, rebuilds AuxKC and changes the installed macOS. Installing the matching kext solely on USB is **not** the full install.

### 6.2 `config.plist`: explicit table for experimental profile

| Field | Value/decision | Notes |
|---|---|---|
| `Kernel/Add/Lilu.kext` | `Enabled=true` | Before plugins. |
| `Kernel/Add/WhateverXe.kext` | `Enabled=true` | Only in experimental EFI. |
| `Kernel/Add/WhateverGreen.kext` | `Enabled=false` / absent | Do not load both. |
| `Kernel/Add/AMFIPass.kext` | `Enabled=true`, **Mod build** | Must be the project-linked modified build, not just 1.4.1 upstream. |
| `Kernel/Block` WEX rule | Remove only the conflicting rule from staged EFI, after inspecting it | `Kernel/Add/Enabled` governs injection. |
| `NVRAM/Add/7C436110-AB2A-4BBB-A880-FE41995C9F82/boot-args` | Required: `-allow3d -disablegfxfirmware`; remove `-wexoff` | Retain `-v keepsyms=1 debug=0x100` during diagnostics if appropriate. |
| Same NVRAM GUID / `csr-active-config` | **Data** `03080000` | Reduced SIP; **do not** write `03080000` as String. |
| `DeviceProperties/Add/PciRoot(0x0)/Pci(0x2,0x0)/device-id` | **No spoof by default** | WEX selects supported ID automatically; actual GPU is `0x9A49`. |
| `AAPL,ig-platform-id` | **Do not inject unverified fake ID** | Unneeded platform injection can black-screen the OLED. |
| `Misc/Boot/PollAppleHotKeys` | Keep known-working preboot setting | Unrelated to ASUS macOS brightness keys. |
| `UEFI/Input/KeySupport` | Keep known-working setting | Test picker selection and recovery shortcut. |

**Audit stale flags** before copying: `-novpanic`, `npci=0x2000`, `-dbgenhdbg`, `igfxonln=1`, `alcverbs=1`, `-igfxdvmt` should not be accumulated without a reproducible reason. Preserve one-variable-at-a-time control. Removing a flag from running NVRAM is ineffective if OpenCore re-injects it from `config.plist` on next boot. Do not blanket-clear NVRAM.

### 6.3 DVMT (ONLY if real allocation verified)

WEX README: set BIOS DVMT Pre-Allocated to **96 MB** if supported. If firmware is **fixed at 60 MB**, use their documented branch:

```text
boot-args: ... -allow3d -disablegfxfirmware -igfxdvmt
DeviceProperties -> Add -> PciRoot(0x0)/Pci(0x2,0x0):
  framebuffer-patch-enable = Data 01000000
  framebuffer-stolenmem    = Data 0000C003
```

Do **not** change DVMT or add these values blindly. An arbitrary 96 MB BIOS mod, stolen-memory number, fake `device-id`, hacked pixel clock or unverified `AAPL,ig-platform-id` can cause black screens. No BIOS flashing or hidden-variable writing in this plan.

### 6.4 Stage C: kext-only boot, then Graphics package

1. Confirm **separate working recovery USB** and the exact Sonoma build gate.
2. Clone working EFI into a staging folder. Set only the changes in 6.1–6.3, run validators and save SHA256 checksums + diff.
3. Boot **experimental USB** through ASUS `Esc` picker and select macOS **without** changing the default or internal EFI.
4. Confirm the screen stays on at FileVault/login/Desktop; if black screen, **STOP** and use the baseline USB. Collect verbose boot logs before another experiment.
5. Only when kext-only experimental USB reaches the desktop, inspect loaded WEX/Mod chain, and then install the **official matching WhateverXe Graphics `.pkg` into macOS** following its instructions. Keep the package and `uninstall.sh` from the same official project available locally.
6. Reboot with experimental USB and verify graphics, panel, app rendering, and **repeated cold boot**. If pkg installation errors appear, inspect `/var/log/install.log` before rebooting or repeating installation.
7. For failed Graphics install: boot recovery EFI, run official `uninstall.sh` for WEX Graphics with a backup and confirmed source, reboot, and restore baseline EFI + original security settings. **The USB EFI swap alone does not revert OS-installed Graphics.**

### 6.5 Prove 60 Hz **and** acceleration **and** measured FPS

Use three separate tests:

1. **Refresh mode:** `system_profiler SPDisplaysDataType` and System Settings Displays show the OLED at **1920×1080, 60 Hz**. This is just display output timing.
2. **Real driver:** The system reports a functioning Metal GPU and a real Metal app renders correctly. Check loaded kexts and display properties. Merely showing `1536 MB` VRAM or `Metal: Supported` is insufficient if the app fails to render or falls back.
3. **Measured FPS:** Use a reliable frame-time or FPS tool with a specific Metal app, same window/scene and power state. Log mean, 1% low, dropped frames and screen artifacts over at least 5 minutes. **60 FPS** means ~16.7 ms per frame; report actual result, never assert "smooth 60 FPS" without measurement. Check on AC and battery, thermal throttling, UI scrolling, video H.264/HEVC, browser canvas, display sleep/wake.

**Stop** if eDP remains black, flashes excessively, loses backlight, kernel panics, shows obvious artifacts, or fails cold boot. Changing platform-ID, display clock, framebuffer, and DVMT all at once destroys your ability to isolate the cause.

## 7. Brightness — actual OLED luminance, Fn F4/F5

**Goal:** real physical brightness controls, not software gamma overlays. Keep the existing visible display at every step.

1. Check System Settings > Displays: is there a brightness slider? Does it physically change OLED light output? Record at 20%, 50%, 80%.
2. Test **F4/F5, Fn+F4/F5 and Fn+Esc**. Determine whether hotkey events reach macOS using an HID-event viewer.
3. If slider works but keys don't, correct keyboard/ACPI translation only. Check `BrightnessKeys.kext` actual load, AsusSMC notifications and Fn-lock behavior.
4. If slider missing or doesn't affect actual light, investigate loaded GPU/backlight driver, actual `SSDT-PNLF` (`_PNLF` attachment), IORegistry `AppleBacklightDisplay`, firmware eDP configuration, and whether WEX panel backend supports it. A keyboard mapper won't create a missing backlight mechanism.
5. Modify only a **machine-specific SSDT** after extracting native ACPI and verifying source methods, then validate aml and boot. Don't invent `_Qxx`/GPIO addresses, VBT/EDID overrides, or use unsafe OLED PWM hacks.
6. Test after cold boot and wake, with minimal/max luminance steps and without black screen.

**Acceptance:** physical screen brightness responds from both the UI slider and F4/F5 repeatedly and stays stable at 60 Hz.

## 8. ASUS keyboard illumination — Fn F7

1. Verify physical keyboard lights work in ASUS firmware / Windows (if available). Avoid assuming absence of lighting due to OS failure.
2. Check `AsusSMC.kext` **actually loads** (not merely listed Enabled). Its upstream requirements include a supported ASUS **ATK** device and correct ACPI patching. Driver version alone does not guarantee it supports this BIOS.
3. In a native **ACPI dump**, inspect `ATKD`/WMI devices and keyboard-light method. AsusSMC checks an **`SKBV`** ACPI method and exposes `IsKeyboardBacklightSupported` in its implementation; use the real DSDT/IORegistry to confirm this pathway, not generic ROG/ThinkPad patches.
4. Test Fn+F7, Fn lock, keyboard illumination off/on levels; use HID viewer to decide whether events arrive.
5. If no supported ATK path but vendor-specific WMI works in Windows, record the documented limitation; investigate safe model-specific WMI/EC bridging. Do not randomly write EC register addresses.
6. Do not install competing hotkey drivers simultaneously (e.g. AsusSMC and another ASUS keyboard driver with overlapping events) without verifying code paths. Test sleep/wake persistence.

**Acceptance:** physical keyboard LEDs change in response to keypress, off/on and preferably multiple levels, without degrading typing, touchpad or sleep.

## 9. All F1–F12 and input devices

Verify one by one **against the actual ASUS manual and key icons**; do not guess an unrelated ASUS generation's layout.

| Hardware/action | Test | Dependencies / note |
|---|---|---|
| Mute, volume down/up | F1/F2/F3 and Fn variants | Key events + AppleALC; test speakers and headphones. |
| Screen brightness | F4/F5 | Section 7; actual luminance. |
| Touchpad toggle | F6 | Model may expose ASUS ATK/WMI or direct firmware key. |
| Keyboard backlight | F7 | Section 8. |
| Display/presentation switches | F8 where present | Do not plug external monitors until internal panel stable. |
| Function modes/media | F9–F12 by physical legends | Check actual firmware key paths; keyboard layouts differ. |
| Fn+Esc lock | Toggle Fn-lock twice and verify | Check firmware support, not OpenCore preboot setting. |
| Precision trackpad | tap, gestures, clicks, palm rejection | VoodooI2C, HID and GPIO path. |
| Keyboard | typing, key repeat, special symbols, backlight | VoodooPS2Keyboard + ASUS EC. |
| NumberPad (if fitted) | test independently from pointing | May need model-specific driver not automatically available. |

For I2C, disable `-vi2c-force-polling` **only** if the GPIO interrupt path is demonstrated working; polling can be a reliability workaround. Check no duplicate `VoodooInput` plugin loads.

## 10. Wi-Fi speed — real AX201 tuning, not fabricated Mbps

**Screenshot says ~54 Mbps on 2.4 GHz**; treat that as a reported *link rate*, not an independently verified internet speed. Wi-Fi link rate, LAN throughput, and ISP/download speed are different metrics.

### Test before router changes

```bash
networksetup -listallhardwareports  # identify correct Wi-Fi interface
system_profiler SPAirPortDataType    # band, PHY, channel and link details (may expose SSIDs)
networkQuality -v                   # actual network quality/internet test
ping -c 20 1.1.1.1                 # latency/loss indicator; not bandwidth
```

Record band **2.4/5 GHz**, channel width **20/40/80/160 MHz**, RSSI/noise if available, negotiated TX rate, Wi-Fi driver/build, router capabilities, distance, obstacles, number of clients, ISP rate and an independent device's results in the same location. Do speed tests over several runs at different times; wireless fluctuates.

### Corrective steps in order

1. **Connect to a verified 5 GHz SSID** when in good signal range. If one SSID uses band steering, temporarily split SSIDs on router only if you control it and understand other users' impact.
2. Check the router actually offers 5 GHz **802.11ac VHT80**; 160 MHz only if supported, stable and locally permitted. Wider channels can increase interference; do not force 160 MHz blindly.
3. Set WPA2-AES or supported WPA3 security; avoid WEP/TKIP/legacy compatibility that can restrict modern modes. Do not use illegal channel or country-code spoofing.
4. Leave native AX201 Intel card installed; **AirportItlwm 2.3.0 stable** is the documented Sonoma driver, with a separate binary for 14.0–14.3 vs 14.4+. **Never load both** `itlwm.kext` and `AirportItlwm.kext` together.
5. **Important limitation:** the OpenIntelWireless FAQ states `HE` (802.11ax / Wi-Fi 6) is **disabled** although VHT80 and VHT160 are implemented. Do not promise Wi-Fi 6 native AX performance under macOS.
6. Compare multiple Speedtest/`networkQuality` runs, router LAN `iperf3` if available, and a wired adapter or another known-good client to separate router/ISP limits from macOS driver limits.
7. Check Bluetooth interference in 2.4 GHz, USB 3 devices close to antennas, weak 5 GHz signal, antenna connection, router firmware and network congestion only if measurements point to them.
8. Avoid fake "speed unlock" NVRAM flags, aggressive TCP sysctl tweaks, random DNS changes, or replacing working Wi-Fi kext just to chase a claimed 867 Mbps number. DNS does not increase physical Wi-Fi throughput.
9. Only if macOS driver is proved the bottleneck, compare a documented compatible `itlwm.kext + HeliPort` setup on **another boot profile**, accepting that native Wi-Fi integration changes. Do not install both.

**Acceptance:** stable 5 GHz association where available, demonstrably higher measured **real throughput** than baseline with no dropouts or connectivity regression. Record numbers; there is no universal guaranteed Mbps.

## 11. Remaining hardware, safety and reliability audit

| Area | Required test | Stop / rollback on |
|---|---|---|
| PC711 NVMe | `diskutil verifyVolume` on correct volume only as a read-focused verification; large file copy with checksum to a backed-up location; repeated boots | resets, kernel panics, filesystem errors |
| Battery and CPU power | charge %, discharge, idle drain, charge limit if firmware actually implements it; check `pmset`, frequency/thermal behavior | abnormal heat/drain, charging glitches |
| Sleep/wake | lid close/open, 10–20 repeated wakes, idle sleep, overnight as optional later test | black OLED, data loss, frozen USB/I2C |
| Intel Bluetooth | pairing, reconnect, sleep/wake, audio; preserve correct Intel firmware / patch stack | persistent disconnects or kernel panic |
| ALC294 sound | speaker, mic, headset, mute/volume, video call | lost audio or wake panic |
| Touchpad | pointer, two-finger scroll, gestures, palm rejection, Fn toggle | lost input / random ghost touches |
| USB-A/USB-C | flash storage, powered peripheral, boot, charging safety; ports mapped individually | port loss / unstable wake |
| Webcam | video capture, reconnect after sleep | disappeared camera |
| OLED | full-screen image/color, 60 Hz, brightness, display-off/on, black-screen recurrence | black screen / severe flicker |
| Thermal & fan | 15–30 min controlled load, actual temps if reliable sensors available, noise and throttling; keep fans under firmware control | abnormal temperatures, sustained throttling |
| Security | acknowledge reduced SIP, check FileVault status and disk backup, test System Update strategy | broken disk unlock or inability to revert |

**Do not** enable `SMCProcessor.kext` on a machine with a recorded Tiger Lake panic solely for a temperature widget. Sensor data requires an actually compatible source. Avoid changing ACPI and SMBIOS while diagnosing graphics.

## 12. Boot test matrix with objective results

| Test | Baseline A | Hotkeys B | WEX C | WEX+Graphics D |
|---|---|---|---|---|
| cold boot to usable desktop, three times | □ | □ | □ | □ |
| FileVault unlock / original Windows boot | □ | □ | □ | □ |
| internal OLED stable at native 1080p60 | □ | □ | □ | □ |
| native OLED physical brightness slider | □ | □ | □ | □ |
| F4/F5 and Fn+F7 actual effect | □ | □ | □ | □ |
| Metal rendering + measured FPS | N/A | N/A | □ | □ |
| Wi-Fi speed, packet loss and reconnect | □ | □ | □ | □ |
| audio, touchpad, keyboard, battery | □ | □ | □ | □ |
| USB-A/C, camera, Bluetooth | □ | □ | □ | □ |
| multiple sleep/wake and shutdown | □ | □ | □ | □ |
| no new panic and logs inspected | □ | □ | □ | □ |

Fill with `PASS/FAIL/UNVERIFIED`, timestamps and diagnostic evidence. **Do not mark a row PASS based only on a chat agent claiming “WORKING.”**

### Performance targets (acceptance, not guarantees)

- OLED **1920×1080/60 Hz** native output and no black screen.
- GPU loaded, actual Metal app works, test FPS recorded without a claim of guaranteed 60.
- Native brightness slider changes *luminance* and F4/F5 events work.
- Fn+F7 changes physical keyboard illumination.
- 5 GHz (where router and signal allow), measured Wi-Fi rate and real throughput improved versus known 2.4 GHz baseline.
- At least 3 consecutive cold boots; at least 10 short sleep/wake checks after driver changes; no new data loss or storage panics.

## 13. Rollback — tested before experiments

**Failure on USB kext-only experiment:** power off; use the *separate recovery USB*, boot macOS, and recheck the unchanged internal EFI and original boot args. Do not reset NVRAM blindly. If no display after the boot text, stop re-running the same EFI and collect logs.

**Failure after WEX Graphics `.pkg`:** swapping EFI alone **does not** remove the OS driver package. Boot known-good rescue path; use the project's official, reviewed `uninstall.sh` (`sudo bash uninstall.sh`) and reboot; restore compatible graphics cache, EFI and NVRAM/SIP configuration. Keep a full backup / APFS snapshot before package changes.

**Failure after keyboard/ACPI patch:** revert only the changed SSDT and config entries on the staged USB; do not delete every ACPI patch in frustration.

**Failure after changing Wi-Fi:** revert to last verified `AirportItlwm` config/SSID; restore router configuration (written down before changes); test link independent of macOS.

**Failure after internal EFI copy:** restore an exact, verified EFI backup using booted recovery media and the **confirmed** target EFI partition UUID; never infer `/dev/diskXsY` from an earlier boot.

## 14. Implementation order and work ownership for a high-effort coding agent

Use this sequence **without skipping gates**:

**Phase 0 — forensic safety**: inspect `deploy_master_zenbook_hardware.sh`, record file SHA256 and all destructive commands; compare screenshot claims to source; create rescue and data backups; identify all EFI partitions by diskutil.

**Phase 1 — data collection**: baseline diagnostics, kext loading, GPU device ID, macOS build, actual display brightness keys, ATK/WMI/EC methods, router band/link rate, AppleALC, touchpad and power tests.

**Phase 2 — compatibility**: official version matrix WEX/Graphics/Mod AMFIPass, Sonoma build; full EFI diff and `ocvalidate`; remove contradictory legacy graphics/synthetic display patches only from experimental copy.

**Phase 3 — input first**: repair brightness key events if slider already works; keyboard backlight only after verified ATK method; one ACPI change per iteration.

**Phase 4 — acceleration**: stage isolated WEX EFI; preflight and boot; install matching WEX Graphics **inside macOS** only after kext boot passes; verify Metal, OLED refresh/luminance and actual FPS.

**Phase 5 — network**: record 2.4 GHz benchmark; test 5 GHz 80 MHz; review Sonoma-specific Intel Wi-Fi kext and router configuration; compare speed + loss + wake.

**Phase 6 — regression**: audio, Bluetooth, touchpad, camera, USB-C, power, SSD health, lid sleep, brightness, software login, FileVault, cold boots, thermal tests.

**Phase 7 — release**: generate a versioned ZIP with a redacted config diff and hashes, a result sheet with PASS/FAIL/UNVERIFIED, a human-reviewed rollback runbook, and a user-approved optional internal EFI deployment. Never create an unreviewed auto-reboot script.

### Deliverable names

```text
UX325EA_STAGE2_STAGE3_MASTER_PLAN.md
UX325EA_Stage3_ReadOnly_Diagnostics.sh
UX325EA_Stage3_Graphics_Config_Preflight.py
UX325EA_Test_Matrix.csv
UX325EA_Stage3_README.txt
```

## 15. Source links / material distinctions

1. **ASUS UX325EA OEM panel/CPU specs:** https://www.asus.com/eg-en/laptops/for-home/zenbook/zenbook-13-oled-ux325-11th-gen-intel/techspec/ — lists 13.3-inch OLED 1920×1080 at 60 Hz.
2. **Intel i7-1165G7 GPU specs:** https://www.intel.com/content/www/us/en/products/sku/208662/intel-core-i71165g7-processor-12m-cache-up-to-4-70-ghz/specifications.html — 96 EU, 0x9A49.
3. **WhateverXe:** https://github.com/b00t0x/WhateverXe — currently experimental for untested 96-EU Tiger Lake-U and external reconnection/sleep limitations; mandatory flags, DVMT conditional, required macOS builds.
4. **WhateverXe Graphics:** https://github.com/b00t0x/WhateverXe-Graphics — current AMFIPass **Mod** trust chain, `.pkg`, SIP, official uninstall procedure.
5. **OpenIntelWireless:** https://github.com/OpenIntelWireless/itlwm/releases ; https://openintelwireless.github.io/itlwm/FAQ — Sonoma build selection, 5 GHz VHT/HE disabled, feature limitations.
6. **AsusSMC:** https://github.com/hieplpvip/AsusSMC ; https://github.com/hieplpvip/AsusSMC/blob/master/AsusSMC/AsusSMC.cpp — ATK prerequisite and SKBV keyboard backlight path.
7. **OpenCore:** https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Configuration.tex — `PollAppleHotKeys` is preboot modifier handling.

**Status on publication:** Plan prepared, **not executed**. Only a real copy of the user's EFI / macOS build / logs / actual script can establish which custom patch is appropriate and whether each hardware goal is achieved.
