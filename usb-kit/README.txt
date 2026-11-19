ZenBook UX325EA Hackintosh - v9.2 (2026-11-19)
================================================

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
