# ASUS ZenBook 13 OLED (UX325EA) - Flash Drive Rescue & Staging

This directory structure implements **Section 3** of the `UX325EA_OpenCore_USB_Upgrade_Plan.md`.

## Directory Contents
- **`BACKUPS/`**:
  - `Original-EFI.zip`: A complete compressed snapshot of the functional baseline EFI.
  - `Original-config.plist`: Exact snapshot of `config.plist` before any experimental edits.
  - `Current-hardware-inventory.txt`: Full hardware specifications and driver mapping.
- **`STAGING/`**:
  - `EFI-BASELINE.zip`: Baseline OpenCore configuration with Iris Xe experimental extensions disabled (safe display mode, full 1080p, OLED panel powered ON, zero black screens).
- **`LOGS/`**:
  - Reserved for test logs, panic dumps, and `pmset -g log` outputs.

## Quick Recovery Tool
If the internal drive `macOS` ever experiences black screens after running experimental packages, open **macOS Recovery Terminal** and run:
```bash
sh /Volumes/*/fix
```
This automatically unlocks FileVault, removes conflicting extensions, clears the kernel collection cache, and restores normal booting.
