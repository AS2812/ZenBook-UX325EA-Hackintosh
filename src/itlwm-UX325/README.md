# itlwm 2.3.1 "UX325" — patched Intel Wi-Fi driver

Official [itlwm](https://github.com/OpenIntelWireless/itlwm) **v2.3.0** (`4ac4c79`) plus
[`0001-itlwm-2.3.0-UX325EA.patch`](0001-itlwm-2.3.0-UX325EA.patch). It ships inside the Wi-Fi
package 2.5; this laptop's USB EFI keeps the official build as the fallback.

| # | Change | Why (AX201 on the UX325EA) |
|---|---|---|
| 1 | `iwx_init_task`: after a fatal firmware error / device timeout / critical-temperature stop, restart the device (max 5 per 10 min) | OpenBSD stops the device and waits for `ifconfig up`; nothing on macOS does that, so the card stayed dead with an empty scan list until a power-off |
| 2 | `DVACT_WAKEUP` (radio on): always run `init_task` | one 50 ms NIC_READY poll failed after a crash and nothing else started the card; `iwx_start_hw` has the full sequence (retries, SW reset, power gating for integrated CNVi) |
| 3 | attach: if HW_REV / RF_ID read all-ones or zero, SW-reset + `iwx_prepare_card_hw` and read again | after a warm restart the frozen card was not recognised and the driver did not start |
| 4 | `XYLog` also `IOLog` (≤ 40 lines / 10 s) | `kprintf` never reaches the macOS log — errors were invisible |
| — | private `__bzero`, `clock_get_uptime` | newer clang imports `__bzero`; the built kext now imports exactly the same kernel symbols as the official 2.3.0 |

Build (Xcode 26, x86_64):

```sh
git clone https://github.com/OpenIntelWireless/itlwm && cd itlwm && git checkout v2.3.0
git clone --depth 1 https://github.com/acidanthera/MacKernelSDK
git apply ../0001-itlwm-2.3.0-UX325EA.patch
xcodebuild -project itlwm.xcodeproj -scheme itlwm -configuration Release ARCHS=x86_64 MODULE_VERSION=2.3.1
```

Rollback on the laptop: `sudo sh "/Volumes/<USB>/wifi-driver.sh" stock`. License: GPL-2.0, like itlwm.
