#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - Wi-Fi recorder: logs until you press Enter      v1.1
#
#   sudo sh "/Volumes/Install macOS Sonoma/wifi-log.sh"
#
# Use the laptop normally: browse, close and open the lid as often as you like. It does NOT keep
# the laptop awake and keeps recording after every wake. Press Enter to stop - it prints a summary.
#   every 5 s : time, time since the last wake, internet, router reply, DNS, IP, HeliPort,
#               screen, Bluetooth, battery/charger | Wi-Fi state, band, channel, signal, networks seen
#   v1.1: Bluetooth on/off column (this card shares 2.4 GHz and the antenna with Bluetooth)
#   outages   : start, how long after the wake, a snapshot at that moment, and how long it lasted
#   beside it : the recovery agent's log (live) and driver / HeliPort / DHCP / sleep messages
# Saved on the SSD (/Users/Shared/UX325EA-Logs) and copied to the USB every minute and at the end:
#   UX325EA-RESCUE/TEST-RESULTS/wifi-log-<time>.txt (+ -system.txt)
# Test on another Mac: ZB_DRY=1 ZB_TEST_ITF=en0 ZB_LOG_SECONDS=30 sh wifi-log.sh
# ==============================================================================
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
VERSION=1.1
DRY="${ZB_DRY:-0}"
INTERVAL="${ZB_INTERVAL:-5}"
if [ "$DRY" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[*] Administrator rights are needed (system log) - asking for your password..."
    exec sudo /bin/bash "$0" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# run from a copy on the SSD: the USB may be unplugged or go to sleep with the laptop
if [ -z "${ZB_FROM_COPY:-}" ] && [ "$DRY" != 1 ]; then
    T=/private/tmp/zb-wifi-log; mkdir -p "$T" && /bin/cp "$0" "$T/wifi-log.sh" \
        && ZB_FROM_COPY=1 ZB_SRC_DIR="$SCRIPT_DIR" exec /bin/bash "$T/wifi-log.sh" "$@"
fi
SCRIPT_DIR="${ZB_SRC_DIR:-$SCRIPT_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="/Users/Shared/UX325EA-Logs"; [ "$DRY" = 1 ] && LOGDIR="${TMPDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null
LOG="$LOGDIR/wifi-log-$TS.txt"; SYS="$LOGDIR/wifi-log-$TS-system.txt"
USBLOG="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"
UH="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; [ -n "$UH" ] || UH="$(eval echo "~$U")"
AGENTLOG="$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt"
WC="/Library/Application Support/ZenBook Wi-Fi/WakeCheck"
ITF="$(ioreg -r -c itlwm -l -w0 2>/dev/null | sed -n 's/.*"BSD Name" = "\(en[0-9]*\)".*/\1/p' | head -1)"
[ "$DRY" = 1 ] && [ -n "${ZB_TEST_ITF:-}" ] && ITF="$ZB_TEST_ITF"
exec 3>&1
exec > >(tee -a "$LOG") 2>&1

mask()   { sed -E 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g'; }
mins()   { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
ksec()   { sysctl -n "$1" 2>/dev/null | sed -E 's/^[{] sec = ([0-9]+).*/\1/'; }
screen() { local v; v="$(ioreg -n IODisplayWrangler -r -d 1 2>/dev/null | sed -n 's/.*"CurrentPowerState" = \([0-9]*\).*/\1/p' | head -1)"
           case "$v" in 4) echo on ;; [0-3]) echo off ;; *) echo "?" ;; esac; }
bt()     { case "$(defaults read /Library/Preferences/com.apple.Bluetooth ControllerPowerState 2>/dev/null)" in
               1) echo on ;; 0) echo off ;; *) echo "?" ;; esac; }
power()  { pmset -g batt 2>/dev/null | awk 'NR == 1 { src = ($0 ~ /AC Power/) ? "charger" : "battery" }
           NR == 2 { if (match($0, /[0-9]+%/)) pct = substr($0, RSTART, RLENGTH) } END { print src " " pct }'; }
wifi()   { local o=""; [ -x "$WC" ] && o="$("$WC" --link 2>/dev/null)"; [ -z "$o" ] && [ -x "$WC" ] && o="$("$WC" --status 2>/dev/null)"
           echo "${o:-(recovery agent not installed)}"; }
copy_usb() {   # the USB is nearly full: only when there is room, the system log capped at 3 MB
    [ "$DRY" = 1 ] && return 0; [ -d "$USBLOG" ] || return 0
    local free; free="$(df -k "$USBLOG" 2>/dev/null | awk 'NR == 2 { print $4 }')"; [ "${free:-0}" -gt 6000 ] || return 0
    /bin/cp "$LOG" "$USBLOG/" 2>/dev/null; tail -c 3000000 "$SYS" 2>/dev/null | mask > "$USBLOG/$(basename "$SYS")"; sync
}
PIDS=""
stop_all() { for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=""; return 0; }
trap 'stop_all; copy_usb' EXIT

echo "=== ZenBook Wi-Fi recorder v$VERSION - started $(date '+%Y-%m-%d %H:%M:%S') - user $U $( [ "$DRY" = 1 ] && echo '(DRY RUN)')"
sw_vers | tr '\n' ' '; echo
echo "Wi-Fi package $(pkgutil --pkg-info local.zenbook.macos.wifi 2>/dev/null | awk '/^version:/{print $2}')  HeliPort $([ -f /Applications/HeliPort.app/Contents/Info.plist ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/HeliPort.app/Contents/Info.plist 2>/dev/null || echo none)  itlwm interface ${ITF:-NONE}"
echo "boot-args: $(nvram boot-args 2>/dev/null | cut -f2-)"
pmset -g custom 2>/dev/null | grep -E "Power:|^ (sleep|displaysleep|lowpowermode) " | tr -s ' ' | paste -sd' ' -
echo "HeliPort Auto Join order:"
{ if [ "$(id -u)" -eq 0 ]; then launchctl asuser "$(id -u "$U")" sudo -u "$U" security dump-keychain; else security dump-keychain; fi; } 2>/dev/null | awk '
    function flush() { if (svc == "com.OpenIntelWireless.HeliPort" && acct != "") print (ord == "" ? 0 : ord) "\t" (aj == "" ? "true" : aj) "\t" acct
                       svc = ""; acct = ""; ord = ""; aj = "" }
    /^keychain: / { flush() }
    /"svce"<blob>="/ { v = $0; sub(/.*"svce"<blob>="/, "", v); sub(/"$/, "", v); svc = v }
    /"acct"<blob>="/ { v = $0; sub(/.*"acct"<blob>="/, "", v); sub(/"$/, "", v); acct = v }
    /"icmt"<blob>=/  { if (match($0, /"order": *-?[0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*: */, "", v); ord = v }
                       if (match($0, /"autoJoin": *(true|false)/)) { v = substr($0, RSTART, RLENGTH); sub(/.*: */, "", v); aj = v } }
    END { flush() }' | sort -n | awk -F'\t' '{ printf "    %d. %-28s Auto Join %s\n", NR, $3, ($2 == "true" ? "ON" : "off") }'
[ -n "$ITF" ] || echo "!!! the itlwm driver is not running in this start - recording anyway"
IF="${ITF:-en0}"

# beside the main log: driver / HeliPort / DHCP / sleep messages from the system log
log stream --style compact --predicate "(process == \"kernel\" AND (eventMessage CONTAINS[c] \"itlwm\" OR eventMessage CONTAINS[c] \"iwx\" OR eventMessage CONTAINS \"Wake reason\" OR eventMessage CONTAINS[c] \"$IF\")) OR process == \"HeliPort\" OR (process == \"configd\" AND (eventMessage CONTAINS[c] \"dhcp\" OR eventMessage CONTAINS[c] \"$IF\")) OR (process == \"powerd\" AND (eventMessage CONTAINS[c] \"sleep\" OR eventMessage CONTAINS[c] \"wake\"))" \
    > "$SYS" 2>/dev/null &
PIDS="$PIDS $!"; disown $! 2>/dev/null
# the recovery agent's own log: new lines are shown in the loop (its times are UTC)
AL=0; [ -f "$AGENTLOG" ] && AL="$(wc -l < "$AGENTLOG" | tr -d ' ')"
agent_new() {
    [ -f "$AGENTLOG" ] || return 0
    local n; n="$(wc -l < "$AGENTLOG" | tr -d ' ')"
    [ "$n" -lt "$AL" ] && AL=0                       # the agent rotated its log
    [ "$n" -gt "$AL" ] && sed -n "$((AL + 1)),${n}p" "$AGENTLOG" | sed 's/^[0-9-]* \([0-9:]*\) [+0-9]*  */          [agent \1 UTC] /'
    AL="$n"
}

echo ""
echo ">>> RECORDING. Use the laptop normally. Close / open the lid as often as you like."
echo ">>> Press Enter to STOP (the summary and the log path are printed then)."
echo ""
echo "time      wake+   NET   router    DNS   IP               HeliPort  screen  BT   power        | Wi-Fi"
BOOT="$(ksec kern.boottime)"; LASTWAKE="$(ksec kern.waketime)"; [ "${LASTWAKE:-0}" -gt 0 ] 2>/dev/null || LASTWAKE="$BOOT"
START="$(date +%s)"; N=0; OKN=0; WAKES=0; DOWN_SINCE=""; DOWN_AT=0; OUTAGES=""; NOUT=0; LONGEST=0
while :; do
    NOW="$(date +%s)"
    W="$(ksec kern.waketime)"
    if [ -n "$W" ] && [ "$W" != 0 ] && [ "$W" != "$LASTWAKE" ]; then
        SL="$(ksec kern.sleeptime)"; WAKES=$((WAKES + 1)); LASTWAKE="$W"
        echo "========== WAKE at $(date -r "$W" '+%H:%M:%S') (slept at $(date -r "${SL:-$W}" '+%H:%M:%S'), for $(mins $(( W - ${SL:-$W} )))) =========="
    fi
    SINCE=$(( NOW - LASTWAKE )); [ "$SINCE" -lt 0 ] && SINCE=0
    IP="$(ipconfig getifaddr "$IF" 2>/dev/null)"; R="$(ipconfig getoption "$IF" router 2>/dev/null)"
    RT="-"
    if [ -n "$R" ]; then RT="$(ping -c 1 -t 1 -b "$IF" "$R" 2>/dev/null | sed -n 's/.*time=\([0-9]*\).*/\1ms/p')"; RT="${RT:-no-reply}"; fi
    NET=DOWN; [ -n "$IP" ] && curl -s -m 3 --interface "$IF" -o /dev/null https://1.1.1.1/ 2>/dev/null && NET=ok
    DNS="-"; if [ "$NET" = ok ]; then curl -s -m 3 --interface "$IF" http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success && DNS=ok || DNS=FAIL; fi
    HP=closed; pgrep -x HeliPort >/dev/null && HP=running
    printf '%s  %-6s  %-4s  %-8s  %-4s  %-15s  %-8s  %-6s  %-3s  %-12s | %s\n' "$(date '+%H:%M:%S')" "$(mins "$SINCE")" "$NET" "$RT" "$DNS" "${IP:--}" "$HP" "$(screen)" "$(bt)" "$(power)" "$(wifi)"
    agent_new
    N=$((N + 1)); [ "$NET" = ok ] && OKN=$((OKN + 1))
    if [ "$NET" != ok ] && [ -z "$DOWN_SINCE" ]; then
        DOWN_SINCE="$NOW"; DOWN_AT="$SINCE"
        echo "!!!!!!!!!! OUTAGE START $(date '+%H:%M:%S') - $(mins "$SINCE") after the last wake - screen $(screen), Bluetooth $(bt) - snapshot:"
        ifconfig "$IF" 2>/dev/null | grep -E "status|inet |media" | mask | sed 's/^/      /'
        scutil --nwi 2>/dev/null | grep -E "flags|address|reach" | head -6 | sed 's/^/      /'
        netstat -rn -f inet 2>/dev/null | awk '$1 == "default"' | head -3 | sed 's/^/      route: /'
        [ -f "$AGENTLOG" ] && tail -5 "$AGENTLOG" | sed 's/^/      agent: /'
    elif [ "$NET" = ok ] && [ -n "$DOWN_SINCE" ]; then
        D=$(( NOW - DOWN_SINCE )); NOUT=$((NOUT + 1)); [ "$D" -gt "$LONGEST" ] && LONGEST="$D"
        OUTAGES="$OUTAGES    $(date -r "$DOWN_SINCE" '+%H:%M:%S')  started $(mins "$DOWN_AT") after a wake, lasted $(mins "$D")
"
        echo "========== BACK ONLINE after $(mins "$D") =========="
        DOWN_SINCE=""
    fi
    [ $((N % 12)) = 0 ] && copy_usb
    if [ "$DRY" = 1 ]; then
        [ $(( $(date +%s) - START )) -ge "${ZB_LOG_SECONDS:-30}" ] && break; sleep "$INTERVAL"
    elif read -t "$INTERVAL" -r _ < /dev/tty; then break; fi
done
END="$(date +%s)"
if [ -n "$DOWN_SINCE" ]; then NOUT=$((NOUT + 1)); D=$(( END - DOWN_SINCE )); [ "$D" -gt "$LONGEST" ] && LONGEST="$D"
    OUTAGES="$OUTAGES    $(date -r "$DOWN_SINCE" '+%H:%M:%S')  started $(mins "$DOWN_AT") after a wake, STILL DOWN at the end ($(mins "$D"))
"; fi
stop_all
echo ""
echo "=== SUMMARY - recorded $(mins $(( END - START ))) (min:s), $N checks"
echo "    online: $OKN of $N checks ($(( N > 0 ? OKN * 100 / N : 0 ))%)   lid wakes: $WAKES   outages: $NOUT   longest: $(mins "$LONGEST")"
[ -n "$OUTAGES" ] && { echo "    outages:"; printf '%s' "$OUTAGES"; }
echo "    Wi-Fi now: $(wifi)"
echo "--- recovery agent log (last 30 lines):"; [ -f "$AGENTLOG" ] && tail -30 "$AGENTLOG"
echo ""
echo "Log: $LOG"
echo "     $SYS (driver / HeliPort / DHCP / sleep messages)"
copy_usb
[ "$DRY" != 1 ] && [ -d "$USBLOG" ] && echo "Copied to the USB: UX325EA-RESCUE/TEST-RESULTS - bring it back."
exec 1>&3
