#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - Wi-Fi: fix everything, permanent           v2.0
#
#   sudo sh "/Volumes/Install macOS Sonoma/fix-wifi.sh"
#
# For the itlwm + HeliPort setup. Everything is stored on the SSD - the USB is not needed after.
#   1. Installs / updates "Install ZenBook Wi-Fi.pkg" from this USB (itlwm, HeliPort, recovery
#      agent, ZenBook Wi-Fi Repair) and starts its background jobs.
#   2. HeliPort "!" = joined to the router, but macOS has no internet path on the Intel card
#      (no network service / no IP address / no DNS). The card gets its own enabled DHCP service
#      "Intel Wi-Fi", first in the service order; DHCP is renewed; DNS falls back to 1.1.1.1 /
#      8.8.8.8 only if the router's DNS does not answer. Then it checks exactly like HeliPort.
#   3. macOS Wi-Fi icon "!": with itlwm macOS has no Wi-Fi card at all, so that icon can only
#      ever show a warning. It is hidden from the menu bar - HeliPort is the Wi-Fi menu.
#      (wifi-driver.sh airport brings it back.)
#   4. Power: no idle sleep 2 minutes after opening the lid (battery 5/30 min, charger never).
#   5. ZenBookHelper from this USB, optional lid check.
# Network settings backup: /Users/Shared/UX325EA-Logs/network-backup-<time>/
# Log: UX325EA-RESCUE/TEST-RESULTS/wifi-fix-<time>.txt on the USB (+ /Users/Shared/UX325EA-Logs)
# v1.x (AirportItlwm era) is in UX325EA-RESCUE/BACKUPS.
# ==============================================================================
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
VERSION=2.0
PKGID=local.zenbook.macos.wifi
WC="/Library/Application Support/ZenBook Wi-Fi/WakeCheck"
WAGENT=/Library/LaunchAgents/local.zenbook.wifi.wakecheck.plist
WDAEMON=/Library/LaunchDaemons/local.zenbook.wifi.ipconfig.plist
SVCNAME="Intel Wi-Fi"

# --- pure helpers (unit-tested on another Mac with ZB_SOURCE_ONLY=1) -----------------------
svc_rows() {   # stdin: networksetup -listnetworkserviceorder -> name<TAB>port<TAB>device<TAB>enabled
    awk '
    /^\([0-9]+\) / { name = $0; sub(/^\([0-9]+\) /, "", name); en = 1; next }
    /^\(\*\) /     { name = $0; sub(/^\(\*\) /, "", name); en = 0; next }
    /^\(Hardware Port: / {
        l = $0; sub(/^\(Hardware Port: /, "", l); sub(/\)$/, "", l)
        n = index(l, ", Device: ")
        if (n == 0) { port = l; dev = "" } else { port = substr(l, 1, n - 1); dev = substr(l, n + 10) }
        if (name != "") print name "\t" port "\t" dev "\t" en
        name = "" }'
}
port_of() {    # $1 device; stdin: networksetup -listallhardwareports -> its hardware port name
    awk -v d="$1" '/^Hardware Port: /{ p = substr($0, 16) } /^Device: /{ if ($2 == d) { print p; exit } }'
}
pkg_file_version() {   # $1 .pkg -> version of the component inside
    local t; t="$(mktemp -d /private/tmp/zbpkg.XXXXXX)" && rm -rf "$t" || return 1
    pkgutil --expand "$1" "$t" >/dev/null 2>&1 &&
        cat "$t"/*.pkg/PackageInfo 2>/dev/null | grep -o '<pkg-info[^>]*>' | grep -o ' version="[0-9.]*"' | head -1 | cut -d'"' -f2
    rm -rf "$t"
}
mask() { sed -E 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g'; }
reachable_like_heliport() {   # same rule as HeliPort's icon: reachable and no connection required
    local r; r="$(scutil -r captive.apple.com 2>/dev/null)"
    case "$r" in Reachable*) case "$r" in *"Connection Required"*) return 1 ;; esac; return 0 ;; esac
    return 1
}
[ -n "${ZB_SOURCE_ONLY:-}" ] && return 0 2>/dev/null

DRY="${ZB_DRY:-0}"                      # ZB_DRY=1: dry run on another Mac, writes nothing
CHECK_SECONDS="${ZB_CHECK_SECONDS:-180}"
if [ "$DRY" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[*] Administrator rights are needed (network and power settings) - asking for your password..."
    exec sudo /bin/bash "$0" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# keep running even if the USB disappears during the lid sleep - run from a copy on the SSD
if [ -z "${ZB_FROM_COPY:-}" ] && [ "$DRY" != 1 ]; then
    T=/private/tmp/zb-fix-wifi; mkdir -p "$T" && /bin/cp "$0" "$T/fix-wifi.sh" \
        && ZB_FROM_COPY=1 ZB_SRC_DIR="$SCRIPT_DIR" exec /bin/bash "$T/fix-wifi.sh" "$@"
fi
SCRIPT_DIR="${ZB_SRC_DIR:-$SCRIPT_DIR}"      # the USB (packages, helper app, TEST-RESULTS)
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="/Users/Shared/UX325EA-Logs"; [ "$DRY" = 1 ] && LOGDIR="${TMPDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null; LOG="$LOGDIR/wifi-fix-$TS.txt"
USBLOG="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"
savelog() { sleep 0.5; [ "$DRY" != 1 ] && [ -d "$USBLOG" ] && /bin/cp "$LOG" "$USBLOG/" 2>/dev/null; return 0; }
trap savelog EXIT
exec > >(tee -a "$LOG") 2>&1
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"; UID_U="$(id -u "$U")"
UH="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; [ -n "$UH" ] || UH="$(eval echo "~$U")"
HI="$UH/Applications/ZenBookHelper.app"; HU="$SCRIPT_DIR/ZenBookHelper.app"; HB="$HI/Contents/MacOS/ZenBookHelper"
AGENTS="com.zenbook.brightness com.zenbook.numberpad com.zenbook.wifi"
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [..]   $*"; }
run()  { if [ "$DRY" = 1 ]; then echo "  (dry) $*"; else "$@"; fi; }
as_u() { if [ "$(id -u)" -eq 0 ]; then launchctl asuser "$UID_U" sudo -u "$U" -H "$@"; else "$@"; fi; }
FAILS=0; RESTART=0
echo "=== ZenBook UX325EA - Wi-Fi fix v$VERSION ($TS) user $U $( [ "$DRY" = 1 ] && echo '(DRY RUN)')"
if [ "$(uname -m)" != x86_64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
    if [ "$DRY" != 1 ]; then echo "This is not the ZenBook - nothing was changed."; exit 1; fi
    echo "  (dry run on another Mac: only reading)"
fi
status_now() { if [ -x "$WC" ]; then "$WC" --status 2>/dev/null; else echo "(recovery agent not installed)"; fi; }
itl_if() { ioreg -r -c itlwm -l -w0 2>/dev/null | sed -n 's/.*"BSD Name" = "\(en[0-9]*\)".*/\1/p' | head -1; }
airport_loaded() { ioreg -r -c AirportItlwm -d1 2>/dev/null | grep -q AirportItlwm; }

# ---------------------------------------------------------------------------
# 0. How it looks now (saved before anything is changed)
# ---------------------------------------------------------------------------
echo ""; echo "--- before:"
sw_vers | tr '\n' ' '; echo
echo "boot-args: $(nvram boot-args 2>/dev/null | cut -f2-)"
echo "Wi-Fi package: $(pkgutil --pkg-info "$PKGID" 2>/dev/null | awk '/^version:/{print $2}')  agent: $(status_now)"
echo "driver: itlwm interface '$(itl_if)'$(airport_loaded && echo ', AirportItlwm LOADED')"
echo "HeliPort: $(pgrep -x HeliPort >/dev/null && echo running || echo 'not running')"
networksetup -listallhardwareports 2>/dev/null | grep -E "Hardware Port|Device" | paste - - | sed 's/^/  /'
networksetup -listnetworkserviceorder 2>/dev/null | grep -v asterisk | sed '/^$/d; s/^/  /'
scutil --nwi 2>/dev/null | sed -n '1,12p' | mask
echo "like HeliPort: captive.apple.com $(reachable_like_heliport && echo reachable || echo 'NOT reachable -> HeliPort shows !')"
[ -f "$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt" ] && { echo "--- agent log (last 25):"; tail -25 "$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt"; }

# ---------------------------------------------------------------------------
# 1. Wi-Fi package from this USB (itlwm + HeliPort + recovery agent + Wi-Fi Repair)
# ---------------------------------------------------------------------------
echo ""; echo "--- 1. Wi-Fi package"
PKG="$SCRIPT_DIR/Install ZenBook Wi-Fi.pkg"
VI="$(pkgutil --pkg-info "$PKGID" 2>/dev/null | awk '/^version:/{print $2}')"
VU=""; [ -f "$PKG" ] && VU="$(pkg_file_version "$PKG")"
UPDATED=0
if [ -z "$VU" ]; then
    [ -n "$VI" ] && ok "Wi-Fi package $VI installed (none on this USB to compare)" \
        || note "no Wi-Fi package on this USB - skipped (HeliPort from wifi-driver.sh itlwm still works)"
elif [ "$VI" = "$VU" ] && [ -x "$WC" ]; then
    ok "Wi-Fi package $VI is already installed"
else
    echo "  installing Wi-Fi package ${VU} (installed: ${VI:-none}) - takes about a minute..."
    if run installer -pkg "$PKG" -target / ; then
        UPDATED=1; ok "Wi-Fi package ${VI:-none} -> $VU installed on the SSD (also updates the SSD's EFI, with a backup)"
    else
        bad "the Wi-Fi package did not install - details:"; grep -E "macOS EFI|Wi-Fi setup|ZenBook" /var/log/install.log 2>/dev/null | tail -8
    fi
fi
if [ -x "$WC" ] || [ "$DRY" = 1 ]; then
    # start (or restart after an update) the login agent and the DHCP helper job
    if launchctl print "gui/$UID_U/local.zenbook.wifi.wakecheck" >/dev/null 2>&1; then
        [ "$UPDATED" = 1 ] && run launchctl kickstart -k "gui/$UID_U/local.zenbook.wifi.wakecheck"
    else run launchctl bootstrap "gui/$UID_U" "$WAGENT" 2>/dev/null; fi
    if launchctl print system/local.zenbook.wifi.ipconfig >/dev/null 2>&1; then
        [ "$UPDATED" = 1 ] && run launchctl kickstart -k system/local.zenbook.wifi.ipconfig
    else run launchctl bootstrap system "$WDAEMON" 2>/dev/null; fi
    sleep 2
    launchctl print "gui/$UID_U/local.zenbook.wifi.wakecheck" 2>/dev/null | grep -q "state = running" \
        && ok "Wi-Fi recovery agent running (starts by itself at every login and checks after every wake)" \
        || { [ "$DRY" = 1 ] && note "(dry) agent not checked" || bad "Wi-Fi recovery agent is not running"; }
fi
ITF="$(itl_if)"; [ "$DRY" = 1 ] && [ -n "${ZB_TEST_ITF:-}" ] && ITF="$ZB_TEST_ITF"
if [ -z "$ITF" ]; then
    if airport_loaded; then note "this start used AirportItlwm - the package switched the SSD to itlwm"
    else note "the itlwm driver is not running in this start"; fi
    RESTART=1
fi
case " $(nvram boot-args 2>/dev/null | cut -f2-) " in *" -novht "*|*" -noht40 "*)
    note "speed-limit switches -novht/-noht40 are active in this start (the package removed them from the EFI)"; RESTART=1 ;; esac

# ---------------------------------------------------------------------------
# 2. HeliPort "!" - a working network service for the Intel card
# ---------------------------------------------------------------------------
echo ""; echo "--- 2. network service for the Intel card"
if [ -z "$ITF" ]; then note "skipped until the restart (no itlwm interface yet)"
else
    BK="$LOGDIR/network-backup-$TS"
    if [ "$DRY" != 1 ]; then mkdir -p "$BK" && /bin/cp -p /Library/Preferences/SystemConfiguration/preferences.plist \
        /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist "$BK/" 2>/dev/null && ok "network settings backed up: $BK"; fi
    PORTS="$(networksetup -listallhardwareports 2>/dev/null)"; PORT="$(printf '%s\n' "$PORTS" | port_of "$ITF")"
    if [ -z "$PORT" ]; then run networksetup -detectnewhardware; sleep 2
        PORTS="$(networksetup -listallhardwareports 2>/dev/null)"; PORT="$(printf '%s\n' "$PORTS" | port_of "$ITF")"; fi
    if [ -z "$PORT" ]; then bad "macOS does not list the Intel card ($ITF) as network hardware"
    else
        ok "Intel card: $ITF = hardware port \"$PORT\""
        ROWS="$(networksetup -listnetworkserviceorder 2>/dev/null | svc_rows)"
        S="$(printf '%s\n' "$ROWS" | awk -F'\t' -v p="$PORT" -v d="$ITF" '$2 == p && $3 == d { print $1; exit }')"
        if [ -z "$S" ]; then
            run networksetup -createnetworkservice "$SVCNAME" "$PORT" && S="$SVCNAME" && ok "created network service \"$SVCNAME\" for the Intel card (it had none)"
        elif [ "$S" != "$SVCNAME" ] && ! printf '%s\n' "$ROWS" | cut -f1 | grep -qxF "$SVCNAME"; then
            run networksetup -renamenetworkservice "$S" "$SVCNAME" && ok "service \"$S\" renamed to \"$SVCNAME\"" && S="$SVCNAME"
        fi
        [ "$DRY" = 1 ] && [ -z "$S" ] && S="$SVCNAME"
        if printf '%s\n' "$ROWS" | awk -F'\t' -v s="$S" '$1 == s && $4 == 0 { f = 1 } END { exit !f }'; then
            run networksetup -setnetworkserviceenabled "$S" on && ok "\"$S\" switched on (it was disabled)"
        fi
        if ! networksetup -getinfo "$S" 2>/dev/null | grep -q "^DHCP Configuration"; then
            run networksetup -setdhcp "$S" && ok "\"$S\" set to DHCP (automatic address from the router)"
        fi
        ORDER=("$S"); while IFS= read -r n; do n="${n#\*}"; [ -n "$n" ] && [ "$n" != "$S" ] && ORDER+=("$n"); done \
            < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
        run networksetup -ordernetworkservices "${ORDER[@]}" && ok "\"$S\" is first in the service order"
        STALE="$(printf '%s\n' "$ROWS" | awk -F'\t' -v d="$ITF" -v p="$PORT" '$3 == d && $2 != p { print $1 " (" $2 ")" }' | paste -sd, -)"
        [ -n "$STALE" ] && note "old service(s) on the same card left as they are: $STALE (inactive with itlwm; used again if you go back to AirportItlwm)"

        # HeliPort running and joined?
        pgrep -x HeliPort >/dev/null || { run as_u open -g -a /Applications/HeliPort.app; sleep 3; }
        joined() {   # recovery agent if installed, else the interface's link state (itlwm: active = associated)
            if [ -x "$WC" ]; then case "$(status_now)" in "IP configured"*|"Joined"*) return 0 ;; esac; return 1; fi
            ifconfig "$ITF" 2>/dev/null | grep -q "status: active"; }
        if ! joined && [ "$DRY" != 1 ]; then
            echo "  >>> Not connected yet: click the HeliPort icon (top right), choose your Wi-Fi, type the"
            echo "      password once and tick Auto Join. Waiting up to 3 minutes..."
            T=0; while ! joined && [ $T -lt 180 ]; do sleep 3; T=$((T + 3)); done
        fi
        echo "  agent: $(status_now)"
        if joined && [ -z "$(ipconfig getifaddr "$ITF" 2>/dev/null)" ]; then
            note "joined but no IP address - renewing DHCP"
            run networksetup -setdhcp "$S"; T=0
            while [ -z "$(ipconfig getifaddr "$ITF" 2>/dev/null)" ] && [ $T -lt 30 ] && [ "$DRY" != 1 ]; do sleep 2; T=$((T + 2)); done
            [ -z "$(ipconfig getifaddr "$ITF" 2>/dev/null)" ] && { run ipconfig set "$ITF" DHCP; T=0
                while [ -z "$(ipconfig getifaddr "$ITF" 2>/dev/null)" ] && [ $T -lt 20 ] && [ "$DRY" != 1 ]; do sleep 2; T=$((T + 2)); done; }
        fi
        IP="$(ipconfig getifaddr "$ITF" 2>/dev/null)"; R="$(ipconfig getoption "$ITF" router 2>/dev/null)"
        if [ -n "$IP" ]; then ok "IP address $IP, router ${R:-?}"; else bad "no IP address on $ITF (is HeliPort connected?)"; fi
        if [ -n "$IP" ]; then
            [ -n "$R" ] && { ping -c 2 -t 4 -b "$ITF" "$R" >/dev/null 2>&1 && ok "router answers" || note "router does not answer ping (some routers never do)"; }
            NET=0; curl -s -m 6 --interface "$ITF" -o /dev/null https://1.1.1.1/ && NET=1
            BYNAME=0; curl -s -m 6 --interface "$ITF" http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success && BYNAME=1
            if [ "$BYNAME" = 1 ]; then ok "internet and DNS work over the Intel card"
            elif [ "$NET" = 1 ]; then
                note "internet works but names do not resolve - using 1.1.1.1 and 8.8.8.8 for \"$S\""
                run networksetup -setdnsservers "$S" 1.1.1.1 8.8.8.8; run dscacheutil -flushcache; run killall -HUP mDNSResponder; sleep 2
                curl -s -m 6 --interface "$ITF" http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success \
                    && ok "DNS fixed (undo: networksetup -setdnsservers \"$S\" empty)" || bad "names still do not resolve"
            else bad "no internet beyond the router (router / provider problem, or a captive portal page)"; fi
        fi
        if reachable_like_heliport; then ok "HeliPort's own check passes - its icon shows signal bars, no \"!\""
        else bad "HeliPort's check (captive.apple.com reachable) still fails - its icon keeps the \"!\""; fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. macOS Wi-Fi icon (always "!" with itlwm - macOS sees no Wi-Fi card) -> hidden
# ---------------------------------------------------------------------------
echo ""; echo "--- 3. menu bar"
run as_u defaults -currentHost write com.apple.controlcenter WiFi -int 8
run as_u defaults write com.apple.controlcenter "NSStatusItem Visible WiFi" -bool false
run as_u killall ControlCenter 2>/dev/null
ok "macOS Wi-Fi icon hidden (it cannot control the Intel card with itlwm) - use the HeliPort icon"

# ---------------------------------------------------------------------------
# 4. Power settings (no idle sleep 2 minutes after opening the lid)
# ---------------------------------------------------------------------------
echo ""; echo "--- 4. power"
run pmset -b displaysleep 5 sleep 30
run pmset -c displaysleep 10 sleep 0
run pmset -a womp 0 powernap 0 tcpkeepalive 0 standby 0 autopoweroff 0 proximitywake 0 hibernatemode 0 2>&1 | grep -v "^Warning"
val() { pmset -g custom 2>/dev/null | awk -v blk="$1" -v key="$2" '/Power:/{cur=$0} index(cur, blk) && $1 == key {print $2; exit}'; }
if [ "$DRY" = 1 ]; then note "(dry) not checked"
elif [ "$(val Battery sleep)" = 30 ] && [ "$(val Battery displaysleep)" = 5 ] && [ "$(val AC sleep)" = 0 ] && [ "$(val AC displaysleep)" = 10 ]; then
    ok "battery: display off 5 min / sleep 30 min; charger: never sleeps by itself (closing the lid still sleeps)"
else bad "power settings did not stick"; fi

# ---------------------------------------------------------------------------
# 5. ZenBookHelper (only watches Wi-Fi with itlwm; the recovery agent does the repairs)
# ---------------------------------------------------------------------------
echo ""; echo "--- 5. helper"
ver() { [ -f "$1/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
HVI="$(ver "$HI")"; HVU="$(ver "$HU")"
if [ -d "$HU" ] && [ -n "$HVU" ] && [ "$HVI" != "$HVU" ]; then
    for L in $AGENTS; do run launchctl bootout "gui/$UID_U/$L" 2>/dev/null; done
    run rm -rf "$HI"; run /bin/cp -R "$HU" "$HI"; run xattr -dr com.apple.quarantine "$HI"; run chown -R "$U":staff "$HI"
    for L in $AGENTS; do [ -f "$UH/Library/LaunchAgents/$L.plist" ] && run launchctl bootstrap "gui/$UID_U" "$UH/Library/LaunchAgents/$L.plist" 2>/dev/null; done
    ok "ZenBookHelper ${HVI:-none} -> $HVU"
else ok "ZenBookHelper ${HVI:-?} is installed"; fi

# ---------------------------------------------------------------------------
# 6. Result, optional lid check
# ---------------------------------------------------------------------------
echo ""
if [ "$RESTART" = 1 ]; then
    echo "=== RESTART NEEDED: eject the USB, restart (internal SSD), sign in, then run this script once"
    echo "    more - it finishes the network part with the itlwm driver running."
elif [ -n "$ITF" ] && [ "$DRY" != 1 ]; then
    echo "  LID CHECK (optional). Press Enter to start it (or type s and Enter to skip): "
    A=""; read -r A < /dev/tty
    if [ "$(printf '%s' "$A" | cut -c1 | tr S s)" != s ]; then
        wk() { sysctl -n kern.waketime 2>/dev/null | sed -E 's/^[{] sec = ([0-9]+).*/\1/'; }
        W0="$(wk)"; savelog
        echo "  >>> Close the lid NOW. Wait 1 minute. Open it and log in. Then do NOTHING for $((CHECK_SECONDS / 60)) minutes."
        T=0; while [ "$(wk)" = "$W0" ] && [ $T -lt 900 ]; do sleep 2; T=$((T + 2)); done
        if [ "$(wk)" = "$W0" ]; then bad "no lid sleep seen in 15 minutes - lid check stopped"; else
            sleep 5; T0=$(date +%s); N=0; OKN=0; FIRST=""
            while [ $(( $(date +%s) - T0 )) -lt "$CHECK_SECONDS" ]; do
                E=$(( $(date +%s) - T0 )); N=$((N + 1))
                if reachable_like_heliport && curl -s -m 5 --interface "$ITF" http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success; then
                    OKN=$((OKN + 1)); M=ok; else M="NO INTERNET"; [ -z "$FIRST" ] && FIRST=$E; fi
                printf "    %3d s  %-12s %s\n" "$E" "$M" "$(status_now)"
                sleep 10
            done
            if [ "$OKN" = "$N" ]; then ok "Wi-Fi worked the whole time after the lid ($OKN/$N checks)"
            elif [ "$OKN" -ge $((N - 4)) ]; then ok "Wi-Fi worked $OKN/$N checks (short gap at ${FIRST} s while it rejoined)"
            else bad "Wi-Fi failed $((N - OKN)) of $N checks after the lid (first at ${FIRST} s)"; fi
            echo "--- agent log after the lid:"; tail -20 "$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt" 2>/dev/null
        fi
    else echo "  Lid check skipped."; fi
fi
echo ""
if [ "$FAILS" = 0 ] && [ "$RESTART" = 0 ]; then echo "=== DONE - all saved on the SSD permanently. You can unplug the USB."
elif [ "$FAILS" != 0 ]; then echo "=== $FAILS problem(s) - bring the USB back (the log shows why)."; fi
echo "    Speed: Applications -> ZenBook Wi-Fi Repair -> Test Speed"
echo "    Log: $LOG (also on the USB: UX325EA-RESCUE/TEST-RESULTS)"
