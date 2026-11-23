ZenBook UX325EA Hackintosh - v10.14 (2026-11-23)
=================================================

WHY WI-FI IS SLOW / LOST AFTER A MINUTE (found 2026-11-23 from the laptop's own log)
  1. HeliPort joins the FIRST saved network it can see, even a weak far-away one. The log shows
     it joining "Neighbour" (5 GHz, signal -86 dBm) and losing it ~90 s later, then going back to
     your home Wi-Fi. FIX: HeliPort icon -> Preferences -> Networks -> Auto Join ONLY on your home Wi-Fi.
  2. Weak signal where the ZenBook was: -74 to -86 dBm (the M4 Mac here: -59 dBm). Under about
     -75 dBm Wi-Fi gets slow and drops. Sit closer, or put the router higher / more central.
  3. Your home router (ZTE H188A) is 2.4 GHz only, auto channel 3 (overlaps 1 and 6). On this
     Intel card 2.4 GHz is shared with Bluetooth. Router settings (192.168.1.1): channel 1, 6
     or 11 (fixed, NOT 12/13 - the ZenBook uses US channels 1-11), 20 MHz, WPA2-PSK AES only.
  4. Your internet line: 34 Mbps down / 16 Mbps up (measured on the M4 here). That is the most
     the ZenBook can reach too. A dual-band (5 GHz) router or access point is the big upgrade.
  The driver is already the newest official one (itlwm 2.3.0 - more stable and faster than
  AirportItlwm per its docs). The new "Wi-Fi 6" test drivers online are experimental (AX210
  only, not this AX201) - not used.

WI-FI: FIX EVERYTHING - ONE COMMAND (fix-wifi.sh v2.1 + Wi-Fi package 2.2, 2026-11-23)

  Sign in to macOS, plug in this USB, open Terminal and type:

      sudo sh "/Volumes/Install macOS Sonoma/fix-wifi.sh"

  It installs/updates the Wi-Fi package, fixes HeliPort's "!" and hides the macOS Wi-Fi
  icon, checks HeliPort's auto-join list (point 1 above), runs a speed test with the signal,
  sets the sleep timers, then offers a lid check. If it says RESTART NEEDED: restart from
  the SSD and run it once more. Log: UX325EA-RESCUE/TEST-RESULTS/wifi-fix-<time>.txt

  The two "!" icons:
  - HeliPort "!" = joined to your router, but macOS has no internet path on the Intel card
    (no network service, no IP address or no DNS). The script gives the card its own service
    "Intel Wi-Fi" (DHCP, first in the order), renews the address, falls back to 1.1.1.1/8.8.8.8
    DNS only if the router's DNS fails, then checks exactly like HeliPort does.
  - macOS Wi-Fi icon "!" = with itlwm macOS sees no Wi-Fi card at all, so that icon can never
    work. It is hidden; HeliPort is the Wi-Fi menu. (wifi-driver.sh airport brings it back.)
  - Package 2.2: the recovery agent no longer mistakes the old "Wi-Fi" service from
    AirportItlwm for the Intel card's service, so it can re-create a missing one by itself.

New in 2.1:
  - Empty network list after the lid: if Wi-Fi was working before, the radio is on, but the
    driver's network list stays EMPTY for a full minute, the agent restarts the Intel radio once
    (it re-checks right before). Next automatic restart only after the link recovers or a new
    wake, and at least 10 minutes later. Networks visible = it leaves the radio alone.
  - Speed test: Applications -> ZenBook Wi-Fi Repair -> Test Speed. Measures download and upload
    over the Intel Wi-Fi (Apple's networkQuality) and shows band (2.4 / 5 GHz), channel, width
    and signal. On 2.4 GHz it offers "Try 5 GHz" when the same network is visible strongly on
    5 GHz. A router with a separate 5 GHz name: pick that name in HeliPort.
  - The installer also removes -novht / -noht40 from the SSD's OpenCore profiles if present
    (those switches cap the card at slow speeds). All five profiles are validated with ocvalidate.
  - Show Report -> Save a Copy... saves wake log + latest speed test (choose this USB:
    UX325EA-RESCUE/TEST-RESULTS).

TEST (please): Test Speed near the router -> close the lid 10 minutes -> open, use Wi-Fi for
10 minutes -> Test Speed again in the same spot -> Show Report -> Save a Copy... to this USB.
Compare with a phone on the same Wi-Fi and band.
Old 2.0 installer: kept on the Mac (~/zenbook_dsdt/backups/wifi-pkg-2.0), no room on this USB.

Previous setup (2026-11-21 21:05): Wi-Fi stayed on AirportItlwm (macOS Wi-Fi menu + location by Wi-Fi).
  Its build is the correct one (= official AirportItlwm 2.3.0 "Sonoma 14.4+", checked byte for byte).
  (HISTORY - that was fix-wifi.sh v1.3; today's fix-wifi.sh is v2.0 above. v1.3: UX325EA-RESCUE/BACKUPS/pre-wifi22-*)
  It installs helper 8.24 (Wi-Fi really OFF during sleep, ON after wake - 8.22 had a bug) and records
  what macOS's Wi-Fi/location/Bluetooth services did if Wi-Fi drops again. 8.24 also writes
  "after wake +60/120/180 s: Wi-Fi working / NOT working" after EVERY lid open, by itself.
  fix-wifi v1.3 keeps its log on the SSD (/Users/Shared/UX325EA-Logs) and copies it here.
  AirDrop: impossible with ANY Intel Wi-Fi card (needs Apple's AWDL = a Broadcom card).

Earlier manual driver-switch instructions (2026-11-21)
  Not applied: with itlwm, Location Services by Wi-Fi stops working and the macOS Wi-Fi menu is
  replaced by HeliPort. (AirDrop works with NEITHER Intel driver - it needs a Broadcom card.)
  The lid check (fix-wifi v1.1) showed the real problem: AirportItlwm loses the router 10-95 s
  after joining - with or without the lid - and then sometimes refuses every scan. itlwm is the
  same Intel driver without Apple's Wi-Fi stack; HeliPort (menu-bar icon) joins and re-joins.
      sudo sh "/Volumes/Install macOS Sonoma/wifi-driver.sh" itlwm
  Then restart, click the HeliPort icon (top right), choose your network, type the password
  once. Back to the old driver: ... wifi-driver.sh airport    Show: ... wifi-driver.sh status
  It switches the SSD's and this USB's OpenCore, installs HeliPort 1.5.0 and helper 8.23
  (8.22 bug fixed: it switched Wi-Fi back on 1.7 s after "off before sleep").

WI-FI AFTER THE LID - ONE COMMAND (fix-wifi.sh, 2026-11-21)
  Cause: on battery macOS put the laptop to sleep ~2 minutes after the lid was opened (display
  off after 2 min, sleep right after) - every sleep switches the Wi-Fi card off. Fix, stored on
  the SSD for good: battery display off 5 min / sleep 30 min, charger never sleeps by itself
  (closing the lid still sleeps), plus the Wi-Fi helper with auto-reconnect.
      sudo sh "/Volumes/Install macOS Sonoma/fix-wifi.sh"
  v1.1 (helper 8.22): Wi-Fi is switched OFF right before every sleep and ON right after the
  wake (a clean restart of the card, like clicking Wi-Fi off/on - the Wi-Fi driver's own
  sleep handling is what lost the connection). Not joined after a wake -> off/on again at
  40 s, 2 min, 4 min. The script first saves the Wi-Fi/sleep history of the last failure.
  Lid check: press Enter, close the lid 1 minute, open it, log in - it starts by itself.
  Rollback: UX325EA-RESCUE/BACKUPS/pre-wifi822-*/ (helper 8.21, fix-wifi 1.0).

DONE 2026-11-21: macOS only. make-mac-only.sh deleted Windows, macOS has the whole SSD
(1024 GB) and starts from the power button without this USB (OpenCore on the SSD, no menu).
Keep this USB as the rescue stick: power on holding Alt, or tap Esc and choose the USB.

v10.10 - Wi-Fi that stays usable (helper 8.21)
  Problem: sometimes Wi-Fi shows connected but nothing loads. The old watchdog only acted when
  Wi-Fi had NO IP address, so a stalled link (weak 2.4 GHz signal, -72..-86 dBm in the last
  test) stayed stuck until you switched Wi-Fi off and on yourself.
  - Every 10 s while connected the helper checks: does the router answer (ping), does the
    internet answer (1.1.1.1 / 8.8.8.8, no DNS needed), does name lookup (DNS) work.
  - Router AND internet silent for ~30 s -> it reconnects Wi-Fi by itself (off/on; at most once
    per 3 min, 3 times per hour). Router answers but internet does not -> your provider/router,
    Wi-Fi is left alone. Everything is logged, plus a quality line every 5 minutes.
  - Check by hand any time:  ~/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper wifiprobe
  - Off switch: defaults write com.zenbook.helper wifiHealthCheck -bool NO
  - Also included: helper 8.20 speaker fix (amplifier on after a fresh start).
  - Test v10.10: no "started from the SSD" warning any more (the SSD is the setup now); records
    the Wi-Fi probe after each lid round and the Wi-Fi health history.
  Best Wi-Fi: your router was only seen on 2.4 GHz. If it has 5 GHz, switch it on in the router
  and join that network - it is faster and has less interference. Near the router it is great
  (-32 to -50 dBm); two walls away 2.4 GHz drops to -85 dBm, where any Wi-Fi card struggles.
  Undo: UX325EA-RESCUE/BACKUPS/pre-v1010-*/ (helper 8.20, test v10.9).

macOS ONLY - whole SSD, no USB needed (make-mac-only.sh, tested on disk images)
  1. Start macOS from this USB, plug in the charger, open Terminal.
  2. Check (changes nothing, shows what would be deleted):
         sudo sh "/Volumes/Install macOS Sonoma/make-mac-only.sh"
  3. Do it (type ERASE WINDOWS when asked - ALL Windows files are lost):
         sudo sh "/Volumes/Install macOS Sonoma/make-mac-only.sh" --apply
     Deletes the Windows partitions, grows macOS over the whole SSD, copies this USB's
     OpenCore to the SSD (no menu), removes Windows Boot Manager. If Windows lies BEFORE
     macOS on the disk it stops without changing anything (macOS cannot grow backwards).
  4. Shut Down, unplug the USB, power on tapping Esc, choose the SSD entry ONCE.
     From then on: power button -> macOS. Keep this USB as the rescue stick.

v10.9 - speakers right after a fresh start (helper 8.20)
  v10.8 test: keys, lid (20 s and 1 min), Wi-Fi after the lid, Delete key and the speakers
  AFTER a lid sleep all work. But right after a fresh start the speakers stayed silent until
  the first sleep: layout 66 switches the speaker amplifier on at every wake, not at startup.
  - Helper 8.20 checks the ALC294 speaker amplifier (EAPD of pin 0x14) through AppleALC's
    verb interface (alcverbs=1, already set) at login, after each wake and whenever sound
    starts, and switches it on if it is off. Every action is logged ("speaker amp ...").
    Off switch: defaults write com.zenbook.helper speakerAmp -bool NO
  - Test v10.9 = v10.8 + the helper's speaker-amplifier log after each sound check.
    Run it right after a fresh start, BEFORE closing the lid (a sleep turns the speakers on
    by itself and would hide the result).
  Undo: copy UX325EA-RESCUE/BACKUPS/pre-v109-*/ZenBookHelper.app back (helper 8.19).

v10.8 - speakers after the lid, Delete key, boot menu, Wi-Fi capture
  v10.7 test (keyboard file SSDT-KEYS loaded): the screen and F-keys came back after both lid
  rounds. Wi-Fi: the driver never started in that one boot (not the lid; in every other test
  Wi-Fi reconnected 5-9 s after opening the lid). Reported since: no speaker sound after the
  lid, the key next to the power button does nothing, and after the battery ran empty the USB
  started Windows (BIOS reset: Secure Boot back on; then the saved "start macOS" was gone).
  - Speakers: AppleALC layout 11 has no wake setup, so the speaker amplifier stays off after
    a sleep. Layout 66 (same ALC294 wiring: speaker 0x14, mic 0x1b, headphone 0x21) also turns
    the amplifiers back on at every wake. alcid=66 + layout-id 66 in all five configs.
  - Delete key (next to the power button): it is the Mac "forward delete" key, which does
    nothing in Finder. Helper 8.19 makes it Move to Trash in Finder (like Windows) unless a
    text field is focused (renaming) or a modifier is held; every press is logged.
  - Helper 8.19: the F-key bridge from 8.18 is off by default (SSDT-KEYS already does the
    keys); switch on with: defaults write com.zenbook.helper fkeyBridge -bool YES
  - Boot menu: this USB's config.plist shows the OpenCore menu and waits (ShowPicker on) until
    macOS is the Startup Disk again (System Settings > General > Startup Disk > macOS).
  - Test v10.8 plays a sound before sleep and after each lid round, asks if you heard it,
    tests the Delete key on a new folder and records whether the Wi-Fi driver attached.
  Undo: the previous configs, script and README are in
  UX325EA-RESCUE/BACKUPS/pre-v108-20261120-232239 (copy them back to EFI/OC).


Internal keyboard and lid wake
  Boot macOS through this USB's OpenCore. F1 mutes, F2/F3 change volume,
  F4/F5 change OLED brightness and F7 cycles the keyboard light. The new
  mapping handles bare function keys on the built-in keyboard from boot.
  Try the keys again after closing the lid, reopening it and signing in.
  To restore standard shortcuts for these six keys, disable SSDT-KEYS.aml
  under OpenCore > ACPI > Add and restart.

Frame-rate check
  In Finder on macOS, open "Check FPS After Restart" on this USB once.
  Restart and sign in. The app tests a moving triangle on the built-in
  display and opens FPS Result.txt with the measured presentation rate.


v10.7 - Fn-lock after a lid wake, real-colour loading screen
  v10.6 test: lid sleeps every time now (sensor poll), Genie + Dock magnification work. After a
  lid wake Fn+F1/F4/F5/F7 type plain keys; yellow/green pixels at boot and during the login
  switch (the EDID fix removed the extra mode switch that used to hide them with black).
  - SSDT-WAKE v1.9: the EC forgets the ASUS Fn-lock (WMI 0x00100023, EC byte FEST, EC command
    0x72/0xB3) in a lid-closed sleep. XPTS(3) saves it, XWAK and the first 10 s of the poll
    write it back - the same thing Linux asus-wmi does on every resume.
  - Driver v4.6: WhateverXe copies the Apple-logo loading screen into the framebuffer at boot
    and when macOS re-initialises it; that copy was raw 8-bit data in a 30-bit (10-bit per
    colour) framebuffer -> yellow/green noise. Now converted pixel by pixel to 10-bit.
  - Helper 8.17 logs plain F1-F12 presses after a wake (Fn-lock evidence).

v10.6 - lid without EC events, black login fix attempt, D3 at shutdown, Dock effects
  v10.5 test: AsusSMC now registers (ATKP 1, OSDT 1) and volume works; after a lid wake the
  EC still flags no events. Brightness timeline: the panel stayed at full brightness during
  login, so the black screen after the password is not brightness.
  - SSDT-WAKE v1.8 + BrightnessKeys-UX325 poll (from each wake until the next sleep):
    lid from the EC hall sensor (LSTE changed -> Notify LID0) and a direct EC event query
    once a second for events the EC queued without announcing them.
  - Login black screen: the panel EDID lists 1920x1080@60 twice, so macOS has two identical
    modes (0x80001000 / 0x80001001) and switched between them at startup - every switch
    retrains the OLED link (black). OpenCore now gives the framebuffer the same EDID with the
    duplicate removed (AAPL00,override-no-connect): one mode, nothing to switch.
  - Driver v4.5: before Shut Down / Restart the panel also goes to sleep (DPCD D3), not only
    0 nits (green dots were still visible).
  - Dock: Genie minimize, magnification and launch animation switched on by --test.

v10.5 - ROOT CAUSE of the dead Fn keys after a lid wake; black shutdown; login timeline
  The EC snapshot after a wake (v10.4) showed ATKP = 0 and OSDT = 0: the ASUS hotkey
  registration (ATKD.INIT) had never run since day one. AsusSMC passes an 8-byte argument to
  the ASUS WMI method WMNB, which reads 20 bytes (IIA0..IIA4) and aborts with
  AE_AML_BUFFER_LIMIT before INIT (reproduced in acpiexec). The EC therefore ran in its
  "no OS driver" fallback (volume/mute as plain keys), which does not survive a lid-closed sleep.
  - SSDT-WAKE v1.7: WMNB wrapper pads the argument to 32 bytes (OpenCore renames WMNB -> XMNB
    in all profiles). AsusSMC now registers like the Windows ATK driver. Its battery charge
    limit (80%) is blocked, so charging stays exactly as before.
  - Driver v4.4: the OLED is set to 0 nits just before Shut Down / Restart -> plain black,
    no green dots. Records the last 24 brightness writes with timestamps
    (WEXTGLEDPBacklightHistory) to find the black screen after the password.
  - --test: asks about the last shutdown and this login, checks volume before sleep, 2 lid rounds.

v10.4 - EC "display on" after a lid wake, Wi-Fi recovery
  v10.3 test: lid sleep/wake OK, but after the first lid wake the EC sent NO events at all (the
  2nd lid close was not seen - the Mac slept by idle timer - and no Fn keys); the poll found
  nothing waiting. This firmware is built for Modern Standby: Windows calls PEPD._DSM display
  off/on on lid close/open -> H_EC.ECNT(1)/ECNT(0) = EC commands 0x5D/0x5E (low power enter/
  exit). macOS (S3) never sends "exit", so the EC stays in low power after a lid-closed sleep.
  - SSDT-WAKE v1.6: every wake calls ECNT(0) like the display-on notification.
  - BrightnessKeys-UX325: EC poll only for 10 min after each wake (not at boot); EC state
    snapshot (ECNO, status, OS type, OS driver flag, lid) as property UX325ECDiag.
  - Helper 8.16: Wi-Fi switched off at login -> switched on; logs Wi-Fi off / no interface.

v10.3 - after a lid wake macOS takes no more EC events (Fn keys, lid close, battery)
  v10.2 test: the wake drain found the stuck lid event, but afterwards the kernel got NO event at
  all - no lid close (no 2nd sleep), no Fn keys. macOS' EC event channel stays dead after a lid
  wake (power-button wakes are fine). Fallback that does not depend on it:
  - BrightnessKeys-UX325 calls DD1F.ZECP every 300 ms. When the EC has had an event waiting for
    two polls in a row (macOS takes them within milliseconds when it works), SSDT-WAKE v1.5
    reads it and runs the firmware's own handler (_Q15 brightness, _Q1C volume, _Q0D lid ...).
    It never steps in while macOS' channel works. Log: "UX325 EC poll" (kernel).

v10.2 - Fn keys frozen after a lid wake
  v10.1: the screen comes back after the lid, but every Fn key stays dead. The embedded
  controller delivers events one at a time (SCI_EVT, read by the OS with QR_EC). The lid-open
  event that woke the laptop is not read during resume, so the controller waits forever and
  never reports newer events (Fn keys, AC, battery). Power-button wakes are not EC events,
  which is why they never had the problem.
  - SSDT-WAKE v1.4: on every wake drain pending EC events (up to 8, through the controller's
    status/command ports, like Linux after resume) and pass lid / AC / battery ones to macOS.
  - --test: two lid rounds, each followed by Fn+F5, Fn+F4, volume and mute.

v10.1 - lid: macOS kept thinking the lid was closed
  v10.0 test: everything works except the lid. Kernel log of the failed lid test: clamshell
  sleep, then wakes at :29 / :44 / :54 (the last one on a key press) - every one with
  "clamshell closed 1"; "Clamshell opened" came only after the restart. The EC's "lid open"
  event that woke the laptop was lost during resume, so macOS kept the built-in screen off.
  - SSDT-WAKE v1.3: on every wake Notify(LID0) -> macOS re-reads _LID (the EC hall sensor).
    The first 30 Fn presses after a wake re-check the lid too (Fn+F5 brings the screen back).
  - --test now tests only the lid (2 rounds); --test-all runs the full test.

v10.0 - lid wake fix + ready to make permanent
  v9.9 test: EVERYTHING works (shutdown shows apps closing, brightness keys + slider, volume,
  mute, two-finger menu, Wi-Fi, keys after power-button sleep) - except: lid open = black screen.
  - Lid: on lid close macOS fades the OLED to 0 (black since v9.9, as wished). If macOS sends the
    "restore brightness" before the panel is powered again, the driver had to skip it and the
    OLED stayed at 0. Driver v4.3 re-sends the last brightness the moment the panel powers on;
    helper 8.15 also re-sends it 2.5 s after every wake and logs lid/clamshell state.
  - All USB profiles are now the final setup: config.plist = config-gpu = config-trial;
    config-stable = same fixes without GPU acceleration (safe mode, verbose boot).
  - When the test says EVERYTHING WORKS:  sudo sh sync-efi-to-ssd.sh --launcher-full
    copies this setup to the SSD (Windows untouched). Then the laptop starts without the USB.

v9.9 - USB test setup: volume/mute after sleep via BrightnessKeys, black at 0, shutdown log
  v9.8 test: brightness keys, Control Centre slider, mute, two-finger menu and Wi-Fi OK.
  Volume/mute still dead after lid or power-button sleep.
  - Brightness (Fn+F4/F5) uses EC query -> Notify(DD1F) -> BrightnessKeys -> PS/2 keyboard and
    keeps working after sleep. Volume/mute used EC query -> ATKD queue -> AsusSMC, which stops
    after sleep. SSDT-WAKE v1.2 now sends volume up/down/mute as Notify(DD1F, 0x90/0x91/0x92);
    BrightnessKeys-UX325.kext (BrightnessKeys 1.0.3 + these 3 codes) turns them into the PS/2
    keyboard's sound up/down/mute keys - the same proven path as brightness.
  - Brightness 0 = black screen again, as wished (boot-arg -wex-tgl-edp-bl-zero).
  - Shut Down "screen goes black at once": the GPU driver now logs every panel on/off, and the
    test records the whole previous shutdown (WindowServer crashed late in one earlier shutdown).
  - Microphone: the test records the firmware's audio table (NHLT) and the codec inputs to
    check once more whether the built-in mic is wired to the Realtek codec or to Intel's DSP.

v9.8 - USB test setup: Fn keys after sleep (queue fix), two-finger menu, Wi-Fi, never black
  v9.7 test: Control Centre brightness and the native brightness keys are active (macOS
  brightness 0..100% drives the OLED). Wi-Fi did not connect, volume/mute dead after sleep,
  two-finger tap did not open the menu, shutdown slow with a black screen.
  - Volume / mute after sleep: ASUS sends these keys through a 16-entry queue in ATKD (one
    Notify per key, AsusSMC takes one entry per Notify). One lost Notify around sleep leaves
    an old entry behind for good - every later key delivers the PREVIOUS key's code.
    SSDT-WAKE v1.1 empties stale entries before each new key and on every wake
    (OpenCore renames ATKD.IANE -> XANE; brightness uses another path, so it kept working).
  - Two fingers open the menu again (right click, like a Mac). Helper 8.9-8.13 had turned it
    into a left click by mistake.
  - Wi-Fi: helper 8.13 switched Wi-Fi off/on every ~40 s while AirportItlwm needs up to
    2 minutes to join at -75..-88 dBm: it never connected. Now never while joining, at most
    once per wake/drop after 90 s without a link. Signal is weak where the laptop is used:
    closer to the router or its 5 GHz network = faster and steadier.
  - Brightness 0% no longer turns the OLED black: driver v4.1 keeps 0.5% (3 nits).
  - Shut Down: the test copies macOS' "shutdown stall" reports to find what blocks it.

v9.7 - USB test setup: Control Centre brightness slider, keys after sleep, two-finger click
  Confirmed by the v9.6 test: real OLED brightness, Bluetooth (real controller address),
  mute, lid sleep and power-button sleep. Now on the USB test setup:
  - Control Centre DISPLAY slider + Mac brightness curve: the backlight device (PNLF) had
    ID 24. The GPU driver adds its 16-bit brightness profile only for ID 19, so macOS never
    created a "brightness" control (only the raw "bklt" value). PNLF is now ID 19: macOS
    controls the OLED itself (slider, keys, brightness symbol, 16 steps, darkest step ~1%).
  - Keys dead after sleep: the embedded controller forgets the ASUS hotkey driver on wake.
    New SSDT-WAKE re-registers it on every wake (ATKD.INIT, as Windows does), through ASUS'
    empty XWAK hook (OpenCore renames DSDT XWAK->YWAK and XPTS->YPTS, 1 match each).
  - Shut Down: the USB controller can no longer wake the laptop right back up (XHCI PME off).
    The test now records how the previous shutdown ended.
  - Helper 8.13: one mute press = one toggle (a held key flipped it ~10 times); mute AND unmute
    show the macOS speaker symbol; brightness uses the macOS bezel; two-finger tap -> left
    click is converted before WindowServer (8.9-8.12 converted too late, apps ignored it);
    Wi-Fi: reconnect after 12 s without IP after wake (was 45 s), up to 3 tries.
  - Microphone: still not possible on macOS (digital mic on Intel's audio DSP). Use a headset
    (audio jack), Bluetooth (AirPods) or a USB microphone.
  - Test:  Shut Down, plug in the USB, power on tapping Esc, choose the USB, then
           sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --test

v9.6 - USB test setup: REAL OLED brightness v4, Bluetooth fix, lock screen, no software dimming
  - Brightness: the panel is a Samsung OLED with Intel's OLED brightness interface (DPCD 0x340:
    01 57 01, AUX enabled by the BIOS). Driver v4 sets the real brightness in nits (0x354)
    using the panel's EDID maximum (617 nits), like Linux. The VESA registers were ignored.
  - Software dimming (dark layer) removed. Fn+F4/F5 change only the real panel brightness.
  - Bluetooth: NVRAM bluetoothExternalDongleFailed=00 + bluetoothInternalControllerInfo=14x00
    (rewritten every boot) + -btlfxallowanyaddr. Fix confirmed on the same AX201 chip
    (OpenIntelWireless/IntelBluetoothFirmware issue 513). Needs a full Shut Down, then power on.
  - --test now sets "require password immediately after sleep" (lid / power button).
  - USB map: HS04 is an outside port.  sync-efi-to-ssd.sh keeps its backup on the laptop.

v9.5 - THE USB IS THE TEST SETUP, THE SSD IS YOUR NORMAL MAC
  - Without the USB: the laptop starts from the SSD = your normal, working setup.
  - With the USB: power on, tap Esc, choose the USB ("UEFI: ..." entry) = newest TEST setup
    (GPU driver v3 with real OLED brightness, USB map for Bluetooth, helper 8.11).
    Then run:  sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --test
    It updates the helper, guides 5 short tests and saves everything for the other Mac.
  - Test broke something? Shut down, unplug the USB, power on = normal Mac.
  - Helper 8.11: the mute key itself mutes (volume 0 / restore).
  - Old daily USB profile kept as EFI/OC/config-gpu-v2.plist.

v9.4 - Bluetooth map, real mute, power button, two-finger tap, REAL OLED brightness (trial)
  - USB port map (USBMap-UX325EA.kext, all profiles): Bluetooth (port HS10), webcam (HS06)
    and HS04 are now INTERNAL. macOS treated the Bluetooth chip as an external USB stick and
    bluetoothd failed to start it ("OI_HciIfc_Init_USB Initialization failed").
    Bluetooth also needs a COLD start after Windows: Shut Down, then power on (no Restart).
  - ZenBookHelper 8.9: mute key really silences the speakers (volume saved/restored),
    power button press = sleep (like a MacBook), two-finger tap = left click fixed
    (tap-to-click could stay switched off after the NumberPad was used).
  - Microphone: the built-in mic is a digital mic wired to Intel's audio DSP, which macOS
    cannot drive. Use a headset (audio jack), Bluetooth or USB microphone.
  - REAL OLED brightness = GPU driver v3 (WhateverXe-UX325-v3.kext, -wex-tgl-edp-bl): the
    panel's own brightness over DPCD (VESA eDP), like Apple's own panels. Try it once:
        sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-trial   -> restart
    The boot after the trial is your normal setup again. Happy?  --gpu-trial-keep
  - The daily profile is GPU acceleration again (it had been switched to the safe profile).

v9.3 - BOOTS LIKE A REAL MAC (no menu) + boot without the USB
  - No boot menu: power on -> Apple logo -> macOS (the Startup Disk choice).
    Hold Option (Alt) while turning on = boot menu (Windows, rescue).
  - Set the default once: System Settings > General > Startup Disk > macOS > Restart.
  - Boot without USB:  sudo sh "/Volumes/Install macOS Sonoma/sync-efi-to-ssd.sh" --launcher-full
    then shut down, unplug the USB, power on tapping Esc, choose the internal SSD entry
    (NOT Windows Boot Manager) ONCE. OpenCore adds itself as the first boot option.
  - Keep this USB as the rescue stick (Esc at power-on -> choose the USB).
  - Previous settings: UX325EA-RESCUE/BACKUPS/pre-macboot-*

v9.2 - GPU ACCELERATION WORKS (Iris Xe, Metal, 1920x1080 30-bit) - now the daily profile
  - Clean boot: Apple logo (no -v text), diagnostic tracing removed. Debug profile kept in
    UX325EA-RESCUE/BACKUPS/gpu-working-20261119/config-gpu-debug.plist.
  - This USB's data partition was damaged by unplugging without Eject; it was backed up,
    reformatted and restored. ALWAYS right-click "Install macOS Sonoma" -> Eject before unplugging.
  - Old GPU test reports moved off the USB (kept on the other Mac) to free space.
  - Back to the old setup any time: fix-hardware.sh --gpu-off  or  GPU-OFF.command

v9.1 - GPU test #6: CUSTOM WhateverXe v2 (real cause found)
  Test #5: the 2-lane fix worked (mode-sets 2x faster), then the kernel logged
  "IOAccelDisplayPipeTransaction time out" and WindowServer hung -> watchdog restart.
  Real cause, found in Apple's Tiger Lake driver: setDisplayMode() lets setupDisplayTiming()
  fill the mode timing; on this machine its graphics-policy (AGDC) query fails and it returns
  WITHOUT writing it, so the panel gets programmed from leftover memory (pixel clock/sizes =
  garbage). That one bug explains the lane failure, the old divide-error panic and the dead
  display pipe. v2 fills that timing with the real 1920x1080 mode first (-wex-tgl-edp-timing)
  and uses the panel's own link: 2 lanes x 2.7 Gbps like the BIOS (-wex-tgl-edp-lanes).
  Same steps as before:
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-test   -> restart
    screen works: a box asks "Keep?" -> Keep -> --gpu-report -> --gpu-keep
    black screen: do nothing - it records data and restarts by itself (~4 min)

v9.0 - GPU test #5: CUSTOM WhateverXe for this laptop
  Test #4 found the cause of the black screen: Apple's Tiger Lake driver fails to compute
  the lane count for this panel (setupOptimalLaneCount -> 0xE00002C7) and keeps a 4-lane
  default, then tries to train 4 lanes on a 2-lane OLED (DPCD 0x002=0xC2): lanes 2/3 never
  lock, the link never comes up, the screen stays black. WhateverXe-UX325.kext = official
  0.8.3 source + a 30-line patch that clamps the lane count to the panel's 2 lanes when
  Apple's calculation fails (boot-arg -wex-tgl-edp-lanes, GPU profile only). Same test suite
  results as the unmodified driver. Source patch: Post-Install/src/WhateverXe-UX325.
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-test   -> restart
    screen works: a box asks "Keep?" -> Keep -> --gpu-report -> --gpu-keep
    black screen: do nothing - it restarts by itself into the normal Mac (~4 min)

v8.9 - GPU test #4: one more DIAGNOSTIC boot (no driver changes)
  Test #3: brightness keys reached the helper, but macOS does not treat the panel as a
  brightness display in GPU mode (DisplayServices -1), panel stayed black, no link-training
  errors logged. Other Tiger Lake owners report the same black eDP (WhateverXe issues #154,
  #21, #37, #77); the main known cause is eDP 1.4 panels with a link-rate TABLE that Apple's
  driver mishandles. Test #4 records the panel's DisplayPort registers and power sequence
  (-wex-display-trace) to confirm which case this is before a custom driver is built.
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-test   -> restart
    black screen: do nothing - it restarts by itself after ~3 minutes into the normal Mac
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-report -> bring the USB back

v8.8 - GPU test #3 (same steps)
  Test #2 data: GPU + display pipeline healthy (panel EDID read = Samsung ATNA33XC11, mode
  set, framebuffer on, AUX to the panel works) BUT macOS registered the panel's brightness
  ("bklt") at 0 and the driver wrote backlight duty 0 -> black. ZenBookHelper 8.6 now
  raises the native brightness to 80% when it finds it at 0 (GPU mode only).
  During the black screen also press Fn+F5 a few times; still black -> wait 4 minutes,
  hold power 10 s, run --gpu-report, bring the USB back.
  If it stays black, the next step is a custom WhateverXe build that switches the OLED's
  brightness on over AUX for Tiger Lake (code exists in WhateverXe for Alder Lake only).

v8.7 - GPU test #2 = DIAGNOSTIC boot (same steps as before)
  Test #1 result: the Iris Xe driver DID start (accelerator attached, 5 clean display
  mode-sets, no crash) but the OLED stayed dark. Cause (from the driver source): on Tiger
  Lake WhateverXe only drives a PWM backlight wire; this Samsung OLED sets brightness over
  the DisplayPort AUX channel, so after the mode-set nobody turns the panel's light back on.
  Test #2 records the driver's internal panel/backlight state DURING the black screen, so the
  fix (adding OLED AUX brightness for Tiger Lake to WhateverXe) is built on real data.
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-test     -> restart
    black screen: WAIT 3 FULL MINUTES, then hold power 10 s -> normal Mac returns
    sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-report   -> bring the USB back
  Optional: an HDMI TV/monitor plugged in before the test may show the GPU desktop.

v8.6 - Iris Xe GPU acceleration TEST (optional, your working setup is not changed)
  What: WhateverXe 0.8.3 (newest, checksum-verified) + AMFIAnchor 0.1.2 + WhateverXe Graphics
        0.4.4 (already installed). Your old attempt lacked AMFIAnchor and -allow3d.
  Honest status: experimental community driver. Tiger Lake laptops are verified with the
        48-unit GPU; your i7-1165G7 has 96 units = "expected to work, not yet tested".
        Your OLED panel's brightness method may not be supported (the helper's
        Fn+F4/F5 dimming keeps working either way). Sleep with GPU is experimental.
  Files: EFI/OC/config-stable.plist = your working setup (identical to config.plist now)
         EFI/OC/config-gpu.plist    = GPU profile
  1. sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --gpu-test   (asks to restart)
     The GPU profile is used for ONE boot. A guard switches the USB back to normal at
     the very start of that boot.
  2. Works?  --gpu-report  (Metal must say Supported)  then  --gpu-keep  to keep it.
  3. Black screen / frozen 3 min?  Hold power 10 s, turn on -> normal Mac is back.
     Run --gpu-report and bring the USB back.
  4. Restart loop? Double-click GPU-OFF.command on this USB from ANY Mac.
  Back to normal any time:  fix-hardware.sh --gpu-off

v8.5 - permanent fixes (run fix-hardware.sh again):
  - NumberPad lights: the helper had lost its macOS permissions. Each update was signed
    by file hash, so macOS saw a "new" app and the Input Monitoring / Accessibility
    switches stopped applying (log: touchpad access 0xE00002E2, accessibility 0).
    Now signed with a FIXED identity: switch both ON one last time and they stay on
    through every future update. The script waits for you and then checks that the
    lights come on from the touchpad icon.
  - Wi-Fi permanent: AirportItlwm 2.3.0 is already the newest driver. Added: Wi-Fi
    watchdog (re-joins automatically if Wi-Fi fails after sleep), sleep settings that
    keep the card stable, link speed shown in the audit. Best speed = your router's
    5 GHz network; on 2.4 GHz the audit warns you (max ~144 Mbps).
  - At the end the script offers to copy everything to the internal SSD (boot without USB).
  Brightness, calculator and clicks are unchanged.

v8.4:
  - NumberPad turned itself on/off and taps stopped clicking: the helper read the touchpad
    size from its mouse section (127) instead of the finger section, so the whole pad acted
    as the toggle icon. Fixed; only the real top-right icon toggles now.
  - NumberPad LED: the script asks you after each of 4 short tests "lights on? y/n" and
    remembers the one that works (re-test any time: fix-hardware.sh --led-test).
  - Calculator: slide your finger out of the top-left corner.
  - Clicks: tap = left click, double-tap = double click, two-finger tap = left click,
    PRESS the bottom-right corner = right click (Control+click also works).


ONE script does everything:   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh"
(run it as your normal user, type your password when asked, then RESTART)

WHAT v8.3 FIXES
  Display brightness  Fn+F4/F5 now really darken/brighten the OLED (pixel dimming).
                      v8.2 only moved the on-screen bar: this display mode ignores
                      the colour table, so nothing changed on the panel.
  Apple ID / iCloud   The board serial (MLB) in config.plist was invalid (16 chars,
                      bad checksum). Replaced with a valid one that matches your serial.
                      Wi-Fi is now marked "built-in" and rebuilt as en0, which Apple ID needs.
  Wi-Fi               One-time clean rebuild of macOS network settings: the native Wi-Fi
                      icon/settings, router DNS (stock), no leftovers from itlwm/HeliPort.
                      Saved Wi-Fi passwords stay. VPN profiles must be re-added (the
                      backup in UX325EA-RESCUE/TEST-RESULTS/network-backup-* has them).
  NumberPad           LED test runs automatically once. Then:
                        hold TOP-RIGHT touchpad icon 1 s = NumberPad on/off
                        slide out of the TOP-LEFT corner = Calculator
                      An on-screen notice shows NumberPad ON / OFF.
  Trackpad            tap / two-finger tap = left click, bottom-right press = right click.
                      (zenbook-helper twofinger right = two-finger tap becomes right click again)

AFTER RUNNING THE SCRIPT
  1. System Settings opens: Privacy & Security > Input Monitoring AND Accessibility
     -> switch ON "ZenBookHelper" in both.
  2. Restart (needed for Wi-Fi + Apple ID).
  3. Sign in: System Settings > "Sign in with your Apple Account".
  4. Check:  sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --audit
  Every run is saved in UX325EA-RESCUE/TEST-RESULTS - if something still fails,
  just bring this USB back to the other Mac.

OTHER COMMANDS
  sync-efi-to-ssd.sh          copy this EFI to the internal SSD (boot without USB) - later
  zenbook-helper status | up | down | set 60 | mode overlay|gamma | numpad on|off
  tail -f ~/Library/Logs/ZenBookHelper.log      every key/touch event the helper sees

Apple ID note: if sign-in still says the device is not eligible, check the serial at
checkcoverage.apple.com - it must NOT belong to a real Mac ("serial not valid" is good).

OLD FILES: everything replaced is in UX325EA-RESCUE/ARCHIVE-replaced-by-v8.3-*
(installer and rescue scripts, old readmes, WhateverXe package, old configs). Delete that
folder when you no longer need it. Backups of every change: UX325EA-RESCUE/BACKUPS/.

NOT POSSIBLE ON macOS: Windows Hello face login, Thunderbolt hot-plug of PCIe docks/eGPU,
external monitors (they need the Iris Xe driver that blacks out this OLED panel).
