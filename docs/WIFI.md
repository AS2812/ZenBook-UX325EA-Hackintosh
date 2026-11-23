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
| Stability on this laptop | drops 10–95 s after joining | daily driver + recovery agent |
| AirDrop / AWDL | ❌ | ❌ (no Intel card can do it) |

Switch at any time — both directions edit the SSD's and the USB's EFI, with backups:

```sh
sudo sh "/Volumes/<USB>/wifi-driver.sh" itlwm      # or: airport · status
```

## 4. Recovery agent and speed test (Wi-Fi 2.1)

With itlwm, macOS no longer manages the card, so a small login agent watches it through the
public itlwm / HeliPort API (no extra kernel code):

| Situation after a wake | What the agent does |
|---|---|
| Driver ready, HeliPort closed | opens HeliPort once the interface exists |
| Radio on, still searching after 60 s | asks HeliPort for a fresh saved-network scan |
| Worked before, radio on, **driver's network list empty for 60 s** | restarts the Intel radio **once**, after re-checking right before |
| Router known to answer goes silent, no packets, no TCP reply for 45 s | restarts the radio once |
| Radio switched off by you | leaves it off |
| **System going to sleep / waking up (2.3)** | stops the radio cleanly before sleep, restarts it with fresh firmware after wake — itlwm's own sleep handler never touches the card |
| Joined, DHCP service waiting for an address | a root job asks macOS to retry DHCP |

2.3: up to 3 automatic restarts per failure, 2 minutes apart (2.1/2.2: one, then 10 minutes); a
recovered link resets the count, so it can never loop. Visible networks or a failed list read
never trigger a restart. Record a whole day with `sudo sh "/Volumes/<USB>/wifi-log.sh"` (Enter
stops it).

**ZenBook Wi-Fi Repair → Test Speed** runs Apple's `networkQuality` on the Intel interface and
reports download, upload, band, channel, width and signal. On 2.4 GHz it offers **Try 5 GHz**
when the same network (same name and security) is visible on 5 GHz at a strong signal; the driver
then picks the band. The installer also removes the itlwm troubleshooting switches `-novht` and
`-noht40` from every OpenCore profile, because they switch off 802.11ac and 40 MHz channels.

> [!NOTE]
> 2.1 passed simulated wake, empty-list, stall and recovery replays. Real-world throughput and
> long-sleep behaviour still need a run on the laptop: test speed, close the lid for 10 minutes,
> use Wi-Fi for 10 minutes, test again, then **Show Report → Save a Copy**.

Source, policy tests and the profile updater: [src/WiFiRecovery](../src/WiFiRecovery).

## 5. The two "!" icons (Wi-Fi 2.2, `fix-wifi.sh` 2.0)

| Icon | Meaning | Fix |
|---|---|---|
| HeliPort "!" | joined, but `captive.apple.com` is not reachable for macOS (HeliPort's own rule) — no service, no IP or no DNS on the Intel card | `fix-wifi.sh`: own DHCP service "Intel Wi-Fi", first in the order; DHCP renew; public DNS only if the router's DNS fails |
| macOS Wi-Fi "!" | itlwm is an Ethernet-type interface, macOS has no Wi-Fi card to show | hidden from the menu bar; `wifi-driver.sh airport` shows it again |

The old "Wi-Fi" service from AirportItlwm keeps the same BSD name (`en0`) but is bound to an
802.11 interface type. Agent 2.1 matched services by BSD name only, so it could take that
leftover service for the Intel card's and never create the missing one. 2.2 also compares
the interface type, so the root DHCP job re-creates a missing service by itself.

## 6. Slow or lost Wi-Fi: what actually limits it (research, 2026-11-23)

| Factor | Evidence | What to do |
|---|---|---|
| **HeliPort auto-join order** | HeliPort tries saved networks in list order and joins the first visible one, ignoring signal strength (`NetworkManager.scanSavedNetworks`). The laptop log showed it joining a far 5 GHz network at -86 dBm, losing it ~90 s later, then rejoining home. | Keep **Auto Join** only on your home network (HeliPort → Preferences → Networks), or drag it to the top. `fix-wifi.sh` 2.1 lists the order and checks it. |
| **Signal level** | -74 … -86 dBm on the laptop vs -59 dBm for a Mac near the router. | Aim for -65 dBm or better. |
| **2.4 GHz + Bluetooth** | The itlwm FAQ notes 2.4 GHz performance issues with Bluetooth coexistence; the AX201 shares the band and antenna. | Use 5 GHz where possible; compare Test Speed with Bluetooth off. |
| **Router channel / security** | Auto channel 3 overlaps 1 and 6. With TKIP as the *pairwise* cipher itlwm (OpenBSD net80211) refuses 802.11n/ac (`ieee80211_ht_negotiate`); mixed TKIP+AES still picks AES. | Fixed channel 1, 6 or 11, 20 MHz, WPA2-PSK AES only. |
| **Driver** | itlwm 2.3.0 is the latest official release. The FAQ quotes up to 950 / 650 Mbps on 5 GHz 160 MHz (AX201 tested; 802.11ax disabled, 11ac used). The project calls itlwm "stabler and faster" than AirportItlwm. | Stay on itlwm. Community "Wi-Fi 6" AirportItlwm forks from Nov 2026 are experimental debug builds tested on AX210 only. |
| **Hardware** | The AX201 is a CNVi module; a Broadcom or AX210 card needs a PCIe-capable slot. A UX325EA teardown confirming a removable slot was not found. | A USB-C Ethernet adapter is the zero-risk wired option. |

Sources: [itlwm FAQ](https://openintelwireless.github.io/itlwm/FAQ.html) ·
[itlwm installation notes](https://openintelwireless.github.io/itlwm/Installation.html) ·
[itlwm releases](https://github.com/OpenIntelWireless/itlwm/releases) ·
[Notebookcheck UX325EA review (Windows iperf3)](https://www.notebookcheck.net/Asus-ZenBook-13-laptop-review-Core-i7-1165G7-versus-Ryzen-7-5800U-Which-one-is-the-better-ZenBook.540357.0.html)

## 7. The freeze (2026-11-23 logs)

| Time (UTC) | What the agent saw |
|---|---|
| 12:45:03 | wake, joined in 15 s, working at -74 … -82 dBm |
| 12:53:48 (+525 s) | radio on, **driver list empty** |
| 12:54:49 | radio restart (full stop + firmware init) → **still empty**; recovered only after a reboot |
| 13:15:21 → 13:23:42 (+502 s) | the same pattern again |
| 13:34 | froze during a speed test (upload phase), ~1 minute after boot |
| 13:37 | after a quick restart the itlwm driver **did not attach at all** |

itlwm itself reports `power on` throughout, because its power state is taken from the interface
flags, so the agent judges by the scan list. Intel's own forum has AX201 reports of drops every
5–10 minutes on Wi-Fi 4/5 routers and of a card that only worked again after a power-off. Package
2.4 detects the freeze, tells the user to close the lid for 15 s or **Shut Down (not Restart)**, and logs
whether the lid revived it; `wifi-log.sh` with Bluetooth on vs off isolates the trigger.

## 8. The root cause in the driver, and the patch (itlwm 2.3.1 "UX325")

Reading the itlwm 2.3.0 source explained every symptom in §7:

- `iwx_init_task` computes `fatal = HW_ERR | RFKILL`, stops the device and only calls `iwx_init` when
  **not** fatal. A fatal firmware error, device timeout or critical-temperature stop therefore leaves
  the card stopped for good — interface still "up", scan list empty.
- Radio on (`ItlIwx::enable` → `DVACT_WAKEUP`) starts the card only if a single 50 ms `NIC_READY`
  poll succeeds; after a crash it does not, so the agent's radio restart could not revive it.
- At attach, a card that does not answer is "not recognised" and the driver does not start.
- `XYLog` is `kprintf`, which macOS does not keep — so none of this was visible.

The patch fixes all four ([src/itlwm-UX325](../src/itlwm-UX325)); its messages start with `itlwm:` and
contain `UX325` when a recovery happens, and `wifi-log.sh` lists them.

## Checking it yourself

```sh
~/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper wifiprobe   # router, internet, DNS, verdict
sudo sh "/Volumes/<USB>/fix-wifi.sh"                                       # lid check with a log
grep "after wake" ~/Library/Logs/ZenBookHelper.log                         # every wake's verdict
```
