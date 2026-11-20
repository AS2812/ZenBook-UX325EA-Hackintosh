#!/bin/bash
# Builds ZenBookHelper.app (universal x86_64 + arm64, ad-hoc signed) next to this script.
set -e
cd "$(dirname "$0")"
APP=ZenBookHelper.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"; printf 'APPL????' > "$APP/Contents/PkgInfo"
for arch in x86_64 arm64; do
  clang -arch $arch -mmacosx-version-min=12.0 -fobjc-arc -O2 -Wall -Wno-unused-variable \
    -framework Cocoa -framework Carbon -framework ApplicationServices -framework IOKit -framework CoreWLAN -framework CoreAudio -framework AudioToolbox \
    ZenBookHelper.m -o ZenBookHelper.$arch
done
lipo -create ZenBookHelper.x86_64 ZenBookHelper.arm64 -output "$APP/Contents/MacOS/ZenBookHelper"
rm -f ZenBookHelper.x86_64 ZenBookHelper.arm64
# Fixed designated requirement: macOS privacy permissions (Input Monitoring, Accessibility)
# are stored against this requirement, so they survive every future rebuild. The default
# ad-hoc requirement is the binary hash, which changes on each build and drops the grant.
codesign --force --deep -s - -r='designated => identifier "com.zenbook.helper"' "$APP"
echo "built $(pwd)/$APP"
