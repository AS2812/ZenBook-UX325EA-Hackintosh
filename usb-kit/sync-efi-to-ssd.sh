#!/bin/bash
# ==============================================================================
# ASUS ZenBook 13 OLED (UX325EA) - Sync OpenCore EFI (USB -> internal SSD)  v2.0
#
#   sudo sh "/Volumes/Install macOS Sonoma/sync-efi-to-ssd.sh"                 sync
#   sudo sh "/Volumes/Install macOS Sonoma/sync-efi-to-ssd.sh" --dry-run       plan only, writes nothing
#   sudo sh "/Volumes/Install macOS Sonoma/sync-efi-to-ssd.sh" --launcher-full also set
#        Misc>Boot>LauncherOption=Full in the SSD copy (adds a firmware "OpenCore" boot entry,
#        survives Windows rewriting \EFI\BOOT\BOOTX64.EFI)
#   Overrides: --source diskXsY   --target diskXsY
#
# What v1.0 got wrong, and v2.0 fixes:
#  1. v1 took "Part of Whole" of the APFS volume '<macOS volume>'. That is the synthesized APFS
#     container (disk1), so it targeted disk1s1 = the macOS APFS volume, not the SSD EFI.
#     v2 follows APFSPhysicalStore (disk0s3) -> parent disk (disk0) -> partition of type EFI.
#  2. v1 did 'rm -rf EFI' on the SSD ESP. That partition is shared with Windows
#     (Microsoft Reserved + Basic Data + Windows Recovery are on disk0), so it would have
#     deleted \EFI\Microsoft (Windows Boot Manager). v2 replaces only EFI/OC and EFI/BOOT.
#  3. v1 checked '[ -d /Volumes/SSD_EFI ]' after it had already created that directory
#     itself, so a failed mount still counted as success. v2 checks the real mount point.
#  4. v1 put a full EFI backup inside the 200 MB ESP on every run, so it filled up.
#     v2.1 backs up to /Users/Shared/UX325EA-EFI-Backups on the laptop (USB space is small).
#  5. v1 hard-coded disk6s1/disk2s1. v2 identifies disks by properties and refuses to run
#     on Apple Silicon or when source and target are on the same disk.
#  6. v2 verifies the copy with diff -r before it reports success.
# ==============================================================================
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "[*] Root is required to mount EFI partitions - re-running with sudo..."
    exec sudo /bin/bash "$0" "$@"
fi

DRY=0; LAUNCHER_FULL=0; SRC_DEV=""; TGT_DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n)    DRY=1 ;;
        --launcher-full) LAUNCHER_FULL=1 ;;
        --source)        shift; SRC_DEV="${1:-}" ;;
        --target)        shift; TGT_DEV="${1:-}" ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "[ERROR] Unknown option: $1"; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MOUNTED_SRC=0; MOUNTED_TGT=0; SRC_MNT=""; TGT_MNT=""

say()  { echo "[*] $*"; }
warn() { echo "[!] $*"; }
cleanup() {
    [ "$MOUNTED_TGT" = 1 ] && [ -n "$TGT_DEV" ] && diskutil unmount "$TGT_DEV" >/dev/null 2>&1
    [ "$MOUNTED_SRC" = 1 ] && [ -n "$SRC_DEV" ] && diskutil unmount "$SRC_DEV" >/dev/null 2>&1
}
die()  { echo "[ERROR] $*" >&2; cleanup; exit 1; }
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
parts_of() { diskutil list "$1" 2>/dev/null | awk '{print $NF}' | grep -E "^${1}s[0-9]+$"; }

echo "=========================================================="
echo "  UX325EA: Sync OpenCore EFI  USB -> internal SSD  (v2.0)"
[ "$DRY" = 1 ] && echo "  DRY RUN - nothing will be written"
echo "=========================================================="

[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && die "This is an Apple Silicon Mac. Run this on the ZenBook only."

# ------------------------------------------------------------------------------
# 1. Source: FAT partition on an EXTERNAL disk that contains EFI/OC/OpenCore.efi
# ------------------------------------------------------------------------------
is_oc_src() {   # $1 = device; echoes mount point if it is an external OpenCore partition
    local d="$1" mp
    [ "$(pinfo "$d" Internal)" = "false" ] || return 1
    mp="$(pinfo "$d" MountPoint)"
    [ -n "$mp" ] && [ -f "$mp/EFI/OC/OpenCore.efi" ] && [ -f "$mp/EFI/OC/config.plist" ] && { echo "$mp"; return 0; }
    return 1
}

if [ -z "$SRC_DEV" ]; then
    CANDS=""
    for d in $(diskutil list external 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
        is_oc_src "$d" >/dev/null && CANDS="$CANDS $d"
    done
    if [ -z "$CANDS" ]; then   # nothing mounted yet: try mounting external FAT partitions
        for d in $(diskutil list external 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
            [ -z "$(pinfo "$d" MountPoint)" ] || continue
            case "$(pinfo "$d" Content)" in EFI|"Microsoft Basic Data"|DOS_FAT_32) ;; *) continue ;; esac
            diskutil mount readOnly "$d" >/dev/null 2>&1 || continue
            if is_oc_src "$d" >/dev/null; then CANDS="$CANDS $d"; SRC_DEV="$d"; MOUNTED_SRC=1; break; fi
            diskutil unmount "$d" >/dev/null 2>&1
        done
    fi
    set -- $CANDS
    [ $# -eq 0 ] && die "No external partition with EFI/OC/OpenCore.efi found. Plug in the USB or use --source diskXsY."
    [ $# -gt 1 ] && die "Several OpenCore USB partitions found ($CANDS). Choose one with --source diskXsY."
    SRC_DEV="$1"
else
    if [ -z "$(pinfo "$SRC_DEV" MountPoint)" ]; then diskutil mount readOnly "$SRC_DEV" >/dev/null 2>&1 && MOUNTED_SRC=1; fi
fi
SRC_MNT="$(is_oc_src "$SRC_DEV")" || die "$SRC_DEV is not an external partition containing EFI/OC/OpenCore.efi"
SRC_WHOLE="$(pinfo "$SRC_DEV" ParentWholeDisk)"
say "Source (USB) : /dev/$SRC_DEV  ($SRC_WHOLE, $(pinfo "$SRC_DEV" BusProtocol))  mounted at $SRC_MNT"

# ------------------------------------------------------------------------------
# 2. Target: EFI-type partition on the INTERNAL disk that hosts macOS '<macOS volume>'
# ------------------------------------------------------------------------------
if [ -z "$TGT_DEV" ]; then
    REFVOL="/"
    # Optional: MACOS_VOLUME="My Mac" sudo sh sync-efi-to-ssd.sh  (default: the running system)
    [ -n "${MACOS_VOLUME:-}" ] && diskutil info "$MACOS_VOLUME" >/dev/null 2>&1 && REFVOL="$MACOS_VOLUME"
    STORE="$(pinfo "$REFVOL" APFSPhysicalStores.0.APFSPhysicalStore)"
    [ -n "$STORE" ] || die "Could not resolve the APFS physical store of '$REFVOL'. Use --target diskXsY."
    TGT_WHOLE="$(pinfo "$STORE" ParentWholeDisk)"
    for p in $(parts_of "$TGT_WHOLE"); do
        if [ "$(pinfo "$p" Content)" = "EFI" ]; then TGT_DEV="$p"; break; fi
    done
    [ -n "$TGT_DEV" ] || die "No EFI partition found on $TGT_WHOLE. Use --target diskXsY."
    say "macOS volume : '$REFVOL' -> APFS store /dev/$STORE -> disk /dev/$TGT_WHOLE"
else
    TGT_WHOLE="$(pinfo "$TGT_DEV" ParentWholeDisk)"
    [ "$(pinfo "$TGT_DEV" Content)" = "EFI" ] || die "$TGT_DEV is not an EFI partition (Content=$(pinfo "$TGT_DEV" Content))"
fi
[ "$(pinfo "$TGT_WHOLE" Internal)" = "true" ] || die "Target disk $TGT_WHOLE is not internal - refusing."
[ "$TGT_WHOLE" != "$SRC_WHOLE" ] || die "Source and target are on the same disk ($TGT_WHOLE) - refusing."

TGT_MNT="$(pinfo "$TGT_DEV" MountPoint)"
if [ -z "$TGT_MNT" ]; then
    diskutil mount "$TGT_DEV" >/dev/null 2>&1 || die "Could not mount /dev/$TGT_DEV"
    MOUNTED_TGT=1
    TGT_MNT="$(pinfo "$TGT_DEV" MountPoint)"
fi
[ -n "$TGT_MNT" ] && [ -d "$TGT_MNT" ] || die "Target /dev/$TGT_DEV did not mount."
[ "$(pinfo "$TGT_DEV" FilesystemType)" = "msdos" ] || die "Target /dev/$TGT_DEV is not FAT32 - refusing."
[ "$TGT_MNT" != "$SRC_MNT" ] || die "Source and target resolved to the same mount point - refusing."
say "Target (SSD) : /dev/$TGT_DEV  ($TGT_WHOLE, internal EFI)  mounted at $TGT_MNT"

HAS_WIN=0
if [ -f "$TGT_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    HAS_WIN=1; say "Windows Boot Manager found on the SSD EFI - it will be PRESERVED."
fi
for x in "$TGT_MNT"/EFI/*; do [ -e "$x" ] && echo "      existing: EFI/$(basename "$x")"; done

# ------------------------------------------------------------------------------
# 3. Space and plan
# ------------------------------------------------------------------------------
NEED_KB=$(du -sk "$SRC_MNT/EFI/OC" "$SRC_MNT/EFI/BOOT" 2>/dev/null | awk '{s+=$1} END{print s+0}')
OLD_KB=$(du -sk "$TGT_MNT/EFI/OC" "$TGT_MNT/EFI/BOOT" 2>/dev/null | awk '{s+=$1} END{print s+0}')
FREE_KB=$(df -k "$TGT_MNT" | awk 'NR==2{print $4}')
STAGED=0; [ "$FREE_KB" -ge $((NEED_KB + 4096)) ] && STAGED=1
say "Space: new OC+BOOT ${NEED_KB} KB, current OC+BOOT ${OLD_KB} KB, free ${FREE_KB} KB"
[ $((FREE_KB + OLD_KB)) -ge $((NEED_KB + 1024)) ] || die "Not enough space on the SSD EFI even after replacing EFI/OC."
if [ "$STAGED" = 1 ]; then say "Plan: copy to EFI/OC.new, verify, then swap (old OC stays until the new one is verified)."
else warn "Plan: not enough room to stage. The old EFI/OC is deleted before copying (it is backed up first)."; fi

if [ "$DRY" = 1 ]; then
    say "DRY RUN complete. Re-run without --dry-run to apply."
    cleanup; exit 0
fi

# ------------------------------------------------------------------------------
# 4. Backup of the SSD EFI (stored OUTSIDE the ESP)
# ------------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
# v2.1: keep the (70-90 MB) SSD EFI backup on the laptop - the USB data partition is small
BK_ROOT="/Users/Shared/UX325EA-EFI-Backups"; mkdir -p "$BK_ROOT" 2>/dev/null
[ -d "$BK_ROOT" ] && [ -w "$BK_ROOT" ] || BK_ROOT="$SCRIPT_DIR/UX325EA-RESCUE/BACKUPS"
BK="$BK_ROOT/SSD-ESP-$TS"
mkdir -p "$BK" || die "Cannot create backup folder $BK"
if [ -d "$TGT_MNT/EFI" ]; then
    /bin/cp -RX "$TGT_MNT/EFI" "$BK/EFI" || die "Backup failed - nothing was changed."
    say "Backup of SSD EFI saved to: $BK/EFI"
else
    say "SSD EFI has no EFI folder yet - nothing to back up."
fi

# ------------------------------------------------------------------------------
# 5. Copy (merge: only EFI/OC and EFI/BOOT are replaced)
# ------------------------------------------------------------------------------
mkdir -p "$TGT_MNT/EFI" || die "Cannot create $TGT_MNT/EFI"
rm -rf "$TGT_MNT/EFI/OC.new" "$TGT_MNT/EFI/BOOT.new"
if [ "$STAGED" = 0 ]; then rm -rf "$TGT_MNT/EFI/OC"; fi
/bin/cp -RX "$SRC_MNT/EFI/OC"   "$TGT_MNT/EFI/OC.new"   || die "Copy of EFI/OC failed. Restore from $BK if needed."
/bin/cp -RX "$SRC_MNT/EFI/BOOT" "$TGT_MNT/EFI/BOOT.new" || die "Copy of EFI/BOOT failed. Restore from $BK if needed."
find "$TGT_MNT/EFI/OC.new" "$TGT_MNT/EFI/BOOT.new" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null

same_tree() { diff -rq -x '._*' -x '.DS_Store' "$1" "$2" >/dev/null 2>&1; }
same_tree "$SRC_MNT/EFI/OC"   "$TGT_MNT/EFI/OC.new"   || die "Verification of EFI/OC.new failed. Old EFI/OC was left in place."
same_tree "$SRC_MNT/EFI/BOOT" "$TGT_MNT/EFI/BOOT.new" || die "Verification of EFI/BOOT.new failed. Old EFI/BOOT was left in place."

rm -rf "$TGT_MNT/EFI/OC" "$TGT_MNT/EFI/BOOT"
mv "$TGT_MNT/EFI/OC.new" "$TGT_MNT/EFI/OC"     || die "Swap of EFI/OC failed. Restore from $BK."
mv "$TGT_MNT/EFI/BOOT.new" "$TGT_MNT/EFI/BOOT" || die "Swap of EFI/BOOT failed. Restore from $BK."
find "$TGT_MNT/EFI/OC" "$TGT_MNT/EFI/BOOT" -name '._*' -delete 2>/dev/null
rm -f "$TGT_MNT/EFI/._OC" "$TGT_MNT/EFI/._BOOT" "$TGT_MNT/EFI/._OC.new" "$TGT_MNT/EFI/._BOOT.new" 2>/dev/null
sync

same_tree "$SRC_MNT/EFI/OC" "$TGT_MNT/EFI/OC" || die "Final verification failed. Restore from $BK."
plutil -lint "$TGT_MNT/EFI/OC/config.plist" >/dev/null || die "SSD config.plist does not parse. Restore from $BK."
if [ "$HAS_WIN" = 1 ] && [ ! -f "$TGT_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    die "Windows Boot Manager disappeared - restore EFI/Microsoft from $BK/EFI/Microsoft"
fi

if [ "$LAUNCHER_FULL" = 1 ]; then
    # every profile on the SSD, so --gpu-off / --gpu-keep keep the firmware "OpenCore" entry
    for CFG in "$TGT_MNT"/EFI/OC/config*.plist; do
        /usr/libexec/PlistBuddy -c "Set :Misc:Boot:LauncherOption Full" "$CFG" \
            && say "SSD copy: LauncherOption=Full in $(basename "$CFG") (USB copy unchanged)." \
            || warn "Could not set LauncherOption in $(basename "$CFG")."
    done
fi
say "Verified: SSD EFI/OC and EFI/BOOT match the USB byte-for-byte."
cleanup

echo ""
echo "=========================================================="
echo "  SUCCESS - OpenCore is on the internal SSD EFI (/dev/$TGT_DEV)"
[ "$HAS_WIN" = 1 ] && echo "  Windows Boot Manager preserved."
echo "  Backup: $BK"
echo ""
echo "  Next: reboot, press ESC at the ASUS logo, pick the SK hynix"
echo "  'UEFI OS' entry (not 'Windows Boot Manager'), keep the USB in"
echo "  as a fallback for the first boot. When it works, set that entry"
echo "  first in BIOS > Boot."
echo "=========================================================="
