#!/bin/bash
# Sync all fixed drivers, configs, and packages to the USB flash drive
set -euo pipefail

USB_DATA="/Volumes/Install macOS Sonoma"
USB_EFI="/Volumes/EFI"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== ZenBook UX325EA - Flash Drive Sync ==="

if [ ! -d "$USB_DATA" ] || [ ! -d "$USB_EFI" ]; then
    echo "[!] Flash drive not detected at $USB_DATA or $USB_EFI."
    echo "[!] Please connect the flash drive to this Mac and re-run."
    exit 1
fi

echo "[*] 1. Syncing EFI to $USB_EFI..."
/bin/cp -RX "$REPO_DIR/EFI/" "$USB_EFI/EFI/"
find "$USB_EFI" -name '._*' -delete 2>/dev/null || true
echo "    EFI sync complete."

echo "[*] 2. Syncing updated package and tools to $USB_DATA..."
/bin/cp -X "$REPO_DIR/usb-kit/Install ZenBook Wi-Fi.pkg" "$USB_DATA/Install ZenBook Wi-Fi.pkg"
rm -rf "$USB_DATA/ZenBookHelper.app"
/bin/cp -RX "$REPO_DIR/usb-kit/ZenBookHelper.app" "$USB_DATA/ZenBookHelper.app"
/bin/cp -X "$REPO_DIR/usb-kit/fix-hardware.sh" "$USB_DATA/fix-hardware.sh"
/bin/cp -X "$REPO_DIR/usb-kit/fix-wifi.sh" "$USB_DATA/fix-wifi.sh"
/bin/cp -X "$REPO_DIR/usb-kit/wifi-driver.sh" "$USB_DATA/wifi-driver.sh"
/bin/cp -X "$REPO_DIR/usb-kit/sync-efi-to-ssd.sh" "$USB_DATA/sync-efi-to-ssd.sh"
find "$USB_DATA" -name '._*' -delete 2>/dev/null || true
echo "    Package and tools sync complete."

echo "[*] 3. Verifying package version on USB..."
PKG_VER=$(pkgutil --expand "$USB_DATA/Install ZenBook Wi-Fi.pkg" /tmp/check_pkg_usb >/dev/null 2>&1 && cat /tmp/check_pkg_usb/WiFi.pkg/PackageInfo | grep -o 'version="[^"]*"' | head -1 | cut -d'"' -f2; rm -rf /tmp/check_pkg_usb)
echo "    Installed package version on USB: $PKG_VER"

echo "[*] 4. Disk space on USB:"
df -h "$USB_DATA" "$USB_EFI"

echo ""
echo "[OK] Flash drive is completely updated and ready for ZenBook!"
