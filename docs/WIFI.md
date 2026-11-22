# Wi-Fi after sleep — the investigation

The Intel AX201 worked, but "Wi-Fi gets lost after the lid" kept coming back. This is what the
logs showed, step by step, and what fixed each part.

## 1. The laptop went back to sleep two minutes after the lid opened

The power log showed `Entering Sleep state due to 'Idle Sleep'` every ~2 minutes **while the
laptop was in use**. macOS's battery defaults (display off after 2 min, sleep right after) put it
to sleep as soon as nobody touched the keyboard — and every sleep switches the Wi-Fi card off.
On a real Mac the card is back within a second; here it takes 5–9 s and sometimes never returns.

**Fix — `fix-wifi.sh`:** battery display off after 5 min and sleep after 30 min, charger never
sleeps by itself. Closing the lid still sleeps immediately.

## 2. AirportItlwm lost the router 10–95 s after joining

With the idle sleep gone, a hands-off lid check showed the second problem: Wi-Fi came back, worked
for about 75 s, then disassociated (`signal 0 dBm`). The kernel then logged
`IO80211ScanManager::startScan: Scan request failed (22)` and the driver never rejoined — even after
a Wi-Fi off/on. The history showed the same drops **without the lid** right after start-up, and
one session in which the driver did not start at all.

The installed AirportItlwm was verified byte for byte against the official 2.3.0 "Sonoma 14.4+"
build, so it was not a wrong build.

**Mitigations in ZenBookHelper (still active with AirportItlwm):**

| Version | Change |
|---|---|
| 8.21 | link-health check every 10 s — router ping, internet TCP probe, DNS; reconnects a link that passes no traffic for ~30 s (max once per 3 min, 3 per hour) |
| 8.22 / 8.23 | Wi-Fi **off right before sleep, on right after wake** — a clean restart instead of the driver's own resume path (8.23 fixed 8.22 switching it back on before the real sleep) |
| 8.24 | logs `after wake +60/120/180 s: Wi-Fi working / NOT working` after every wake |

With 8.24 one lid wake stayed up (working at +60 s and +120 s), another still dropped at ~80 s.

## 3. The switch to itlwm

`itlwm` is the same Intel driver without Apple's Wi-Fi stack: macOS's background scans and roaming
requests never reach it, and the HeliPort menu-bar app joins and re-joins the network.

| | AirportItlwm | itlwm + HeliPort |
|---|---|---|
| Wi-Fi menu | Apple's | HeliPort icon |
| Wi-Fi-based location | ✅ | ❌ |
| Stability on this laptop | drops 10–95 s after joining | daily driver |
| AirDrop / AWDL | ❌ | ❌ (no Intel card can do it) |

Switch at any time — both directions edit the SSD's and the USB's EFI, with backups:

```sh
sudo sh "/Volumes/<USB>/wifi-driver.sh" itlwm      # or: airport · status
```

## Checking it yourself

```sh
~/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper wifiprobe   # router, internet, DNS, verdict
sudo sh "/Volumes/<USB>/fix-wifi.sh"                                       # lid check with a log
grep "after wake" ~/Library/Logs/ZenBookHelper.log                         # every wake's verdict
```
