ZenBook UX325EA Hackintosh - v10.0 (2026-11-20)
=================================================

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
