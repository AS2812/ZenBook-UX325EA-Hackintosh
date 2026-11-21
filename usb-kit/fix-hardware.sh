#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - Master Hardware & Performance Fixes v10.7
# (Wi-Fi + Apple ID + Fn+F4/F5 OLED dimming + NumberPad/Calculator + Trackpad + Audit)
# Every run saves its output to UX325EA-RESCUE/TEST-RESULTS on the USB.
#
# Run it as your NORMAL user (no sudo). It asks for your password only for the
# few network commands that need root; all preferences go to YOUR account.
#
#   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh"             apply all fixes + audit
#   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --audit     audit only, changes nothing
#   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --probe     live Fn-key event probe
#   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --led-test   NumberPad LED test (asks y/n, remembers what works)
#   sh "/Volumes/Install macOS Sonoma/fix-hardware.sh" --collect   audit + helper log saved to the USB
#   GPU (Iris Xe acceleration, WhateverXe - experimental):
#     --gpu-test    next boot ONLY uses the GPU profile; then it switches back by itself
#     --gpu-report  save GPU results/logs to the USB (run after the test boot)
#     --gpu-keep    keep the GPU profile for every boot (only after a good test)
#     --gpu-off     back to the normal profile (same as GPU-OFF.command on any Mac)
#   options: --public-dns    use 8.8.8.8 / 1.1.1.1 instead of the router DNS (default = router, like stock macOS)
#            --keep-dns      do not touch DNS at all
#            --reset-network rebuild macOS network settings again (done automatically once in v8.3)
#            --no-network    skip the Wi-Fi stage
#
# v8.2: ZenBookHelper replaces ZenBookBrightness v4 (which never saw the Fn keys):
#  catches Fn+F4/F5 itself, dims the OLED, sun HUD; NumberPad LED + keypad.
#
# v8.1 fixes over v8.0:
#  - Under sudo, v8.0 wrote every 'defaults' value into ROOT's preferences and left
#    root-owned LaunchAgents/apps in your home. Without sudo, every network command
#    failed silently. v8.1 writes defaults as you and uses sudo only for network commands.
#  - Every preference is read back. Silent failures (e.g. protected
#    com.apple.universalaccess on Sonoma) are reported with a manual fix.
#  - Brightness daemon is started through launchd (no 'open' that aborted the script),
#    and launchd restarts it if it crashes (KeepAlive/SuccessfulExit=false).
#  - The trackpad LaunchAgent now runs activateSettings after writing, so the values
#    are actually applied at login (v8.0 only wrote them).
#  - Real audit: kexts with versions, SSDT-KBL v5.1 load check, AsusSMC/BrightnessKeys
#    state, ACPI errors this boot, Wi-Fi '!' diagnosis (IP/DNS/captive/country code),
#    EFI guard-rails (WhateverXe off, SecureBootModel, DmgLoading, boot-args).
# ==============================================================================
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VERSION="10.10"

MODE="apply"; DNS_MODE="dhcp"; DO_NET=1; FORCE_NETRESET=0; NEED_REBOOT=0
for a in "$@"; do
    case "$a" in
        --probe|-p)  MODE="probe" ;;
        --audit|-a)  MODE="audit" ;;
        --collect)   MODE="collect" ;;
        --diagnose)  MODE="diagnose" ;;
        --test)      MODE="usbtest"; TESTALL=0 ;;   # v10.1: lid only (everything else confirmed working)
        --test-all)  MODE="usbtest"; TESTALL=1 ;;
        --numpad-probe|--led-test) MODE="led-test" ;;
        --gpu-test)  MODE="gpu-test" ;;
        --gpu-trial) MODE="gpu-trial" ;;
        --gpu-trial-keep) MODE="gpu-trial-keep" ;;
        --gpu-keep)  MODE="gpu-keep" ;;
        --gpu-off)   MODE="gpu-off" ;;
        --gpu-report) MODE="gpu-report" ;;
        --dhcp-dns)  DNS_MODE="dhcp" ;;
        --public-dns) DNS_MODE="public" ;;
        --reset-network) FORCE_NETRESET=1 ;;
        --keep-dns)  DNS_MODE="keep" ;;
        --no-network) DO_NET=0 ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "[!] Unknown option: $a  (use --help)"; exit 2 ;;
    esac
done

# ------------------------------------------------------------------------------
# Identity: always target the real logged-in user, even if launched with sudo
# ------------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-}"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        TARGET_USER="$(stat -f %Su /dev/console 2>/dev/null)"
    fi
else
    TARGET_USER="$(id -un)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "[!] Could not determine your user account. Log in normally and run without sudo."
    exit 1
fi
TARGET_UID="$(id -u "$TARGET_USER")"
USER_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="$(eval echo "~$TARGET_USER")"
LAUNCH_DIR="$USER_HOME/Library/LaunchAgents"
TS="${ZB_TS:-$(date +%Y%m%d-%H%M%S)}"
RESULTS="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"

# Save everything this run prints onto the USB (so results come back with the stick)
if [ -z "${ZB_TEE:-}" ] && [ "$MODE" != "probe" ] && mkdir -p "$RESULTS" 2>/dev/null && [ -w "$RESULTS" ]; then
    export ZB_TEE=1 ZB_TS="$TS"
    /bin/bash "$0" "$@" 2>&1 | tee "$RESULTS/run-$MODE-$TS.txt"
    rc=${PIPESTATUS[0]}
    echo "(this output was saved to $RESULTS/run-$MODE-$TS.txt)"
    exit $rc
fi

WARN_LIST=()
warn() { echo "  [WARN] $*"; WARN_LIST+=("$*"); }
ok()   { echo "  [OK]   $*"; }
info() { echo "  ->     $*"; }

as_user() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$TARGET_USER" -H "$@"; else "$@"; fi; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
own()     { [ "$(id -u)" -eq 0 ] && chown -R "$TARGET_USER":staff "$@" 2>/dev/null; return 0; }

# setdef [-currentHost] <domain> <key> <-bool|-int|-float> <value>   (writes as user + reads back)
setdef() {
    local host=""
    if [ "$1" = "-currentHost" ]; then host="-currentHost"; shift; fi
    local dom="$1" key="$2" typ="$3" val="$4" want got
    as_user defaults $host write "$dom" "$key" "$typ" "$val" 2>/dev/null
    got="$(as_user defaults $host read "$dom" "$key" 2>/dev/null)"
    case "$typ" in
        -bool) [ "$val" = "true" ] && want=1 || want=0 ;;
        *)     want="$val" ;;
    esac
    if [ "$typ" = "-float" ]; then
        [ -n "$got" ] && awk -v a="$got" -v b="$want" 'BEGIN{exit !((a-b)<1e-6 && (b-a)<1e-6)}' && return 0
    else
        [ "$got" = "$want" ] && return 0
    fi
    return 1
}

echo "=========================================================="
echo "  ASUS ZenBook 13 OLED (UX325EA) Master Hardware Fix v$VERSION"
echo "  Mode: $MODE   User: $TARGET_USER   Home: $USER_HOME"
echo "=========================================================="

# ------------------------------------------------------------------------------
# Probe mode
# ------------------------------------------------------------------------------
if [ "$MODE" = "probe" ]; then
    echo "[*] Stage 4 live Fn-key probe. Needs Terminal in System Settings >"
    echo "    Privacy & Security > Accessibility AND Input Monitoring. Ctrl+C to stop."
    echo "    Expect ONE brightness event per Fn+F4 / Fn+F5 press."
    for p in "$SCRIPT_DIR/UX325EA_Fn_Key_Probe" "$USER_HOME/Downloads/UX325EA_Stage4_Addon/UX325EA_Fn_Key_Probe"; do
        [ -x "$p" ] && exec "$p"
    done
    echo "[!] UX325EA_Fn_Key_Probe binary not found."; exit 1
fi

if [ "$MODE" = "collect" ]; then
    mkdir -p "$RESULTS"
    echo "[*] Press Fn+F4 and Fn+F5 a few times NOW (10 s), then the audit runs..."
    sleep 10
    /bin/bash "$0" --audit 2>&1 | tee "$RESULTS/audit-$TS.txt"
    /bin/cp "$USER_HOME/Library/Logs/ZenBookHelper.log" "$RESULTS/helper-log-$TS.txt" 2>/dev/null
    log show --last 15m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "AsusSMC" OR eventMessage CONTAINS[c] "BrightnessKeys" OR eventMessage CONTAINS "ACPI")' \
        > "$RESULTS/kernel-log-$TS.txt" 2>/dev/null
    echo ""; echo "[*] Saved to $RESULTS - plug the USB into the other Mac and tell Claude."
    exit 0
fi
if [ "$MODE" = "diagnose" ]; then
    # Read-only, guided data capture for sound / Bluetooth / power button / sleep / USB-C.
    mkdir -p "$RESULTS"; OUT="$RESULTS/diagnose-$TS.txt"; : > "$OUT"
    sec() { echo "" >> "$OUT"; echo "==================== $* ====================" >> "$OUT"; }
    run() { sec "$1"; shift; "$@" >> "$OUT" 2>&1; }
    stamp() { /bin/date '+%Y-%m-%d %H:%M:%S'; }
    LIVE='process == "kernel" OR process == "powerd" OR process == "loginwindow" OR process == "coreaudiod" OR process == "bluetoothd" OR process == "WindowServer" OR process == "ZenBookHelper" OR process == "SystemUIServer" OR process == "ControlCenter"'
    step() {   # step "label" "instruction"
        local t0; echo ""; echo "------------------------------------------------------------"; echo ">>> $2"
        t0="$(stamp)"; printf "    Press Enter here when done... "; read -r _ < /dev/tty
        sec "LIVE: $1 ($t0 .. $(stamp))"
        /usr/bin/log show --start "$t0" --style compact --predicate "$LIVE" 2>/dev/null | grep -vE 'com.apple.xpc|Sandbox|sandbox' | tail -400 >> "$OUT"
        tail -40 "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | sed 's/^/[helper] /' >> "$OUT"
    }
    echo ""; echo "[*] ZenBook diagnose: about 3 minutes. Nothing is changed on this Mac."
    echo "    Step 1/2: collecting system information..."
    run "system" sw_vers; run "boot-args" nvram boot-args
    run "kexts" sh -c "kmutil showloaded 2>/dev/null | grep -iE 'ALC|HDA|Bluetooth|BlueTool|IntelBT|Voodoo|AsusSMC|Brightness|Realtek|SMC|Lilu|WhateverXe|USB' | awk '{print \$6, \$7}'"
    run "audio devices" system_profiler SPAudioDataType
    run "audio ioreg (HDEF/codec)" sh -c "ioreg -rxn HDEF -l -w0 2>/dev/null | grep -E 'layout-id|alc-|AAPL|device-id|vendor-id|IOName|class-code|subsystem' | head -40; ioreg -l -w0 2>/dev/null | grep -E '\"IOHDACodec(VendorID|RevisionID|Address)\"|\"layout-id\"|\"alc-layout-id\"|\"PinConfigurations\"|AppleHDAEngine(Input|Output)|\"IOAudioEngineDescription\"|\"IOAudioDeviceName\"' | head -60"
    run "audio kernel log (this boot)" sh -c "/usr/bin/log show --last boot --style compact --predicate 'process == \"kernel\" AND (eventMessage CONTAINS[c] \"AppleALC\" OR eventMessage CONTAINS[c] \"AppleHDA\" OR eventMessage CONTAINS[c] \"HDA\")' 2>/dev/null | tail -80"
    run "bluetooth" system_profiler SPBluetoothDataType
    run "bluetooth nvram" sh -c "nvram -p 2>/dev/null | grep -i bluetooth"
    run "bluetooth kernel log (this boot)" sh -c "/usr/bin/log show --last boot --style compact --predicate 'process == \"kernel\" AND (eventMessage CONTAINS[c] \"Bluetooth\" OR eventMessage CONTAINS[c] \"IntelBT\" OR eventMessage CONTAINS[c] \"BlueTool\" OR eventMessage CONTAINS[c] \"8087\")' 2>/dev/null | tail -120"
    run "bluetoothd errors (this boot)" sh -c "/usr/bin/log show --last boot --style compact --predicate 'process == \"bluetoothd\" AND (messageType == error OR messageType == fault)' 2>/dev/null | tail -80"
    run "USB tree" ioreg -p IOUSB -w0
    run "USB devices detail" sh -c "ioreg -p IOUSB -l -w0 2>/dev/null | grep -E '\+-o|\"idVendor\"|\"idProduct\"|\"locationID\"|\"USB Product Name\"|\"Device Speed\"|\"UsbConnector\"' "
    run "USB / Thunderbolt controllers" sh -c "ioreg -rc IOPCIDevice -w0 -l 2>/dev/null | grep -E '\+-o (XHC|TXHC|TDM|TRP|TBT|RP0|PXSX|XDCI)|\"device-id\" = <(13|ed|1b|1d|2f|31|33|35|36)9a|\"compatible\"' | head -60; system_profiler SPUSBDataType SPThunderboltDataType"
    run "power settings" sh -c "pmset -g; echo; pmset -g cap; echo; pmset -g assertions"
    run "sleep/wake history" sh -c "pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure|Shutdown|Start) ' | tail -80"
    run "power button / lid ACPI" sh -c "ioreg -rxn PWRB -w0 2>/dev/null | head -20; ioreg -rxn LID0 -w0 2>/dev/null | head -20; ioreg -r -k AppleClamshellState -d 1 -w0 2>/dev/null | grep -E 'Clamshell|SleepDisabled'"
    run "displays" system_profiler SPDisplaysDataType
    echo "    Step 2/2: short live tests. Do each one, then press Enter."
    step "power-button" "Press the POWER button ONCE, briefly (do not hold it). If the screen goes off, wake it, log in, then continue."
    step "mute-key" "Play any sound (e.g. a YouTube video). Press the MUTE key (Fn+F1) once, wait 3 s, press it again."
    step "volume-keys" "Press volume down (Fn+F2) twice, then volume up (Fn+F3) twice."
    step "microphone" "Open System Settings > Sound > Input. Speak for 5 seconds and watch the input level bars."
    step "bluetooth" "Click the Bluetooth icon in the menu bar (or System Settings > Bluetooth) and try to turn Bluetooth ON."
    run "bluetooth after test" system_profiler SPBluetoothDataType
    run "USB before plug" ioreg -p IOUSB -w0
    step "usb-c" "Plug a USB-C device (phone cable, USB-C stick or adapter) into a USB-C port, wait 10 s."
    run "USB after plug" sh -c "ioreg -p IOUSB -w0; system_profiler SPUSBDataType"
    step "lid" "Close the lid, wait 20 seconds, open it again and log in."
    run "sleep/wake after lid test" sh -c "pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure) ' | tail -20"
    echo ""; printf "  Quick answers (type and press Enter):\n"
    printf "  Did the POWER button do anything? (nothing / screen off / sleep / menu): "; read -r A1 < /dev/tty
    printf "  Did MUTE silence the sound? (yes/no): "; read -r A2 < /dev/tty
    printf "  Microphone level bars moved? (yes/no): "; read -r A3 < /dev/tty
    printf "  Lid: did it sleep and wake correctly? (yes/no/black screen): "; read -r A4 < /dev/tty
    printf "  USB-C device worked? (yes/no/not tested): "; read -r A5 < /dev/tty
    sec "user answers"; printf "power=%s\nmute=%s\nmic=%s\nlid=%s\nusbc=%s\n" "$A1" "$A2" "$A3" "$A4" "$A5" >> "$OUT"
    /bin/cp "$USER_HOME/Library/Logs/ZenBookHelper.log" "$RESULTS/helper-log-$TS.txt" 2>/dev/null
    sync; echo ""; echo "[*] Saved to $OUT"
    echo "    Eject the USB (right-click 'Install macOS Sonoma' > Eject) and bring it to the other Mac."
    exit 0
fi
if [ "$MODE" = "usbtest" ]; then
    # USB test bench: boot with the USB plugged in (it starts the newest test setup), run this,
    # do the short tests, then eject and bring the USB back. Unplugged = the normal SSD setup.
    mkdir -p "$RESULTS"; OUT="$RESULTS/test-$TS.txt"; : > "$OUT"
    sec() { echo "" >> "$OUT"; echo "==================== $* ====================" >> "$OUT"; }
    run() { sec "$1"; shift; "$@" >> "$OUT" 2>&1; }
    stamp() { /bin/date '+%Y-%m-%d %H:%M:%S'; }
    HB="$USER_HOME/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper"
    LIVE='process == "kernel" OR process == "powerd" OR process == "coreaudiod" OR process == "bluetoothd" OR process == "ZenBookHelper"'
    step() {
        local t0; echo ""; echo "------------------------------------------------------------"; echo ">>> $2"
        t0="$(stamp)"; printf "    Press Enter here when done... "; read -r _ < /dev/tty
        sec "LIVE: $1 ($t0 .. $(stamp))"
        /usr/bin/log show --start "$t0" --style compact --predicate "$LIVE" 2>/dev/null | grep -vE 'Sandbox|com.apple.xpc|wlan0|IO80211|corecapture|SPOwner|WirelessProximity' | tail -200 >> "$OUT"
        awk -v t="$t0" 'substr($0,1,19) >= t' "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -80 | sed 's/^/[helper] /' >> "$OUT"
    }
    # one key answers (y / n / other letter) - F-keys or arrows typed by mistake are ignored
    ask() { local a=""; while :; do printf "  %s " "$1" > /dev/tty; read -r a < /dev/tty; a="$(printf '%s' "$a" | tr -cd 'a-zA-Z' | cut -c1 | tr A-Z a-z)"; [ -n "$a" ] && break; echo "    (type y or n, then Enter)" > /dev/tty; done; echo "$2=$a" >> "$ANS"; }
    ANS="$RESULTS/.answers-$TS"; : > "$ANS"
    echo ""; echo "[*] ZenBook USB test v$VERSION (about 4 minutes)"
    # 0. how did the LAST shutdown end? (recorded by macOS at this boot)
    sec "previous shutdown"
    /usr/bin/log show --last boot --style compact --predicate 'eventMessage CONTAINS "Previous shutdown cause"' 2>/dev/null | grep -v noninteractively | tail -3 >> "$OUT"
    echo "  (5 = normal shut down, 3 = power button held, 0/-128 = power lost or forced, -20/-60/-61/-62 = stall or watchdog)" >> "$OUT"
    pmset -g log 2>/dev/null | grep -E ' (Shutdown|Restart|ShutdownCause|Sleep|Wake|Failure) ' | tail -8 >> "$OUT"
    ls -lt /Library/Logs/DiagnosticReports/ 2>/dev/null | grep -iE 'shutdown|stall|panic|hang' | head -6 >> "$OUT"
    # full stall reports (decoded on the other Mac) + what the system logged while it stalled
    for f in $(ls -t /Library/Logs/DiagnosticReports/*hutdown*tall* 2>/dev/null | head -2); do
        /bin/cp "$f" "$RESULTS/" 2>/dev/null || as_root /bin/cp "$f" "$RESULTS/" 2>/dev/null
        echo "copied $(basename "$f")" >> "$OUT"
    done
    NEWEST="$(ls -t /Library/Logs/DiagnosticReports/*hutdown*tall* 2>/dev/null | head -1)"
    if [ -n "$NEWEST" ]; then
        STS="$(basename "$NEWEST" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{6}')"
        SE="$(/bin/date -j -f '%Y-%m-%d-%H%M%S' "$STS" '+%s' 2>/dev/null)"
        if [ -n "$SE" ]; then
            sec "log around the newest shutdown stall ($STS)"
            /usr/bin/log show --style compact --start "$(/bin/date -r $((SE-120)) '+%Y-%m-%d %H:%M:%S')" --end "$(/bin/date -r $((SE+60)) '+%Y-%m-%d %H:%M:%S')" \
                --predicate 'process == "kernel" OR process == "launchd" OR process == "shutdown" OR process == "loginwindow" OR process == "logd" OR process == "bluetoothd" OR process == "airportd"' 2>/dev/null \
                | grep -vE 'Sandbox|com.apple.xpc|corecapture|SPOwner' | tail -400 >> "$OUT"
        fi
    fi
    BT="$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^[{] sec = ([0-9]+),.*/\1/')"
    if [ -n "$BT" ]; then
        sec "previous shutdown timeline (15 min before this start)"
        TL="$RESULTS/.timeline-$TS"
        /usr/bin/log show --style compact --start "$(/bin/date -r $((BT-900)) '+%Y-%m-%d %H:%M:%S')" --end "$(/bin/date -r "$BT" '+%Y-%m-%d %H:%M:%S')" \
            --predicate 'process == "loginwindow" OR process == "WindowServer" OR process == "corebrightnessd" OR process == "powerd" OR (process == "kernel" AND (eventMessage CONTAINS[c] "shutdown" OR eventMessage CONTAINS "UX325" OR eventMessage CONTAINS "IGFB" OR eventMessage CONTAINS "Corpse" OR eventMessage CONTAINS[c] "clamshell" OR eventMessage CONTAINS "Wake reason" OR eventMessage CONTAINS[c] "backlight"))' 2>/dev/null \
            | grep -vE 'Sandbox|com.apple.xpc' > "$TL"
        tail -450 "$TL" >> "$OUT"
        rm -f "$TL"
    fi
    sec "lid / wake history (last 3 hours, all sessions)"
    { pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure) ' | tail -25
      echo "--- driver + clamshell (kernel)"
      /usr/bin/log show --last 3h --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS "UX325" OR eventMessage CONTAINS[c] "clamshell" OR eventMessage CONTAINS "Wake reason")' 2>/dev/null | tail -60
      echo "--- helper (wake checks)"
      grep -E 'wake \+|wake: brightness|NSWorkspace(Did|Screens)Wake|power button' "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -30; } >> "$OUT"
    # 1. newest helper from the USB
    HI="$USER_HOME/Applications/ZenBookHelper.app"; HU="$SCRIPT_DIR/ZenBookHelper.app"
    VI="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HI/Contents/Info.plist" 2>/dev/null)"
    VU="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HU/Contents/Info.plist" 2>/dev/null)"
    if [ -d "$HU" ] && [ "$VI" != "$VU" ]; then
        for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do launchctl bootout "gui/$TARGET_UID/$L" 2>/dev/null; done
        rm -rf "$HI"; /bin/cp -R "$HU" "$HI"; xattr -dr com.apple.quarantine "$HI" 2>/dev/null; own "$HI"
        for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do
            [ -f "$LAUNCH_DIR/$L.plist" ] && launchctl bootstrap "gui/$TARGET_UID" "$LAUNCH_DIR/$L.plist" 2>/dev/null
        done
        ok "ZenBookHelper updated ${VI:-?} -> $VU (permissions kept) - waiting 5 s for it to start"; sleep 5
    else ok "ZenBookHelper $VI is current"; fi
    # Dock: Genie minimize, magnification, launch animation (user preferences, no sudo)
    as_user defaults write com.apple.dock mineffect -string genie
    as_user defaults write com.apple.dock magnification -bool true
    as_user defaults write com.apple.dock largesize -int 96
    as_user defaults write com.apple.dock launchanim -bool true
    as_user killall Dock 2>/dev/null
    RM="$(as_user defaults read com.apple.universalaccess reduceMotion 2>/dev/null)"
    ok "Dock: Genie minimize + magnification on (Scale: System Settings > Desktop & Dock)"
    [ "$RM" = "1" ] && warn "Reduce motion is ON - it disables Genie and magnification: System Settings > Accessibility > Display > Reduce motion = off"
    # 2. like a MacBook: password right after sleep (lid or power button)
    if ! sysadminctl -screenLock status 2>&1 | grep -q "immediate"; then
        echo ""; echo "    Lock screen: ask for your password right after sleep (lid or power button)."
        echo "    Type your LOGIN password when asked:"
        as_user sysadminctl -screenLock immediate -password - 2>&1 | grep -viE "^$|^Enter" | sed 's/^.*\] /    /' | tail -2
    fi
    sysadminctl -screenLock status 2>&1 | grep -q "immediate" && ok "Password required immediately after sleep" || warn "Lock screen setting not changed - set it in System Settings > Lock Screen"
    # 3. what is running (boot-path is exposed by the v9.7 test config; boot-args as a fallback)
    BP="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2-)"
    case "$BP" in
        *USB*|*Pci\(0x14,0x0\)*) BOOTED="USB stick (test setup)" ;;
        "") if nvram boot-args 2>/dev/null | grep -q -- '-wex-tgl-edp-bl'; then BOOTED="USB stick (test setup)"; else BOOTED="internal SSD (normal setup)"; fi ;;
        *)  BOOTED="internal SSD (normal setup)" ;;
    esac
    echo "    Started from: $BOOTED"
    run "boot" sh -c "echo 'started from: $BOOTED'; echo \"boot-path: $BP\"; sw_vers; nvram boot-args"
    run "GPU + panel brightness driver" sh -c "system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|Metal|VRAM|Resolution|Depth'; ioreg -p IOService -l -w0 -d 1 2>/dev/null | grep -E '\"WEXTGLEDP[A-Za-z]*\"|WhateverXeBacklight'"
    run "Control Centre brightness (PNLF 19 profile, display parameters)" sh -c "ioreg -l -w0 -n PNLF 2>/dev/null | grep -E '\"_UID\"' | head -2; ioreg -r -c AppleIntelPanel -w0 -l 2>/dev/null | grep -E 'WhateverXeBacklight' | cut -c1-200; ioreg -r -c AppleBacklightDisplay -w0 -l 2>/dev/null | grep -oE '\"(brightness|linear-brightness|usable-linear-brightness|bklt)\"=[{][^}]*[}]'"
    sec "ACPI fixes loaded (1 = yes)"
    AT="$(ioreg -l -w0 2>/dev/null | grep -m1 '"ACPI Tables"')"
    { echo "SSDT-WAKE table: $(echo "$AT" | grep -c 5a454e424b0057414b45)"
      echo "DSDT IANE->XANE: $(echo "$AT" | grep -c 58414e4509)  XWAK->YWAK: $(echo "$AT" | grep -c 5957414b01)  XPTS->YPTS: $(echo "$AT" | grep -c 5950545301)"
      echo "ACPI table names: $(echo "$AT" | grep -oE '"[A-Z0-9-]{4,8}"=' | tr -d '"=' | tr '\n' ' ')"
      echo "NHLT (audio DSP endpoints, for the microphone): $(echo "$AT" | grep -oE '"NHLT"=<[0-9a-f]*>' | cut -c1-6000)"
      echo "BrightnessKeys: $(ioreg -r -c BrightnessKeys -l -w0 2>/dev/null | grep -oE '"(UX325VolumeKeys|BrightnessPanel|BrightnessKeyRouted)" = [^ ]*' | tr '\n' ' ')"
      echo "BrightnessKeys build: $(kextstat -l 2>/dev/null | grep -i brightnesskeys | awk '{print $6, $7}')"
      echo "--- ACPI messages at boot"; /usr/bin/log show --last boot --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS "ACPI" OR eventMessage CONTAINS "AE_")' 2>/dev/null | head -40; } >> "$OUT"
    as_user "$HB" twofinger right >/dev/null 2>&1
    run "helper status" as_user "$HB" status
    run "audio before" as_user "$HB" audio
    # v10.10: since make-mac-only the SSD has the same OpenCore as this USB - both are fine
    [ "$BOOTED" = "internal SSD (normal setup)" ] && ok "Started from the internal SSD (macOS-only setup)"
    run "Wi-Fi health now (helper 8.21 probe)" as_user "$HB" wifiprobe
    if [ "${TESTALL:-0}" = 1 ]; then
    echo ""; echo "    First a question about your LAST shutdown (before this start):"
    ask "BEFORE this test you closed and opened the lid: did the screen come back? (y/n):" lid_before_test
    fi
    if [ "${TESTALL:-0}" = 1 ]; then
    echo "    Now do each short test, then press Enter."
    step "brightness keys" "Press Fn+F4 (darker) and Fn+F5 (brighter) several times (at 0 the screen is black, like before)."
    step "volume" "Play a sound. Press volume UP (Fn+F3) 3 times and volume DOWN (Fn+F2) 3 times."
    step "brightness slider" "Click Control Centre (top-right, the two-switches icon), drag the DISPLAY slider left and right, then close it."
    step "mute" "Play a sound or video. Press MUTE (Fn+F1) once, wait 3 s, press it again. You should see the crossed speaker, then the speaker with bars."
    run "audio after mute test" as_user "$HB" audio
    step "two-finger" "Tap with TWO fingers on the desktop: the menu should open (like a Mac). Press Esc. Do it 3 times."
    fi
    echo ""; echo "    About your LAST Shut Down and THIS start:"
    ask "Last Shut Down: was the screen plain black (no green dots)? (y/n):" shutdown_black
    ask "This start: normal loading screen after the password (no black, no yellow/green pixels)? (y/n):" login_normal
    sec "boot / login brightness timeline"
    { echo "boot: $(sysctl -n kern.boottime 2>/dev/null)"
      echo "login (helper start): $(grep -E 'brightness daemon v' "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -1 | cut -c1-23)"
      echo "WEXTGLEDPBacklightHistory = {ms since boot, macOS level 0..65535, nits | ok<<31} x24:"
      ioreg -p IOService -l -w0 -d 1 2>/dev/null | grep -o '"WEXTGLEDPBacklightHistory" = <[0-9a-f]*>'
      echo "--- display mode switches and login (whole boot)"
      /usr/bin/log show --last boot --style compact --predicate '(process == "WindowServer" AND (eventMessage CONTAINS "IOFBSetDisplayModeAndDepth: Setting" OR eventMessage CONTAINS[c] "fade")) OR (process == "kernel" AND eventMessage CONTAINS "modeset") OR (process == "loginwindow" AND eventMessage CONTAINS "login state")' 2>/dev/null | grep -vE 'Partial modeset' | head -80
      echo "--- EDID in use (single mode = duplicate timing removed): $(ioreg -r -c AppleBacklightDisplay -w0 -l 2>/dev/null | grep -o '"IODisplayEDID" = <[0-9a-f]\{180\}' | cut -c164-200)"
      echo "--- framebuffer re-init {count, copy, zero, 8->10-bit, ms since boot, vram}: $(ioreg -p IOService -l -w0 -d 1 2>/dev/null | grep -o '"WEXFramebufferInit" = <[0-9a-f]*>')"
      echo "--- Dock: mineffect=$(as_user defaults read com.apple.dock mineffect 2>/dev/null) magnification=$(as_user defaults read com.apple.dock magnification 2>/dev/null) reduceMotion=$RM"; } >> "$OUT"
    echo "    (your password is needed once, to read the graphics / key drivers' log)"
    sec "driver log (dmesg)"; as_root dmesg 2>/dev/null | grep -E 'UX325|brkeys|AsusSMC|atk' | tail -60 >> "$OUT"
    # v10.8: speakers after a lid wake (AppleALC layout 66 = layout 11 + speaker amp on at wake)
    sound_check() {   # $1 label  $2 answer key
        osascript -e 'set volume without output muted' -e 'if output volume of (get volume settings) < 40 then set volume output volume 60' >/dev/null 2>&1
        echo "    Playing a test sound now (3 pings from the laptop speakers) ..."
        for _i in 1 2 3; do afplay /System/Library/Sounds/Ping.aiff 2>/dev/null; done
        sec "sound + Wi-Fi: $1"
        { as_user "$HB" audio
          echo "--- layout in use: $(ioreg -r -c AppleHDAController -w0 -l 2>/dev/null | grep -oE '"alc-layout-id" = <[0-9a-f]*>' | head -1)"
          echo "--- Wi-Fi now: $(networksetup -getairportnetwork en0 2>&1 | tail -1), IP $(ipconfig getifaddr en0 2>/dev/null || echo none)"
          echo "--- speaker amplifier (helper 8.20):"; grep 'speaker amp' "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -4
          echo "--- Wi-Fi probe:"; as_user "$HB" wifiprobe 2>&1 | tail -4; } >> "$OUT" 2>&1
        ask "Did you HEAR the 3 pings from the laptop speakers? (y/n):" "$2"
    }
    sound_check "before sleep" speakers_before
    step "keys" "Before any sleep: press volume UP (Fn+F3) 3 times, volume DOWN (Fn+F2) 3 times, MUTE (Fn+F1) twice, Fn+F5 and Fn+F4."
    step "delete key" "Delete key: on the Desktop right-click > New Folder, click the new folder ONCE, then press the key NEXT TO THE POWER BUTTON. The folder should go to the Trash."
    echo "    LID TEST (2 rounds). Press Enter after each round - a test sound plays after each one."
    step "lid" "Round 1: close the lid, wait 20 s, open it, log in. Wait until the Wi-Fi icon is connected. Then press Fn+F5, Fn+F4, Fn+F3 (volume up), Fn+F1 (mute) twice and Fn+F7 (keyboard light)."
    sound_check "after lid round 1 (20 s)" speakers_round1
    step "lid2" "Round 2: close the lid, wait 1 MINUTE, open it, log in. Wait until the Wi-Fi icon is connected. Then press Fn+F5, Fn+F4, Fn+F3, Fn+F1 twice and Fn+F7."
    sound_check "after lid round 2 (1 min)" speakers_round2
    run "EC state + event poll (BrightnessKeys-UX325)" sh -c "ioreg -r -c BrightnessKeys -l -w0 2>/dev/null | grep -E 'UX325'; echo '(UX325ECDiag = ECNO, ECUP, EC status, OS type, OS driver, lid, ATKP, ECNT calls, drained, last event, polled, ATK flushes, lid changes by poll, blind-query events, Fn-lock now, Fn-lock saved, Fn-lock re-applied)'; /usr/bin/log show --last 30m --style compact --predicate 'eventMessage CONTAINS \"UX325 EC\"' 2>/dev/null | tail -30"
    run "Wi-Fi state" sh -c "networksetup -getairportpower en0 2>&1; ifconfig en0 2>&1 | head -6; kextstat -l 2>/dev/null | grep -i itlwm; system_profiler SPAirPortDataType 2>/dev/null | sed -n '1,30p'; grep -E '\\[wifi\\]' '$USER_HOME/Library/Logs/ZenBookHelper.log' 2>/dev/null | tail -15; /usr/bin/log show --last boot --style compact --predicate 'eventMessage CONTAINS[c] \"itlwm\"' 2>/dev/null | head -25; echo '--- Wi-Fi driver instance (empty = AirportItlwm did not attach):'; ioreg -r -c AirportItlwm -w0 -d1 2>/dev/null | head -3; echo '--- Wi-Fi PCI device 8086:a0f0 (AX201):'; ioreg -r -c IOPCIDevice -w0 -l 2>/dev/null | grep -B12 '\"device-id\" = <f0a00000>' | grep -E '\+-o|IOName|pcidebug' | head -4"
    run "lid / wake after the test" sh -c "pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure) ' | tail -12; /usr/bin/log show --last 10m --style compact --predicate 'process == \"kernel\" AND (eventMessage CONTAINS[c] \"clamshell\" OR eventMessage CONTAINS \"UX325\" OR eventMessage CONTAINS \"Wake reason\")' 2>/dev/null | tail -60; grep -E 'wake \+|wake: brightness|after wake|f14/f15|native slider|mute key|Delete key|key tap ready|speaker amp' '$USER_HOME/Library/Logs/ZenBookHelper.log' 2>/dev/null | tail -40"
    if [ "${TESTALL:-0}" = 1 ]; then
    step "power" "Press the POWER button once (the Mac sleeps). Wake it with a key, log in. Then press Fn+F5, volume up (Fn+F3) and MUTE twice."
    step "wifi" "Wait until the Wi-Fi icon shows it is connected (up to 2 minutes). Then press Enter."
    run "Wi-Fi details" sh -c "system_profiler SPAirPortDataType 2>/dev/null | sed -n '1,80p'"
    run "audio inputs (microphone)" sh -c "system_profiler SPAudioDataType 2>/dev/null | sed -n '1,60p'; ioreg -r -c AppleHDACodecGeneric -l -w0 2>/dev/null | grep -E 'PinConfig|NodeID|Mic' | head -20"
    run "volume/mute keys via BrightnessKeys (count)" sh -c "ioreg -r -c BrightnessKeys -l -w0 2>/dev/null | grep -E 'UX325|Brightness'"
    run "bluetooth state" sh -c "system_profiler SPBluetoothDataType 2>/dev/null | grep -E 'Address|State|Chipset|Firmware' | head -5"
    run "sleep/wake history" sh -c "pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure) ' | tail -12"
    run "Wi-Fi (helper watchdog)" sh -c "grep -E '\[wifi\]' '$USER_HOME/Library/Logs/ZenBookHelper.log' 2>/dev/null | tail -40"
    run "panel brightness driver after tests" sh -c "ioreg -p IOService -l -w0 -d 1 2>/dev/null | grep -E '\"WEXTGLEDPBacklight[A-Za-z]*\"'; ioreg -r -c AppleBacklightDisplay -w0 -l 2>/dev/null | grep -oE '\"(bklt|brightness)\"=[^}]*}'"
    fi
    echo ""; printf "  Quick answers (type, then Enter):\n"
    ask "Before sleep: each volume press moved the volume ONE step and mute worked? (y/n):" keys_before
    ask "Round 1 (20 s): screen came back AND Fn keys (brightness, volume, mute, keyboard light) worked? (y/n):" lid_round1
    ask "Round 2 (1 min): screen came back AND Fn keys worked? (y/n):" lid_round2
    ask "After EACH lid opening the Wi-Fi connected again by itself (within about 30 s)? (y/n):" wifi
    ask "Since the last test, whenever Wi-Fi showed connected, did websites always load? (y/n):" wifi_always_works
    ask "The key next to the power button sent the new folder to the Trash? (y/n):" delete_key
    if [ "${TESTALL:-0}" = 1 ]; then
    ask "Fn+F4/F5 changed the brightness? (y/n):" brightness_keys
    ask "Control Centre DISPLAY slider changed the brightness? (y/n):" cc_slider
    ask "Volume up/down worked (before sleep)? (y/n):" volume
    ask "Mute and unmute both worked? (y/n):" mute
    ask "Two fingers opened the menu? (y/n):" two_finger_menu
    ask "After LID sleep: brightness, volume and mute keys worked? (y/n):" keys_after_lid
    ask "After POWER-button sleep: brightness, volume and mute keys worked? (y/n):" keys_after_power
    ask "Wi-Fi connected again by itself? (y/n):" wifi
    fi
    sec "Wi-Fi health history (helper 8.21: drops, dead links, reconnects, 5-min quality)"
    grep -E 'Wi-Fi (quality|connected but|passed no traffic|reconnect|traffic OK|health|lost|back|has no IP|power cycle)|internet not reachable|DNS ' "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -120 >> "$OUT"
    sec "user answers"; cat "$ANS" >> "$OUT"; rm -f "$ANS"
    run "helper log" tail -200 "$USER_HOME/Library/Logs/ZenBookHelper.log"
    sync; echo ""; echo "[*] Saved to $OUT"
    if ! sed -n '/==== user answers/,/==== helper log/p' "$OUT" | grep -qE '^[a-z_]+=[^y]'; then
        echo ""; echo "    EVERYTHING WORKS. Make it permanent (copies this USB setup to the SSD, Windows untouched):"
        echo "        sudo sh \"$SCRIPT_DIR/sync-efi-to-ssd.sh\" --launcher-full"
        echo "    Then Shut Down, unplug the USB, power on: the laptop starts like a Mac, without the USB."
    else
        echo "    Something still fails - bring the USB back (a black screen after the lid: hold the power"
        echo "    button to restart, then run this test again - it records what happened)."
    fi
    echo "    Or eject the USB (right-click 'Install macOS Sonoma' > Eject) and bring it to the other Mac."
    exit 0
fi
if [ "$MODE" = "led-test" ]; then
    HB="$USER_HOME/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper"
    [ -x "$HB" ] || HB="$SCRIPT_DIR/ZenBookHelper.app/Contents/MacOS/ZenBookHelper"
    as_user "$HB" numpad ledtest < /dev/tty
    launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.numberpad" 2>/dev/null
    /bin/cp "$USER_HOME/Library/Logs/ZenBookHelper.log" "$RESULTS/helper-log-$TS.txt" 2>/dev/null
    exit 0
fi

# ------------------------------------------------------------------------------
# GPU profile (WhateverXe 0.8.3 + AMFIAnchor 0.1.2 + WhateverXe Graphics 0.4.4)
# ------------------------------------------------------------------------------
GD="/Library/Application Support/ZenBook"
gpu_esp() {   # mount point of the OpenCore partition holding config-gpu/config-stable (booted one first)
    local guid d mp pass
    guid="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | grep -oE 'GPT,[0-9A-Fa-f-]{36}' | cut -d, -f2 | tr a-f A-F)"
    for pass in booted any; do
        for d in $(diskutil list 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
            [ "$(diskutil info -plist "$d" 2>/dev/null | plutil -extract FilesystemType raw -o - - 2>/dev/null)" = "msdos" ] || continue
            if [ "$pass" = booted ]; then
                [ -n "$guid" ] || continue
                [ "$(diskutil info -plist "$d" 2>/dev/null | plutil -extract DiskUUID raw -o - - 2>/dev/null | tr a-f A-F)" = "$guid" ] || continue
            fi
            mp="$(diskutil info -plist "$d" 2>/dev/null | plutil -extract MountPoint raw -o - - 2>/dev/null)"
            if [ -z "$mp" ]; then as_root diskutil mount -mountOptions nobrowse "$d" >/dev/null 2>&1; mp="$(diskutil info -plist "$d" 2>/dev/null | plutil -extract MountPoint raw -o - - 2>/dev/null)"; fi
            [ -n "$mp" ] && [ -f "$mp/EFI/OC/config-gpu.plist" ] && [ -f "$mp/EFI/OC/config-stable.plist" ] && { echo "$mp"; return 0; }
        done
    done
    return 1
}
all_esps() {  # every OpenCore partition holding the GPU profiles (USB and SSD), one mount point per line
    local d mp
    for d in $(diskutil list 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
        [ "$(diskutil info -plist "$d" 2>/dev/null | plutil -extract FilesystemType raw -o - - 2>/dev/null)" = "msdos" ] || continue
        mp="$(diskutil info -plist "$d" 2>/dev/null | plutil -extract MountPoint raw -o - - 2>/dev/null)"
        if [ -z "$mp" ]; then as_root diskutil mount -mountOptions nobrowse "$d" >/dev/null 2>&1; mp="$(diskutil info -plist "$d" 2>/dev/null | plutil -extract MountPoint raw -o - - 2>/dev/null)"; fi
        [ -n "$mp" ] && [ -f "$mp/EFI/OC/config-gpu.plist" ] && [ -f "$mp/EFI/OC/config-stable.plist" ] && echo "$mp"
    done
}
gpu_state() { if [ -f "$1/EFI/OC/config-trial.plist" ] && cmp -s "$1/EFI/OC/config.plist" "$1/EFI/OC/config-trial.plist"; then echo trial; elif cmp -s "$1/EFI/OC/config.plist" "$1/EFI/OC/config-gpu.plist"; then echo gpu; elif cmp -s "$1/EFI/OC/config.plist" "$1/EFI/OC/config-stable.plist"; then echo stable; else echo custom; fi; }

if [ "$MODE" = "gpu-test" ] || [ "$MODE" = "gpu-keep" ] || [ "$MODE" = "gpu-off" ] || [ "$MODE" = "gpu-trial" ] || [ "$MODE" = "gpu-trial-keep" ]; then
    echo ""
    as_root -v 2>/dev/null || [ "$(id -u)" -eq 0 ] || { echo "[!] Your admin password is needed."; exit 1; }
    ESP="$(gpu_esp)" || { echo "[!] OpenCore partition with the GPU profiles not found - plug in the ZenBook USB."; exit 1; }
    OCD="$ESP/EFI/OC"
    echo "[*] OpenCore partition: $ESP (now: $(gpu_state "$ESP") profile)"
    case "$MODE" in
    gpu-off)
        as_root /bin/cp "$OCD/config-stable.plist" "$OCD/config.plist" && sync
        echo off | as_root tee "$GD/gpu-mode" >/dev/null 2>&1
        echo "[OK] Normal profile active ($(gpu_state "$ESP")). Restart to use it." ;;
    gpu-keep)
        as_root /bin/cp "$OCD/config-gpu.plist" "$OCD/config.plist" && sync
        echo keep | as_root tee "$GD/gpu-mode" >/dev/null 2>&1
        echo "[OK] GPU profile is now used for EVERY boot ($(gpu_state "$ESP"))."
        echo "     Undo: --gpu-off, or double-click GPU-OFF.command on this USB from any Mac." ;;
    gpu-trial-keep)
        [ -f "$OCD/config-trial.plist" ] || { echo "[!] no trial profile on $ESP"; exit 1; }
        EL="$(mktemp)"; all_esps > "$EL"
        while IFS= read -r M; do
            [ -f "$M/EFI/OC/config-trial.plist" ] || continue
            as_root /bin/cp "$M/EFI/OC/config-gpu.plist" "$M/EFI/OC/config-gpu-before-trial.plist"
            as_root /bin/cp "$M/EFI/OC/config-trial.plist" "$M/EFI/OC/config-gpu.plist" && as_root /bin/cp "$M/EFI/OC/config-trial.plist" "$M/EFI/OC/config.plist" && sync \
                && ok "trial setup is now the daily GPU profile on $M"
        done < "$EL"; rm -f "$EL"
        echo keep | as_root tee "$GD/gpu-mode" >/dev/null 2>&1
        echo "[OK] The trial profile is now the daily GPU profile ($(gpu_state "$ESP"))."
        echo "     Old one saved as config-gpu-before-trial.plist. Undo: --gpu-off" ;;
    gpu-test|gpu-trial)
        V="$(sw_vers -productVersion)"; B="$(sw_vers -buildVersion)"
        [ "$V" = "14.8.9" ] && ok "macOS $V ($B) - the version WhateverXe 0.8.3 requires for Sonoma" \
                            || warn "macOS $V: WhateverXe 0.8.3 requires Sonoma 14.8.9 exactly - test may fail"
        if kmutil showloaded 2>/dev/null | grep -q AppleIntelTGLCompat || pkgutil --pkgs 2>/dev/null | grep -qiE 'whateverxe|b00t0x'; then
            ok "WhateverXe Graphics package installed (AppleIntelTGLCompat present)"
        else
            PKG="$SCRIPT_DIR/UX325EA-RESCUE/GPU/WhateverXe-Graphics-0.4.4.pkg"
            echo "  The WhateverXe Graphics 0.4.4 package (required) is not installed."
            printf "  Install it now? It goes to /Library only; restart afterwards, then run --gpu-test again. [y/N] "
            read ANS < /dev/tty
            case "$ANS" in y|Y) as_root installer -pkg "$PKG" -target / && echo "[OK] Installed - RESTART, then run --gpu-test again."; exit 0 ;;
                           *) echo "Cancelled."; exit 0 ;; esac
        fi
        HI="$USER_HOME/Applications/ZenBookHelper.app"; HU="$SCRIPT_DIR/ZenBookHelper.app"
        VI="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HI/Contents/Info.plist" 2>/dev/null)"
        VU="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HU/Contents/Info.plist" 2>/dev/null)"
        if [ -d "$HU" ] && [ "$VI" != "$VU" ]; then
            for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do launchctl bootout "gui/$TARGET_UID/$L" 2>/dev/null; done
            rm -rf "$HI"; /bin/cp -R "$HU" "$HI"; xattr -dr com.apple.quarantine "$HI" 2>/dev/null; own "$HI"
            for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do
                [ -f "$LAUNCH_DIR/$L.plist" ] && launchctl bootstrap "gui/$TARGET_UID" "$LAUNCH_DIR/$L.plist" 2>/dev/null
            done
            ok "ZenBookHelper updated ${VI:-?} -> $VU (permissions kept)"
        fi
        as_root mkdir -p "$GD"
        as_root /bin/cp "$SCRIPT_DIR/UX325EA-RESCUE/GPU/gpu-guard.sh" "$GD/gpu-guard.sh"
        as_root chmod 755 "$GD/gpu-guard.sh"
        as_root /bin/sh -c "cat > /Library/LaunchDaemons/com.zenbook.gpu-guard.plist" <<GUARD_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zenbook.gpu-guard</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$GD/gpu-guard.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
GUARD_EOF
        as_root chown root:wheel /Library/LaunchDaemons/com.zenbook.gpu-guard.plist
        as_root chmod 644 /Library/LaunchDaemons/com.zenbook.gpu-guard.plist
        plutil -lint /Library/LaunchDaemons/com.zenbook.gpu-guard.plist >/dev/null || { echo "[!] guard plist invalid - aborting"; exit 1; }
        if [ "$MODE" = "gpu-trial" ]; then
            if [ ! -f "$OCD/config-trial.plist" ]; then
                # Started from the internal SSD copy of OpenCore, which predates the trial files.
                echo ""
                echo "[*] This Mac started from the SSD copy of OpenCore ($ESP)."
                echo "    The USB has newer files (USB map for Bluetooth, trial GPU driver)."
                printf "    Copy the USB EFI to the SSD now (Windows boot files are kept)? [Y/n] "; read ANS < /dev/tty
                case "$ANS" in n|N) echo "Cancelled."; exit 1 ;; esac
                as_root /bin/bash "$SCRIPT_DIR/sync-efi-to-ssd.sh" --launcher-full || { echo "[!] copy to the SSD failed - nothing changed"; exit 1; }
                ESP="$(gpu_esp)" || { echo "[!] OpenCore partition not found after the copy"; exit 1; }
                OCD="$ESP/EFI/OC"
                [ -f "$OCD/config-trial.plist" ] || { echo "[!] still no trial profile on $ESP"; exit 1; }
                ok "SSD OpenCore updated from the USB ($ESP)"
            fi
            cmp -s "$OCD/config.plist" "$OCD/config-trial.plist" && { echo "[!] the trial profile is already active (run --gpu-trial-keep or --gpu-off)"; exit 1; }
            as_root /bin/cp "$OCD/config.plist" "$OCD/config-prev.plist"
            echo trial | as_root tee "$GD/gpu-mode" >/dev/null
            as_root /bin/cp "$OCD/config-trial.plist" "$OCD/config.plist" && sync
            [ "$(gpu_state "$ESP")" = trial ] || { echo "[!] could not switch the profile"; exit 1; }
            # The laptop starts from the USB when it is plugged in, else from the SSD: arm both.
            EL="$(mktemp)"; all_esps > "$EL"
            while IFS= read -r M; do
                [ "$M" = "$ESP" ] && continue
                [ -f "$M/EFI/OC/config-trial.plist" ] || { warn "no trial profile on $M - that copy keeps its normal setup"; continue; }
                cmp -s "$M/EFI/OC/config.plist" "$M/EFI/OC/config-trial.plist" && continue
                as_root /bin/cp "$M/EFI/OC/config.plist" "$M/EFI/OC/config-prev.plist" && as_root /bin/cp "$M/EFI/OC/config-trial.plist" "$M/EFI/OC/config.plist" && sync \
                    && ok "trial also armed on $M"
            done < "$EL"; rm -f "$EL"
            echo ""
            echo "=========================================================="
            echo "  GPU TRIAL armed for the NEXT boot only (USB and SSD):"
            echo "    $(/usr/libexec/PlistBuddy -c 'Print :Kernel:Add' "$OCD/config-trial.plist" 2>/dev/null | grep -o 'WhateverXe[^ ]*kext' | head -1)"
            echo "  - Right at the start of that boot your current setup is put back, so the"
            echo "    boot after it is your normal Mac again, whatever happens."
            echo "  - SCREEN WORKS: after ~2.5 min a box asks 'Keep?' - click Keep, test, then"
            echo "    run --gpu-report. Happy with it?  --gpu-trial-keep  makes it permanent."
            echo "  - BLACK screen: do nothing. It records data and restarts by itself (~4 min)."
            echo "=========================================================="
        else
            echo test | as_root tee "$GD/gpu-mode" >/dev/null
            as_root /bin/cp "$OCD/config-gpu.plist" "$OCD/config.plist" && sync
            [ "$(gpu_state "$ESP")" = gpu ] || { echo "[!] could not switch the profile"; exit 1; }
            echo ""
            echo "=========================================================="
            echo "  GPU TEST is armed for the NEXT boot only."
            echo "  - Restart and pick macOS as usual. Verbose text scrolls; the screen may"
            echo "    flicker or go dark while the GPU driver starts."
            echo "  - Have a TV/monitor with HDMI? Plug it in BEFORE restarting - the GPU"
            echo "    desktop may appear there even if the OLED stays dark."
            echo "  - It WORKS: run   sh \"$SCRIPT_DIR/fix-hardware.sh\" --gpu-report"
            echo "    and if Metal shows 'Supported' and all is smooth:  --gpu-keep"
            echo "  - Uses the CUSTOM WhateverXe v2 for this OLED (correct mode timing +"
            echo "    2 lanes x 2.7 Gbps link, the same link the BIOS uses)."
            echo "  - SCREEN WORKS: after ~2.5 min a box asks 'Keep?' - click Keep, then run"
            echo "    --gpu-report, and if all is good --gpu-keep."
            echo "  - BLACK screen: DO NOTHING. After about 4 minutes the laptop records the"
            echo "    driver data and RESTARTS BY ITSELF into the normal Mac."
            echo "    (Only if nothing happens for 6 minutes: hold the power button 10 s,"
            echo "    turn it on again -> the normal Mac comes back by itself."
            echo "    Then run --gpu-report and bring the USB to the other Mac."
            echo "  - Keeps restarting: double-click GPU-OFF.command on this USB from any Mac."
            echo "=========================================================="
        fi
        printf "  Restart now? [y/N] "; read ANS < /dev/tty
        case "$ANS" in y|Y) as_root shutdown -r now ;; esac ;;
    esac
    exit 0
fi

if [ "$MODE" = "gpu-report" ]; then
    mkdir -p "$RESULTS"; OUT="$RESULTS/gpu-report-$TS.txt"
    ESP="$(gpu_esp 2>/dev/null)"
    {
    echo "== GPU report $(date)"; sw_vers
    echo "== OpenCore profile on ${ESP:-?}: $( [ -n "$ESP" ] && gpu_state "$ESP")   guard mode: $(cat "$GD/gpu-mode" 2>/dev/null || echo none)"
    echo "== guard log"; tail -20 "$GD/gpu-guard.log" 2>/dev/null
    for PFX in gpu-early gpu-spin gpu-diag; do
        LD="$(ls -t "$GD"/$PFX-*.txt 2>/dev/null | head -1)"
        if [ -n "$LD" ]; then echo "== LIVE capture from the GPU test boot: $LD"; cat "$LD"; /bin/cp "$LD" "$RESULTS/" 2>/dev/null; fi
    done
    T0="$(grep 'GPU test boot started' "$GD/gpu-guard.log" 2>/dev/null | tail -1 | cut -c1-19)"
    S0="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$T0" +%s 2>/dev/null)"
    if [ -n "$S0" ]; then
        echo "== Kernel/WindowServer log of the last GPU test boot (guard start $T0, -2 min .. +6 min)"
        /usr/bin/log show --start "$(/bin/date -r $((S0-120)) '+%Y-%m-%d %H:%M:%S')" --end "$(/bin/date -r $((S0+360)) '+%Y-%m-%d %H:%M:%S')" --style compact \
            --predicate '(process == "kernel" AND (sender CONTAINS[c] "Intel" OR sender CONTAINS[c] "WhateverXe" OR sender CONTAINS[c] "IOAccel" OR sender CONTAINS[c] "IOGraphics" OR sender CONTAINS[c] "AMFI" OR eventMessage CONTAINS[c] "watchdog" OR eventMessage CONTAINS[c] "panic")) OR ((process == "watchdogd" OR process == "WindowServer") AND (messageType == error OR messageType == fault))' 2>/dev/null | tail -2500
    fi
    echo "== boot-args"; nvram boot-args 2>/dev/null
    echo "== GPU kexts"; kmutil showloaded 2>/dev/null | grep -iE 'WhateverXe|AMFIAnchor|AMFIPass|TGLCompat|AppleIntelICL|IntelAccelerator|Lilu' | awk '{print $6, $7}'
    echo "== AMFIAnchor"; ioreg -r -c AMFIAnchor -l -w0 2>/dev/null | grep -E 'InstallStatus|LoadedAnchors'
    echo "== Graphics package"; pkgutil --pkgs 2>/dev/null | grep -iE 'whateverxe|b00t0x'
    echo "== Display / Metal"; system_profiler SPDisplaysDataType 2>/dev/null
    echo "== ZenBookHelper status + log (now)"; as_user "$USER_HOME/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper" status 2>/dev/null | head -30
    tail -200 "$USER_HOME/Library/Logs/ZenBookHelper.log" 2>/dev/null
    echo "== Bluetooth"; system_profiler SPBluetoothDataType 2>/dev/null | head -14
    echo "== USB internal/external (power assertions)"; pmset -g assertions 2>/dev/null | grep -E "usb\.(internal|external)device" | head
    echo "== sleep/wake history"; pmset -g log 2>/dev/null | grep -E " (Sleep|Wake|DarkWake|Failure) " | tail -15
    echo "== trackpad settings"; for k in Clicking TrackpadRightClick TrackpadCornerSecondaryClick Dragging; do printf "  %s = %s\n" "$k" "$(as_user defaults read com.apple.AppleMultitouchTrackpad $k 2>/dev/null)"; done
    echo "== Panics (newest 2)"
    for f in $(ls -t /Library/Logs/DiagnosticReports/*anic* 2>/dev/null | head -2); do echo "-- $f"; head -80 "$f"; done
    echo "== Kernel log, last 3 h (GPU related)"
    log show --last 3h --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "WhateverXe" OR eventMessage CONTAINS[c] "WEX" OR eventMessage CONTAINS[c] "AMFIAnchor" OR eventMessage CONTAINS "IGFB" OR eventMessage CONTAINS[c] "AppleIntelICL" OR eventMessage CONTAINS[c] "IntelAccel" OR eventMessage CONTAINS[c] "CD clock" OR eventMessage CONTAINS[c] "TGLCompat")' 2>/dev/null | tail -400
    } > "$OUT" 2>&1
    grep -E "Metal|Chipset|VRAM|Resolution|profile on|guard mode|WhateverXe|AMFIAnchor|TGLCompat|InstallStatus" "$OUT" | head -25
    echo ""; echo "[*] Full report saved to $OUT - bring the USB to the other Mac."
    exit 0
fi

if [ "$MODE" = "apply" ]; then
# ------------------------------------------------------------------------------
# 1. Native Wi-Fi
# ------------------------------------------------------------------------------
echo ""
echo "[1/6] Native Apple Wi-Fi + Apple ID network identity (en0, built-in, stock settings)..."
pkill -9 -x HeliPort 2>/dev/null
launchctl bootout "gui/$TARGET_UID/com.openintelwireless.heliport" 2>/dev/null
rm -f "$LAUNCH_DIR/com.openintelwireless.heliport.plist"
rm -rf "$USER_HOME/Applications/HeliPort.app"
[ -e "/Applications/HeliPort.app" ] && as_root rm -rf "/Applications/HeliPort.app"
info "HeliPort removed (single native Wi-Fi menu item)."

if [ "$DO_NET" = 1 ]; then
    if as_root -v 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
        WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')"
        # Hackintosh sleep settings: no hibernation/standby image, no Power Nap dark wakes.
        # AirportItlwm recovers far more reliably from plain sleep (Dortania laptop defaults).
        as_root pmset -a hibernatemode 0 standby 0 autopoweroff 0 powernap 0 2>/dev/null
        as_root pmset -a proximitywake 0 2>/dev/null
        as_root rm -f /private/var/vm/sleepimage 2>/dev/null
        info "Sleep: hibernation/standby/Power Nap off (stable Wi-Fi after wake); Wi-Fi watchdog re-joins if needed"
        STALE="$(networksetup -listnetworkserviceorder 2>/dev/null | grep -c 'Device: )')"
        DONE_ONCE="$(as_user defaults read com.zenbook.helper.settings netResetV83 2>/dev/null)"
        NETRESET=0; WHY=""
        [ -n "$WIFI_DEV" ] && [ "$WIFI_DEV" != "en0" ] && { NETRESET=1; WHY="Wi-Fi is $WIFI_DEV (Apple ID needs Wi-Fi on en0)"; }
        [ "${STALE:-0}" -gt 0 ] && { NETRESET=1; WHY="$WHY ${STALE} stale network service(s) from old itlwm/HeliPort tests"; }
        [ "$DONE_ONCE" != "1" ] && { NETRESET=1; WHY="$WHY one-time clean rebuild (v8.3)"; }
        [ "$FORCE_NETRESET" = 1 ] && { NETRESET=1; WHY="$WHY --reset-network"; }
        if [ "$NETRESET" = 1 ]; then
            SC=/Library/Preferences/SystemConfiguration
            NB="$RESULTS/network-backup-$TS"; mkdir -p "$NB"
            for f in NetworkInterfaces.plist preferences.plist; do [ -f "$SC/$f" ] && as_root /bin/cp "$SC/$f" "$NB/$f"; done
            as_root chown -R "$TARGET_USER":staff "$NB" 2>/dev/null
            as_root rm -f "$SC/NetworkInterfaces.plist" "$SC/preferences.plist"
            as_user defaults write com.zenbook.helper.settings netResetV83 -bool true
            NEED_REBOOT=1
            ok "Network settings reset:$WHY"
            info "Backup: $NB  (saved Wi-Fi passwords are kept)"
            info "After the RESTART macOS rebuilds them: Wi-Fi = en0, stock icon, router DNS."
        fi
        if [ "$NETRESET" = 1 ]; then
            :
        elif [ -z "$WIFI_DEV" ]; then
            warn "No 'Wi-Fi' hardware port: AirportItlwm is not attached. Check kext load in the audit below."
        else
            WIFI_SVC="$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$WIFI_DEV" '
                /^\([0-9*]+\) /{svc=$0; sub(/^\([0-9*]+\) /,"",svc)}
                index($0,"Device: " dev ")"){print svc; exit}')"
            if [ -z "$WIFI_SVC" ]; then
                as_root networksetup -createnetworkservice "Wi-Fi" "$WIFI_DEV" && WIFI_SVC="Wi-Fi"
                info "Created network service 'Wi-Fi' on $WIFI_DEV"
            fi
            info "Wi-Fi device $WIFI_DEV, service '$WIFI_SVC'"
            as_root networksetup -setairportpower "$WIFI_DEV" on 2>/dev/null
            as_root networksetup -setdhcp "$WIFI_SVC" 2>/dev/null
            case "$DNS_MODE" in
                public) as_root networksetup -setdnsservers "$WIFI_SVC" 8.8.8.8 1.1.1.1 2>/dev/null
                        info "DNS 8.8.8.8 / 1.1.1.1 (hotel/campus login page not showing? re-run without --public-dns)" ;;
                dhcp)   as_root networksetup -setdnsservers "$WIFI_SVC" Empty 2>/dev/null
                        info "DNS from router (stock macOS setting)" ;;
                keep)   info "DNS left unchanged" ;;
            esac
            as_root ipconfig set "$WIFI_DEV" DHCP 2>/dev/null
            as_root dscacheutil -flushcache 2>/dev/null
            as_root killall -HUP mDNSResponder 2>/dev/null
            ok "Wi-Fi stack refreshed."
        fi
    else
        warn "No admin password given: Wi-Fi network reset skipped (re-run and enter your password)."
    fi
else
    info "Network stage skipped (--no-network)."
fi

# ------------------------------------------------------------------------------
# 2. Headless OLED brightness daemon
# ------------------------------------------------------------------------------
echo ""
echo "[2/6] ZenBookHelper: Fn+F4/F5 OLED brightness + NumberPad (headless, no menu bar item)..."
pkill -9 -x MonitorControl 2>/dev/null
rm -rf "$USER_HOME/Applications/MonitorControl.app"
[ -e "/Applications/MonitorControl.app" ] && as_root rm -rf "/Applications/MonitorControl.app"

H_APP="$USER_HOME/Applications/ZenBookHelper.app"
H_BIN="$H_APP/Contents/MacOS/ZenBookHelper"
for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do launchctl bootout "gui/$TARGET_UID/$L" 2>/dev/null; done
pkill -x ZenBookBrightness 2>/dev/null; pkill -x ZenBookHelper 2>/dev/null
rm -rf "$USER_HOME/Applications/ZenBookBrightness.app"          # old v4 daemon (could not see Fn keys)
sleep 1

write_agent() {   # $1 label  $2 daemon argument
    cat > "$LAUNCH_DIR/$1.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$1</string>
    <key>ProgramArguments</key>
    <array>
        <string>$H_BIN</string>
        <string>$2</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF
    chmod 644 "$LAUNCH_DIR/$1.plist"; own "$LAUNCH_DIR/$1.plist"
    plutil -lint "$LAUNCH_DIR/$1.plist" >/dev/null || warn "$1 LaunchAgent plist is invalid."
}

if [ -d "$SCRIPT_DIR/ZenBookHelper.app" ]; then
    mkdir -p "$USER_HOME/Applications" "$USER_HOME/bin" "$LAUNCH_DIR"
    rm -rf "$H_APP"
    /bin/cp -R "$SCRIPT_DIR/ZenBookHelper.app" "$H_APP"
    xattr -dr com.apple.quarantine "$H_APP" 2>/dev/null
    rm -f "$USER_HOME/bin/zenbook-helper" "$USER_HOME/bin/zenbook-oled-brightness"
    ln -s "$H_BIN" "$USER_HOME/bin/zenbook-helper"
    [ -f "$USER_HOME/.zshrc" ] || : > "$USER_HOME/.zshrc"
    for rc in "$USER_HOME/.zshrc" "$USER_HOME/.bash_profile"; do
        [ -f "$rc" ] || continue
        grep -q 'HOME/bin' "$rc" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$rc"
    done
    as_user defaults delete com.zenbook.helper.settings brightnessStarts 2>/dev/null
    as_user defaults delete com.zenbook.helper.settings numpadStarts 2>/dev/null
    as_user defaults delete com.zenbook.helper.settings wifiStarts 2>/dev/null
    write_agent com.zenbook.brightness --brightness
    write_agent com.zenbook.numberpad  --numberpad
    write_agent com.zenbook.wifi       --wifi
    own "$H_APP" "$USER_HOME/bin" "$USER_HOME/.zshrc" "$USER_HOME/.bash_profile"
    for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do
        launchctl bootstrap "gui/$TARGET_UID" "$LAUNCH_DIR/$L.plist" 2>/dev/null || info "$L starts at next login."
    done
    sleep 2
    pgrep -f "ZenBookHelper --brightness" >/dev/null && ok "Brightness daemon running" || warn "Brightness daemon not running (see ~/Library/Logs/ZenBookHelper.log)"
    pgrep -f "ZenBookHelper --numberpad"  >/dev/null && ok "NumberPad daemon running"  || warn "NumberPad daemon not running (see ~/Library/Logs/ZenBookHelper.log)"
    pgrep -f "ZenBookHelper --wifi"       >/dev/null && ok "Wi-Fi watchdog running"    || warn "Wi-Fi watchdog not running (see ~/Library/Logs/ZenBookHelper.log)"
    echo ""
    # v8.5: older builds were signed by file hash, so every update silently lost these
    # permissions (helper log: touchpad 0xE00002E2, accessibility = 0). The app is now signed
    # with a fixed identity; clear the stale entries once and grant them one last time.
    if [ "$(as_user defaults read com.zenbook.helper.settings tccResetV85 2>/dev/null)" != "1" ]; then
        for svc in ListenEvent Accessibility PostEvent; do
            as_user tccutil reset "$svc" com.zenbook.helper >/dev/null 2>&1
            as_root tccutil reset "$svc" com.zenbook.helper >/dev/null 2>&1
        done
        as_user defaults write com.zenbook.helper.settings tccResetV85 -bool true
        launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.numberpad" 2>/dev/null
        launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.brightness" 2>/dev/null
        info "Old (broken) permission entries for ZenBookHelper removed."
    fi
    perm_state() { as_user defaults read com.zenbook.helper.settings numpadStatus 2>/dev/null | tr -d ' ;' ; }
    for attempt in 1 2; do
        sleep 6
        ST="$(perm_state)"
        if echo "$ST" | grep -q 'touchpadAccess=1' && echo "$ST" | grep -q 'accessibility=1'; then
            ok "ZenBookHelper has Input Monitoring + Accessibility (permanent from now on)"; break
        fi
        echo ""
        echo "  >>> PERMISSIONS - LAST TIME (they now survive every update):"
        echo "      System Settings > Privacy & Security > Input Monitoring -> switch ON ZenBookHelper"
        echo "      System Settings > Privacy & Security > Accessibility    -> switch ON ZenBookHelper"
        echo "      Not in a list? press +, open your home folder > Applications > ZenBookHelper."
        as_user open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null
        as_user open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
        printf "      Press Return here when BOTH switches are ON... "
        read _ < /dev/tty
        launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.numberpad" 2>/dev/null
        launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.brightness" 2>/dev/null
    done
    ST="$(perm_state)"
    echo "$ST" | grep -q 'touchpadAccess=1' || warn "NumberPad lights: ZenBookHelper still has no Input Monitoring access"
    echo "$ST" | grep -q 'accessibility=1'  || warn "NumberPad digits / two-finger left click: ZenBookHelper still has no Accessibility access"
    as_user "$H_BIN" twofinger right >/dev/null 2>&1
    info "Two-finger tap / click = menu (right click), like a Mac"
    LEDVAR="$(as_user defaults read com.zenbook.helper.settings numpadLEDVariant 2>/dev/null)"
    if [ -z "$LEDVAR" ]; then
        echo ""
        echo "  >>> NumberPad LED test: up to 4 short tests. After each one, LOOK AT THE TOUCHPAD"
        echo "      and answer y (lights are on) or n (still dark)."
        as_user "$H_BIN" numpad ledtest < /dev/tty
        launchctl kickstart -k "gui/$TARGET_UID/com.zenbook.numberpad" 2>/dev/null
    else
        ok "NumberPad LED mode: $LEDVAR  (re-test: sh \"$SCRIPT_DIR/fix-hardware.sh\" --led-test)"
    fi
    if echo "$(perm_state)" | grep -q 'touchpadAccess=1'; then
        as_user "$H_BIN" numpad on >/dev/null 2>&1; sleep 2
        printf "  >>> NumberPad switched ON by the helper - are the touchpad number LIGHTS on? [y/n] "
        read LEDOK < /dev/tty
        as_user "$H_BIN" numpad off >/dev/null 2>&1
        case "$LEDOK" in y|Y) ok "NumberPad lights work from the touchpad icon" ;;
                         *)   warn "NumberPad lights did not come on from the helper - bring the USB back (logs saved)" ;; esac
    fi
    info "NumberPad: hold the TOP-RIGHT touchpad icon 1 s = on/off.  Slide from the TOP-LEFT corner = Calculator."
else
    warn "ZenBookHelper.app not found next to this script - brightness/NumberPad stage skipped."
fi

# ------------------------------------------------------------------------------
# 3. UI speed-up for software rendering (Iris Xe in -wexoff framebuffer mode)
# ------------------------------------------------------------------------------
echo ""
echo "[3/6] UI speed-up (no live blur / animations on CPU rendering)..."
UA_FAIL=0
setdef com.apple.universalaccess reduceTransparency -bool true || UA_FAIL=1
setdef com.apple.universalaccess reduceMotion -bool true       || UA_FAIL=1
if [ "$UA_FAIL" = 1 ]; then
    warn "Reduce Transparency/Motion could not be written (Sonoma protects this domain)."
    info "Do it by hand: System Settings > Accessibility > Display > Reduce motion + Reduce transparency."
else
    ok "Reduce Transparency + Reduce Motion ON"
fi
setdef NSGlobalDomain AppleReduceDesktopTinting -bool true         || warn "AppleReduceDesktopTinting not set"
setdef NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false || warn "NSAutomaticWindowAnimationsEnabled not set"
setdef NSGlobalDomain NSWindowResizeTime -float 0.001              || warn "NSWindowResizeTime not set"
setdef NSGlobalDomain QLPanelAnimationDuration -float 0            || warn "QLPanelAnimationDuration not set"
setdef com.apple.dock launchanim -bool false                       || warn "Dock launchanim not set"
setdef com.apple.dock expose-animation-duration -float 0.1         || warn "Dock expose-animation-duration not set"
ok "Window/Dock animations shortened."

# ------------------------------------------------------------------------------
# 4. Function keys
# ------------------------------------------------------------------------------
echo ""
echo "[4/6] Function keys..."
setdef NSGlobalDomain com.apple.keyboard.fnState -bool false && ok "Hardware functions have priority on the top row" || warn "fnState not set"
info "Fn+F4 / Fn+F5 : display brightness down / up  (EC _Q15/_Q16 -> SSDT-KBL v5.2 -> AsusSMC + BrightnessKeys -> ZenBookHelper)"
info "Fn+F7         : keyboard backlight cycle 0 -> 1 -> 2 -> 3 -> 0 (EC _Q66 -> SSDT-KBL v5.2)"
info "Ctrl+Option+Up/Down : brightness step through the daemon (backup path)"
info "Fn+Esc toggles the ASUS hardware Fn-Lock."

# ------------------------------------------------------------------------------
# 5. Trackpad
# ------------------------------------------------------------------------------
echo ""
echo "[5/6] Trackpad gestures..."
TP_OK=1
for d in com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad; do
    setdef "$d" Clicking -bool true           || TP_OK=0
    setdef "$d" Dragging -bool true           || TP_OK=0
    setdef "$d" TrackpadRightClick -bool true || TP_OK=0
done
setdef com.apple.AppleMultitouchTrackpad TrackpadCornerSecondaryClick -int 2                     || TP_OK=0
setdef com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadCornerSecondaryClick -int 2     || TP_OK=0
setdef -currentHost NSGlobalDomain com.apple.trackpad.trackpadCornerClickBehavior -int 1          || TP_OK=0
setdef com.apple.AppleMultitouchTrackpad TrackpadScroll -bool true      || TP_OK=0
setdef com.apple.AppleMultitouchTrackpad TrackpadHorizScroll -bool true || TP_OK=0
setdef NSGlobalDomain com.apple.mouse.tapBehavior -int 1                  || TP_OK=0
setdef -currentHost NSGlobalDomain com.apple.mouse.tapBehavior -int 1     || TP_OK=0
setdef NSGlobalDomain com.apple.trackpad.enableSecondaryClick -bool true  || TP_OK=0
setdef -currentHost NSGlobalDomain com.apple.trackpad.enableSecondaryClick -bool true || TP_OK=0
[ "$TP_OK" = 1 ] && ok "Tap = left click, double-tap = double click, two-finger tap = left click, press bottom-right corner = right click" || warn "Some trackpad keys did not stick."

ACT=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings
T_PLIST="$LAUNCH_DIR/com.zenbook.trackpad.plist"
mkdir -p "$LAUNCH_DIR"
cat > "$T_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zenbook.trackpad</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>for d in com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad; do defaults write \$d Clicking -bool true; defaults write \$d Dragging -bool true; defaults write \$d TrackpadRightClick -bool true; done; defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1; defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1; defaults write NSGlobalDomain com.apple.trackpad.enableSecondaryClick -bool true; defaults -currentHost write NSGlobalDomain com.apple.trackpad.enableSecondaryClick -bool true; defaults write com.apple.AppleMultitouchTrackpad TrackpadCornerSecondaryClick -int 2; defaults -currentHost write NSGlobalDomain com.apple.trackpad.trackpadCornerClickBehavior -int 1; $ACT -u</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST_EOF
chmod 644 "$T_PLIST"; own "$T_PLIST"
plutil -lint "$T_PLIST" >/dev/null || warn "Trackpad LaunchAgent plist is invalid."
launchctl bootout "gui/$TARGET_UID/com.zenbook.trackpad" 2>/dev/null
launchctl bootstrap "gui/$TARGET_UID" "$T_PLIST" 2>/dev/null || info "Trackpad agent registers at next login."
as_user "$ACT" -u 2>/dev/null
pkill -HUP -u "$TARGET_UID" -x cfprefsd 2>/dev/null
pkill -u "$TARGET_UID" -x Dock 2>/dev/null
ok "Trackpad settings applied now and re-applied at every login."
fi   # MODE=apply

# ------------------------------------------------------------------------------
# 6. Stage 4 audit (read-only)
# ------------------------------------------------------------------------------
echo ""
echo "[6/6] Stage 4 hardware & driver audit (read-only)..."

echo "  --- System ---"
info "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), model $(sysctl -n hw.model)"
OCV="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | awk '{print $2}')"
BOOTP="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2-)"
[ -n "$OCV" ] && info "OpenCore $OCV"
case "$BOOTP" in
    *USB*)  info "Booted from: USB stick" ;;
    *NVMe*) info "Booted from: internal SSD (standalone)" ;;
    "")     info "Booted from: unknown (boot-path not exposed)" ;;
    *)      info "Booted from: $BOOTP" ;;
esac

echo "  --- Kernel extensions ---"
KLIST="$( (kmutil showloaded 2>/dev/null || kextstat 2>/dev/null) | grep -oE '[a-z][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+)+ \([^)]*\)' )"
for pair in Lilu:Lilu VirtualSMC:VirtualSMC SMCBatteryManager:SMCBatteryManager AsusSMC:AsusSMC \
            BrightnessKeys:BrightnessKeys VoodooPS2Keyboard:PS2Keyboard VoodooI2C:VoodooI2C VoodooI2CHID:VoodooI2CHID \
            VoodooInput:VoodooInput AirportItlwm:AirportItlwm IntelBluetoothFirmware:IntelBluetoothFirmware \
            BlueToolFixup:BlueToolFixup AppleALC:AppleALC ECEnabler:ECEnabler RealtekCardReader:rtsx \
            PC711Probe:PC711Probe RestrictEvents:RestrictEvents; do
    label="${pair%%:*}"; idtail="${pair##*:}"
    line="$(echo "$KLIST" | grep -i "\.$idtail " | head -1)"
    [ -n "$line" ] && ok "$label  $line" || warn "$label is NOT loaded"
done
echo "$KLIST" | grep -qi whateverxe && warn "WhateverXe is LOADED - this black-screens the ATNA33XC01 panel. Disable it!" || ok "WhateverXe not loaded (OLED-safe)"
echo "$KLIST" | grep -qiE '\.itlwm ' && warn "itlwm is loaded alongside AirportItlwm - disable one of them."

echo "  --- ACPI hotkey plumbing ---"
ACPI="$(ioreg -p IOACPIPlane -w0 2>/dev/null)"
echo "$ACPI" | grep -q "KBLI" && ok "SSDT-KBL loaded (KBLI device present)" || warn "SSDT-KBL NOT loaded (no KBLI device). Fn+F4/F5/F7 cannot work."
echo "$ACPI" | grep -q "DD1F" && ok "GFX0.DD1F panel device present" || warn "GFX0.DD1F missing (BrightnessKeys fallback has no panel)"
SMC="$(ioreg -rc AsusSMC -w0 2>/dev/null)"
if [ -n "$SMC" ]; then
    echo "$SMC" | grep -q '"IsKeyboardBacklightSupported" = Yes' && ok "AsusSMC sees SKBV (keyboard backlight supported)" \
                                                                 || warn "AsusSMC reports no keyboard backlight (SKBV missing -> SSDT-KBL not loaded?)"
else
    warn "AsusSMC service not found in IORegistry"
fi
ioreg -rc BrightnessKeys -w0 2>/dev/null | grep -q BrightnessKeys && ok "BrightnessKeys attached (fallback path)" || info "BrightnessKeys not attached (fine while AsusSMC handles keys)"
ACPI_ERR="$(log show --last boot --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "ACPI"' 2>/dev/null \
            | grep -iE 'error|exception|already|AE_' | grep -iE 'KBL|BRTN|DD1F|SKBV|Q66|ZKBL|ALREADY' | head -5)"
if [ -n "$ACPI_ERR" ]; then warn "ACPI errors this boot related to SSDT-KBL:"; echo "$ACPI_ERR" | sed 's/^/           /'
else ok "No SSDT-KBL related ACPI errors in this boot's kernel log"; fi

echo "  --- Display / brightness / NumberPad (ZenBookHelper) ---"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Metal|Resolution|VRAM' | sed 's/^ */       /'
pgrep -f "ZenBookHelper --brightness" >/dev/null && ok "Brightness daemon running" || warn "Brightness daemon NOT running"
pgrep -f "ZenBookHelper --numberpad"  >/dev/null && ok "NumberPad daemon running"  || warn "NumberPad daemon NOT running"
pgrep -x ZenBookBrightness >/dev/null && warn "Old ZenBookBrightness v4 still running - re-run fix-hardware.sh"
HB="$USER_HOME/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper"
[ -x "$HB" ] && as_user "$HB" status 2>/dev/null | sed 's/^/       /'
HLOG="$USER_HOME/Library/Logs/ZenBookHelper.log"
if [ -f "$HLOG" ]; then
    info "Last ZenBookHelper log lines (press Fn+F4/F5 before running --audit to see them here):"
    tail -n 15 "$HLOG" | sed 's/^/           /'
fi

echo "  --- UI / trackpad preferences (your account) ---"
for kv in "com.apple.universalaccess reduceTransparency" "com.apple.universalaccess reduceMotion" "com.apple.AppleMultitouchTrackpad Clicking" "com.apple.AppleMultitouchTrackpad Dragging" "com.apple.AppleMultitouchTrackpad TrackpadRightClick" "NSGlobalDomain com.apple.keyboard.fnState"; do
    set -- $kv
    v="$(as_user defaults read "$1" "$2" 2>/dev/null)"
    [ "$v" = "1" ] && ok "$1 $2 = 1" || warn "$1 $2 = ${v:-unset}"
done

echo "  --- Wi-Fi ('!' diagnosis) ---"
WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')"
if [ -z "$WIFI_DEV" ]; then
    warn "No Wi-Fi hardware port (AirportItlwm not attached)"
else
    IP="$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)"
    GW="$(ipconfig getoption "$WIFI_DEV" router 2>/dev/null)"
    DNS="$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | tr '\n' ' ')"
    info "Device $WIFI_DEV  IP ${IP:-none}  router ${GW:-none}  DNS ${DNS:-none}"
    HBW="$USER_HOME/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper"
    if [ -x "$HBW" ]; then
        LINK="$(as_user "$HBW" wifi 2>/dev/null)"
        info "Link: $LINK"
        case "$LINK" in *"2.4 GHz"*) warn "Wi-Fi is on 2.4 GHz (max ~144 Mbps). For full speed join your router's 5 GHz network (often named ...5G)." ;; esac
    fi
    CC="$(system_profiler SPAirPortDataType 2>/dev/null | awk -F': ' '/Country Code/{print $2; exit}')"
    info "Country code: ${CC:-unknown} (boot-arg itlwm_cc=US expected)"
    case "$IP" in
        "")        warn "No IP on $WIFI_DEV: not associated or DHCP failed -> '!' in menu bar" ;;
        169.254.*) warn "Self-assigned IP $IP: DHCP failed -> '!' (router/AP or AirportItlwm association)" ;;
        *)  if dscacheutil -q host -a name apple.com 2>/dev/null | grep -q ip_address; then
                ok "DNS resolves"
                if curl -s -m 6 http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success; then
                    ok "Internet reachable (captive check passed) - no reason for a '!'"
                else
                    warn "DNS OK but captive check failed: captive/login portal or no upstream internet"
                fi
            else
                warn "IP OK but DNS fails -> '!' (try --dhcp-dns or --keep-dns, or check router)"
            fi ;;
    esac
    networksetup -listallnetworkservices 2>/dev/null | sed 1d | grep '^\*' | sed 's/^/           disabled service: /'
fi

echo "  --- Apple ID / iCloud readiness ---"
MLBN="$(nvram 4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14:MLB 2>/dev/null | awk '{print $2}')"
if [ ${#MLBN} -eq 17 ]; then ok "MLB is 17 characters (valid format)"
else warn "MLB is ${#MLBN} characters - boot the v8.3 EFI from the USB (it carries the corrected MLB)"; fi
EN0PORT="$(networksetup -listallhardwareports 2>/dev/null | awk '/Hardware Port:/{p=$0; sub(/Hardware Port: /,"",p)} /^Device: en0$/{print p; exit}')"
[ "$EN0PORT" = "Wi-Fi" ] && ok "en0 is Wi-Fi" || warn "en0 is '${EN0PORT:-missing}' - Apple ID needs Wi-Fi as en0 (restart after the network reset)"
EN0BI="$(ioreg -r -k IOBuiltin -w0 -d1 2>/dev/null | awk '/^\+-o /{bsd=0;b=""} /"BSD Name" = "en0"/{bsd=1} /"IOBuiltin" = /{b=$NF} bsd && b!="" {print b; exit}')"
[ "$EN0BI" = "Yes" ] && ok "en0 is built-in (IOBuiltin = Yes)" || warn "en0 IOBuiltin = ${EN0BI:-unknown} - boot the v8.3 EFI (Wi-Fi marked built-in)"
[ "$(date +%Y)" -ge 2025 ] && ok "System date $(date '+%Y-%m-%d') looks right" || warn "System date is wrong - Apple ID sign-in fails until it is fixed"
info "Sign in: System Settings > 'Sign in with your Apple Account' (top of the sidebar)."

echo "  --- EFI guard-rails ---"
CFG=""
for c in /Volumes/*/EFI/OC/config.plist; do [ -f "$c" ] && CFG="$c" && break; done
if [ -z "$CFG" ]; then
    info "No EFI partition mounted - skipped. To include: sudo diskutil mount <EFI id> and re-run --audit."
else
    PB=/usr/libexec/PlistBuddy
    info "Checking $CFG"
    BA="$($PB -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$CFG" 2>/dev/null)"
    [ "$($PB -c 'Print :Misc:Security:SecureBootModel' "$CFG" 2>/dev/null)" = "Disabled" ] && ok "SecureBootModel = Disabled" || warn "SecureBootModel is not Disabled"
    [ "$($PB -c 'Print :Misc:Security:DmgLoading' "$CFG" 2>/dev/null)" = "Any" ] && ok "DmgLoading = Any" || warn "DmgLoading is not Any"
    case "$BA" in *-wexoff*) ok "boot-args has -wexoff" ;; *) warn "boot-args missing -wexoff" ;; esac
    case "$BA" in *itlwm_cc=*) ok "boot-args has itlwm_cc" ;; *) warn "boot-args missing itlwm_cc" ;; esac
    i=0
    while BP="$($PB -c "Print :Kernel:Add:$i:BundlePath" "$CFG" 2>/dev/null)"; do
        if [ "$BP" = "WhateverXe.kext" ]; then
            [ "$($PB -c "Print :Kernel:Add:$i:Enabled" "$CFG")" = "false" ] && ok "WhateverXe.kext disabled in config" || warn "WhateverXe.kext ENABLED in config"
        fi
        i=$((i+1))
    done
    [ "$($PB -c 'Print :Misc:Debug:AppleDebug' "$CFG" 2>/dev/null)" = "false" ] && ok "AppleDebug off (fast boot)" || warn "AppleDebug on: boot.efi file logging adds ~2 min to every boot"
    CFGDIR="$(dirname "$CFG")"
    [ -f "$CFGDIR/ACPI/SSDT-KBL.aml" ] && ok "SSDT-KBL.aml present ($(wc -c < "$CFGDIR/ACPI/SSDT-KBL.aml" | tr -d ' ') bytes; v5.2 = 996)"
fi

if [ -d "$RESULTS" ] && [ -w "$RESULTS" ]; then
    /bin/cp "$USER_HOME/Library/Logs/ZenBookHelper.log" "$RESULTS/helper-log-$TS.txt" 2>/dev/null
    { echo "== I2C HID devices"; ioreg -r -k Transport -w0 -d1 2>/dev/null | grep -E '"Product" =|"Transport" =|"VendorID" =|"ProductID" =|"PrimaryUsage'
      echo "== network"; networksetup -listnetworkserviceorder 2>/dev/null; networksetup -listallhardwareports 2>/dev/null
      echo "== IOBuiltin"; ioreg -r -k IOBuiltin -w0 -d1 2>/dev/null | grep -E '"BSD Name"|"IOBuiltin"'
      echo "== kexts"; kmutil showloaded 2>/dev/null | grep -viE 'com\.apple\.' | awk '{print $6, $7}'
    } > "$RESULTS/hw-snapshot-$TS.txt" 2>&1
fi

if [ "$MODE" = "apply" ] && [ -f "$SCRIPT_DIR/sync-efi-to-ssd.sh" ]; then
    echo ""
    printf "  >>> Make it PERMANENT: copy this EFI to the internal SSD so the laptop boots without the USB? [y/N] "
    read SSDOK < /dev/tty
    case "$SSDOK" in
        y|Y) /bin/bash "$SCRIPT_DIR/sync-efi-to-ssd.sh" || warn "SSD copy did not finish - the USB still boots everything" ;;
        *)   info "Skipped. Later: sudo sh \"$SCRIPT_DIR/sync-efi-to-ssd.sh\"" ;;
    esac
fi

echo ""
echo "=========================================================="
if [ "$NEED_REBOOT" = 1 ]; then
    echo "  >>> RESTART NOW (Apple menu > Restart) to finish the Wi-Fi / Apple ID fix."
    echo "      After the restart: sh \"$SCRIPT_DIR/fix-hardware.sh\" --audit"
fi
if [ ${#WARN_LIST[@]} -eq 0 ]; then
    echo "  DONE - no warnings."
else
    echo "  DONE with ${#WARN_LIST[@]} warning(s):"
    for w in "${WARN_LIST[@]}"; do echo "   - $w"; done
fi
echo "=========================================================="
echo "Quick tests:"
echo "  1. Wi-Fi  : menu bar icon without '!'; the audit above says why if it is there."
echo "  2. Fn+F4 / Fn+F5 -> the screen really gets darker / brighter, one step per press."
echo "  3. Fn+F7 x4  -> backlight 1, 2, 3, off (cycle)."
echo "  4. Trackpad: tap = left click, double-tap = double click, two-finger tap = left click,"
echo "     PRESS the bottom-right corner = right click (Control+click also works)."
echo "  5. NumberPad: hold the top-right touchpad icon 1 s. Calculator: slide from the top-left corner."
echo "  6. Apple ID: after the restart, System Settings > Sign in."
echo "  7. Not working? Just bring the USB back - this run is saved in UX325EA-RESCUE/TEST-RESULTS."
echo "=========================================================="
exit 0
