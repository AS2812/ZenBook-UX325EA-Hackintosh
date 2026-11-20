# ASUS ZenBook 13 OLED (UX325EA) - Emergency Rollback Runbook

## If You Ever Experience a Black Screen:

### 1. The Quickest Fix (Zero Terminal Commands)
The active EFI on your flash drive is currently set to **PROFILE A (BASELINE SAFE)**:
1. Boot from the flash drive (press **Esc** at ASUS logo).
2. Select **macOS** and press **Enter**.
3. The display will boot with 100% visible basic framebuffer at full 1080p.

### 2. If You Installed a Graphics Package inside macOS and Need to Clean macOS
1. In the OpenCore boot picker, select **Install macOS Sonoma**.
2. Go to **Utilities** → **Terminal**.
3. Run the space-proof rescue tool:
   ```bash
   sh /Volumes/*/fix
   ```
4. Enter your macOS FileVault password when prompted.
5. The script automatically removes `/Library/Extensions/AppleIntelTGL*`, resets the auxiliary kernel collection, clears corrupted WindowServer preferences, and resets the display.
6. Type `reboot` to restart.

### 3. Switching Profiles from Terminal:
To switch between baseline and experimental profiles:
- Switch to Baseline Safe:
  ```bash
  sh /Volumes/*/set-profile-baseline.sh
  ```
- Switch to WEX Experimental:
  ```bash
  sh /Volumes/*/set-profile-wex.sh
  ```
