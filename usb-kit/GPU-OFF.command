#!/bin/bash
# ZenBook UX325EA - put the NORMAL (stable, no GPU acceleration) OpenCore config back on this USB.
# Double-click it on ANY Mac (or run it on the ZenBook) if the GPU profile ever leaves you with a
# black screen or restart loop.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
pinfo() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
echo "== ZenBook: switching the OpenCore USB back to the normal (stable) config =="
done_any=0
for d in $(diskutil list external 2>/dev/null | awk '{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
    [ "$(pinfo "$d" FilesystemType)" = "msdos" ] || continue
    mp="$(pinfo "$d" MountPoint)"
    [ -z "$mp" ] && { diskutil mount "$d" >/dev/null 2>&1 || sudo diskutil mount "$d" >/dev/null 2>&1; mp="$(pinfo "$d" MountPoint)"; }
    [ -n "$mp" ] && [ -f "$mp/EFI/OC/config-stable.plist" ] || continue
    if /bin/cp "$mp/EFI/OC/config-stable.plist" "$mp/EFI/OC/config.plist" 2>/dev/null || sudo /bin/cp "$mp/EFI/OC/config-stable.plist" "$mp/EFI/OC/config.plist"; then
        sync; echo "[OK] $d ($mp): normal config restored."; done_any=1
    fi
done
[ -f "/Library/Application Support/ZenBook/gpu-mode" ] && { echo off | sudo tee "/Library/Application Support/ZenBook/gpu-mode" >/dev/null; }
[ "$done_any" = 1 ] && echo "Done. Put the USB back in the ZenBook and boot normally." || echo "[!] OpenCore USB with config-stable.plist not found - is the USB plugged in?"
