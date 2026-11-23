#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - choose the Wi-Fi driver                   v1.2
#
#   sudo sh "/Volumes/Install macOS Sonoma/wifi-driver.sh" itlwm     STABLE: itlwm + HeliPort
#   sudo sh "/Volumes/Install macOS Sonoma/wifi-driver.sh" airport   back to AirportItlwm
#   sudo sh "/Volumes/Install macOS Sonoma/wifi-driver.sh" status    show which one is on
#   sudo sh "/Volumes/Install macOS Sonoma/wifi-driver.sh" stock     ROLLBACK: the official itlwm 2.3.0
#        from this USB's EFI replaces the patched itlwm 2.3.1 (Wi-Fi package 2.5) on the SSD
#
# Why (logs 2026-11-21): AirportItlwm 2.3.0 drops the router 10-95 s after joining (with or
# without the lid), sometimes refuses all scans afterwards ("Scan request failed (22)") and
# once did not start for a whole session. itlwm is the same Intel driver without Apple's Wi-Fi
# stack (no background scans/roaming from macOS); HeliPort (menu bar) joins and re-joins.
#
# Changes, on the SSD EFI (what the laptop starts from) AND on this USB's EFI:
#   - Kernel > Add: itlwm.kext on / AirportItlwm.kext off (or the reverse) in every config*.plist
#   - itlwm.kext: removes the author's sample networks (one was an OPEN network called "Redmi")
#   - itlwm mode: installs /Applications/HeliPort.app and starts it at every login
#   - v1.1: itlwm hides the macOS Wi-Fi icon (with itlwm macOS sees no Wi-Fi card, the icon only
#     shows "!"); airport shows it again
# Backups: /Users/Shared/UX325EA-EFI-Backups/wifi-driver-<time>/  Log: TEST-RESULTS/wifi-driver-<time>.txt
# Test only: ZB_TEST_ESPS="dir1|dir2" ZB_TEST_APPS=dir ZB_TEST_HOME=dir (no root, no disks)
# ==============================================================================
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
MODE="${1:-itlwm}"
case "$MODE" in itlwm|airport|status|stock) ;; *) echo "Use: itlwm | airport | status | stock"; exit 2 ;; esac
TEST=0; [ -n "${ZB_TEST_ESPS:-}" ] && TEST=1
if [ "$TEST" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[*] Administrator rights are needed (EFI partitions) - asking for your password..."
    exec sudo /bin/bash "$0" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"; [ "$TEST" = 1 ] && LOGDIR="${TMPDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null; LOG="$LOGDIR/wifi-driver-$TS.txt"
exec > >(tee -a "$LOG") 2>&1
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"
UH="${ZB_TEST_HOME:-$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')}"
APPS="${ZB_TEST_APPS:-/Applications}"
BK="/Users/Shared/UX325EA-EFI-Backups/wifi-driver-$TS"; [ "$TEST" = 1 ] && BK="${TMPDIR:-/tmp}/wifi-driver-$TS"
ok()   { echo "  [OK]   $*"; }
fail() { echo ""; echo "[ERROR] $*"; echo "        Nothing more was changed. Log: $LOG"; exit 1; }
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
PB=/usr/libexec/PlistBuddy
echo "=== ZenBook UX325EA - Wi-Fi driver v1.2 ($TS) mode: $MODE  user: $U"

# ---------------------------------------------------------------------------
# 1. The two EFI partitions: internal SSD (starts the laptop) and this USB
# ---------------------------------------------------------------------------
MOUNTED=""; M=""
mount_esp() {   # $1 = partition -> sets M (mount point); remembers what it mounted (no subshell)
    M="$(pinfo "$1" MountPoint)"
    if [ -z "$M" ]; then diskutil mount "$1" >/dev/null 2>&1 && MOUNTED="$MOUNTED $1"; M="$(pinfo "$1" MountPoint)"; fi
}
ESPS=""
if [ "$TEST" = 1 ]; then ESPS="$ZB_TEST_ESPS"; else
    STORE=""; for V in / /System/Volumes/Data; do [ -n "$STORE" ] && break
        STORE="$(diskutil info -plist "$V" 2>/dev/null | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - - 2>/dev/null)"; done
    SSD="$(pinfo "$STORE" ParentWholeDisk)"
    for P in $(diskutil list "$SSD" 2>/dev/null | awk '{print $NF}' | grep -E "^${SSD}s[0-9]+$"); do
        [ "$(pinfo "$P" Content)" = EFI ] && { mount_esp "$P"; [ -f "$M/EFI/OC/config.plist" ] && ESPS="$M"; break; }
    done
    [ -n "$ESPS" ] || fail "OpenCore EFI on the internal SSD ($SSD) not found."
    ok "SSD EFI: $ESPS"
    UDISK="$(pinfo "$(df "$SCRIPT_DIR" | awk 'NR==2{print $1}')" ParentWholeDisk)"
    for P in $(diskutil list "$UDISK" 2>/dev/null | awk '{print $NF}' | grep -E "^${UDISK}s[0-9]+$"); do
        C="$(pinfo "$P" Content)"; case "$C" in EFI|"Microsoft Basic Data"|DOS_FAT_32) ;; *) continue ;; esac
        mount_esp "$P"; [ -f "$M/EFI/OC/OpenCore.efi" ] && { ESPS="$ESPS|$M"; ok "USB EFI: $M"; break; }
    done
fi
cleanup() { for P in $MOUNTED; do diskutil unmount "$P" >/dev/null 2>&1; done; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2. Kext switch in every config*.plist (status: only report)
# ---------------------------------------------------------------------------
idx() {   # $1 config, $2 bundle -> index in Kernel:Add
    local i=0 b
    while b="$($PB -c "Print :Kernel:Add:$i:BundlePath" "$1" 2>/dev/null)"; do
        [ "$b" = "$2" ] && { echo "$i"; return 0; }; i=$((i + 1))
    done; return 1
}
state() { $PB -c "Print :Kernel:Add:$(idx "$1" "$2"):Enabled" "$1" 2>/dev/null; }
IFS='|' read -r -a ESPLIST <<< "$ESPS"     # mount points may contain spaces ("/Volumes/NO NAME")
N=0
for E in "${ESPLIST[@]}"; do
    [ -n "$E" ] || continue
    for CFG in "$E"/EFI/OC/config*.plist; do
        IA="$(idx "$CFG" AirportItlwm.kext)" || fail "$CFG has no AirportItlwm.kext entry"
        IT="$(idx "$CFG" itlwm.kext)" || fail "$CFG has no itlwm.kext entry"
        if [ "$MODE" = status ]; then echo "  $CFG: AirportItlwm $(state "$CFG" AirportItlwm.kext), itlwm $(state "$CFG" itlwm.kext)"; continue; fi
        D="$BK/$(echo "$E" | tr '/ ' '__')"; mkdir -p "$D" && /bin/cp -X "$CFG" "$D/" || fail "backup of $CFG failed"
        if [ "$MODE" = itlwm ] || [ "$MODE" = stock ]; then A=false; T=true; else A=true; T=false; fi
        $PB -c "Set :Kernel:Add:$IA:Enabled $A" -c "Set :Kernel:Add:$IT:Enabled $T" "$CFG" || fail "could not edit $CFG"
        plutil -lint "$CFG" >/dev/null || { /bin/cp -X "$D/$(basename "$CFG")" "$CFG"; fail "$CFG broke - restored the backup"; }
        [ "$(state "$CFG" AirportItlwm.kext)" = "$A" ] && [ "$(state "$CFG" itlwm.kext)" = "$T" ] || fail "$CFG did not change"
        N=$((N + 1))
    done
    KP="$E/EFI/OC/Kexts/itlwm.kext/Contents/Info.plist"
    if [ "$MODE" = itlwm ] && [ -f "$KP" ] && $PB -c "Print :IOKitPersonalities:itlwm:WiFiConfig:WiFi_1" "$KP" >/dev/null 2>&1; then
        /bin/cp -X "$KP" "$D/itlwm-Info.plist"
        $PB -c "Delete :IOKitPersonalities:itlwm:WiFiConfig" -c "Add :IOKitPersonalities:itlwm:WiFiConfig dict" "$KP" && plutil -lint "$KP" >/dev/null \
            && ok "itlwm sample networks removed ($E)" || { /bin/cp -X "$D/itlwm-Info.plist" "$KP"; fail "itlwm Info.plist edit failed - restored"; }
    fi
    find "$E/EFI" -name '._*' -delete 2>/dev/null
done
[ "$MODE" = status ] || ok "$N config files: $( [ "$MODE" = airport ] && echo 'AirportItlwm ON, itlwm off' || echo 'itlwm ON, AirportItlwm off') (backup: $BK)"
for E in "${ESPLIST[@]}"; do   # which itlwm build sits in each EFI
    [ -n "$E" ] && [ -f "$E/EFI/OC/Kexts/itlwm.kext/Contents/Info.plist" ] && \
        echo "  itlwm in $E: $($PB -c 'Print :CFBundleShortVersionString' "$E/EFI/OC/Kexts/itlwm.kext/Contents/Info.plist" 2>/dev/null)"
done
# v1.2 rollback: copy the official itlwm 2.3.0 from this USB's EFI onto the SSD's EFI
if [ "$MODE" = stock ]; then
    SSDE="${ESPLIST[0]:-}"; USBE="${ESPLIST[1]:-}"
    SRC="$USBE/EFI/OC/Kexts/itlwm.kext"; DST="$SSDE/EFI/OC/Kexts/itlwm.kext"
    [ -n "$USBE" ] && [ -f "$SRC/Contents/MacOS/itlwm" ] || fail "the USB's EFI with the official itlwm was not found"
    [ "$($PB -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null)" = 2.3.0 ] || fail "the USB's itlwm is not the official 2.3.0"
    mkdir -p "$BK/ssd-itlwm" && /bin/cp -R "$DST" "$BK/ssd-itlwm/" || fail "backup of the SSD's itlwm failed"
    rm -rf "$DST" && /bin/cp -R "$SRC" "$DST" && cmp -s "$SRC/Contents/MacOS/itlwm" "$DST/Contents/MacOS/itlwm" \
        || { rm -rf "$DST"; /bin/cp -R "$BK/ssd-itlwm/itlwm.kext" "$DST"; fail "copy failed - the previous itlwm was put back"; }
    find "$SSDE/EFI" -name '._*' -delete 2>/dev/null
    ok "SSD now has the official itlwm 2.3.0 (patched one backed up in $BK/ssd-itlwm)"
fi

# ---------------------------------------------------------------------------
# 3. HeliPort (itlwm mode): app + start at login
# ---------------------------------------------------------------------------
AGENT="$UH/Library/LaunchAgents/com.zenbook.heliport.plist"
if [ "$MODE" = itlwm ]; then
    [ -d "$SCRIPT_DIR/HeliPort.app" ] || fail "HeliPort.app is missing next to this script"
    rm -rf "$APPS/HeliPort.app" && /bin/cp -R "$SCRIPT_DIR/HeliPort.app" "$APPS/HeliPort.app" || fail "could not copy HeliPort to $APPS"
    xattr -dr com.apple.quarantine "$APPS/HeliPort.app" 2>/dev/null
    find "$APPS/HeliPort.app" -name '._*' -delete 2>/dev/null
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.zenbook.heliport</string>
    <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$APPS/HeliPort.app</string></array>
    <key>RunAtLoad</key><true/>
</dict></plist>
EOF
    [ "$TEST" = 0 ] && chown "$U":staff "$AGENT"
    plutil -lint "$AGENT" >/dev/null && ok "HeliPort 1.5.0 installed in $APPS, starts at every login" || fail "login item for HeliPort is broken"
elif [ "$MODE" = airport ] && [ -f "$AGENT" ]; then
    rm -f "$AGENT" && ok "HeliPort no longer starts at login (the app stays in $APPS)"
fi
# v1.1: macOS Wi-Fi icon - hidden with itlwm (no Wi-Fi card for macOS), back with AirportItlwm
asu() { if [ "$TEST" = 0 ]; then launchctl asuser "$(id -u "$U")" sudo -u "$U" -H "$@"; else echo "  (test) $*"; fi; }
if [ "$MODE" = itlwm ]; then
    asu defaults -currentHost write com.apple.controlcenter WiFi -int 8
    asu defaults write com.apple.controlcenter "NSStatusItem Visible WiFi" -bool false
    asu killall ControlCenter 2>/dev/null; ok "macOS Wi-Fi icon hidden (with itlwm it can only show \"!\") - HeliPort is the Wi-Fi menu"
elif [ "$MODE" = airport ]; then
    asu defaults -currentHost delete com.apple.controlcenter WiFi 2>/dev/null
    asu defaults delete com.apple.controlcenter "NSStatusItem Visible WiFi" 2>/dev/null
    asu killall ControlCenter 2>/dev/null; ok "macOS Wi-Fi icon back in the menu bar"
fi
# ---------------------------------------------------------------------------
# 4. ZenBookHelper from this USB (8.23 knows itlwm; the same steps as fix-hardware/fix-wifi)
# ---------------------------------------------------------------------------
HI="$UH/Applications/ZenBookHelper.app"; HU="$SCRIPT_DIR/ZenBookHelper.app"
ver() { [ -f "$1/Contents/Info.plist" ] && $PB -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
VI="$(ver "$HI")"; VU="$(ver "$HU")"
if [ "$MODE" != status ] && [ "$TEST" = 0 ] && [ -n "$VU" ] && [ "$VI" != "$VU" ]; then
    UIDU="$(id -u "$U")"
    for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do launchctl bootout "gui/$UIDU/$L" 2>/dev/null; done
    rm -rf "$HI"; /bin/cp -R "$HU" "$HI"; xattr -dr com.apple.quarantine "$HI" 2>/dev/null; chown -R "$U":staff "$HI"
    for L in com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi; do
        [ -f "$UH/Library/LaunchAgents/$L.plist" ] && launchctl bootstrap "gui/$UIDU" "$UH/Library/LaunchAgents/$L.plist" 2>/dev/null
    done
    ok "ZenBookHelper updated ${VI:-none} -> $VU (permissions kept)"
elif [ "$MODE" != status ]; then ok "ZenBookHelper ${VI:-?} (USB has ${VU:-?})"; fi
sync
echo ""
case "$MODE" in
  itlwm)   echo "=== DONE. Restart the laptop. After you log in, click the HeliPort icon in the menu bar"
           echo "    (top right), choose your Wi-Fi network and type its password ONCE. HeliPort remembers it"
           echo "    and joins by itself after every start and every lid sleep."
           echo "    Back to the old driver: sudo sh \"$SCRIPT_DIR/wifi-driver.sh\" airport" ;;
  airport) echo "=== DONE. Restart the laptop - the normal macOS Wi-Fi menu is back." ;;
  stock)   echo "=== DONE. Apple menu > Shut Down, wait 30 s, power on - the official itlwm 2.3.0 runs again." ;;
  status)  echo "=== status only, nothing changed" ;;
esac
echo "    Log: $LOG"
