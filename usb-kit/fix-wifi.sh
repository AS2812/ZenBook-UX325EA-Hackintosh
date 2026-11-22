#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - Wi-Fi after the lid, permanent fix        v1.3
#
#   sudo sh "/Volumes/Install macOS Sonoma/fix-wifi.sh"
#
# Why Wi-Fi died ~2 minutes after opening the lid (test 2026-11-21 17:46-17:50):
#   on battery macOS turned the display off after 2 min and put the laptop to sleep right
#   after it ("Idle Sleep" every ~2 min while in use). Every sleep switches the Wi-Fi card off;
#   AirportItlwm needs 5-9 s to come back and sometimes does not.
# This script (everything is stored on the SSD - permanent, the USB is not needed afterwards):
#   1. Battery: display off after 5 min, sleep after 30 min. Charger: display off after 10 min,
#      never sleeps by itself. Closing the lid still sleeps at once. No wake-for-network.
#   2. Installs/updates ZenBookHelper (Wi-Fi watchdog + link-health check, auto-reconnect).
#   3. Lid check: close the lid 1 minute, open it - the check starts by itself (it sees the
#      wake) and tests Wi-Fi every 10 s for 3 minutes.
# v1.1: saves the Wi-Fi/sleep history FIRST (the failure that already happened), helper 8.22
#       (Wi-Fi off before sleep / on after wake), automatic lid check (v1.0 waited for keys).
# v1.2: helper 8.23 (8.22 switched Wi-Fi back on 1.7 s after "off before sleep"); records what
#       macOS's Wi-Fi / location / Bluetooth services did around a drop (scans, disassociations).
# v1.3: runs from a copy on the SSD and logs to /Users/Shared/UX325EA-Logs (copied to the USB) -
#       v1.2's lid check left no trace when the run stopped during the sleep; helper 8.24 logs
#       "after wake +60/120/180 s: Wi-Fi working / NOT working" after EVERY lid open by itself.
# Log: UX325EA-RESCUE/TEST-RESULTS/wifi-fix-<time>.txt on the USB.
# ==============================================================================
# "sh script" = bash in POSIX mode -> restart in real bash first
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
DRY="${ZB_DRY:-0}"                      # ZB_DRY=1: test on another Mac, writes nothing
CHECK_SECONDS="${ZB_CHECK_SECONDS:-180}"
if [ "$DRY" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[*] Administrator rights are needed for the power settings - asking for your password..."
    exec sudo /bin/bash "$0" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# v1.3: keep running even if the USB disappears during the lid sleep - run from a copy on the SSD
if [ -z "${ZB_FROM_COPY:-}" ] && { [ "$DRY" != 1 ] || [ -n "${ZB_TEST_REEXEC:-}" ]; }; then
    T=/private/tmp/zb-fix-wifi; mkdir -p "$T" && /bin/cp "$0" "$T/fix-wifi.sh" \
        && ZB_FROM_COPY=1 ZB_SRC_DIR="$SCRIPT_DIR" exec /bin/bash "$T/fix-wifi.sh" "$@"
fi
SCRIPT_DIR="${ZB_SRC_DIR:-$SCRIPT_DIR}"      # the USB (helper app, TEST-RESULTS)
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="/Users/Shared/UX325EA-Logs"; [ "$DRY" = 1 ] && LOGDIR="${TMPDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null; LOG="$LOGDIR/wifi-fix-$TS.txt"
USBLOG="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"
savelog() { sleep 0.5; [ "$DRY" != 1 ] && [ -d "$USBLOG" ] && /bin/cp "$LOG" "$USBLOG/" 2>/dev/null; return 0; }
trap savelog EXIT
exec > >(tee -a "$LOG") 2>&1
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"; UID_U="$(id -u "$U")"
UH="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; [ -n "$UH" ] || UH="$(eval echo "~$U")"
HI="$UH/Applications/ZenBookHelper.app"; HU="$SCRIPT_DIR/ZenBookHelper.app"; HB="${ZB_HB:-$HI/Contents/MacOS/ZenBookHelper}"
AGENTS="com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi"
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
run()  { if [ "$DRY" = 1 ]; then echo "  (dry) $*"; else "$@"; fi; }
as_u() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$U" -H "$@"; else "$@"; fi; }
FAILS=0
echo "=== ZenBook UX325EA - Wi-Fi after the lid v1.3 ($TS) user $U $( [ "$DRY" = 1 ] && echo '(DRY RUN)')"
HLOG="$UH/Library/Logs/ZenBookHelper.log"
# ---------------------------------------------------------------------------
# 0. What already happened (saved before anything is changed)
# ---------------------------------------------------------------------------
echo ""; echo "--- Wi-Fi history (helper log):"; grep -E '\[wifi\]' "$HLOG" 2>/dev/null | tail -150
echo "--- sleep/wake history:"; pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake|Failure) ' | tail -30 | cut -c1-220
echo "--- Wi-Fi driver messages (last 3 h):"
log show --last 3h --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "itlwm" OR eventMessage CONTAINS "80211")' 2>/dev/null | grep -v "Boot args" | tail -80 | cut -c1-220
echo "--- Wi-Fi now:"; networksetup -getairportpower en0 2>&1; ifconfig en0 2>&1 | grep -E "status|inet |ether" | sed -E 's/ether [0-9a-f:]+/ether <mac>/'
ioreg -r -c AirportItlwm -w0 -d1 2>/dev/null | head -2 | cut -c1-120

# ---------------------------------------------------------------------------
# 1. Power settings (stored in /Library/Preferences on the SSD)
# ---------------------------------------------------------------------------
echo ""; echo "--- power settings before:"; pmset -g custom 2>/dev/null | grep -E "Power:|^ (sleep|displaysleep|womp|powernap|tcpkeepalive|standby|hibernatemode|proximitywake|autopoweroff) "
run pmset -b displaysleep 5 sleep 30
run pmset -c displaysleep 10 sleep 0
run pmset -a womp 0 powernap 0 tcpkeepalive 0 standby 0 autopoweroff 0 proximitywake 0 hibernatemode 0 2>&1 | grep -v "^Warning"
# read back: "Battery Power:" block, then "AC Power:" block
val() { pmset -g custom 2>/dev/null | awk -v blk="$1" -v key="$2" '/Power:/{cur=$0} index(cur, blk) && $1 == key {print $2; exit}'; }
B_SLEEP="$(val Battery sleep)"; B_DISP="$(val Battery displaysleep)"; C_SLEEP="$(val AC sleep)"; C_DISP="$(val AC displaysleep)"
echo "--- power settings now: battery display ${B_DISP:-?} min / sleep ${B_SLEEP:-?} min, charger display ${C_DISP:-?} min / sleep ${C_SLEEP:-?} (0 = never)"
if [ "$DRY" = 1 ]; then echo "  (dry) not checked"
elif [ "$B_SLEEP" = 30 ] && [ "$B_DISP" = 5 ] && [ "$C_SLEEP" = 0 ] && [ "$C_DISP" = 10 ]; then
    ok "No more sleeping after 2 minutes: battery sleeps after 30 min idle, charger never (lid close still sleeps)"
else bad "Power settings did not stick - see above"; fi

# ---------------------------------------------------------------------------
# 2. ZenBookHelper (Wi-Fi watchdog + link health) - newest from this USB
# ---------------------------------------------------------------------------
ver() { [ -f "$1/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
VI="$(ver "$HI")"; VU="$(ver "$HU")"
if [ -d "$HU" ] && [ "$VI" != "$VU" ]; then
    for L in $AGENTS; do run launchctl bootout "gui/$UID_U/$L" 2>/dev/null; done
    run rm -rf "$HI"; run /bin/cp -R "$HU" "$HI"; run xattr -dr com.apple.quarantine "$HI"
    [ "$(id -u)" -eq 0 ] && run chown -R "$U":staff "$HI"
    for L in $AGENTS; do [ -f "$UH/Library/LaunchAgents/$L.plist" ] && run launchctl bootstrap "gui/$UID_U" "$UH/Library/LaunchAgents/$L.plist" 2>/dev/null; done
    ok "ZenBookHelper updated ${VI:-none} -> $VU (permissions kept)"; [ "$DRY" = 1 ] || sleep 5
else ok "ZenBookHelper ${VI:-?} is installed"; fi
if [ "$DRY" = 1 ] || launchctl print "gui/$UID_U/com.zenbook.wifi" 2>/dev/null | grep -q "state = running"; then
    ok "Wi-Fi watchdog is running (it starts by itself at every login)"
else
    run launchctl kickstart -k "gui/$UID_U/com.zenbook.wifi" 2>/dev/null; sleep 3
    launchctl print "gui/$UID_U/com.zenbook.wifi" 2>/dev/null | grep -q "state = running" && ok "Wi-Fi watchdog started" \
        || bad "Wi-Fi watchdog is not running - run fix-hardware.sh once (it installs the background services)"
fi

# ---------------------------------------------------------------------------
# 3. Wi-Fi now, and the lid check
# ---------------------------------------------------------------------------
probe() {   # one line: verdict signal
    local o v s; o="$(as_u "$HB" wifiprobe 2>/dev/null)"
    v="$(printf '%s\n' "$o" | sed -n 's/^verdict \([0-9]\).*/\1/p')"; s="$(printf '%s\n' "$o" | grep -o 'signal -\{0,1\}[0-9]* dBm' | head -1)"
    echo "${v:-x} ${s:-no signal}"
}
P="$(probe)"; echo ""; echo "--- Wi-Fi now: verdict ${P%% *} (0 = working), ${P#* }"
[ "${P%% *}" = 0 ] && ok "Wi-Fi works right now" || bad "Wi-Fi does not pass traffic right now (${P#* }) - is the router reachable?"
echo ""
echo "  LID CHECK. Press Enter to start it (or type s and Enter to skip): "
A=""; [ "$DRY" = 1 ] && A="${ZB_LIDCHECK:-s}" || read -r A < /dev/tty
if [ "$(printf '%s' "$A" | cut -c1 | tr S s)" != s ]; then
    wk() { sysctl -n kern.waketime 2>/dev/null | sed -E 's/^[{] sec = ([0-9]+).*/\1/'; }
    W0="$(wk)"
    savelog
    echo ""
    echo "  >>> Close the lid NOW. Wait 1 minute. Open it and log in."
    echo "  >>> Then do NOTHING - this check starts by itself and runs $((CHECK_SECONDS / 60)) minutes."
    T=0
    while [ "$(wk)" = "$W0" ] && [ "$DRY" != 1 ] && [ $T -lt 900 ]; do sleep 2; T=$((T + 2)); done
    if [ "$DRY" != 1 ] && [ "$(wk)" = "$W0" ]; then echo "  [FAIL] no lid sleep seen in 15 minutes - lid check stopped"; FAILS=$((FAILS + 1)); else
    WAKE="$(wk)"; echo "  Woke at $(date -r "${WAKE:-$(date +%s)}" '+%H:%M:%S') - waiting 5 s, then checking Wi-Fi every 10 s..."; sleep 5
    T0=$(date +%s); N=0; OKN=0; FIRST_BAD=""; SLEPT0="$(wk)"
    while [ $(( $(date +%s) - T0 )) -lt "$CHECK_SECONDS" ]; do
        P="$(probe)"; N=$((N + 1)); E=$(( $(date +%s) - T0 ))
        if [ "${P%% *}" = 0 ]; then OKN=$((OKN + 1)); M="ok"; else M="NO TRAFFIC"; [ -z "$FIRST_BAD" ] && FIRST_BAD="$E"; fi
        printf "    %3d s  %-10s %s\n" "$E" "$M" "${P#* }"
        sleep 10
    done
    [ "$(wk)" = "$SLEPT0" ] && ok "The laptop stayed awake during the check" || bad "The laptop went to sleep during the check"
    if [ "$OKN" = "$N" ]; then ok "Wi-Fi worked the whole time ($OKN/$N checks) - FIXED"
    elif [ "$OKN" -ge $((N - 3)) ]; then ok "Wi-Fi worked $OKN/$N checks (short gap at ${FIRST_BAD} s, the watchdog reconnects by itself)"
    else bad "Wi-Fi failed $((N - OKN)) of $N checks (first at ${FIRST_BAD} s) - bring the USB back, this log shows why"; fi
    echo "--- helper Wi-Fi log around the lid:"
    grep -E '\[wifi\]|sleep: Wi-Fi' "$HLOG" 2>/dev/null | tail -25
    echo "--- sleep/wake around the lid:"; pmset -g log 2>/dev/null | grep -E ' (Sleep|Wake|DarkWake) ' | tail -4 | cut -c1-220
    echo "--- what macOS did around the lid (Wi-Fi / location / Bluetooth services):"
    log show --last 6m --style compact --predicate '(process == "airportd" OR process == "locationd" OR process == "wifip2pd" OR process == "bluetoothd" OR process == "sharingd") AND (eventMessage CONTAINS[c] "scan" OR eventMessage CONTAINS[c] "disassoc" OR eventMessage CONTAINS[c] "deauth" OR eventMessage CONTAINS[c] "link down" OR eventMessage CONTAINS[c] "linkdown" OR eventMessage CONTAINS[c] "roam" OR eventMessage CONTAINS[c] "awdl" OR eventMessage CONTAINS[c] "reason")' 2>/dev/null \
        | grep -v -E "Sandbox|com.apple.xpc" | tail -120 | cut -c1-230
    echo "--- Bluetooth now:"; system_profiler SPBluetoothDataType 2>/dev/null | grep -E "State|Connected:" | head -4
    echo "--- Wi-Fi driver messages since the lid:"
    log show --last 10m --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "itlwm" OR eventMessage CONTAINS "80211")' 2>/dev/null | tail -40 | cut -c1-220
    fi
else echo "  Lid check skipped."; fi
echo ""
if [ "$FAILS" = 0 ]; then echo "=== DONE - saved on the SSD permanently. You can unplug the USB."
else echo "=== $FAILS problem(s) - bring the USB back (log below)."; fi
echo "    Log: $LOG (also copied to the USB: UX325EA-RESCUE/TEST-RESULTS)"
