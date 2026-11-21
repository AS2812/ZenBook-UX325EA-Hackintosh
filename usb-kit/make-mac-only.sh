#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - macOS only, no USB needed                 v1.1
#
#   sudo sh "/Volumes/Install macOS Sonoma/make-mac-only.sh"          CHECK ONLY (changes nothing)
#   sudo sh "/Volumes/Install macOS Sonoma/make-mac-only.sh" --apply  do it (you type ERASE WINDOWS)
#
# With --apply:
#  1. Checks: this Mac started macOS from the internal SSD, the charger is connected, and every
#     Windows partition lies AFTER the macOS (APFS) partition. If not, it stops: nothing changed.
#  2. Deletes the Windows partitions (Microsoft Reserved, Microsoft Basic Data, Windows Recovery).
#     ALL WINDOWS FILES ARE LOST.
#  3. Grows the macOS APFS container over the whole freed space (live; FileVault stays on).
#  4. Copies this USB's tested OpenCore to the SSD (sync-efi-to-ssd.sh --launcher-full).
#  5. Removes \EFI\Microsoft (Windows Boot Manager) from the SSD's EFI partition (a copy goes
#     to /Users/Shared/UX325EA-EFI-Backups) and turns the OpenCore menu off on the SSD copy, so
#     the power button starts macOS directly.
# Then: Shut Down, unplug the USB, power on tapping Esc, choose the SSD entry ONCE.
# A log is saved to UX325EA-RESCUE/TEST-RESULTS/mac-only-<time>.txt on the USB.
#
# Test only (disk images on another Mac): --disk diskN --store diskNsM  (no root/AC/sync)
# v1.1: works with "sudo sh" too (v1.0 stopped with a syntax error: macOS sh is bash in POSIX
#       mode, which rejects the log redirection); Microsoft Reserved deleted last and optional.
# ==============================================================================
# "sh script" = bash in POSIX mode -> restart in real bash before any bash-only line is read
case ":${SHELLOPTS:-}:" in *:posix:*) exec /bin/bash "$0" "$@" ;; esac
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u
APPLY=0; DISK=""; STORE=""; TESTMODE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --disk)  shift; DISK="${1:-}"; TESTMODE=1 ;;
        --store) shift; STORE="${1:-}"; TESTMODE=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; exit 2 ;;
    esac
    shift
done
if [ "$TESTMODE" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[*] Administrator rights are needed (disk changes) - asking for your password..."
    exec sudo /bin/bash "$0" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$SCRIPT_DIR/UX325EA-RESCUE/TEST-RESULTS"; [ "$TESTMODE" = 1 ] && LOGDIR="${TMPDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null; LOG="$LOGDIR/mac-only-$TS.txt"
exec > >(tee -a "$LOG") 2>&1

say()  { echo "[*] $*"; }
ok()   { echo "  [OK]   $*"; }
stop() { echo ""; echo "[STOP] $*"; echo "       Nothing was changed. Log: $LOG"; exit 1; }
fail() { echo ""; echo "[ERROR] $*"; echo "        Log: $LOG"; exit 1; }
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
gb()    { awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

echo "=== ZenBook UX325EA - macOS only v1.1 ($TS) $( [ $APPLY = 1 ] && echo APPLY || echo CHECK ONLY)"
# ---------------------------------------------------------------------------
# 1. Where is macOS?
# ---------------------------------------------------------------------------
for V in / /System/Volumes/Data; do
    [ -n "$STORE" ] && break
    STORE="$(diskutil info -plist "$V" 2>/dev/null | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - - 2>/dev/null)"
done
[ -n "$STORE" ] || stop "Could not find the APFS partition of the running macOS."
[ -n "$DISK" ] || DISK="$(pinfo "$STORE" ParentWholeDisk)"
[ -n "$DISK" ] || stop "Could not find the disk that holds $STORE."
if [ "$TESTMODE" = 0 ]; then
    [ "$(pinfo "$DISK" Internal)" = "true" ] || stop "macOS was not started from the internal SSD ($DISK is not internal)."
    [ "$(uname -m)" = "x86_64" ] || stop "This is not the ZenBook (not an Intel Mac)."
    pmset -g batt 2>/dev/null | grep -q "AC Power" || stop "Connect the charger first (the disk is resized live)."
fi
say "macOS APFS partition: $STORE on $DISK ($(pinfo "$DISK" MediaName), $(gb "$(pinfo "$DISK" TotalSize)"))"
echo ""; diskutil list "$DISK"
# ---------------------------------------------------------------------------
# 2. Classify every partition by type and physical position
# ---------------------------------------------------------------------------
STORE_OFF="$(pinfo "$STORE" PartitionMapPartitionOffset)"; STORE_SIZE="$(pinfo "$STORE" TotalSize)"
[ -n "$STORE_OFF" ] || stop "Could not read the position of $STORE."
STORE_END=$((STORE_OFF + STORE_SIZE))
ESP=""; WIN=""; MSR=""; WIN_BYTES=0; PROBLEMS=""
for P in $(diskutil list "$DISK" | awk '{print $NF}' | grep -E "^${DISK}s[0-9]+$"); do
    C="$(pinfo "$P" Content)"; O="$(pinfo "$P" PartitionMapPartitionOffset)"; S="$(pinfo "$P" TotalSize)"
    N="$(pinfo "$P" VolumeName)"
    if [ "$P" = "$STORE" ]; then echo "  keep    $P  macOS (APFS)          $(gb "$S")"; continue; fi
    case "$C" in
        EFI)
            ESP="$P"; echo "  keep    $P  EFI partition         $(gb "$S")" ;;
        "Microsoft Reserved")
            MSR="$MSR $P"; echo "  delete  $P  Microsoft Reserved    $(gb "$S")" ;;
        "Microsoft Basic Data"|"Windows Recovery")
            if [ "${O:-0}" -lt "$STORE_OFF" ]; then
                PROBLEMS="$PROBLEMS\n  $P ($C, $(gb "$S"), \"$N\") lies BEFORE macOS - its space cannot be added to macOS in place."
            fi
            WIN="$WIN $P"; WIN_BYTES=$((WIN_BYTES + S)); echo "  delete  $P  $C  \"$N\"  $(gb "$S")" ;;
        *)
            PROBLEMS="$PROBLEMS\n  $P has an unexpected type ($C, \"$N\", $(gb "$S")) - not touched, so the script stops."
            echo "  ????    $P  $C \"$N\" $(gb "$S")" ;;
    esac
done
[ -n "$ESP" ] || PROBLEMS="$PROBLEMS\n  No EFI partition on $DISK."
[ -n "$PROBLEMS" ] && stop "This disk cannot be turned into macOS-only automatically:$(printf "$PROBLEMS")"
if [ -z "$WIN$MSR" ]; then
    say "No Windows partitions left - only the OpenCore steps are needed."
else
    say "Windows partitions to delete:$WIN$MSR  (macOS grows by about $(gb "$WIN_BYTES"))"
fi
if [ "$APPLY" = 0 ]; then
    echo ""; echo "CHECK ONLY - nothing was changed. To do it:"
    echo "    sudo sh \"$SCRIPT_DIR/make-mac-only.sh\" --apply"
    exit 0
fi
# ---------------------------------------------------------------------------
# 3. Confirm, delete Windows, grow macOS
# ---------------------------------------------------------------------------
if [ -n "$WIN$MSR" ]; then
    echo ""; echo "!!! This DELETES Windows and ALL its files on this laptop. It cannot be undone. !!!"
    if [ "$TESTMODE" = 1 ] && [ -n "${ZB_CONFIRM:-}" ]; then A="$ZB_CONFIRM"; else
        printf "    Type ERASE WINDOWS (capital letters) and press Enter, anything else cancels: "; read -r A < /dev/tty; fi
    [ "$A" = "ERASE WINDOWS" ] || stop "Cancelled."
    for P in $WIN; do
        diskutil unmount force "$P" >/dev/null 2>&1
        diskutil eraseVolume free none "$P" >/dev/null 2>&1 || fail "Could not delete $P (diskutil eraseVolume free)."
        ok "deleted $P"
    done
    for P in $MSR; do          # 16 MB, no files: if it refuses, it only costs those 16 MB
        if diskutil eraseVolume free none "$P" >/dev/null 2>&1; then ok "deleted $P (Microsoft Reserved)"
        else echo "  [WARN] could not delete $P (Microsoft Reserved, 16 MB) - left in place, harmless"; fi
    done
    say "Growing the macOS container over the free space (can take a minute)..."
    diskutil apfs resizeContainer "$STORE" 0 || fail "Resize failed. macOS is unchanged and still works; the freed space stays empty."
    ok "macOS container now $(gb "$(pinfo "$STORE" TotalSize)") of $(gb "$(pinfo "$DISK" TotalSize)")"
fi
echo ""; diskutil list "$DISK"
# ---------------------------------------------------------------------------
# 4. OpenCore from this USB to the SSD
# ---------------------------------------------------------------------------
if [ "$TESTMODE" = 0 ]; then
    say "Copying the USB's OpenCore to the SSD..."
    /bin/bash "$SCRIPT_DIR/sync-efi-to-ssd.sh" --launcher-full --target "$ESP" || fail "OpenCore copy to the SSD failed (see above). Keep using the USB to start."
else
    say "(test) OpenCore copy skipped"
fi
# ---------------------------------------------------------------------------
# 5. SSD EFI: Windows Boot Manager away, OpenCore menu off
# ---------------------------------------------------------------------------
MNT="$(pinfo "$ESP" MountPoint)"; MOUNTED=0
if [ -z "$MNT" ]; then diskutil mount "$ESP" >/dev/null 2>&1 && MOUNTED=1; MNT="$(pinfo "$ESP" MountPoint)"; fi
[ -n "$MNT" ] && [ -d "$MNT/EFI/OC" ] || fail "SSD EFI partition $ESP has no EFI/OC after the copy."
if [ -d "$MNT/EFI/Microsoft" ]; then
    BK="/Users/Shared/UX325EA-EFI-Backups/EFI-Microsoft-$TS"; [ "$TESTMODE" = 1 ] && BK="${TMPDIR:-/tmp}/EFI-Microsoft-$TS"
    mkdir -p "$BK" && /bin/cp -R "$MNT/EFI/Microsoft" "$BK/" && rm -rf "$MNT/EFI/Microsoft" && ok "Windows Boot Manager removed (copy: $BK)"
fi
for CFG in "$MNT"/EFI/OC/config*.plist; do
    /usr/libexec/PlistBuddy -c "Set :Misc:Boot:ShowPicker false" "$CFG" >/dev/null 2>&1
    [ "$(/usr/libexec/PlistBuddy -c 'Print :Misc:Boot:ShowPicker' "$CFG" 2>/dev/null)" = "false" ] || fail "Could not turn the menu off in $CFG"
done
ok "SSD OpenCore: no menu - the power button starts macOS (hold Option/Alt at power-on for the menu)"
find "$MNT" -name '._*' -delete 2>/dev/null
sync; [ "$MOUNTED" = 1 ] && diskutil unmount "$ESP" >/dev/null 2>&1
echo ""
echo "=== DONE. macOS now has the whole SSD and starts without the USB:"
echo "    1. Apple menu > Shut Down. Unplug the USB."
echo "    2. Power on while tapping Esc, choose the SSD entry (UEFI OS / the SSD name) ONCE."
echo "       OpenCore adds itself as the first boot option; from then on: power button -> macOS."
echo "    Log: $LOG"
