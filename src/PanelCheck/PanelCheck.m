#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern int runPanelTest(void);
static NSString *const label = @"local.zenbook.panelcheck";

static NSString *currentBoot(void) {
    char uuid[64] = {0};
    size_t length = sizeof(uuid);
    if (sysctlbyname("kern.bootsessionuuid", uuid, &length, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:uuid];
}

static void message(NSString *title, NSString *details) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = details;
    [alert runModal];
}

static BOOL desktopReady(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue]
        && [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"].count > 0;
}

static NSURL *executableIn(NSURL *app) {
    return [app URLByAppendingPathComponent:@"Contents/MacOS/PanelCheck"];
}

static BOOL scheduleCheck(NSURL *source, NSURL *app, NSURL *job, NSString *boot, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = app.URLByDeletingLastPathComponent;
    for (NSURL *directory in @[support, job.URLByDeletingLastPathComponent]) {
        if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    }
    if (![source.URLByStandardizingPath isEqual:app.URLByStandardizingPath]) {
        NSURL *staged = [support URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]];
        BOOL copied = [fm copyItemAtURL:source toURL:staged error:error];
        if (copied && [fm fileExistsAtPath:app.path]) {
            copied = [fm replaceItemAtURL:app withItemAtURL:staged backupItemName:nil options:0 resultingItemURL:NULL error:error];
        } else if (copied) {
            copied = [fm moveItemAtURL:staged toURL:app error:error];
        }
        if (!copied) { [fm removeItemAtURL:staged error:NULL]; return NO; }
    }
    NSDictionary *spec = @{@"Label": label, @"ProgramArguments": @[executableIn(app).path, @"--after-restart", boot],
                           @"RunAtLoad": @YES, @"LimitLoadToSessionType": @"Aqua"};
    return [spec writeToURL:job error:error];
}

static int panelCheck(NSArray<NSString *> *arguments) {
    if (arguments.count == 2 && [arguments[1] isEqual:@"--version"]) {
        puts("ZenBook Panel Check 1.0");
        return 0;
    }
    if (arguments.count == 2 && [arguments[1] isEqual:@"--measure"]) return runPanelTest();

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *library = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *support = [library URLByAppendingPathComponent:@"Application Support/ZenBook Panel Check"];
    NSURL *agents = [library URLByAppendingPathComponent:@"LaunchAgents"];
    NSURL *job = [agents URLByAppendingPathComponent:[label stringByAppendingString:@".plist"]];
    NSURL *app = [support URLByAppendingPathComponent:@"Check FPS After Restart.app"];
    NSURL *tool = executableIn(app);
    NSString *boot = currentBoot();
    NSError *error = nil;

    if (arguments.count == 1) {
        NSURL *source = NSBundle.mainBundle.bundleURL;
        if (!boot || !source || !scheduleCheck(source, app, job, boot, &error)) {
            message(@"Couldn’t queue the display check", error.localizedDescription ?: @"The current boot or app could not be identified.");
            return 1;
        }
        message(@"Display check queued", @"Restart macOS when you’re ready. After you sign in, a triangle will move across the OLED for nine seconds. Your frame-rate report will open in TextEdit.");
        return 0;
    }
    if (arguments.count != 3 || ![arguments[1] isEqual:@"--after-restart"]) return 2;
    if (!boot || [boot isEqual:arguments[2]]) return 0;
    int safe = 0; size_t size = sizeof(safe);
    if (sysctlbyname("kern.safeboot", &safe, &size, NULL, 0) != 0 || safe) return 0;
    for (int i = 0; i < 180 && !desktopReady(); i++) sleep(1);
    if (!desktopReady()) return 0;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = tool;
    task.arguments = @[@"--measure"];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    NSString *result;
    if ([task launchAndReturnError:&error]) {
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (task.terminationStatus) result = [@"Frame-rate measurement failed.\n" stringByAppendingString:result];
    } else {
        result = error.localizedDescription;
    }
    NSURL *report = [support URLByAppendingPathComponent:@"FPS Result.txt"];
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n", NSDate.date, result];
    if (![text writeToURL:report atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        message(@"Couldn’t save the display check", error.localizedDescription);
        return 1;
    }
    NSDictionary *scheduled = [NSDictionary dictionaryWithContentsOfURL:job];
    if ([scheduled[@"ProgramArguments"] isEqual:@[tool.path, @"--after-restart", arguments[2]]])
        [fm removeItemAtURL:job error:NULL];
    if (![NSWorkspace.sharedWorkspace openFile:report.path withApplication:@"TextEdit"])
        message(@"Display check", text);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool { return panelCheck(NSProcessInfo.processInfo.arguments); }
}
