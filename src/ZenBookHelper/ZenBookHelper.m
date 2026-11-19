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
//   up | down | set <5-100> | status | mode <overlay|gamma|auto> | hud <on|off>
//   twofinger <left|right> | numpad <on|off|toggle|probe> | selftest
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
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <signal.h>
#include <math.h>

#define ZB_VERSION "8.7"
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
static float ZStepLevel(float cur, int dir) {
    float q = roundf(cur * 16.0f) / 16.0f;
    return ZClampLevel(q + dir * kStep);
}

// =============================================================================
#pragma mark - Brightness daemon
// =============================================================================
typedef int  (*DSGetFn)(CGDirectDisplayID, float *);
typedef int  (*DSSetFn)(CGDirectDisplayID, float);
static DSGetFn DSGet; static DSSetFn DSSet;
enum { SrcHotkey = 0, SrcNX, SrcFKey, SrcCLI, SrcNative, SrcFKeyHK };
static const char *kSrcNames[] = { "ctrl-option-hotkey", "nx-brightness-key", "f14/f15-key(tap)", "cli", "native-slider", "f14/f15-key(hotkey)" };

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
        if (e.subtype == 8) {
            NSInteger d1 = e.data1;
            int code = (int)((d1 & 0xFFFF0000) >> 16);
            BOOL down = (((d1 & 0xFF00) >> 8) == 0x0A);
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

    [self installTap];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { if (!self->_tap) [self installTap]; }];
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
- (NSString *)mode { NSString *m = [Defs() stringForKey:@"mode"]; return m.length ? m : @"overlay"; }

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

- (void)step:(int)dir source:(int)src {
    double now = CFAbsoluteTimeGetCurrent();
    if (!ZDedupAccept(&_dedup, src, dir, now)) { ZLog(@"key %s %s merged (duplicate path)", kSrcNames[src], dir > 0 ? "up" : "down"); return; }
    float nl = ZStepLevel(_level, dir);
    ZLog(@"key %s %s -> %.0f%%", kSrcNames[src], dir > 0 ? "up" : "down", nl * 100);
    [self setLevel:nl push:YES hud:YES];
}

- (void)setLevel:(float)l push:(BOOL)push hud:(BOOL)hud {
    _level = ZClampLevel(l);
    [self apply];
    BOOL hudEnabled = [Defs() objectForKey:@"hud"] == nil || [Defs() boolForKey:@"hud"];
    if (hud && hudEnabled) [self showHUD];
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
    NSString *m = [self mode];
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
    if (_lastNative < 0) { _lastNative = v; if (!_nativeLogged) { _nativeLogged = YES; ZLog(@"DisplayServices brightness readable: %.2f", v); } return; }
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self nativeRescue]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self apply]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self apply]; });
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
                         @"pid": @(getpid()), @"version": @ZB_VERSION } forKey:@"brightnessStatus"];
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
    double _lastMultiFinger; BOOL _convertingUp; CFMachPortRef _clickTap;
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
        NSUserDefaults *tp = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.AppleMultitouchTrackpad"];
        [Defs() setBool:[tp boolForKey:@"Clicking"] forKey:@"numpadSavedClicking"];
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

// Two-finger tap / click -> LEFT click (user preference, default on; `zenbook-helper twofinger right` to undo).
// macOS turns a two-finger tap into a right click; we turn it back into a left click when the
// trackpad reported two or more fingers in the last 0.35 s. Corner presses and external mice are untouched.
static CGEventRef ClickTapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ud) {
    ZNumpad *np = (__bridge ZNumpad *)ud;
    return [np clickEvent:ev type:type];
}
- (void)installClickTap {
    if (!AXIsProcessTrusted()) return;                         // active taps need Accessibility
    CGEventMask m = CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp);
    _clickTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, m, ClickTapCB, (__bridge void *)self);
    if (!_clickTap) { ZLog(@"two-finger click tap could not be created"); return; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, _clickTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(_clickTap, true);
    ZLog(@"two-finger click tap active (mode: %@)", [self twoFingerLeft] ? @"left click" : @"right click");
}
- (BOOL)twoFingerLeft { NSString *m = [Defs() stringForKey:@"twofinger"]; return !m.length || [m isEqualToString:@"left"]; }
- (CGEventRef)clickEvent:(CGEventRef)ev type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) { CGEventTapEnable(_clickTap, true); return ev; }
    if (![self twoFingerLeft]) return ev;
    double now = CFAbsoluteTimeGetCurrent();
    // only right clicks that follow a 2+ finger touch (two-finger tap); corner presses stay right clicks
    BOOL fromPad = (_mtDevices > 0) && (now - _lastMultiFinger < 0.35);
    if (type == kCGEventRightMouseDown && fromPad) {
        CGEventSetType(ev, kCGEventLeftMouseDown); CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, 0);
        _convertingUp = YES;
    } else if (type == kCGEventRightMouseUp && _convertingUp) {
        CGEventSetType(ev, kCGEventLeftMouseUp); CGEventSetIntegerValueField(ev, kCGMouseEventButtonNumber, 0);
        _convertingUp = NO;
    }
    return ev;
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
@implementation ZWiFi { double _lastGood, _lastToggle, _eventAt; NSString *_lastDesc; }
- (void)start {
    ZLog(@"Wi-Fi watchdog v%s start", ZB_VERSION);
    CrashLoopGuard(@"wifiStarts");
    _eventAt = CFAbsoluteTimeGetCurrent();
    for (NSString *n in @[NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification])
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            self->_eventAt = CFAbsoluteTimeGetCurrent(); ZLog(@"wake - watching Wi-Fi reconnection"); }];
    [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(check) userInfo:nil repeats:YES];
    [self check];
}
- (void)check {
    CWInterface *i = CWWiFiClient.sharedWiFiClient.interface;
    if (!i) return;
    double now = CFAbsoluteTimeGetCurrent();
    NSString *ip = ZIPv4(i.interfaceName ?: @"en0");
    NSString *desc = ZLinkDesc(i);
    if (ip) {
        _lastGood = now;
        NSString *key = [NSString stringWithFormat:@"%ld/%ld/%.0f", (long)i.activePHYMode, (long)i.wlanChannel.channelNumber, i.transmitRate];
        if (![key isEqualToString:_lastDesc]) { _lastDesc = key; ZLog(@"Wi-Fi up: %@", desc); }
        [Defs() setObject:desc forKey:@"wifiStatus"];
        return;
    }
    [Defs() setObject:desc forKey:@"wifiStatus"];
    if (!i.powerOn) return;                                  // switched off by the user
    double since = MAX(_lastGood, _eventAt);
    BOOL recent = (now - _lastGood < 600) || (now - _eventAt < 300);
    if (recent && now - since > 45 && now - _lastToggle > 300) {
        _lastToggle = now;
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
    printf("%s (%d failure%s)\n", fails ? "SELFTEST FAILED" : "SELFTEST OK", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}

static void PrintStatus(void) {
    [Defs() synchronize];
    printf("ZenBookHelper %s\n", ZB_VERSION);
    NSString *mode = [Defs() stringForKey:@"mode"] ?: @"overlay";
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
        if ([a1 isEqualToString:@"mode"] && ([a2 isEqualToString:@"auto"] || [a2 isEqualToString:@"gamma"] || [a2 isEqualToString:@"overlay"])) {
            [Defs() setObject:a2 forKey:@"mode"]; [Defs() synchronize]; Post(@"reapply"); printf("mode = %s\n", a2.UTF8String); return 0;
        }
        if ([a1 isEqualToString:@"twofinger"] && ([a2 isEqualToString:@"left"] || [a2 isEqualToString:@"right"])) {
            [Defs() setObject:a2 forKey:@"twofinger"]; [Defs() synchronize]; printf("two-finger tap = %s click\n", a2.UTF8String); return 0;
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
                        "       mode <overlay|gamma|auto> | hud <on|off> | twofinger <left|right> | numpad <on|off|toggle|probe|ledtest> | selftest\n");
        return 2;
    }
}
