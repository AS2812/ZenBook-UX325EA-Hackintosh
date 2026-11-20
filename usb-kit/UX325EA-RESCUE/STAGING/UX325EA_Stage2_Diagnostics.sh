#!/bin/bash
# ASUS ZenBook 13 OLED (UX325EA) - Stage 2 Diagnostic Collector
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

REPORT_DIR="$HOME/Desktop/UX325EA_Stage2_Report"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/stage2_report.txt"

echo "=========================================================="
echo "    ASUS ZENBOOK 13 OLED - STAGE 2 HARDWARE DIAGNOSTICS   "
echo "=========================================================="
echo "Writing report to: $REPORT_FILE"
echo ""

{
    echo "=== 1. SYSTEM & MACOS BUILD ==="
    sw_vers
    uname -a
    csrutil status
    echo ""

    echo "=== 2. DISPLAY SUBSYSTEM & GPU ==="
    system_profiler SPDisplaysDataType
    echo ""

    echo "=== 3. BACKLIGHT & BRIGHTNESS SERVICES ==="
    ioreg -r -c AppleBacklightDisplay -l || echo "AppleBacklightDisplay not attached"
    echo ""
    ioreg -r -c AppleIntelPanelA -l || echo "AppleIntelPanelA not attached"
    echo ""

    echo "=== 4. ASUS SMC & HARDWARE CONTROLLERS ==="
    ioreg -r -c AsusSMC -l || echo "AsusSMC not attached"
    echo ""
    ioreg -r -c BrightnessKeys -l || echo "BrightnessKeys not attached"
    echo ""

    echo "=== 5. LOADED HARDWARE KERNEL EXTENSIONS ==="
    kmutil showloaded | grep -Ei 'WhateverXe|AsusSMC|BrightnessKeys|AppleALC|VoodooI2C|VirtualSMC|AirportItlwm|PC711Probe|AMFIPass'
    echo ""

    echo "=== 6. AUDIO HARDWARE ==="
    system_profiler SPAudioDataType
    echo ""

    echo "=== 7. POWER & BATTERY CONFIGURATION ==="
    pmset -g batt
    pmset -g
    echo ""

    echo "=== 8. BOOT ARGUMENTS ==="
    sysctl kern.bootargs
    echo ""
} > "$REPORT_FILE"

echo "[SUCCESS] Report saved to: $REPORT_FILE"
echo "You can open it with: open $REPORT_FILE"
