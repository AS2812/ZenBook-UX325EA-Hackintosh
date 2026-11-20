#!/bin/sh
set -eu
cd "$(dirname "$0")"
app='../../usb-kit/Check FPS After Restart.app'
mkdir -p "$app/Contents/MacOS"
xcrun clang -target x86_64-apple-macos14.0 -Os -fobjc-arc -Wall -Werror \
    -Wno-deprecated-declarations -framework Cocoa -framework Metal -framework QuartzCore \
    PanelCheck.m PanelFrames.m -o "$app/Contents/MacOS/PanelCheck"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
