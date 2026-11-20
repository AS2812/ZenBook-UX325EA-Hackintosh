# OLED brightness, Fn keys after sleep, mute, two-finger menu, Wi-Fi — what was wrong and how it is fixed

Machine: ASUS ZenBook 13 OLED UX325EA, Samsung ATNA33XC11 OLED (eDP), Realtek ALC294,
Intel AX201, ELAN 04F3:3134 touchpad. macOS Sonoma 14.8.9 with the Iris Xe driver from this repo.

## 1. Real OLED brightness

* **Symptom:** with GPU acceleration the brightness keys did nothing. Earlier versions used a
  black overlay ("software dimming").
* **Cause:** Apple's Tiger Lake framebuffer only sets the PCH PWM duty cycle. An OLED has no PWM
  backlight. The panel's DPCD shows it implements Intel's HDR/OLED brightness interface: 0x340 =
  `01 57 01`, nits capability, and SDR AUX enabled by the firmware (0x344 bit 4). The VESA eDP
  brightness registers are not wired (PWMGEN bit count 0).
* **Fix:** driver patch `-wex-tgl-edp-bl` writes the brightness in nits to 0x354/0x355, scaled to
  the panel's maximum luminance from its EDID HDR metadata (616 nits).
* **Control Centre slider:** macOS creates its "brightness" parameter only when the panel driver
  has a brightness curve. WhateverXe adds a 16-bit curve only for `SSDT-PNLF` `_UID` 19, but this
  kit used 24. With `_UID 0x13`, the Control Centre slider, the native keys, the brightness
  bezel and the 16 Mac-like steps all work.
* **Brightness 0:** this kit boots with `-wex-tgl-edp-bl-zero`, so 0 is black like a MacBook.
  Remove that boot-arg to keep a 3-nit minimum.

## 2. Fn volume / mute dead after sleep

All Fn keys arrive as embedded-controller queries:

| Keys | EC queries | Route |
|---|---|---|
| Fn+F4/F5 (brightness) | `_Q15` / `_Q16` → `QLIB` → `BRTN` | `Notify(DD1F, 0x86/0x87)` → BrightnessKeys → PS/2 keyboard |
| Fn+F1/F2/F3 (mute, volume) | `_Q1A` / `_Q1B` / `_Q1C` → `QLIB` | `ATKD.IANE(0x32/0x31/0x30)` → AsusSMC |

`IANE` puts the code into a 16-entry queue in `ATKD` and sends one `Notify(ATKD, 0xFF)`. AsusSMC
answers each Notify by taking one entry (`_WED` → `GANQ`).

After a lid or power-button sleep, brightness kept working but volume and mute never reached
macOS. The EC still sends the queries, because brightness uses the same mechanism. The loss is in
the ATK queue / AsusSMC hand-over.

**Fix (`SSDT-WAKE`, `BrightnessKeys-UX325.kext`):**
* OpenCore renames `ATKD.IANE` to `XANE`, and the SSDT provides a new `IANE`.
* Volume up, volume down and mute become `Notify(DD1F, 0x90/0x91/0x92)`.
* BrightnessKeys-UX325 is BrightnessKeys 1.0.3 plus these three codes. It delivers them to the
  PS/2 keyboard as ADB 0x48/0x49/0x4A, which VoodooPS2 maps to sound up, sound down and mute.
  This is the same route that brightness uses, and it survives sleep.
* The other ATK keys still go through the queue. A stale entry is flushed before each new key and
  on every wake (`XWAK` also calls `ATKD.INIT`, as Windows does).
* `XPTS(5)` clears the XHCI PME enable on Shut Down.

ACPI simulation (acpiexec, DSDT + all SSDTs):
* `_Q1C` gives `Notify(DD1F, 0x90)`.
* The keyboard-light code `0xC5` still reaches AsusSMC.
* Brightness still gives both `Notify(ATKD)` and `Notify(DD1F, 0x86)`.
* `_WAK(3)` flushes the queue and calls INIT.

## 3. Mute key

* **Mute:** ALC294 layout 11 accepts the mute flag but keeps the speaker amplifier playing.
  ZenBookHelper mutes by setting the volume to 0, and restores it.
* **Held key:** a held key used to flip mute about 10 times. One press is now one toggle.
* **Bezel:** mute and unmute both show the macOS bezel (private `OSDManager`).

## 4. Lid open → black screen

* **Symptom:** lid close fades the OLED to 0. On lid open, macOS restores the brightness, but if
  that write arrives before the eDP panel is powered, the driver must skip it (AUX to an
  unpowered sink only times out), and the panel stays black.
* **Fix:** driver v4.3 remembers the skipped level and re-sends it at DPCD `SET_POWER` D0.
  ZenBookHelper also re-sends the current brightness 2.5 s after every wake, and logs the
  clamshell, display and driver state.

## 5. Touchpad, Wi-Fi, power button, lock screen

* **Two fingers** (tap or click) open the menu like on a Mac. Helper versions 8.9–8.13 turned that
  into a left click by mistake.
* **Wi-Fi:** AirportItlwm needs up to two minutes to join at -75 to -88 dBm. The helper's watchdog
  never interrupts a join. It switches Wi-Fi off and on at most once per wake or drop, after 90 s
  with no link.
* **Power button:**
  * The press reaches loginwindow, but nothing happens on this model.
  * The helper sends a short press to sleep, like a MacBook (`zenbook-helper powerbutton off` to
    disable).
  * `fix-hardware.sh --test` sets "require password immediately".

## 6. Not possible

* **Built-in microphone:** it is a digital mic on Intel's audio DSP (Smart Sound / SOF). On Linux
  it only works with the SOF driver. macOS has no driver for that DSP, so use the headset jack,
  Bluetooth or a USB microphone.
* **Windows Hello IR camera; Thunderbolt hot-plug of PCIe devices.**
