// ZenBookHelper v8.2 - headless helper for the ASUS ZenBook 13 OLED (UX325EA) Hackintosh
//
// Daemons (started by LaunchAgents, no menu bar item, no Dock icon):
//   ZenBookHelper --brightness   OLED brightness: catches Fn+F4/F5 (NX brightness keys from
//                                AsusSMC, F14/F15 from BrightnessKeys), Ctrl+Option+Up/Down,
//                                the Control Center slider (if present), dims the panel with a
//                                gamma table (or a black overlay if gamma is not honoured),
//                                shows a sun HUD. Duplicate events < 70 ms apart = one step.
//   ZenBookHelper --numberpad    ASUS NumberPad 2.0: hold the top-right icon 1 s to toggle,
//                                LED grid via HID feature report 0x0D, taps on the grid type
//                                keypad keys (layout up5401ea), hold top-left icon = LED level.
// CLI:
//   up | down | set <5-100> | status | mode <overlay|gamma|auto> | native <on|off> | hud <on|off>
//   twofinger <left|right> | numpad <on|off|toggle|probe> | powerbutton <sleep|off> | selftest
//
// Build (universal):  see build.sh next to this file.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <signal.h>
#include <math.h>
#include <objc/message.h>

#define ZB_VERSION "8.15"
static NSString *const kSuite   = @"com.zenbook.helper.settings";
static NSString *const kCmdNote = @"com.zenbook.helper.cmd";
static const float kMinLevel  = 0.10f;   // never go fully black on the OLED
static const float kStep      = 1.0f / 16.0f;
static const double kDedupWin = 0.07;    // same press arriving over 2 paths

static NSString *gLogName = @"ZenBookHelper";
static NSUserDefaults *Defs(void) {
    static NSUserDefaults *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:kSuite]; });
    return d;
}

static void ZLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ZLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", [df stringFromDate:[NSDate date]], gLogName, msg];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    NSString *path = [dir stringByAppendingPathComponent:@"ZenBookHelper.log"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 512 * 1024) {
        NSString *old = [path stringByAppendingString:@".1"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:path toPath:old error:nil];
    }
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
    fputs(line.UTF8String, stderr);
}

static void RunTool(NSString *path, NSArray<NSString *> *args) {
    @try {
        NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
        [t launch]; [t waitUntilExit];
    } @catch (NSException *e) { ZLog(@"task %@ failed: %@", path, e.reason); }
}

// Stop launchd restart loops: 5 starts within 5 minutes -> exit(0) (KeepAlive ignores clean exits)
static void CrashLoopGuard(NSString *key) {
    double now = CFAbsoluteTimeGetCurrent();
    NSMutableArray *starts = [NSMutableArray array];
    for (NSNumber *t in [Defs() arrayForKey:key] ?: @[]) if (now - t.doubleValue < 300) [starts addObject:t];
    [starts addObject:@(now)];
    [Defs() setObject:starts forKey:key]; [Defs() synchronize];
    if (starts.count >= 5) { ZLog(@"%@: started %lu times in 5 min - stopping to avoid a crash loop (run fix-hardware.sh again to reset)", key, (unsigned long)starts.count); exit(0); }
}

// =============================================================================
#pragma mark - Pure logic (unit-tested by `selftest`)
// =============================================================================
typedef struct { int maxX, maxY; } ZAxisMax;

// Minimal HID report-descriptor walk: logical maximum of Generic Desktop X (0x30) / Y (0x31)
// HID report-descriptor walk: logical maximum of ABSOLUTE Generic Desktop X (0x30) / Y (0x31)
// inside a Digitizer (0x0D) collection. v8.4: v8.3 took the first X/Y it saw, which on the
// ELAN 04F3:3134 is the relative mouse collection (max 127) -> the whole pad became an icon.
static ZAxisMax ZParseXYMax(const uint8_t *d, size_t len) {
    ZAxisMax r = {0, 0};
    uint32_t usagePage = 0; int32_t logMax = 0;
    uint32_t gStackPage[8]; int32_t gStackMax[8]; int sp = 0;
    uint32_t usages[32]; int nUsages = 0;
    uint32_t collPage[16]; int csp = 0;
    size_t i = 0;
    while (i < len) {
        uint8_t b = d[i];
        if (b == 0xFE) { if (i + 2 >= len) break; i += 3 + d[i + 1]; continue; }   // long item
        int size = (b & 0x03) == 3 ? 4 : (b & 0x03);
        int type = (b >> 2) & 0x03, tag = (b >> 4) & 0x0F;
        if (i + (size_t)size >= len) break;
        uint32_t uval = 0;
        for (int k = 0; k < size; k++) uval |= (uint32_t)d[i + 1 + k] << (8 * k);
        int32_t sval = (int32_t)uval;
        if (size == 1) sval = (int8_t)uval; else if (size == 2) sval = (int16_t)uval;
        if (type == 1) {                       // global
            if (tag == 0x0) usagePage = uval;
            else if (tag == 0x2) logMax = (size == 4 || sval >= 0) ? sval : (int32_t)uval;
            else if (tag == 0xA && sp < 8) { gStackPage[sp] = usagePage; gStackMax[sp] = logMax; sp++; }
            else if (tag == 0xB && sp > 0) { sp--; usagePage = gStackPage[sp]; logMax = gStackMax[sp]; }
        } else if (type == 2) {                // local
            if (tag == 0x0 && nUsages < 32) usages[nUsages++] = (size == 4) ? uval : ((usagePage << 16) | uval);
        } else if (type == 0) {                // main
            if (tag == 0xA) {                  // Collection: remember its usage page
                uint32_t cp = nUsages ? (usages[0] >> 16) : usagePage;
                if (csp < 16) collPage[csp++] = cp;
            } else if (tag == 0xC) {           // End Collection
                if (csp > 0) csp--;
            } else if (tag == 0x8 && !(uval & 0x04)) {   // absolute Input
                BOOL inDigitizer = NO;
                for (int c = 0; c < csp; c++) if (collPage[c] == 0x0D) inDigitizer = YES;
                if (inDigitizer) for (int u = 0; u < nUsages; u++) {
                    if (usages[u] == 0x00010030 && logMax > r.maxX) r.maxX = logMax;
                    if (usages[u] == 0x00010031 && logMax > r.maxY) r.maxY = logMax;
                }
            }
            nUsages = 0;
        }
        i += 1 + size;
    }
    return r;
}

// NumberPad geometry (layout up5401ea, raw units from asus-numberpad-driver)
typedef struct { double left, right, top, bottom, iconW, iconH, mx, my; } ZPadGeom;
static ZPadGeom ZGeomFor(ZAxisMax m) {
    // sanity: a touchpad axis is never < 1000 units; anything smaller is a mouse axis
    double mx = m.maxX >= 1000 ? m.maxX : 3200.0, my = m.maxY >= 500 ? m.maxY : 2000.0;
    ZPadGeom g = { 200.0 / mx, 200.0 / mx, 200.0 / my, 80.0 / my, 250.0 / mx, 250.0 / my, mx, my };
    return g;
}
enum { ZRegionNone = -1, ZRegionTopRight = -2, ZRegionTopLeft = -3 };
// x,y normalised 0..1, y measured from the TOP edge. Returns cell index row*5+col, or a region.
static int ZRegionAt(double x, double y, ZPadGeom g) {
    if (x >= 1.0 - g.iconW && y <= g.iconH) return ZRegionTopRight;
    if (x <= g.iconW && y <= g.iconH) return ZRegionTopLeft;
    double x0 = g.left, x1 = 1.0 - g.right, y0 = g.top, y1 = 1.0 - g.bottom;
    if (x < x0 || x >= x1 || y < y0 || y >= y1) return ZRegionNone;
    int col = (int)floor((x - x0) / ((x1 - x0) / 5.0));
    int row = (int)floor((y - y0) / ((y1 - y0) / 4.0));
    if (col < 0 || col > 4 || row < 0 || row > 3) return ZRegionNone;
    return row * 5 + col;
}
// keypad virtual keycodes for the 4x5 grid; 0xFFFF = percent (shift+5)
static const uint16_t kPadKeys[20] = {
    0x59, 0x5B, 0x5C, 0x4B, 0x33,     // 7 8 9 / Backspace
    0x56, 0x57, 0x58, 0x43, 0x33,     // 4 5 6 * Backspace
    0x53, 0x54, 0x55, 0x4E, 0xFFFF,   // 1 2 3 - %
    0x52, 0x41, 0x4C, 0x45, 0x51 };   // 0 . Enter + =
static const char *kPadNames[20] = { "7","8","9","/","BS", "4","5","6","*","BS",
                                     "1","2","3","-","%", "0",".","Enter","+","=" };

// Duplicate filter: events from DIFFERENT sources with the same direction within kDedupWin
typedef struct { double t[8]; int dir[8]; } ZDedup;
static BOOL ZDedupAccept(ZDedup *d, int src, int dir, double now) {
    for (int s = 0; s < 8; s++)
        if (s != src && d->dir[s] == dir && now - d->t[s] < kDedupWin) { d->t[src] = now; d->dir[src] = dir; return NO; }
    d->t[src] = now; d->dir[src] = dir; return YES;
}
static float ZClampLevel(float v) { return v < kMinLevel ? kMinLevel : (v > 1.0f ? 1.0f : v); }
// v8.13: the same 17-point perceptual brightness curve macOS uses for this panel (WhateverXe
// F19 profile, PNLF UID 19). Level 0..1 -> fraction of the panel maximum. Step 1 of 16 is
// ~1% (about 6 nits on this OLED), step 8 ~8%, step 16 = 100% - like a MacBook's keys.
static const uint16_t kCurve[17] = { 0x0000, 0x028F, 0x0353, 0x045A, 0x05A1, 0x07AE, 0x0A3D, 0x0E14, 0x1374,
                                     0x1A5E, 0x2418, 0x31A9, 0x4459, 0x5E76, 0x8311, 0xB6C7, 0xFF7B };
static double ZCurve(float level) {
    double p = (level < 0 ? 0 : (level > 1 ? 1 : level)) * 16.0; int i = (int)floor(p); if (i >= 16) return 1.0;
    double a = kCurve[i], b = kCurve[i + 1]; return (a + (b - a) * (p - i)) / (double)kCurve[16];
}
// A held key repeats every ~80 ms: accept a press only after 0.3 s without any event.
static BOOL ZPressAccept(double *last, double now) { BOOL ok = (now - *last) > 0.30; *last = now; return ok; }
static float ZStepLevel(float cur, int dir) {
    float q = roundf(cur * 16.0f) / 16.0f;
    return ZClampLevel(q + dir * kStep);
}

// =============================================================================
#pragma mark - Real mute (v8.9)
// =============================================================================
// The ALC294 layout accepts the mute flag (the OSD shows "muted") but the speaker amp keeps
// playing. Watch the built-in output's mute flag and enforce it with the volume:
// muted -> remember volume, set 0; unmuted -> restore. Any mute source works (keys, menu).
static AudioObjectPropertyAddress ZAddr(AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { sel, sc, kAudioObjectPropertyElementMain }; return a;
}
static AudioDeviceID ZDefaultOut(void) {
    AudioObjectPropertyAddress a = ZAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioDeviceID d = 0; UInt32 sz = sizeof(d);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d) == noErr ? d : 0;
}
static BOOL ZBuiltIn(AudioDeviceID d) {
    AudioObjectPropertyAddress a = ZAddr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
    UInt32 t = 0, sz = sizeof(t);
    return d && AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &t) == noErr && t == kAudioDeviceTransportTypeBuiltIn;
}
static BOOL ZMuted(AudioDeviceID d) {
    for (UInt32 el = 0; el <= 2; el++) {      // main element, then channels 1/2
        AudioObjectPropertyAddress a = { kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el };
        UInt32 m = 0, sz = sizeof(m);
        if (AudioObjectHasProperty(d, &a) && AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &m) == noErr) return m != 0;
    }
    return NO;
}
static float ZVolume(AudioDeviceID d);
static NSString *ZAudioReport(void) {
    AudioDeviceID d = ZDefaultOut(); NSMutableString *r = [NSMutableString string];
    AudioObjectPropertyAddress na = ZAddr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    CFStringRef name = NULL; UInt32 sz = sizeof(name);
    AudioObjectGetPropertyData(d, &na, 0, NULL, &sz, &name);
    [r appendFormat:@"default output %u \"%@\" built-in %d volume %.2f\n", (unsigned)d, name ? (__bridge NSString *)name : @"?", ZBuiltIn(d), ZVolume(d)];
    if (name) CFRelease(name);
    for (UInt32 el = 0; el <= 2; el++) {
        AudioObjectPropertyAddress a = { kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el };
        UInt32 m = 0; sz = sizeof(m); Boolean settable = false;
        BOOL has = AudioObjectHasProperty(d, &a);
        if (has) { AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &m); AudioObjectIsPropertySettable(d, &a, &settable); }
        [r appendFormat:@"  mute element %u: %@\n", (unsigned)el, has ? [NSString stringWithFormat:@"%u (settable %d)", (unsigned)m, settable] : @"not present"];
    }
    return r;
}
static float ZVolume(AudioDeviceID d) {
    AudioObjectPropertyAddress a = ZAddr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput);
    Float32 v = -1; UInt32 sz = sizeof(v); return AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v) == noErr ? v : -1;
}
static BOOL ZSetVolume(AudioDeviceID d, float v) {
    AudioObjectPropertyAddress a = ZAddr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput);
    Float32 f = v; return AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(f), &f) == noErr;
}
// v8.10: on this Hackintosh DisplayServices does not see the panel; only the IODisplay
// "bklt" parameter of AppleBacklightDisplay exists. Writing it reaches the framebuffer's
// hwSetBacklight(), which the v3 driver turns into real OLED brightness (VESA AUX).
static BOOL ZBklt(SInt32 *cur, SInt32 *mx, SInt32 setValue /* -1 = read only */) {
    io_iterator_t it = 0; BOOL found = NO;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it) != KERN_SUCCESS) return NO;
    io_service_t sv;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    while ((sv = IOIteratorNext(it))) {
        SInt32 c = 0, mn = 0, m = 0;
        if (!found && IODisplayGetIntegerRangeParameter(sv, kNilOptions, CFSTR("bklt"), &c, &mn, &m) == kIOReturnSuccess && m > 0) {
            found = YES;
            if (setValue >= 0) {
                IODisplaySetIntegerParameter(sv, kNilOptions, CFSTR("bklt"), setValue > m ? m : setValue);
                IODisplayCommitParameters(sv, kNilOptions); c = setValue > m ? m : setValue;
            }
            if (cur) *cur = c; if (mx) *mx = m;
        }
        IOObjectRelease(sv);
    }
#pragma clang diagnostic pop
    IOObjectRelease(it);
    return found;
}

static void ShowNotice(NSString *symbol, NSString *text);
// v8.13: the real macOS on-screen bezel (same as a MacBook) via the private OSDManager.
// image 1 = brightness, 3 = speaker, 4 = speaker muted. NO when unavailable.
static BOOL ZShowOSD(long long image, unsigned filled, unsigned total) {
    static id mgr; static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY);
        Class c = NSClassFromString(@"OSDManager"); SEL sm = NSSelectorFromString(@"sharedManager");
        if (c && [c respondsToSelector:sm]) mgr = ((id (*)(id, SEL))objc_msgSend)(c, sm);
        ZLog(@"macOS OSD bezel %@", mgr ? @"available" : @"not available - helper bezel used");
    });
    SEL sel = NSSelectorFromString(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    if (!mgr || ![mgr respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, long long, CGDirectDisplayID, unsigned, unsigned, unsigned, unsigned, BOOL))objc_msgSend)
        (mgr, sel, image, CGMainDisplayID(), 0x1F4, 1000, filled, total, NO);
    return YES;
}

@interface ZMute : NSObject
- (void)start;
- (void)muteKey;
@end
@implementation ZMute { AudioDeviceID _dev; float _saved; BOOL _enforcing; BOOL _softMuted; double _keyAt, _keySeen; int _repeats; }
// v8.11: the mute key itself toggles a real mute (volume 0 / restore), whatever the codec does
// v8.13: one press = one toggle (a held key used to flip mute ~10 times), and the macOS bezel
// is shown for unmute too (the speaker with the restored volume level).
- (void)muteKey {
    double now = CFAbsoluteTimeGetCurrent();
    if (!ZPressAccept(&_keySeen, now)) { if (_repeats++ < 3) ZLog(@"mute key: repeat ignored"); return; }
    _keyAt = now;
    AudioDeviceID d = ZDefaultOut();
    if (!ZBuiltIn(d)) return;
    _dev = d;
    float v = ZVolume(d);
    if (_softMuted && v > 0.001f) _softMuted = NO;              // volume was raised meanwhile: mute again
    BOOL muted;
    if (!_softMuted) {
        if (v > 0.001f) _saved = v;
        ZSetVolume(d, 0); _softMuted = YES; muted = YES; v = 0;
        ZLog(@"mute key: speakers silenced (volume %.2f saved)", _saved);
    } else {
        v = _saved > 0.001f ? _saved : 0.5f;
        ZSetVolume(d, v); _softMuted = NO; muted = NO;
        ZLog(@"mute key: volume %.2f restored", v); _saved = 0;
    }
    unsigned filled = muted ? 0 : (unsigned)MAX(1, lroundf(v * 16));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!ZShowOSD(muted ? 4 : 3, filled, 16))
            ShowNotice(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", muted ? @"Muted" : @"Sound on");
    });
}
- (void)start {
    AudioObjectPropertyAddress def = ZAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, dispatch_get_main_queue(),
        ^(UInt32 n, const AudioObjectPropertyAddress *a) { [self attach]; });
    [self attach];
}
- (void)attach {
    AudioDeviceID d = ZDefaultOut();
    if (d == _dev) return;
    _dev = d;
    if (!ZBuiltIn(d)) { ZLog(@"mute: default output is not built-in - hardware mute used"); return; }
    AudioObjectPropertyAddress m = ZAddr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput);
    AudioObjectAddPropertyListenerBlock(d, &m, dispatch_get_main_queue(),
        ^(UInt32 n, const AudioObjectPropertyAddress *a) { if (d == self->_dev) [self enforce]; });
    ZLog(@"mute: watching built-in output (muted %d, volume %.2f)", ZMuted(d), ZVolume(d));
    [self enforce];
}
- (void)enforce {
    if (_enforcing || !_dev) return;
    if (CFAbsoluteTimeGetCurrent() - _keyAt < 0.8) return;     // the key handler owns this change
    if (_softMuted && ZVolume(_dev) > 0.001f) { _softMuted = NO; _saved = 0; }   // user raised the volume
    _enforcing = YES;
    float v = ZVolume(_dev);
    if (ZMuted(_dev)) {
        if (v > 0.001f) { _saved = v; ZSetVolume(_dev, 0); ZLog(@"mute: ON -> speakers silenced (volume %.2f saved)", v); }
    } else if (_saved > 0.001f && v < 0.001f) {
        ZSetVolume(_dev, _saved); ZLog(@"mute: OFF -> volume %.2f restored", _saved); _saved = 0;
    } else if (v > 0.001f) _saved = 0;
    _enforcing = NO;
}
@end

// v8.15: lid wake evidence - driver counters, clamshell state, display sleep state
static BOOL ZWexLast(uint64_t out[9]) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    CFTypeRef p = root ? IORegistryEntryCreateCFProperty(root, CFSTR("WEXTGLEDPBacklightLast"), kCFAllocatorDefault, 0) : NULL;
    BOOL ok = p && CFGetTypeID(p) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)p) >= 72;
    if (ok) CFDataGetBytes((CFDataRef)p, CFRangeMake(0, 72), (UInt8 *)out);
    if (p) CFRelease(p);
    return ok;
}
static int ZClamshell(void) {
    io_service_t pm = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!pm) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(pm, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(pm);
    int r = v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v) : -1;
    if (v) CFRelease(v);
    return r;
}

// =============================================================================
#pragma mark - Brightness daemon
// =============================================================================
typedef int  (*DSGetFn)(CGDirectDisplayID, float *);
typedef int  (*DSSetFn)(CGDirectDisplayID, float);
static DSGetFn DSGet; static DSSetFn DSSet;
enum { SrcHotkey = 0, SrcNX, SrcFKey, SrcCLI, SrcNative, SrcFKeyHK };
static const char *kSrcNames[] = { "ctrl-option-hotkey", "nx-brightness-key", "f14/f15-key(tap)", "cli", "native-slider", "f14/f15-key(hotkey)" };

// v8.8: the patched Iris Xe driver (WhateverXe-UX325 v3, -wex-tgl-edp-bl) drives the OLED's
// real brightness over DPCD (VESA eDP AUX). It publishes WEXTGLEDPBacklightCaps on the
// IORegistry root; first value 1 = AUX brightness active. Then macOS' own brightness
// (keys, slider, OSD) changes the panel itself and the black overlay must stay off.
static BOOL ZDriverAUXBacklight(void) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return NO;
    CFTypeRef p = IORegistryEntryCreateCFProperty(root, CFSTR("WEXTGLEDPBacklightCaps"), kCFAllocatorDefault, 0);
    BOOL on = NO;
    if (p && CFGetTypeID(p) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)p) >= 8) {
        uint64_t st = 0; CFDataGetBytes((CFDataRef)p, CFRangeMake(0, 8), (UInt8 *)&st); on = (st == 1);
    }
    if (p) CFRelease(p);
    IOObjectRelease(root);
    return on;
}

@interface ZHUDView : NSView
@property float value;
@property (strong) NSImage *sun;
@end
@implementation ZHUDView
- (void)drawRect:(NSRect)r {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:18 yRadius:18];
    [[NSColor colorWithWhite:0.10 alpha:0.82] setFill]; [bg fill];
    if (self.sun) {
        NSRect ir = NSMakeRect((self.bounds.size.width - 84) / 2, 66, 84, 84);
        [self.sun drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    }
    int filled = (int)lroundf(self.value * 16.0f);
    CGFloat segW = 9, gap = 1.5, total = 16 * segW + 15 * gap, x0 = (self.bounds.size.width - total) / 2;
    for (int i = 0; i < 16; i++) {
        NSRect s = NSMakeRect(x0 + i * (segW + gap), 28, segW, 8);
        [(i < filled ? NSColor.whiteColor : [NSColor colorWithWhite:1 alpha:0.18]) setFill];
        NSRectFill(s);
    }
}
@end

// Small notice HUD (symbol + text) used by the NumberPad daemon
@interface ZNoticeView : NSView
@property (copy) NSString *text; @property (strong) NSImage *icon;
@end
@implementation ZNoticeView
- (void)drawRect:(NSRect)r {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:18 yRadius:18];
    [[NSColor colorWithWhite:0.10 alpha:0.85] setFill]; [bg fill];
    if (self.icon) [self.icon drawInRect:NSMakeRect((self.bounds.size.width - 64) / 2, 62, 64, 64) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    [self.text drawInRect:NSMakeRect(8, 22, self.bounds.size.width - 16, 26) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: ps }];
}
@end
static NSImage *WhiteSymbol(NSString *name, CGFloat side) {
    NSImage *sym = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!sym) return nil;
    sym = [sym imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:side weight:NSFontWeightRegular]];
    return [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rr) {
        NSSize s = sym.size; CGFloat k = MIN(rr.size.width / s.width, rr.size.height / s.height);
        [sym drawInRect:NSMakeRect((rr.size.width - s.width * k) / 2, (rr.size.height - s.height * k) / 2, s.width * k, s.height * k)];
        [NSColor.whiteColor set]; NSRectFillUsingOperation(rr, NSCompositingOperationSourceAtop); return YES; }];
}
static void ShowNotice(NSString *symbol, NSString *text) {
    static NSWindow *w; static ZNoticeView *v; static NSTimer *timer;
    if (!w) {
        w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 220, 150) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        w.releasedWhenClosed = NO; w.opaque = NO; w.backgroundColor = NSColor.clearColor; w.hasShadow = NO;
        w.ignoresMouseEvents = YES; w.level = CGShieldingWindowLevel() + 1;
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
        v = [[ZNoticeView alloc] initWithFrame:NSMakeRect(0, 0, 220, 150)]; w.contentView = v;
    }
    v.icon = WhiteSymbol(symbol, 64); v.text = text; [v setNeedsDisplay:YES];
    NSScreen *s = NSScreen.mainScreen ?: NSScreen.screens.firstObject; NSRect f = s.frame;
    [w setFrameOrigin:NSMakePoint(NSMidX(f) - 110, NSMinY(f) + f.size.height * 0.14)];
    [w orderFrontRegardless];
    [timer invalidate];
    timer = [NSTimer scheduledTimerWithTimeInterval:1.4 repeats:NO block:^(NSTimer *t) { [w orderOut:nil]; }];
}

@interface ZBrightness : NSObject
@end
@implementation ZBrightness {
    float _level; float _lastNative; double _lastNativeWrite;
    BOOL _nativeLogged, _gammaOK, _gammaLogged; NSString *_activeMode;
    BOOL _driverNative; double _lastNXTime; int _lastNXDir; ZMute *_mute;
    double _wakeAt, _macKeysAt; int _wakeKeys; double _sampleT[8]; float _sampleV[8]; int _sampleN;
    ZDedup _dedup;
    NSMutableArray<NSWindow *> *_overlays;
    NSWindow *_hud; ZHUDView *_hudView; NSTimer *_hudTimer;
    CFMachPortRef _tap; CFRunLoopSourceRef _tapSrc;
    dispatch_source_t _sigSrc[3];
}

static OSStatus HotKeyCB(EventHandlerCallRef next, EventRef ev, void *ud) {
    EventHotKeyID hk; GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    ZBrightness *b = (__bridge ZBrightness *)ud;
    int dir = (hk.id == 1 || hk.id == 3) ? +1 : -1;
    int src = (hk.id <= 2) ? SrcFKeyHK : SrcHotkey;
    dispatch_async(dispatch_get_main_queue(), ^{ [b step:dir source:src]; });
    return noErr;
}

static CGEventRef TapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ud) {
    ZBrightness *b = (__bridge ZBrightness *)ud;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) { [b reenableTap]; return ev; }
    if (type == 14 /* NX_SYSDEFINED */) {
        NSEvent *e = [NSEvent eventWithCGEvent:ev];
        if (e.subtype == 1 /* NX_SUBTYPE_POWER_KEY */) { [b powerKey:(int)e.data1]; return ev; }
        if (e.subtype != 8 && e.subtype != 7) {
            static int seen[32]; int st = (int)e.subtype & 31;
            if (seen[st]++ < 3) ZLog(@"system key event subtype %d data1 0x%lX", (int)e.subtype, (long)e.data1);
        }
        if (e.subtype == 8) {
            NSInteger dk = e.data1; int kc = (int)((dk & 0xFFFF0000) >> 16);
            if (kc == 6 /* NX_POWER_KEY */ && (((dk & 0xFF00) >> 8) == 0x0A)) { [b powerKey:-1]; return ev; }
        }
        if (e.subtype == 8) {
            NSInteger d1 = e.data1;
            int code = (int)((d1 & 0xFFFF0000) >> 16);
            BOOL down = (((d1 & 0xFF00) >> 8) == 0x0A), rep = (d1 & 0x1) != 0;
            if (down) [b noteKey:code repeat:rep];
            if (down && !rep && code == 7) [b muteKey];           // NX_KEYTYPE_MUTE (held key: once)
            if (down && code == 2) [b step:+1 source:SrcNX];      // NX_KEYTYPE_BRIGHTNESS_UP
            if (down && code == 3) [b step:-1 source:SrcNX];      // NX_KEYTYPE_BRIGHTNESS_DOWN
        }
    } else if (type == kCGEventKeyDown) {
        int64_t kc = CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (CGEventGetIntegerValueField(ev, kCGKeyboardEventAutorepeat)) return ev;
        if (kc == 0x71) [b step:+1 source:SrcFKey];
        if (kc == 0x6B) [b step:-1 source:SrcFKey];
    }
    return ev;
}

- (instancetype)init {
    if ((self = [super init])) { _overlays = [NSMutableArray new]; _lastNative = -1; _activeMode = @""; }
    return self;
}

- (void)start {
    void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (ds) { DSGet = (DSGetFn)dlsym(ds, "DisplayServicesGetBrightness"); DSSet = (DSSetFn)dlsym(ds, "DisplayServicesSetBrightness"); }
    float saved = [Defs() objectForKey:@"level"] ? [Defs() floatForKey:@"level"] : 1.0f;
    _level = ZClampLevel(MAX(saved, 0.30f));                // never start very dark
    ZLog(@"brightness daemon v%s start, level %.0f%%, mode %@", ZB_VERSION, _level * 100, [self mode]);
    CrashLoopGuard(@"brightnessStarts");

    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&HotKeyCB, 1, &spec, (__bridge void *)self, NULL);
    struct { UInt32 key, mods, id; const char *name; } hks[] = {
        { 0x71, 0, 1, "F15 (brightness up)" }, { 0x6B, 0, 2, "F14 (brightness down)" },
        { 0x7E, controlKey | optionKey, 3, "Ctrl+Option+Up" }, { 0x7D, controlKey | optionKey, 4, "Ctrl+Option+Down" } };
    for (int i = 0; i < 4; i++) {
        EventHotKeyRef ref; EventHotKeyID hid = { 'ZBHK', hks[i].id };
        OSStatus st = RegisterEventHotKey(hks[i].key, hks[i].mods, hid, GetApplicationEventTarget(), 0, &ref);
        ZLog(@"hotkey %s: %@", hks[i].name, st == noErr ? @"registered" : [NSString stringWithFormat:@"failed (%d)", (int)st]);
    }

    [self refreshDriver];
    [self installTap];
    _mute = [ZMute new]; [_mute start];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { if (!self->_tap) [self installTap]; [self refreshDriver]; }];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(pollNative) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(reassert) userInfo:nil repeats:YES];

    NSNotificationCenter *wc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSString *n in @[NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification, NSWorkspaceSessionDidBecomeActiveNotification])
        [wc addObserver:self selector:@selector(wakeOrSwitch:) name:n object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(command:) name:kCmdNote object:nil
                                                 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    int sigs[3] = { SIGTERM, SIGINT, SIGHUP };
    for (int i = 0; i < 3; i++) {
        signal(sigs[i], SIG_IGN);
        _sigSrc[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(_sigSrc[i], ^{ ZLog(@"signal - restoring full brightness and exiting"); CGDisplayRestoreColorSyncSettings(); exit(0); });
        dispatch_resume(_sigSrc[i]);
    }
    [self apply];
    [self saveStatus];
    // GPU (WhateverXe) mode: a real backlight display appears and can come up at 0 -> black OLED.
    for (NSNumber *t in @[@3, @12, @30, @60, @100])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self nativeRescue]; });
}

// v8.6: with the Iris Xe driver active, macOS registers AppleBacklightDisplay and its
// backlight parameter "bklt" came up at 0 (GPU test #2: PWM duty 0 -> black OLED).
- (void)nativeRescue {
    float target = MAX(_level, 0.8f), v = -1, after = -1;
    BOOL ds = DSGet && DSGet(CGMainDisplayID(), &v) == 0 && v >= 0;
    if (ds && v >= 0.05f) return;
    if (ds && DSSet) {
        DSSet(CGMainDisplayID(), target); DSGet(CGMainDisplayID(), &after);
        ZLog(@"native backlight was %.3f -> DisplayServices set %.2f -> now %.3f", v, target, after);
    }
    // v8.7: also when DisplayServices is unavailable (GPU test #3: DSGet failed, bklt stayed 0).
    // In -wexoff mode there is no AppleBacklightDisplay, so no "bklt" parameter exists: no-op.
    if (after < 0.05f) {                                            // write the IODisplay parameter directly
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it) == KERN_SUCCESS) {
            io_service_t sv;
            while ((sv = IOIteratorNext(it))) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                SInt32 cur = 0, mn = 0, mx = 0;
                if (IODisplayGetIntegerRangeParameter(sv, kNilOptions, CFSTR("bklt"), &cur, &mn, &mx) == kIOReturnSuccess && mx > 0 &&
                    cur < (SInt32)(mx * 0.05f)) {
                    IOReturn r = IODisplaySetIntegerParameter(sv, kNilOptions, CFSTR("bklt"), (SInt32)(mx * target));
                    IODisplayCommitParameters(sv, kNilOptions);
                    IODisplayGetIntegerRangeParameter(sv, kNilOptions, CFSTR("bklt"), &cur, &mn, &mx);
                    ZLog(@"IODisplay bklt set to %d/%d (0x%08X), now %d", (int)(mx * target), (int)mx, r, (int)cur);
                }
#pragma clang diagnostic pop
                IOObjectRelease(sv);
            }
            IOObjectRelease(it);
        }
    }
    [self saveStatus];
}

// v8.3: default = overlay. In -wexoff mode WindowServer accepts gamma tables but the basic
// framebuffer never applies them (confirmed on the UX325EA: HUD moved, panel did not dim).
// On an OLED, darkening the pixels lowers the emitted light physically.
// v8.12: software dimming (black overlay / gamma) removed by default - the brightness keys
// drive the panel's real brightness through the Iris Xe driver. Only an explicit
// `zenbook-helper mode overlay|gamma|auto` brings the old dimming back.
- (NSString *)mode {
    if (![Defs() boolForKey:@"dimForced"]) return @"none";
    NSString *m = [Defs() stringForKey:@"mode"]; return m.length ? m : @"none";
}

- (void)installTap {
    if (!CGPreflightListenEventAccess()) {
        static BOOL asked; if (!asked) { asked = YES; CGRequestListenEventAccess(); ZLog(@"requested Input Monitoring permission (System Settings > Privacy & Security > Input Monitoring > ZenBookHelper)"); }
    }
    CGEventMask mask = CGEventMaskBit(14) | CGEventMaskBit(kCGEventKeyDown);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, TapCB, (__bridge void *)self);
    if (!_tap) _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, TapCB, (__bridge void *)self);
    if (_tap) {
        _tapSrc = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _tapSrc, kCFRunLoopCommonModes);
        CGEventTapEnable(_tap, true);
        ZLog(@"event tap active (NX brightness keys + F14/F15)");
    } else {
        static BOOL logged; if (!logged) { logged = YES; ZLog(@"event tap NOT available yet - waiting for Input Monitoring permission (F14/F15 hotkeys still work)"); }
    }
    [self saveStatus];
}
- (void)reenableTap { if (_tap) CGEventTapEnable(_tap, true); }
// v8.13: evidence for "keys dead after sleep": log the first media keys after each wake
- (void)noteKey:(int)code repeat:(BOOL)rep {
    if (rep || CFAbsoluteTimeGetCurrent() - _wakeAt > 120 || _wakeKeys >= 12) return;
    _wakeKeys++;
    const char *n = code == 0 ? "volume up" : code == 1 ? "volume down" : code == 7 ? "mute" : code == 2 ? "brightness up" : code == 3 ? "brightness down" : "other";
    ZLog(@"after wake: key %s (NX %d) received", n, code);
}

- (BOOL)nativeWanted { return [Defs() objectForKey:@"native"] == nil || [Defs() boolForKey:@"native"]; }
// macOS-native path (DisplayServices + system OSD) - only when DisplayServices can read the panel
- (BOOL)nativeActive {
    return _driverNative && DSGet && DSSet && [self nativeWanted] && [self nativeValue] >= 0;
}
// helper-driven real brightness via the IODisplay "bklt" parameter (DisplayServices blind)
- (BOOL)bkltActive {
    return _driverNative && [self nativeWanted] && ![self nativeActive] && ZBklt(NULL, NULL, -1);
}
- (void)refreshDriver {
    BOOL d = ZDriverAUXBacklight();
    if (d != _driverNative) {
        _driverNative = d;
        ZLog(@"Iris Xe driver AUX panel brightness: %@ -> %@", d ? @"active" : @"not active",
             [self nativeActive] ? @"native macOS brightness (overlay off)" :
             [self bkltActive] ? @"real panel brightness via bklt (overlay off)" : [NSString stringWithFormat:@"helper %@ dimming", [self mode]]);
        if ([self nativeActive]) { float v = [self nativeValue]; if (v >= 0) _level = v; }
        [self apply]; [self saveStatus];
    }
}
// Native mode: macOS itself handles the NX brightness keys (AsusSMC) with its own OSD.
// The same press also arrives as F14/F15 (BrightnessKeys, swallowed by our hotkeys), so an
// F14/F15 step is only taken when no NX key of that direction came within 150 ms.
- (void)nativeStep:(int)dir source:(int)src at:(double)now {
    if (src == SrcNX) {
        _lastNXTime = now; _lastNXDir = dir;
        ZLog(@"key %s %s -> macOS native brightness", kSrcNames[src], dir > 0 ? "up" : "down");
        return;
    }
    if (src == SrcFKey || src == SrcFKeyHK) {
        if (!ZDedupAccept(&_dedup, src, dir, now)) { ZLog(@"key %s %s merged (duplicate path)", kSrcNames[src], dir > 0 ? "up" : "down"); return; }
        if (now - _macKeysAt < 2.0) { _macKeysAt = now; return; }            // macOS is handling this burst
        // v8.13: the ASUS driver may hand the same press to macOS directly (native bezel).
        // Step ourselves only if the brightness did not move within ~0.25 s around the press.
        float before = [self sampleBefore:now - 0.45], v0 = [self nativeValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            float v1 = [self nativeValue];
            BOOL nx = self->_lastNXDir == dir && fabs(self->_lastNXTime - now) < 0.3;
            BOOL movedNow = v0 >= 0 && v1 >= 0 && (dir > 0 ? v1 > v0 + 0.004f : v1 < v0 - 0.004f);
            BOOL movedBefore = before >= 0 && v0 >= 0 && (dir > 0 ? v0 > before + 0.004f : v0 < before - 0.004f) &&
                               CFAbsoluteTimeGetCurrent() - self->_lastNativeWrite > 0.9;
            if (nx || movedNow || movedBefore) {
                self->_macKeysAt = now;
                ZLog(@"key %s %s handled by macOS itself", kSrcNames[src], dir > 0 ? "up" : "down"); return;
            }
            [self nativeApplyStep:dir source:src];
        });
        return;
    }
    [self nativeApplyStep:dir source:src];
}
- (void)muteKey { [_mute muteKey]; }
// v8.9: macOS receives the ZenBook power button (loginwindow handlePowerButtonEvent) but does
// nothing with it on this model. Like a MacBook: a short press puts the Mac to sleep.
- (void)powerKey:(int)data {
    NSString *pref = [Defs() stringForKey:@"powerbutton"];
    double now = CFAbsoluteTimeGetCurrent(); static double last;
    ZLog(@"power button event (0x%X), action %@", data, pref.length ? pref : @"sleep");
    if ([pref isEqualToString:@"off"] || now - last < 3.0) return;
    last = now;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZLog(@"power button -> sleep now"); RunTool(@"/usr/bin/pmset", @[@"sleepnow"]);
    });
}
- (float)sampleBefore:(double)t {
    float v = -1; double best = -1;
    for (int i = 0; i < 8 && i < _sampleN; i++) if (_sampleT[i] <= t && _sampleT[i] > best) { best = _sampleT[i]; v = _sampleV[i]; }
    return v;
}
- (void)nativeApplyStep:(int)dir source:(int)src {
    float v = [self nativeValue]; if (v < 0) v = _level;
    float nl = roundf(v * 16.0f) / 16.0f + dir * kStep; nl = nl < 0 ? 0 : (nl > 1 ? 1 : nl);
    ZLog(@"key %s %s -> native %.0f%%", kSrcNames[src], dir > 0 ? "up" : "down", nl * 100);
    [self setLevel:nl push:YES hud:YES];
}

- (void)step:(int)dir source:(int)src {
    double now = CFAbsoluteTimeGetCurrent();
    if ([self nativeActive]) { [self nativeStep:dir source:src at:now]; return; }
    if (!ZDedupAccept(&_dedup, src, dir, now)) { ZLog(@"key %s %s merged (duplicate path)", kSrcNames[src], dir > 0 ? "up" : "down"); return; }
    float nl = [self bkltActive] ? roundf(_level * 16.0f) / 16.0f + dir * kStep : ZStepLevel(_level, dir);
    ZLog(@"key %s %s -> %.0f%%", kSrcNames[src], dir > 0 ? "up" : "down", nl * 100);
    [self setLevel:nl push:YES hud:YES];
}

- (void)setLevel:(float)l push:(BOOL)push hud:(BOOL)hud {
    if ([self nativeActive]) _level = l < 0 ? 0 : (l > 1 ? 1 : l);
    else if ([self bkltActive]) _level = l < kStep ? kStep : (l > 1 ? 1 : l);   // darkest step ~1% (like a Mac)
    else _level = ZClampLevel(l);
    [self apply];
    BOOL hudEnabled = [Defs() objectForKey:@"hud"] == nil || [Defs() boolForKey:@"hud"];
    if (hud && hudEnabled && !(([self nativeActive] || [self bkltActive]) && ZShowOSD(1, (unsigned)lroundf(_level * 16), 16))) [self showHUD];
    if (push && DSSet) { DSSet(CGMainDisplayID(), _level); _lastNativeWrite = CFAbsoluteTimeGetCurrent(); _lastNative = _level; }
    [Defs() setFloat:_level forKey:@"level"];
    [self saveStatus];
}

- (BOOL)setGamma:(float)l {
    uint32_t n = 0; CGDirectDisplayID ids[8];
    CGGetActiveDisplayList(8, ids, &n);
    if (l >= 0.999f) { CGDisplayRestoreColorSyncSettings(); return YES; }
    CGGammaValue t[256];
    for (int i = 0; i < 256; i++) t[i] = (i / 255.0f) * l;
    BOOL ok = (n > 0);
    for (uint32_t k = 0; k < n; k++) {
        CGError e = CGSetDisplayTransferByTable(ids[k], 256, t, t, t);
        CGGammaValue r[256], g[256], b[256]; uint32_t cnt = 0;
        CGError e2 = CGGetDisplayTransferByTable(ids[k], 256, r, g, b, &cnt);
        BOOL thisOK = (e == kCGErrorSuccess && e2 == kCGErrorSuccess && cnt > 1 && fabsf(r[cnt - 1] - l) < 0.03f);
        if (!thisOK) ok = NO;
    }
    if (!_gammaLogged || ok != _gammaOK) { ZLog(@"gamma table %@", ok ? @"accepted by WindowServer" : @"NOT honoured -> overlay fallback in auto mode"); _gammaLogged = YES; }
    _gammaOK = ok;
    return ok;
}

- (void)apply {
    if ([self nativeActive]) {
        CGDisplayRestoreColorSyncSettings(); [self updateOverlay:0];
        _activeMode = @"native (panel brightness via Iris Xe driver)"; return;
    }
    if ([self bkltActive]) {
        CGDisplayRestoreColorSyncSettings(); [self updateOverlay:0];
        SInt32 cur = 0, mx = 0; ZBklt(&cur, &mx, -1);
        SInt32 want = (SInt32)lround(ZCurve(_level) * mx);
        if (mx > 0 && labs((long)(want - cur)) > 1) { ZBklt(NULL, NULL, want); ZLog(@"panel brightness (bklt) %d/%d = step %.0f/16", (int)want, (int)mx, _level * 16); }
        _activeMode = @"real panel brightness (bklt -> Iris Xe driver AUX)"; return;
    }
    NSString *m = [self mode];
    if ([m isEqualToString:@"none"]) {
        CGDisplayRestoreColorSyncSettings(); [self updateOverlay:0];
        _activeMode = _driverNative ? @"real panel brightness" : @"none (no software dimming)"; return;
    }
    float overlayAlpha = 0;
    if ([m isEqualToString:@"overlay"]) {
        CGDisplayRestoreColorSyncSettings();
        overlayAlpha = 1.0f - _level;
    } else {
        BOOL ok = [self setGamma:_level];
        if (!ok && [m isEqualToString:@"auto"]) { CGDisplayRestoreColorSyncSettings(); overlayAlpha = 1.0f - _level; }
    }
    _activeMode = overlayAlpha > 0 ? @"overlay" : (_level >= 0.999f ? @"none (100%)" : @"gamma");
    [self updateOverlay:overlayAlpha];
}

- (void)updateOverlay:(float)alpha {
    if (alpha < 0.005f) { for (NSWindow *w in _overlays) [w orderOut:nil]; return; }
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (_overlays.count != screens.count) {
        for (NSWindow *w in _overlays) [w orderOut:nil];
        [_overlays removeAllObjects];
        for (NSScreen *s in screens) {
            NSWindow *w = [[NSWindow alloc] initWithContentRect:s.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed = NO; w.backgroundColor = NSColor.blackColor; w.opaque = NO; w.hasShadow = NO;
            w.ignoresMouseEvents = YES; w.level = CGShieldingWindowLevel(); w.sharingType = NSWindowSharingNone;
            w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
            [w setFrame:s.frame display:NO];
            [_overlays addObject:w];
        }
    }
    for (NSWindow *w in _overlays) { w.alphaValue = alpha; [w orderFrontRegardless]; }
}

- (void)showHUD {
    if (!_hud) {
        _hud = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 200) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        _hud.releasedWhenClosed = NO; _hud.opaque = NO; _hud.backgroundColor = NSColor.clearColor; _hud.hasShadow = NO;
        _hud.ignoresMouseEvents = YES; _hud.level = CGShieldingWindowLevel() + 1;
        _hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
        _hudView = [[ZHUDView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
        NSImage *sym = [NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:@"Brightness"];
        if (sym) {
            sym = [sym imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:64 weight:NSFontWeightRegular]];
            NSImage *white = [NSImage imageWithSize:NSMakeSize(84, 84) flipped:NO drawingHandler:^BOOL(NSRect r) {
                NSSize s = sym.size; CGFloat k = MIN(r.size.width / s.width, r.size.height / s.height);
                NSRect d = NSMakeRect((r.size.width - s.width * k) / 2, (r.size.height - s.height * k) / 2, s.width * k, s.height * k);
                [sym drawInRect:d]; [NSColor.whiteColor set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); return YES; }];
            _hudView.sun = white;
        }
        _hud.contentView = _hudView;
    }
    NSScreen *s = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect f = s.frame;
    [_hud setFrameOrigin:NSMakePoint(NSMidX(f) - 100, NSMinY(f) + f.size.height * 0.14)];
    _hudView.value = _level; [_hudView setNeedsDisplay:YES];
    [_hud orderFrontRegardless];
    [_hudTimer invalidate];
    _hudTimer = [NSTimer scheduledTimerWithTimeInterval:1.3 repeats:NO block:^(NSTimer *t) { [self->_hud orderOut:nil]; }];
}

- (void)pollNative {
    if (!DSGet) return;
    float v = -1;
    if (DSGet(CGMainDisplayID(), &v) != 0 || v < 0) {
        if (!_nativeLogged) { _nativeLogged = YES; ZLog(@"DisplayServices brightness not available (normal in -wexoff mode; keys drive the dimming)"); }
        return;
    }
    { int k = _sampleN % 8; _sampleT[k] = CFAbsoluteTimeGetCurrent(); _sampleV[k] = v; _sampleN++; if (_sampleN > 1000) _sampleN = 8 + (_sampleN % 8); }
    if (_lastNative < 0) { _lastNative = v; if (!_nativeLogged) { _nativeLogged = YES; ZLog(@"DisplayServices brightness readable: %.2f (Control Centre slider + native keys active)", v); } return; }
    if (fabsf(v - _lastNative) > 0.01f) {
        _lastNative = v;
        if (CFAbsoluteTimeGetCurrent() - _lastNativeWrite > 0.8) {
            ZLog(@"native slider -> %.0f%%", v * 100);
            [self setLevel:v push:NO hud:NO];
        }
    }
}

- (void)reassert {
    if (_level < 0.999f && [_activeMode isEqualToString:@"gamma"]) {
        CGGammaValue r[256], g[256], b[256]; uint32_t cnt = 0;
        if (CGGetDisplayTransferByTable(CGMainDisplayID(), 256, r, g, b, &cnt) == kCGErrorSuccess && cnt > 1 && fabsf(r[cnt - 1] - _level) > 0.03f) {
            ZLog(@"gamma was reset by the system - re-applying %.0f%%", _level * 100);
            [self apply];
        }
    }
}
- (float)nativeValue { float v = -1; if (DSGet && DSGet(CGMainDisplayID(), &v) != 0) v = -1; return v; }
- (void)wakeOrSwitch:(NSNotification *)n {
    ZLog(@"%@ - re-applying", n.name);
    if (![n.name isEqualToString:NSWorkspaceSessionDidBecomeActiveNotification]) { _wakeAt = CFAbsoluteTimeGetCurrent(); _wakeKeys = 0; }
    if (_tap && !CGEventTapIsEnabled(_tap)) { ZLog(@"key event tap was disabled during sleep - re-enabled"); CGEventTapEnable(_tap, true); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self nativeRescue]; });
    if (![n.name isEqualToString:NSWorkspaceSessionDidBecomeActiveNotification])
        for (NSNumber *t in @[@2.5, @6.0])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self wakeCheck:t.doubleValue]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self apply]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self apply]; });
}
// v8.15: lid open gave a black panel. If macOS restored the brightness while the panel was
// still powering up, the driver skipped it and the OLED stayed at 0 nits. Re-send the current
// brightness once the screen is on (two writes, 1 step apart - invisible), and log the state.
- (void)wakeCheck:(double)after {
    uint64_t w[9] = {0}; BOOL wex = ZWexLast(w);
    SInt32 cur = -1, mx = -1; BOOL bk = ZBklt(&cur, &mx, -1);
    float v = [self nativeValue];
    BOOL asleep = CGDisplayIsAsleep(CGMainDisplayID());
    ZLog(@"wake +%.1fs: clamshell %d, display asleep %d, macOS brightness %.2f, bklt %d/%d, driver calls %llu skipped %llu level %llu nits %llu",
         after, ZClamshell(), asleep, v, (int)cur, (int)mx, wex ? w[0] : 0, wex ? w[3] : 0, wex ? w[4] : 0, wex ? w[8] : 0);
    if (after < 3 && !asleep && bk && mx > 0 && cur > 1 && [self nativeActive]) {
        ZBklt(NULL, NULL, cur - 1); ZBklt(NULL, NULL, cur);
        ZLog(@"wake: brightness re-sent to the panel (bklt %d)", (int)cur);
    }
}
- (void)screensChanged:(NSNotification *)n {
    for (NSWindow *w in _overlays) [w orderOut:nil];
    [_overlays removeAllObjects];
    [self apply];
}
- (void)command:(NSNotification *)n {
    NSString *c = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    ZLog(@"command '%@'", c);
    if ([c isEqualToString:@"up"]) [self step:+1 source:SrcCLI];
    else if ([c isEqualToString:@"down"]) [self step:-1 source:SrcCLI];
    else if ([c hasPrefix:@"set:"]) [self setLevel:[[c substringFromIndex:4] floatValue] / 100.0f push:YES hud:YES];
    else if ([c isEqualToString:@"reapply"]) [self apply];
}
- (void)saveStatus {
    [Defs() setObject:@{ @"level": @(lroundf(_level * 100)), @"activeMode": _activeMode ?: @"",
                         @"gammaAccepted": @(_gammaOK), @"eventTap": @(_tap != NULL),
                         @"inputMonitoring": @(CGPreflightListenEventAccess()), @"nativeBacklight": @([self nativeValue]),
                         @"pid": @(getpid()), @"version": @ZB_VERSION, @"driverAUXBrightness": @(_driverNative),
                         @"nativeMode": @([self nativeActive]), @"bkltMode": @([self bkltActive]) } forKey:@"brightnessStatus"];
}
@end

// =============================================================================
#pragma mark - NumberPad daemon
// =============================================================================
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int frame; double timestamp; int pathIndex; int state; int fingerID; int handID;
    MTVector normalizedVector; float zTotal; int field9; float angle; float majorAxis; float minorAxis;
    MTVector absoluteVector; int field14; int field15; float zDensity;
} MTTouch;
typedef int  (*MTCallback)(void *dev, MTTouch *touches, int n, double ts, int frame);
typedef CFMutableArrayRef (*MTCreateListFn)(void);
typedef void (*MTRegisterFn)(void *, MTCallback);
typedef void (*MTStartFn)(void *, int);

@interface ZNumpad : NSObject
- (BOOL)openHID:(BOOL)verbose;
- (void)setLED:(uint8_t)v;
- (void)setActive:(BOOL)on;
@property (readonly) ZAxisMax axisMax;
@property (readonly) int mtDevices;
@property BOOL probeMode;
@property BOOL started;
@property (readonly) IOReturn lastLEDResult;
@end

typedef struct { int region; double t0; double x0, y0; BOOL valid, fired; double lastRepeat; } ZFinger;

@implementation ZNumpad {
    IOHIDManagerRef _mgr; IOHIDDeviceRef _pad; ZAxisMax _max; ZPadGeom _geom;
    BOOL _active; int _ledLevel; NSMutableDictionary<NSNumber *, NSValue *> *_fingers;
    double _lastFrame; BOOL _axWarned;
    double _lastMultiFinger; BOOL _convertingUp; CFMachPortRef _clickTap; BOOL _clickHID; int _clickLogs;
    BOOL _hidOpen, _hidWarned;
}
static ZNumpad *gNumpad;

static int MTFrameCB(void *dev, MTTouch *touches, int n, double ts, int frame) {
    NSMutableArray *snap = [NSMutableArray arrayWithCapacity:n];
    for (int i = 0; i < n; i++)
        [snap addObject:@[@(touches[i].pathIndex), @(touches[i].state), @(touches[i].normalizedVector.position.x), @(touches[i].normalizedVector.position.y)]];
    dispatch_async(dispatch_get_main_queue(), ^{ [gNumpad frame:snap]; });
    return 0;
}

- (ZAxisMax)axisMax { return _max; }

- (BOOL)openHID:(BOOL)verbose {
    _mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(_mgr, (__bridge CFDictionaryRef)@{ @kIOHIDTransportKey: @"I2C" });
    IOHIDManagerOpen(_mgr, kIOHIDOptionsTypeNone);
    NSSet *devs = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(_mgr);
    IOHIDDeviceRef best = NULL; int bestScore = -1;
    for (id o in devs) {
        IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)o;
        int vid = [(__bridge NSNumber *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDVendorIDKey)) intValue];
        int pid = [(__bridge NSNumber *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductIDKey)) intValue];
        int up  = [(__bridge NSNumber *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsagePageKey)) intValue];
        int us  = [(__bridge NSNumber *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsageKey)) intValue];
        NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
        NSData *desc = (__bridge NSData *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDReportDescriptorKey));
        BOOL hasFeat0D = NO;
        if (desc) { const uint8_t *p = desc.bytes; for (NSUInteger i = 0; i + 1 < desc.length; i++) if (p[i] == 0x85 && p[i + 1] == 0x0D) hasFeat0D = YES; }
        int score = (up == 0x0D && us == 0x05 ? 4 : 0) + (vid == 0x04F3 ? 2 : 0) + (hasFeat0D ? 2 : 0) + (up == 0x0D ? 1 : 0);
        ZLog(@"I2C HID: %@ VID %04X PID %04X usage %02X:%02X desc %lu bytes, reportID 0x0D %@, score %d",
             name ?: @"?", vid, pid, up, us, (unsigned long)desc.length, hasFeat0D ? @"present" : @"absent", score);
        if (score > bestScore) { bestScore = score; best = d; }
    }
    if (!best) { ZLog(@"no I2C HID touchpad found (VoodooI2CHID not loaded?)"); return NO; }
    _pad = best; CFRetain(_pad);
    IOReturn r = IOHIDDeviceOpen(_pad, kIOHIDOptionsTypeNone);
    _hidOpen = (r == kIOReturnSuccess);
    NSData *desc = (__bridge NSData *)IOHIDDeviceGetProperty(_pad, CFSTR(kIOHIDReportDescriptorKey));
    if (desc) _max = ZParseXYMax(desc.bytes, desc.length);
    NSNumber *ox = [Defs() objectForKey:@"numpadMaxX"], *oy = [Defs() objectForKey:@"numpadMaxY"];
    if (ox) _max.maxX = ox.intValue; if (oy) _max.maxY = oy.intValue;
    _geom = ZGeomFor(_max);
    ZLog(@"touchpad selected (open 0x%08X), logical max X %d Y %d -> grid margins L%.3f R%.3f T%.3f B%.3f icon %.3fx%.3f",
         r, _max.maxX, _max.maxY, _geom.left, _geom.right, _geom.top, _geom.bottom, _geom.iconW, _geom.iconH);
    return YES;
}

// v8.5: the daemon used to open the touchpad once at login; without Input Monitoring that
// fails (0xE00002E2) and every LED write then failed with "not open" (0xE00002CD).
// Now the open is retried until macOS grants access - no restart needed.
- (BOOL)ensureOpen {
    if (_hidOpen || !_pad) return _hidOpen;
    IOReturn r = IOHIDDeviceOpen(_pad, kIOHIDOptionsTypeNone);
    if (r == kIOReturnSuccess) { _hidOpen = YES; _hidWarned = NO; ZLog(@"touchpad access granted - NumberPad lights available"); }
    else if (!_hidWarned) { _hidWarned = YES; ZLog(@"touchpad access denied (0x%08X): allow ZenBookHelper in Privacy & Security > Input Monitoring", r); }
    return _hidOpen;
}
- (IOReturn)sendLED:(uint8_t)v type:(IOHIDReportType)t {
    if (![self ensureOpen]) { _lastLEDResult = kIOReturnNotPermitted; return _lastLEDResult; }
    uint8_t rep[5] = { 0x0D, 0x14, 0x03, v, 0xAD };
    IOReturn r = IOHIDDeviceSetReport(_pad, t, 0x0D, rep, sizeof(rep));
    _lastLEDResult = r;
    ZLog(@"NumberPad LED <- 0x%02X (%@) : %@", v, t == kIOHIDReportTypeOutput ? @"output" : @"feature",
         r == kIOReturnSuccess ? @"OK" : [NSString stringWithFormat:@"IOReturn 0x%08X", r]);
    return r;
}
// LED variant chosen by `numpad ledtest`: feature | feature-slow | output | output-slow | none
- (NSString *)ledVariant { NSString *v = [Defs() stringForKey:@"numpadLEDVariant"]; return v.length ? v : @"feature"; }
- (void)ledSequenceOn:(BOOL)on variant:(NSString *)var {
    IOHIDReportType t = [var hasPrefix:@"output"] ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature;
    BOOL slow = [var hasSuffix:@"slow"];
    if (!on) { [self sendLED:0x00 type:t]; return; }
    [self sendLED:0x60 type:t]; if (slow) usleep(300000);
    [self sendLED:0x01 type:t]; if (slow) { usleep(300000); [self sendLED:0x01 type:t]; usleep(300000); [self sendLED:0x48 type:t]; }
}
- (void)setLED:(uint8_t)v {
    if (!_pad) return;
    if (!_probeMode && ![Defs() boolForKey:@"numpadLEDVerified"]) { ZLog(@"LED 0x%02X skipped: LED not verified yet (fix-hardware.sh runs the LED test)", v); return; }
    if (!_probeMode && [[self ledVariant] isEqualToString:@"none"]) return;
    NSString *var = [self ledVariant];
    if (v == 0x01 || v == 0x60) { if (v == 0x01) [self ledSequenceOn:YES variant:var]; return; }
    [self sendLED:v type:[var hasPrefix:@"output"] ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature];
}
- (void)dumpDiagnostics {
    if (!_pad) return;
    io_service_t svc = IOHIDDeviceGetService(_pad);
    CFTypeRef hd = svc ? IORegistryEntryCreateCFProperty(svc, CFSTR("HIDDescriptor"), kCFAllocatorDefault, 0) : NULL;
    ZLog(@"HIDDescriptor: %@", hd ? [(__bridge id)hd description] : @"(not published)");
    if (hd) CFRelease(hd);
    NSData *desc = (__bridge NSData *)IOHIDDeviceGetProperty(_pad, CFSTR(kIOHIDReportDescriptorKey));
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *p = desc.bytes; for (NSUInteger i = 0; i < desc.length; i++) [hex appendFormat:@"%02X ", p[i]];
    ZLog(@"report descriptor (%lu bytes): %@", (unsigned long)desc.length, hex);
    uint8_t buf[16] = {0}; CFIndex n = sizeof(buf);
    IOReturn gr = IOHIDDeviceGetReport(_pad, kIOHIDReportTypeFeature, 0x0D, buf, &n);
    NSMutableString *g = [NSMutableString string]; for (CFIndex i = 0; i < n && i < 16; i++) [g appendFormat:@"%02X ", buf[i]];
    ZLog(@"GET_REPORT feature 0x0D -> 0x%08X len %ld: %@", gr, (long)n, g);
}

- (void)setTapToClickSuspended:(BOOL)suspend {
    BOOL enabled = [Defs() objectForKey:@"numpadSuspendTapClick"] == nil || [Defs() boolForKey:@"numpadSuspendTapClick"];
    if (!enabled && suspend) return;
    NSString *act = @"/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings";
    if (suspend) {
        // v8.9: never overwrite the saved value while already suspended (it would save "off"
        // and tap-to-click - including the two-finger tap - would stay disabled for good)
        if ([Defs() boolForKey:@"numpadTapClickSuspended"]) return;
        NSUserDefaults *tp = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.AppleMultitouchTrackpad"];
        [Defs() setBool:([tp objectForKey:@"Clicking"] == nil || [tp boolForKey:@"Clicking"]) forKey:@"numpadSavedClicking"];
        [Defs() setBool:YES forKey:@"numpadTapClickSuspended"];
        RunTool(@"/usr/bin/defaults", @[@"write", @"com.apple.AppleMultitouchTrackpad", @"Clicking", @"-bool", @"false"]);
    } else {
        if (![Defs() boolForKey:@"numpadTapClickSuspended"]) return;
        BOOL was = [Defs() objectForKey:@"numpadSavedClicking"] ? [Defs() boolForKey:@"numpadSavedClicking"] : YES;
        RunTool(@"/usr/bin/defaults", @[@"write", @"com.apple.AppleMultitouchTrackpad", @"Clicking", @"-bool", was ? @"true" : @"false"]);
        [Defs() setBool:NO forKey:@"numpadTapClickSuspended"];
    }
    RunTool(act, @[@"-u"]);
}

- (void)setActive:(BOOL)on {
    _active = on;
    if (on) { [self setLED:0x01]; _ledLevel = -1; }
    else    { [self setLED:0x00]; }
    [self setTapToClickSuspended:on];
    ZLog(@"NumberPad %@%@", on ? @"ON" : @"OFF", (on && !_hidOpen) ? @" (lights unavailable: no touchpad access yet)" : @"");
    if (_started) ShowNotice(on ? @"number.square.fill" : @"number.square", on ? @"NumberPad ON" : @"NumberPad OFF");
    [self saveStatus];
}

- (void)start {
    gNumpad = self; _fingers = [NSMutableDictionary new];
    ZLog(@"numberpad daemon v%s start", ZB_VERSION);
    CrashLoopGuard(@"numpadStarts");
    [self setTapToClickSuspended:NO];                     // undo a previous crash
    {   // v8.9: tap-to-click stuck off by older versions -> back on (fix-hardware sets it on)
        NSUserDefaults *tp = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.AppleMultitouchTrackpad"];
        if ([tp objectForKey:@"Clicking"] && ![tp boolForKey:@"Clicking"] && ![Defs() boolForKey:@"tapClickOffByUser"]) {
            RunTool(@"/usr/bin/defaults", @[@"write", @"com.apple.AppleMultitouchTrackpad", @"Clicking", @"-bool", @"true"]);
            RunTool(@"/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", @[@"-u"]);
            ZLog(@"tap to click was off -> switched back on (two-finger tap needs it)");
        }
    }
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        BOOL g = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        ZLog(@"Input Monitoring for touchpad access: %@", g ? @"granted" : @"requested - switch ON ZenBookHelper in Privacy & Security > Input Monitoring");
    }
    [self openHID:YES];
    if (_pad) [self setLED:0x00];
    NSDictionary *opt = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES };
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opt))
        ZLog(@"Accessibility permission needed to type keypad keys (System Settings > Privacy & Security > Accessibility > ZenBookHelper)");
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    MTCreateListFn createList = mt ? (MTCreateListFn)dlsym(mt, "MTDeviceCreateList") : NULL;
    MTRegisterFn reg = mt ? (MTRegisterFn)dlsym(mt, "MTRegisterContactFrameCallback") : NULL;
    MTStartFn startFn = mt ? (MTStartFn)dlsym(mt, "MTDeviceStart") : NULL;
    if (createList && reg && startFn) {
        CFArrayRef list = createList();
        _mtDevices = list ? (int)CFArrayGetCount(list) : 0;
        for (int i = 0; i < _mtDevices; i++) { void *d = (void *)CFArrayGetValueAtIndex(list, i); reg(d, MTFrameCB); startFn(d, 0); }
        ZLog(@"MultitouchSupport: %d device(s) listening", _mtDevices);
    } else {
        ZLog(@"MultitouchSupport not available - keypad typing disabled");
    }
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {   // pick up permissions without restart
        BOOL was = self->_hidOpen;
        if (!was && [self ensureOpen] && self->_active && [Defs() boolForKey:@"numpadLEDVerified"]) [self setLED:0x01];
        [self saveStatus];
    }];
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        if (self->_fingers.count && CFAbsoluteTimeGetCurrent() - self->_lastFrame > 0.35) [self frame:@[]];   // lost lift frame
    }];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(command:) name:kCmdNote object:nil
                                                 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self setActive:NO];
    _started = YES;
    [self installClickTap];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { if (!self->_clickTap) [self installClickTap]; }];
}

// v8.14: the user wants the normal Mac behaviour - two fingers open the menu (right click).
// 8.9-8.13 turned that into a left click by mistake. Conversion now only after an explicit
// `zenbook-helper twofinger left`; the old stored "left" (set by fix-hardware.sh) is reset once.
// macOS turns a two-finger tap into a right click; we turn it back into a left click when the
// trackpad reported two or more fingers in the last 0.35 s. Corner presses and external mice are untouched.
static CGEventRef ClickTapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ud) {
    ZNumpad *np = (__bridge ZNumpad *)ud;
    return [np clickEvent:ev type:type];
}
// v8.13: 8.9-8.12 converted the click at the session level, after WindowServer had already
// recorded a RIGHT button press - logged as converted, but apps ignored the left click.
// Now the tap sits at the HID level (before WindowServer), on its own thread so a busy main
// thread can never delay or disable it. Fallback: session tap + a fresh HID-level left click.
- (void)installClickTap {
    if (_clickTap || !AXIsProcessTrusted()) return;            // active taps need Accessibility
    if (![self twoFingerLeft]) return;                         // normal Mac menu: no tap at all
    CGEventMask m = CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventRightMouseDragged);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, m, ClickTapCB, (__bridge void *)self);
    _clickHID = (tap != NULL);
    if (!tap) tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, m, ClickTapCB, (__bridge void *)self);
    if (!tap) { ZLog(@"two-finger click tap could not be created"); return; }
    _clickTap = tap;
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
        CFRunLoopRun();
    }];
    t.name = @"two-finger click"; t.qualityOfService = NSQualityOfServiceUserInteractive; [t start];
    ZLog(@"two-finger click tap active (%@ level, own thread, mode: %@)", _clickHID ? @"HID" : @"session",
         [self twoFingerLeft] ? @"left click" : @"right click");
}
- (BOOL)twoFingerLeft {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([Defs() integerForKey:@"twofingerV"] < 2) {
            [Defs() setObject:@"right" forKey:@"twofinger"]; [Defs() setInteger:2 forKey:@"twofingerV"]; [Defs() synchronize];
            ZLog(@"two-finger tap/click = menu (right click), like a Mac");
        }
    });
    return [[Defs() stringForKey:@"twofinger"] isEqualToString:@"left"];
}
// runs on the click thread: no AppKit, logging goes through the main queue
- (CGEventRef)clickEvent:(CGEventRef)ev type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) { CGEventTapEnable(_clickTap, true); return ev; }
    if (![self twoFingerLeft]) return ev;
    double now = CFAbsoluteTimeGetCurrent();
    // only right clicks that follow a 2+ finger touch (two-finger tap/click); corner presses stay right clicks
    double dt = now - _lastMultiFinger;
    BOOL fromPad = (_mtDevices > 0) && (dt < 0.8);
    if (type == kCGEventRightMouseDown) {
        if (_clickLogs++ < 20) {
            BOOL hid = _clickHID;
            dispatch_async(dispatch_get_main_queue(), ^{ ZLog(@"right click: last two-finger touch %.2f s ago -> %@", dt,
                fromPad ? (hid ? @"left click (HID level)" : @"left click (re-posted)") : @"kept as right click"); });
        }
        if (!fromPad) { _convertingUp = NO; return ev; }
        _convertingUp = YES;
    } else if (!_convertingUp) return ev;
    CGEventType to = type == kCGEventRightMouseDown ? kCGEventLeftMouseDown : type == kCGEventRightMouseUp ? kCGEventLeftMouseUp : kCGEventLeftMouseDragged;
    if (type == kCGEventRightMouseUp) _convertingUp = NO;
    if (_clickHID) {                                           // before WindowServer: convert in place
        CGEventSetType(ev, to); CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, kCGMouseButtonLeft);
        return ev;
    }
    CGEventRef n = CGEventCreateMouseEvent(NULL, to, CGEventGetLocation(ev), kCGMouseButtonLeft);
    if (n) {
        CGEventSetIntegerValueField(n, kCGMouseEventClickState, CGEventGetIntegerValueField(ev, kCGMouseEventClickState) ?: 1);
        CGEventSetFlags(n, CGEventGetFlags(ev));
        CGEventPost(kCGHIDEventTap, n); CFRelease(n);
    }
    return NULL;
}

- (void)saveStatus {
    [Defs() setObject:@{ @"active": @(_active), @"mtDevices": @(_mtDevices), @"touchpad": @(_pad != NULL),
                         @"touchpadAccess": @(_hidOpen), @"accessibility": @(AXIsProcessTrusted()),
                         @"ledVariant": [self ledVariant], @"pid": @(getpid()), @"version": @ZB_VERSION } forKey:@"numpadStatus"];
}

- (void)openCalculator {
    NSURL *u = [NSURL fileURLWithPath:@"/System/Applications/Calculator.app"];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:u configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    ShowNotice(@"plus.forwardslash.minus", @"Calculator");
    ZLog(@"top-left slide -> Calculator");
}

- (void)command:(NSNotification *)n {
    NSString *c = [n.object isKindOfClass:NSString.class] ? n.object : @"";
    if ([c isEqualToString:@"numpad:on"]) [self setActive:YES];
    else if ([c isEqualToString:@"numpad:off"]) [self setActive:NO];
    else if ([c isEqualToString:@"numpad:toggle"]) [self setActive:!_active];
}

- (void)emitKey:(int)cell {
    if (!AXIsProcessTrusted()) {
        if (!_axWarned) { _axWarned = YES; ZLog(@"cannot type '%s': Accessibility permission missing", kPadNames[cell]); }
        return;
    }
    uint16_t kc = kPadKeys[cell]; CGEventFlags fl = kCGEventFlagMaskNumericPad;
    if (kc == 0xFFFF) { kc = 0x17; fl = kCGEventFlagMaskShift; }      // % = Shift+5
    if (kc == 0x33) fl = 0;
    CGEventRef dn = CGEventCreateKeyboardEvent(NULL, kc, true), up = CGEventCreateKeyboardEvent(NULL, kc, false);
    CGEventSetFlags(dn, fl); CGEventSetFlags(up, fl);
    CGEventPost(kCGHIDEventTap, dn); CGEventPost(kCGHIDEventTap, up);
    CFRelease(dn); CFRelease(up);
    ZLog(@"keypad '%s'", kPadNames[cell]);
}

- (void)frame:(NSArray *)snap {
    double now = CFAbsoluteTimeGetCurrent(); _lastFrame = now;
    NSMutableSet *seen = [NSMutableSet set];
    int touching = 0;
    for (NSArray *t in snap) { int st = [t[1] intValue]; if (st == 3 || st == 4) touching++; }
    if (touching >= 2) _lastMultiFinger = now;
    for (NSArray *t in snap) {
        int ident = [t[0] intValue], state = [t[1] intValue];
        double x = [t[2] doubleValue], yTop = 1.0 - [t[3] doubleValue];
        if (state != 3 && state != 4) continue;                       // making contact / touching
        [seen addObject:t[0]];
        NSValue *v = _fingers[t[0]]; ZFinger f;
        if (!v) {
            f.region = ZRegionAt(x, yTop, _geom); f.t0 = now; f.x0 = x; f.y0 = yTop; f.valid = YES; f.fired = NO; f.lastRepeat = now;
        } else {
            [v getValue:&f];
            if (hypot(x - f.x0, yTop - f.y0) > 0.045) f.valid = NO;     // a swipe, not a tap
            if (f.region >= 0 && ZRegionAt(x, yTop, _geom) != f.region) f.valid = NO;
            if (f.valid && f.region == ZRegionTopRight && !f.fired && now - f.t0 >= 1.0 && touching == 1) { f.fired = YES; [self setActive:!_active]; }
            if (f.region == ZRegionTopLeft && !f.fired && touching == 1 &&
                hypot(x * _geom.mx, yTop * _geom.my) > 1200.0) {        // slide out of the top-left icon
                f.fired = YES; [self openCalculator];
            }
        }
        (void)ident;
        _fingers[t[0]] = [NSValue valueWithBytes:&f objCType:@encode(ZFinger)];
    }
    for (NSNumber *k in _fingers.allKeys) {
        if ([seen containsObject:k]) continue;
        ZFinger f; [_fingers[k] getValue:&f];
        [_fingers removeObjectForKey:k];
        if (_active && f.valid && f.region >= 0 && now - f.t0 < 1.0) [self emitKey:f.region];
    }
}
@end


// =============================================================================
#pragma mark - Wi-Fi watchdog (AirportItlwm sleep/wake recovery)
// =============================================================================
static NSString *ZIPv4(NSString *ifname) {
    struct ifaddrs *ifa = NULL, *p; NSString *res = nil;
    if (getifaddrs(&ifa) != 0) return nil;
    for (p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strcmp(p->ifa_name, ifname.UTF8String) != 0) continue;
        char buf[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, buf, sizeof buf);
        if (strncmp(buf, "169.254.", 8) != 0) { res = @(buf); break; }
    }
    freeifaddrs(ifa);
    return res;
}
static NSString *ZLinkDesc(CWInterface *i) {
    if (!i) return @"no Wi-Fi interface";
    const char *phy[] = { "none", "802.11a", "802.11b", "802.11g", "802.11n (Wi-Fi 4)", "802.11ac (Wi-Fi 5)", "802.11ax (Wi-Fi 6)" };
    NSInteger m = i.activePHYMode; CWChannel *c = i.wlanChannel;
    const char *band = c.channelBand == kCWChannelBand5GHz ? "5 GHz" : (c.channelBand == kCWChannelBand2GHz ? "2.4 GHz" : "6 GHz");
    int width = c.channelWidth == kCWChannelWidth20MHz ? 20 : c.channelWidth == kCWChannelWidth40MHz ? 40 : c.channelWidth == kCWChannelWidth80MHz ? 80 : c.channelWidth == kCWChannelWidth160MHz ? 160 : 0;
    return [NSString stringWithFormat:@"%@ power %@, %s, %s ch %ld (%d MHz), link %.0f Mbps, signal %ld dBm, IP %@",
            i.interfaceName, i.powerOn ? @"on" : @"off", (m >= 0 && m <= 6) ? phy[m] : "?", band, (long)c.channelNumber, width,
            i.transmitRate, (long)i.rssiValue, ZIPv4(i.interfaceName ?: @"en0") ?: @"none"];
}

@interface ZWiFi : NSObject
@end
@implementation ZWiFi { double _lastGood, _lastToggle, _eventAt; NSString *_lastDesc; int _cycles; BOOL _wasUp; int _assocState; }
- (void)start {
    ZLog(@"Wi-Fi watchdog v%s start", ZB_VERSION);
    CrashLoopGuard(@"wifiStarts");
    _eventAt = CFAbsoluteTimeGetCurrent();
    for (NSString *n in @[NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification])
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            double t = CFAbsoluteTimeGetCurrent(); if (t - self->_eventAt > 5) ZLog(@"wake - watching Wi-Fi reconnection");
            self->_eventAt = t; self->_cycles = 0; }];
    [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(check) userInfo:nil repeats:YES];
    [self check];
}
- (void)check {
    CWInterface *i = CWWiFiClient.sharedWiFiClient.interface;
    if (!i) return;
    double now = CFAbsoluteTimeGetCurrent();
    NSString *ip = ZIPv4(i.interfaceName ?: @"en0");
    NSString *desc = ZLinkDesc(i);
    if (ip) {
        if (!_wasUp && _lastGood > 0) ZLog(@"Wi-Fi back after %.0f s", now - MAX(_lastGood, _eventAt));
        _lastGood = now; _cycles = 0; _wasUp = YES;
        NSString *key = [NSString stringWithFormat:@"%ld/%ld/%.0f", (long)i.activePHYMode, (long)i.wlanChannel.channelNumber, i.transmitRate];
        if (![key isEqualToString:_lastDesc]) { _lastDesc = key; ZLog(@"Wi-Fi up: %@", desc); }
        [Defs() setObject:desc forKey:@"wifiStatus"];
        return;
    }
    [Defs() setObject:desc forKey:@"wifiStatus"];
    if (_wasUp) { _wasUp = NO; ZLog(@"Wi-Fi lost its connection: %@", desc); }
    if (!i.powerOn) return;                                  // switched off by the user
    // v8.14: 8.13 switched Wi-Fi off/on every ~40 s, but AirportItlwm needs up to ~2 min to
    // join at this signal level - each restart threw the join away (test 10:56-11:02: never
    // connected). Now: never while joined/joining (link up = waiting for DHCP), and at most
    // ONE off/on per wake or drop, only after 90 s without any link.
    int assoc = (i.rssiValue != 0 || i.transmitRate > 0) ? 1 : 0;
    if (assoc != _assocState) { _assocState = assoc; ZLog(@"Wi-Fi %@: %@", assoc ? @"joined, waiting for an IP address" : @"not joined", desc); }
    if (assoc) return;
    double since = MAX(_lastGood, _eventAt);
    BOOL recent = (now - _lastGood < 900) || (now - _eventAt < 600);
    if (recent && now - since > 90 && _cycles < 1) {
        _lastToggle = now; _cycles++;
        ZLog(@"Wi-Fi has no IP for %.0f s after %@ - power-cycling Wi-Fi once", now - since, now - _eventAt < 300 ? @"wake/login" : @"a drop");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *e1 = nil, *e2 = nil;
            [i setPower:NO error:&e1]; sleep(2); [i setPower:YES error:&e2];
            ZLog(@"Wi-Fi power cycle done%@", (e1 || e2) ? [NSString stringWithFormat:@" (errors: %@ %@)", e1.localizedDescription ?: @"", e2.localizedDescription ?: @""] : @"");
        });
    }
}
@end

// =============================================================================
#pragma mark - CLI
// =============================================================================
static void Post(NSString *cmd) {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kCmdNote object:cmd userInfo:nil deliverImmediately:YES];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}

static int SelfTest(void) {
    int fails = 0;
#define CHECK(c, ...) do { if (c) printf("PASS  " __VA_ARGS__); else { printf("FAIL  " __VA_ARGS__); fails++; } printf("\n"); } while (0)
    // Precision-touchpad style descriptor: Digitizer finger collection with X/Y logical max
    const uint8_t desc[] = {
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02, 0x09,0x01, 0xA1,0x00,                 // mouse first
        0x05,0x01, 0x09,0x30, 0x09,0x31, 0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x02, 0x81,0x06, 0xC0, 0xC0, // rel X/Y max 127
        0x05,0x0D, 0x09,0x05, 0xA1,0x01, 0x85,0x01, 0x09,0x22, 0xA1,0x02,
        0x09,0x42, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x01, 0x81,0x02,
        0x05,0x01, 0x15,0x00, 0x26,0x8C,0x0C, 0x75,0x10, 0x09,0x30, 0x81,0x02,    // X max 3212
        0x26,0x2C,0x07, 0x09,0x31, 0x81,0x02, 0xC0,                               // Y max 1836
        0x06,0x00,0xFF, 0x85,0x0D, 0x09,0x01, 0x95,0x04, 0x75,0x08, 0xB1,0x02, 0xC0 };
    ZAxisMax m = ZParseXYMax(desc, sizeof(desc));
    CHECK(m.maxX == 3212 && m.maxY == 1836, "descriptor X/Y logical max = %d/%d (want 3212/1836)", m.maxX, m.maxY);
    ZPadGeom bad = ZGeomFor((ZAxisMax){127, 127});
    CHECK(bad.iconW < 0.2 && bad.left < 0.2, "mouse-sized axes fall back to sane geometry");
    ZPadGeom g = ZGeomFor(m);
    CHECK(ZRegionAt(0.99, 0.02, g) == ZRegionTopRight, "top-right corner = NumberPad toggle icon");
    CHECK(ZRegionAt(0.01, 0.02, g) == ZRegionTopLeft, "top-left corner = LED level icon");
    CHECK(ZRegionAt(0.10, 0.20, g) == 0, "upper-left grid cell = '7' (got %d)", ZRegionAt(0.10, 0.20, g));
    CHECK(ZRegionAt(0.50, 0.50, g) == 7, "centre = '5' (got %d)", ZRegionAt(0.50, 0.50, g));
    CHECK(ZRegionAt(0.90, 0.93, g) == 19, "lower-right grid cell = '=' (got %d)", ZRegionAt(0.90, 0.93, g));
    CHECK(ZRegionAt(0.02, 0.50, g) == ZRegionNone, "left margin ignored");
    CHECK(kPadKeys[15] == 0x52 && kPadKeys[17] == 0x4C, "keypad 0 / Enter keycodes");
    ZDedup d; memset(&d, 0, sizeof(d)); for (int i = 0; i < 8; i++) d.t[i] = -100;
    CHECK(ZDedupAccept(&d, SrcNX, +1, 10.000), "first event accepted");
    CHECK(!ZDedupAccept(&d, SrcFKey, +1, 10.010), "same press via 2nd path (10 ms) merged");
    CHECK(ZDedupAccept(&d, SrcNX, +1, 10.150), "key repeat 150 ms later accepted");
    CHECK(ZDedupAccept(&d, SrcFKey, -1, 10.160), "opposite direction never merged");
    CHECK(fabsf(ZStepLevel(1.0f, +1) - 1.0f) < 1e-6 && fabsf(ZStepLevel(0.5f, -1) - 0.4375f) < 1e-6, "16 steps, clamped at 100%%");
    CHECK(fabsf(ZStepLevel(0.10f, -1) - kMinLevel) < 1e-6, "never below %.0f%%", kMinLevel * 100);
    CHECK(ZCurve(0) == 0 && fabs(ZCurve(1) - 1.0) < 1e-9 && fabs(ZCurve(1.0f / 16) - 655.0 / 65403) < 1e-6, "curve ends: 0, step 1 = 1%%, 100%%");
    { BOOL mono = YES; for (int i = 1; i <= 64; i++) if (ZCurve(i / 64.0f) <= ZCurve((i - 1) / 64.0f)) mono = NO; CHECK(mono, "curve strictly rises"); }
    CHECK(ZCurve(0.5f) > 0.07 && ZCurve(0.5f) < 0.09, "half-way step = %.1f%% of max (perceptual)", ZCurve(0.5f) * 100);
    { double last = -100; BOOL a = ZPressAccept(&last, 10.0), b = YES; for (int i = 1; i <= 25; i++) b = b && !ZPressAccept(&last, 10.0 + i * 0.083);
      BOOL c = ZPressAccept(&last, 10.0 + 25 * 0.083 + 0.5);
      CHECK(a && b && c, "held mute key (25 repeats, 83 ms) = 1 toggle; next press accepted"); }
    printf("%s (%d failure%s)\n", fails ? "SELFTEST FAILED" : "SELFTEST OK", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}

static void PrintStatus(void) {
    [Defs() synchronize];
    printf("ZenBookHelper %s\n", ZB_VERSION);
    NSString *mode = [Defs() boolForKey:@"dimForced"] ? ([Defs() stringForKey:@"mode"] ?: @"none") : @"none";
    printf("  settings: mode=%s hud=%s level=%.0f%%\n", mode.UTF8String,
           [Defs() objectForKey:@"hud"] && ![Defs() boolForKey:@"hud"] ? "off" : "on", [Defs() floatForKey:@"level"] * 100);
    printf("  brightness daemon: %s\n", [[[Defs() objectForKey:@"brightnessStatus"] description] UTF8String] ?: "(not running yet)");
    printf("  numberpad daemon : %s\n", [[[Defs() objectForKey:@"numpadStatus"] description] UTF8String] ?: "(not running yet)");
    printf("  wi-fi            : %s\n", [[Defs() stringForKey:@"wifiStatus"] UTF8String] ?: "(watchdog not running yet)");
    printf("  log: ~/Library/Logs/ZenBookHelper.log\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *a1 = argc > 1 ? @(argv[1]) : @"";
        NSString *a2 = argc > 2 ? @(argv[2]) : @"";
        if ([a1 isEqualToString:@"--brightness"] || [a1 isEqualToString:@"--numberpad"] || [a1 isEqualToString:@"--wifi"]) {   // daemons only with an explicit flag
            BOOL bright = [a1 isEqualToString:@"--brightness"], wifi = [a1 isEqualToString:@"--wifi"];
            gLogName = bright ? @"brightness" : (wifi ? @"wifi" : @"numberpad");
            NSApplication *app = NSApplication.sharedApplication;
            app.activationPolicy = NSApplicationActivationPolicyAccessory;
            static ZBrightness *b; static ZNumpad *np; static ZWiFi *wf;
            if (bright)    { b = [ZBrightness new]; [b start]; }
            else if (wifi) { wf = [ZWiFi new]; [wf start]; }
            else           { np = [ZNumpad new]; [np start]; }
            [app run];
            return 0;
        }
        gLogName = @"cli";
        if ([a1 isEqualToString:@"selftest"]) return SelfTest();
        if ([a1 isEqualToString:@"status"]) { PrintStatus(); return 0; }
        if ([a1 isEqualToString:@"wifi"]) { printf("%s\n", ZLinkDesc(CWWiFiClient.sharedWiFiClient.interface).UTF8String); return 0; }
        if ([a1 isEqualToString:@"up"] || [a1 isEqualToString:@"down"]) { Post(a1); return 0; }
        if ([a1 isEqualToString:@"set"] && a2.length) { Post([@"set:" stringByAppendingString:a2]); return 0; }
        if ([a1 isEqualToString:@"audio"]) { printf("%s", ZAudioReport().UTF8String); return 0; }
        if ([a1 isEqualToString:@"powerbutton"] && ([a2 isEqualToString:@"sleep"] || [a2 isEqualToString:@"off"])) {
            [Defs() setObject:a2 forKey:@"powerbutton"]; [Defs() synchronize]; printf("power button = %s\n", a2.UTF8String); return 0;
        }
        if ([a1 isEqualToString:@"native"] && ([a2 isEqualToString:@"on"] || [a2 isEqualToString:@"off"])) {
            [Defs() setBool:[a2 isEqualToString:@"on"] forKey:@"native"]; [Defs() synchronize]; Post(@"reapply");
            printf("native brightness = %s (used only when the Iris Xe driver reports AUX panel brightness)\n", a2.UTF8String); return 0;
        }
        if ([a1 isEqualToString:@"mode"] && ([a2 isEqualToString:@"auto"] || [a2 isEqualToString:@"gamma"] || [a2 isEqualToString:@"overlay"] || [a2 isEqualToString:@"none"])) {
            [Defs() setObject:a2 forKey:@"mode"]; [Defs() setBool:![a2 isEqualToString:@"none"] forKey:@"dimForced"]; [Defs() synchronize];
            Post(@"reapply"); printf("mode = %s\n", a2.UTF8String); return 0;
        }
        if ([a1 isEqualToString:@"twofinger"] && ([a2 isEqualToString:@"left"] || [a2 isEqualToString:@"right"])) {
            [Defs() setObject:a2 forKey:@"twofinger"]; [Defs() setInteger:2 forKey:@"twofingerV"]; [Defs() synchronize];
            printf("two-finger tap = %s click%s\n", a2.UTF8String, [a2 isEqualToString:@"right"] ? " (menu, like a Mac)" : ""); return 0;
        }
        if ([a1 isEqualToString:@"hud"] && ([a2 isEqualToString:@"on"] || [a2 isEqualToString:@"off"])) {
            [Defs() setBool:[a2 isEqualToString:@"on"] forKey:@"hud"]; [Defs() synchronize]; return 0;
        }
        if ([a1 isEqualToString:@"numpad"]) {
            if ([a2 isEqualToString:@"on"] || [a2 isEqualToString:@"off"] || [a2 isEqualToString:@"toggle"]) { Post([@"numpad:" stringByAppendingString:a2]); return 0; }
            if ([a2 isEqualToString:@"ledtest"]) {
                printf("NumberPad LED test (ZenBookHelper %s)\n", ZB_VERSION);
                ZNumpad *np = [ZNumpad new]; np.probeMode = YES;
                if (![np openHID:YES]) { printf("No I2C HID touchpad found.\n"); return 1; }
                [np dumpDiagnostics];
                FILE *tty = fopen("/dev/tty", "r");
                NSArray *vars = @[@"feature", @"feature-slow", @"output", @"output-slow"];
                NSString *found = nil;
                for (NSUInteger i = 0; i < vars.count && !found; i++) {
                    printf("\nTest %lu of %lu (%s): watch the touchpad...\n", (unsigned long)i + 1, (unsigned long)vars.count, [vars[i] UTF8String]);
                    fflush(stdout);
                    [np ledSequenceOn:YES variant:vars[i]];
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
                    char line[32] = {0};
                    if (tty) { printf("Are the NumberPad lights ON now? type y or n and press Return: "); fflush(stdout); fgets(line, sizeof(line), tty); }
                    [np ledSequenceOn:NO variant:vars[i]];
                    ZLog(@"ledtest variant %@ -> user answered '%c'", vars[i], line[0] ? line[0] : '-');
                    if (line[0] == 'y' || line[0] == 'Y') found = vars[i];
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                }
                if (tty) fclose(tty);
                [Defs() setBool:YES forKey:@"numpadLEDVerified"];
                [Defs() setObject:(found ?: @"none") forKey:@"numpadLEDVariant"]; [Defs() synchronize];
                if (found) printf("\nLED works with variant '%s' - saved. NumberPad will light up from now on.\n", found.UTF8String);
                else printf("\nNo variant lit the LED - saved as 'none'. NumberPad typing still works (on-screen notice shows ON/OFF).\n");
                return 0;
            }
            if ([a2 isEqualToString:@"probe"]) {
                printf("NumberPad probe (ZenBookHelper %s)\n", ZB_VERSION);
                ZNumpad *np = [ZNumpad new]; np.probeMode = YES;
                if (![np openHID:YES]) { printf("No I2C HID touchpad found.\n"); return 1; }
                printf("Logical max X=%d Y=%d\n", np.axisMax.maxX, np.axisMax.maxY);
                printf("LED test: ON for 3 seconds - look at the touchpad...\n");
                [np ledSequenceOn:YES variant:@"feature"];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
                for (int i = 0; i < 8; i++) { [np setLED:(uint8_t)(0x41 + i)]; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]]; }
                [np setLED:0x00];
                if (np.lastLEDResult == kIOReturnSuccess) {
                    [Defs() setBool:YES forKey:@"numpadLEDVerified"]; [Defs() synchronize];
                    printf("LED commands accepted by the touchpad driver -> NumberPad daemon may now use the LED.\n");
                } else {
                    printf("LED command was rejected (IOReturn 0x%08X) -> LED stays disabled.\n", np.lastLEDResult);
                }
                printf("LED test done. Details: ~/Library/Logs/ZenBookHelper.log\n");
                return 0;
            }
        }
        fprintf(stderr, "usage: ZenBookHelper [--brightness|--numberpad|--wifi] | up | down | set <5-100> | status | wifi |\n"
                        "       mode <none|overlay|gamma|auto> | native <on|off> | hud <on|off> | twofinger <left|right> | numpad <on|off|toggle|probe|ledtest> | powerbutton <sleep|off> | audio | selftest\n");
        return 2;
    }
}
