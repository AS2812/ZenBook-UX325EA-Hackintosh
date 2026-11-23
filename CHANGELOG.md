# Changelog

All notable changes to this setup. Versions follow the USB kit (`usb-kit/README.txt` has the
full, step-by-step log of every test).

## v10.14 — 2026-11-23 · why Wi-Fi was slow and dropped after a minute

- **`fix-wifi.sh` 2.1** — lists HeliPort's auto-join order and walks you through fixing it
  (HeliPort joins the first visible saved network even at -86 dBm, which then drops after about a
  minute), retries the internet check while the link settles, and runs a speed test over the
  Intel card with signal, channel and transmit rate in the log.
- [docs/WIFI.md §6](docs/WIFI.md) — what really limits Wi-Fi on this laptop, with sources.

## v10.13 — 2026-11-23 · one command for Wi-Fi, no more "!" icons

- **`fix-wifi.sh` 2.0** — installs / updates the Wi-Fi package and its jobs, gives the Intel
  card an enabled DHCP service "Intel Wi-Fi" first in the order, renews DHCP, falls back to
  public DNS only when the router's DNS fails, checks reachability exactly like HeliPort,
  hides the macOS Wi-Fi icon (it cannot work with itlwm), sleep timers, optional lid check.
- **Wi-Fi package 2.2** — the recovery agent matches network services by interface type as
  well as BSD name, so the leftover AirportItlwm "Wi-Fi" service no longer hides a missing
  Intel service.
- `wifi-driver.sh` 1.1 — hides the macOS Wi-Fi icon for itlwm and restores it for AirportItlwm.

## v10.12 — 2026-11-23 · Wi-Fi recovery 2.1 and a speed test

- **Empty network list after the lid:** when Wi-Fi worked before, the radio is on and itlwm's
  network list stays empty for a minute, the recovery agent restarts the radio once (re-checked
  right before; then only after a recovered link or new wake, 10-minute cooldown).
- **ZenBook Wi-Fi Repair → Test Speed** — download / upload over the Intel interface with band,
  channel, width and signal; **Try 5 GHz** when the same network is strong on 5 GHz.
- The Wi-Fi installer removes `-novht` / `-noht40` from all OpenCore profiles and validates each.
- **Show Report → Save a Copy** — wake history and the latest speed test in one file.
- New source folder [`src/WiFiRecovery`](src/WiFiRecovery) with policy tests.

## v10.11 — 2026-11-22 · Wi-Fi on itlwm, lid-wake hardening, less logging

- **Wi-Fi:** the daily setup now uses **itlwm 2.3.0 + HeliPort 1.5.0**. AirportItlwm lost the
  router 10–95 s after joining on this laptop (with or without the lid) and sometimes refused
  every scan afterwards. `wifi-driver.sh` switches between the two on the SSD's and the USB's EFI.
- itlwm's built-in sample networks removed (one was an open network called "Redmi").
- **Performance:** daily profiles no longer load DebugEnhancer and drop `-dbgenhdbg`.
- `fix-wifi.sh` 1.3 — no idle sleep 2 minutes after opening the lid (battery 5/30 min, charger
  never), automatic lid check, log kept on the SSD.
- ZenBookHelper 8.22–8.24 — Wi-Fi off during sleep / on after wake, retries at 40 s · 2 min ·
  4 min, itlwm awareness, `after wake +60/120/180 s` Wi-Fi verdicts.
- `zenbook-status.sh` — read-only report of what the laptop actually runs.

## v10.10 — 2026-11-21 · macOS only, Wi-Fi link health

- `make-mac-only.sh` — deletes Windows and grows macOS over the whole SSD (341.5 GB → 1024 GB),
  OpenCore on the SSD with the menu off. Refuses if Windows sits before macOS.
- ZenBookHelper 8.21 — link-health check every 10 s (router, internet, DNS); reconnects a stalled
  link by itself; `wifiprobe` command.
- ZenBookHelper 8.20 — switches the ALC294 speaker amplifier on after a fresh start.

## v10.8 — 2026-11-20 · speakers after the lid, Delete key

- AppleALC **layout 66** (same wiring as 11, plus amplifier re-enable at every wake).
- Delete key next to the power button = Move to Trash in Finder.
- Leaked identifiers removed from the repository history.

## v10.7 — 2026-11-20 · clean loading screen

- Driver v4.6 converts the 8-bit boot console image to the 30-bit framebuffer — no more
  coloured pixels at boot and login. Fn-lock restored after a lid wake.

## v10.5 – v10.6 — 2026-11-20 · hotkeys after a lid wake

- Root cause: AsusSMC passed 8-byte WMI arguments to a 20-byte buffer, so the ATK hotkey device
  never initialised. `SSDT-WAKE` pads them; the EC lid sensor is polled after every wake.
- Driver v4.4 switches the panel off before power-off — a black shut-down screen.

## v10.0 — 2026-11-20 · ready to make permanent

- Lid wake fix, final profiles, `sync-efi-to-ssd.sh` v2 (Windows-safe, verified copy).

## v9.x — 2026-11-19 / 20 · real OLED brightness and a Mac-like boot

- **Real OLED brightness** over DPCD nits (v9.6), Control Centre slider, black at 0.
- Bluetooth fix (AX201), USB map, power button sleep, two-finger menu, NumberPad.
- Boots straight into macOS without a menu (v9.3).
- **GPU acceleration works** (v9.2) — Metal, 1920×1080, 30-bit.

## v8.x — 2026-11-18 / 19 · the Iris Xe black screen

- Six diagnostic boots traced the black OLED to Apple's eDP link setup; the custom WhateverXe
  build fixes the timing and lane/rate computation.
  See [docs/IRIS-XE-BLACK-SCREEN-FIX.md](docs/IRIS-XE-BLACK-SCREEN-FIX.md).
