#!/bin/bash
# ZenBook UX325EA - GPU guard (installed by fix-hardware.sh --gpu-test, runs as root at boot)
#
# gpu-mode = test : this boot runs the GPU (WhateverXe) profile ONCE. Right at the start of
#                   the boot the stable OpenCore config is put back, so if the screen stays
#                   black or freezes, holding power and restarting gives the normal Mac again.
# gpu-mode = keep / off : nothing to do.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
D="/Library/Application Support/ZenBook"
LOG="$D/gpu-guard.log"
MODE="$(cat "$D/gpu-mode" 2>/dev/null)"; MODE="${MODE:-off}"
log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }

restore_stable() {          # every OpenCore partition currently in GPU state -> stable
    local found=0 d mp mine
    for d in $(diskutil list 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
        [ "$(pinfo "$d" FilesystemType)" = "msdos" ] || continue
        mp="$(pinfo "$d" MountPoint)"; mine=0
        if [ -z "$mp" ]; then
            diskutil mount -mountOptions nobrowse "$d" >/dev/null 2>&1 || continue
            mp="$(pinfo "$d" MountPoint)"; mine=1
        fi
        if [ -f "$mp/EFI/OC/config-stable.plist" ] && [ -f "$mp/EFI/OC/config-gpu.plist" ]; then
            found=1
            if cmp -s "$mp/EFI/OC/config.plist" "$mp/EFI/OC/config-gpu.plist"; then
                /bin/cp "$mp/EFI/OC/config-stable.plist" "$mp/EFI/OC/config.plist" && sync \
                    && log "$d: stable OpenCore config restored - the next boot is the normal setup"
            else
                log "$d: already on the stable config"
            fi
        fi
        [ "$mine" = 1 ] && diskutil unmount "$d" >/dev/null 2>&1
    done
    [ "$found" = 1 ]
}

uptime_s() { local up; up=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/'); echo $(( $(date +%s) - up )); }
wait_uptime() { local i; for i in $(seq 1 120); do [ "$(uptime_s)" -ge "$1" ] && return 0; sleep 2; done; }
bounded() {                 # bounded SECONDS command... : never lets one step block the guard
    local t=$1 p w=0; shift
    "$@" & p=$!
    while kill -0 "$p" 2>/dev/null && [ "$w" -lt "$t" ]; do sleep 1; w=$((w+1)); done
    if kill -0 "$p" 2>/dev/null; then kill -9 "$p" 2>/dev/null; echo "[timed out after ${t}s: $1]"; fi
    wait "$p" 2>/dev/null; return 0
}
to_usb() {
    local v
    for v in "/Volumes/Install macOS Sonoma" /Volumes/*; do
        [ -d "$v/UX325EA-RESCUE/TEST-RESULTS" ] && /bin/cp "$1" "$v/UX325EA-RESCUE/TEST-RESULTS/" 2>/dev/null \
            && { sync; log "copied $(basename "$1") to $v"; return 0; }
    done
    log "USB not found for $(basename "$1")"; return 1
}
wex_props() { ioreg -p IOService -l -w0 -d 1 2>/dev/null | grep -E '"(TGL|WEX|WhateverXe)[A-Za-z0-9]*"'; }
kernel_log() {
    local since; since="$(/bin/date -r "$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')" '+%Y-%m-%d %H:%M:%S')"
    /usr/bin/log show --start "$since" --style compact \
        --predicate 'process == "kernel" OR process == "WindowServer" OR process == "watchdogd"' 2>/dev/null \
        | grep -iE 'IGFB|IGPU|WEX|WhateverXe|TGL|IntelAccel|AUX|DPCD|backlight|panel|PPS|EDP|LightUp|link|train|AGDC|modeset|display|watchdog|hang|timeout|WindowServer' | tail -1500
}

early_capture() {           # survives a WindowServer hang: done before the ~170 s watchdog panic
    local ts out sp
    wait_uptime 75; ts=$(date +%Y%m%d-%H%M%S)
    out="$D/gpu-early-$ts.txt"
    { echo "== GPU EARLY capture $(date) uptime $(uptime_s) s"; echo "== boot-args"; nvram boot-args 2>/dev/null
      echo "== WindowServer"; pgrep -lx WindowServer
      echo "== registry root (WhateverXe TGL*/WEX* properties)"; bounded 25 wex_props; } > "$out" 2>&1
    to_usb "$out"
    wait_uptime 95; sp="$D/gpu-spin-$ts.txt"
    { echo "== WindowServer kernel+user stacks $(date) uptime $(uptime_s) s"
      bounded 40 spindump WindowServer 3 20 -onlyTarget -noProcessingWhileSampling -timelimit 35 -o "$sp.raw"
      cat "$sp.raw" 2>/dev/null; rm -f "$sp.raw"; } > "$sp" 2>&1
    to_usb "$sp"
    { echo; echo "== kernel log since boot $(date) uptime $(uptime_s) s"; bounded 35 kernel_log; } >> "$out" 2>&1
    to_usb "$out"
}

capture_diag() {            # full picture once the system has settled (~150 s)
    local ts out
    wait_uptime 150; ts=$(date +%Y%m%d-%H%M%S); out="$D/gpu-diag-$ts.txt"
    {
    echo "== GPU diagnostic capture $(date) uptime $(uptime_s) s"
    echo "== boot-args"; nvram boot-args 2>/dev/null
    echo "== registry root (WhateverXe TGL*/WEX* properties)"; bounded 25 wex_props
    echo "== GFX0 PCI device"; bounded 15 sh -c "ioreg -p IOService -l -w0 -r -n GFX0@2 -d 1 2>/dev/null | grep -vE 'IOPowerManagement|\"pcidebug\"' | head -150"
    echo "== framebuffers"; bounded 15 sh -c "ioreg -p IOService -l -w0 -r -c IOFramebuffer -d 1 2>/dev/null | grep -E '\+-o|online|IOFBCurrentPixel|IOFBConfig|AAPL,boot-display|backlight|Backlight|brightness|IOFBMemorySize|IOFBTransform|connector' | head -120"
    echo "== displays"; bounded 15 sh -c "ioreg -p IOService -l -w0 -r -c IODisplayConnect 2>/dev/null | head -60"
    echo "== accelerator"; bounded 15 sh -c "ioreg -p IOService -l -w0 -r -c IntelAccelerator -d 1 2>/dev/null | head -60"
    echo "== system_profiler"; bounded 20 system_profiler SPDisplaysDataType
    echo "== kernel log since boot (graphics)"; bounded 35 kernel_log
    CU="$(stat -f %Su /dev/console 2>/dev/null)"; CH="$(dscl . -read "/Users/$CU" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    echo "== ZenBookHelper status ($CU)"; bounded 10 sudo -u "$CU" defaults read com.zenbook.helper.settings brightnessStatus
    echo "== ZenBookHelper log"; tail -80 "$CH/Library/Logs/ZenBookHelper.log" 2>/dev/null
    } > "$out" 2>&1
    log "diagnostics captured: $out"
    to_usb "$out"
}

if [ "$MODE" = "test" ]; then
    log "GPU test boot started"
    for i in $(seq 1 45); do restore_stable && break; sleep 2; done
    echo off > "$D/gpu-mode"
    early_capture
    capture_diag
    # Visible screen = working GPU: let the user keep the session. Black screen = nobody can
    # click, so the dialog times out and the laptop restarts into the normal setup by itself.
    CU="$(stat -f %Su /dev/console 2>/dev/null)"; CUID="$(id -u "$CU" 2>/dev/null)"; ANS=""
    if [ -n "$CUID" ] && [ "$CU" != "root" ]; then
        AF="/tmp/zenbook-gpu-dialog.$$"; : > "$AF"
        launchctl asuser "$CUID" sudo -u "$CU" /usr/bin/osascript -e 'display dialog "GPU TEST (Iris Xe acceleration)\n\nYou can see this message, so the screen WORKS.\nClick Keep to stay in this session, then run:\nsh \"/Volumes/Install macOS Sonoma/fix-hardware.sh\" --gpu-report\n\nNo click within 90 s = automatic restart into the normal setup." buttons {"Restart now", "Keep"} default button "Keep" with title "ZenBook GPU test" giving up after 90' > "$AF" 2>&1 &
        DP=$!; W=0
        # Hard watchdog: a frozen WindowServer must never block the automatic restart.
        while kill -0 "$DP" 2>/dev/null && [ "$W" -lt 120 ]; do sleep 2; W=$((W+2)); done
        kill -0 "$DP" 2>/dev/null && { kill "$DP" 2>/dev/null; log "dialog hung ${W}s - killed"; }
        ANS="$(cat "$AF" 2>/dev/null)"; rm -f "$AF"
    fi
    log "dialog answer: ${ANS:-none}"
    case "$ANS" in
        *"button returned:Keep"*"gave up:false"*|*"gave up:false"*"button returned:Keep"*|*"button returned:Keep") log "user confirmed a VISIBLE screen - staying in the GPU session" ;;
        *) log "no confirmation - restarting into the normal setup"; sync; sleep 3; shutdown -r now ;;
    esac
fi
exit 0
