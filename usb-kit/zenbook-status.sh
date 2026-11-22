#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - status report (READ ONLY, changes nothing)   v1.0
#
#   sudo sh "/Volumes/Install macOS Sonoma/zenbook-status.sh"
#
# Saves UX325EA-RESCUE/TEST-RESULTS/status-<time>.txt on this USB: which Wi-Fi driver the SSD
# starts, debug logging on/off, installed ZenBook packages, helper, power settings, a Wi-Fi
# check and any "ZenBook Performance Check" reports from the last 2 days.
# ==============================================================================
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
if [ "$(id -u)" -ne 0 ]; then echo "[*] Password needed once (to read the SSD's EFI partition)..."; exec sudo /bin/bash "$0" "$@"; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"; OUTD="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"; mkdir -p "$OUTD"; OUT="$OUTD/status-$TS.txt"
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"; UH="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
PB=/usr/libexec/PlistBuddy
{
echo "=== ZenBook status v1.0 ($TS) user $U - read only"
sw_vers | tr '\n' ' '; echo; echo "started from: $(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2- | grep -q 'USB' && echo 'USB stick' || echo 'internal SSD')"
echo "boot-args now: $(nvram boot-args 2>/dev/null | cut -f2-)"
echo ""; echo "--- SSD EFI (what the laptop starts from)"
if [ "$(uname -m)" = x86_64 ]; then
    STORE=""; for V in / /System/Volumes/Data; do [ -n "$STORE" ] && break
        STORE="$(diskutil info -plist "$V" 2>/dev/null | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - - 2>/dev/null)"; done
    SSD="$(pinfo "$STORE" ParentWholeDisk)"; ESP=""; MNT=""; MOUNTED=0
    for P in $(diskutil list "$SSD" 2>/dev/null | awk '{print $NF}' | grep -E "^${SSD}s[0-9]+$"); do [ "$(pinfo "$P" Content)" = EFI ] && { ESP="$P"; break; }; done
    if [ -n "$ESP" ]; then
        MNT="$(pinfo "$ESP" MountPoint)"; if [ -z "$MNT" ]; then diskutil mount readOnly "$ESP" >/dev/null 2>&1 && MOUNTED=1; MNT="$(pinfo "$ESP" MountPoint)"; fi
        for CFG in "$MNT"/EFI/OC/config.plist "$MNT"/EFI/OC/config-gpu.plist; do
            [ -f "$CFG" ] || continue
            st=""; i=0; while b="$($PB -c "Print :Kernel:Add:$i:BundlePath" "$CFG" 2>/dev/null)"; do
                case "$b" in AirportItlwm.kext|itlwm.kext|DebugEnhancer.kext) st="$st $b=$($PB -c "Print :Kernel:Add:$i:Enabled" "$CFG")";; esac; i=$((i + 1)); done
            ba="$($PB -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$CFG" 2>/dev/null)"
            echo "$(basename "$CFG"):$st  ShowPicker=$($PB -c 'Print :Misc:Boot:ShowPicker' "$CFG" 2>/dev/null)  -dbgenhdbg=$(echo "$ba" | grep -q -- -dbgenhdbg && echo present || echo removed)"
        done
        ls -l "$MNT/EFI/OC/Kexts" 2>/dev/null | grep -i -E "itlwm|airport" | awk '{print "  kext folder:", $NF}'
        [ "$MOUNTED" = 1 ] && diskutil unmount "$ESP" >/dev/null 2>&1
    else echo "no EFI partition found on $SSD"; fi
else echo "(not the ZenBook - skipped)"; fi
echo ""; echo "--- loaded Wi-Fi / debug drivers"; kextstat -l 2>/dev/null | grep -i -E "itlwm|DebugEnhancer" | awk '{print $6, $7}'
echo ""; echo "--- installed ZenBook packages"
for p in $(pkgutil --pkgs 2>/dev/null | grep -i zenbook); do echo "$p  installed $(date -r "$(pkgutil --pkg-info "$p" | awk '/install-time/{print $2}')" '+%Y-%m-%d %H:%M' 2>/dev/null)"; done
ls -d /Applications/HeliPort.app "/Applications/ZenBook Performance Check.app" 2>/dev/null | sed 's/^/  app: /'
echo ""; echo "--- helper"; /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UH/Applications/ZenBookHelper.app/Contents/Info.plist" 2>/dev/null | sed 's/^/ZenBookHelper /'
echo ""; echo "--- power (battery / charger)"; pmset -g custom 2>/dev/null | grep -E "Power:|^ (sleep|displaysleep|lowpowermode) "
echo ""; echo "--- Wi-Fi now"; sudo -u "$U" "$UH/Applications/ZenBookHelper.app/Contents/MacOS/ZenBookHelper" wifiprobe 2>/dev/null | sed -E 's/ether [0-9a-f:]+/ether <mac>/'
echo ""; echo "--- Wi-Fi after the last lid opens (helper)"; grep -E "after wake \+|sleep: Wi-Fi|wake: Wi-Fi|lost its|back after|NO traffic|itlwm" "$UH/Library/Logs/ZenBookHelper.log" 2>/dev/null | tail -30
[ -f "$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt" ] && { echo "--- ZenBook Wi-Fi Last Wake.txt"; tail -40 "$UH/Library/Logs/ZenBook Wi-Fi/Last Wake.txt"; }
echo ""; echo "--- memory / CPU right now"; sysctl -n hw.memsize | awk '{printf "RAM %.0f GB\n", $1/1073741824}'; vm_stat | head -8; sysctl -n machdep.cpu.brand_string; top -l 1 -n 8 -o cpu -stats pid,command,cpu,mem 2>/dev/null | tail -12
echo ""; echo "--- Performance Check reports (last 2 days)"
find "$UH/Desktop" "$UH/Documents" "$UH/Downloads" "$UH/Library/Logs" "/Library/Application Support/ZenBook Performance" -maxdepth 3 -type f -iname "*performance*" -mtime -2 2>/dev/null | while read -r f; do
    echo "copied: $f"; /bin/cp "$f" "$OUTD/" 2>/dev/null; done
} > "$OUT" 2>&1
sync
echo "Saved: $OUT"
echo "Read-only - nothing was changed. Eject the USB and bring it back."
