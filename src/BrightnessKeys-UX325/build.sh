#!/bin/bash
# Builds BrightnessKeys-UX325.kext: acidanthera BrightnessKeys 1.0.3 + ACPI codes 0x90/0x91/0x92
# (volume up / down / mute, sent by SSDT-WAKE) -> PS/2 keyboard ADB 0x48/0x49/0x4A.
#   SDK=/path/to/MacKernelSDK LILU=/path/to/Lilu.kext(DEBUG) ./build.sh
set -e
: "${SDK:?set SDK to a MacKernelSDK checkout}"; : "${LILU:?set LILU to Lilu.kext (DEBUG build, has Contents/Resources/Headers)}"
HERE="$(cd "$(dirname "$0")" && pwd)"; WORK="$HERE/work"; rm -rf "$WORK"; mkdir -p "$WORK"
git clone -q --branch 1.0.3 https://github.com/acidanthera/BrightnessKeys "$WORK/src"
(cd "$WORK/src" && git apply "$HERE/0001-volume-mute-acpi-codes.patch")
K="$WORK/BrightnessKeys-UX325.kext"; mkdir -p "$K/Contents/MacOS"
cat > "$WORK/info.c" <<'EOC'
#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(as.acidanthera.BrightnessKeys, "1.0.3", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOC
F=(-arch x86_64 -O2 -fno-builtin -fno-asynchronous-unwind-tables -mno-red-zone -nostdinc -DKERNEL -DKERNEL_PRIVATE
   -D__APPLE__ -D__MACH__ "-I$SDK/Headers" "-I$LILU/Contents/Resources" -mmacosx-version-min=10.11 -DAPPLE_KEXT_ASSERTIONS=1
   -DDRIVER_PRIVATE -DAPPLE -DNeXT -fno-common -DPRODUCT_NAME=BrightnessKeys -DMODULE_VERSION=1.0.3)
xcrun clang++ -std=c++17 -fapple-kext -fno-exceptions -fno-rtti "${F[@]}" -c "$WORK/src/BrightnessKeys/BrightnessKeys.cpp" -o "$WORK/bk.o"
xcrun clang "${F[@]}" -c "$WORK/info.c" -o "$WORK/info.o"
xcrun ld -arch x86_64 -kext -undefined dynamic_lookup -no_fixup_chains -macos_version_min 10.11 \
  -o "$K/Contents/MacOS/BrightnessKeys" "$WORK/bk.o" "$WORK/info.o" "$SDK/Library/x86_64/libkmod.a"
xcrun strip -S "$K/Contents/MacOS/BrightnessKeys"
cp "$WORK/src/BrightnessKeys/Info.plist" "$K/Contents/Info.plist"
for k in CFBundleExecutable:BrightnessKeys CFBundleIdentifier:as.acidanthera.BrightnessKeys CFBundleName:BrightnessKeys \
         CFBundleVersion:1.0.3 CFBundleShortVersionString:1.0.3; do
  /usr/libexec/PlistBuddy -c "Set :${k%%:*} ${k#*:}" "$K/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :${k%%:*} string ${k#*:}" "$K/Contents/Info.plist"
done
echo "built $K"
