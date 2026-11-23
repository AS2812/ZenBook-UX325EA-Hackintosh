// User-session recovery for the itlwm 2.3 / HeliPort 1.5 public API.
// The separate root invocation only retries IP configuration for a joined DHCP service.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <poll.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#import "itlwm-api/Common.h"
#import "RecoveryPolicy.h"

static NSString *const clientID = @"com.OpenIntelWireless.HeliPort";
static NSString *const clientPath = @"/Applications/HeliPort.app";
static NSString *const support = @"Library/Application Support/ZenBook Wi-Fi";
static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

@interface Snapshot : NSObject
@property LinkStatus state;
@property(copy) NSString *iface, *router, *network;
@property BOOL dhcp, ipv6;
@property uint64_t received;
@property ScanState scan;
@property unsigned channel, width, rate;
@property int rssi;
@end
@implementation Snapshot @end

static BOOL readMethod(io_connect_t c, uint32_t method, void *out, size_t length) {
    size_t returned = length;
    return IOConnectCallStructMethod(c, method, NULL, 0, out, &returned) == KERN_SUCCESS && returned == length;
}
static io_connect_t adapter(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("itlwm"));
    io_connect_t c = IO_OBJECT_NULL;
    if (service) {
        id name = CFBridgingRelease(IORegistryEntrySearchCFProperty(service, kIOServicePlane,
            CFSTR("BSD Name"), NULL, kIORegistryIterateRecursively));
        if ([name isKindOfClass:NSString.class] && if_nametoindex([name UTF8String]))
            IOServiceOpen(service, mach_task_self(), 0, &c);
        IOObjectRelease(service);
    }
    return c;
}
static BOOL setRadio(BOOL on) {
    io_connect_t c = adapter();
    if (!c) return NO;
    struct ioctl_driver_info info = {0};
    struct ioctl_power power = { .version = IOCTL_VERSION, .enabled = on };
    BOOL ok = readMethod(c, IOCTL_80211_DRIVER_INFO, &info, sizeof(info)) && info.version == IOCTL_VERSION &&
        IOConnectCallStructMethod(c, IOCTL_MASK | IOCTL_80211_POWER, &power, sizeof(power), NULL, NULL) == KERN_SUCCESS;
    IOServiceClose(c);
    return ok;
}

// Read the cache through a new user client. A cache read error is distinct
// from itlwm's explicit empty-list sentinel. No off-channel scan is needed.
static ScanState cachedScan(io_connect_t c) {
    struct ioctl_network_info entry = {0};
    size_t n = sizeof(entry);
    kern_return_t r = IOConnectCallStructMethod(c, IOCTL_80211_SCAN_RESULT, NULL, 0, &entry, &n);
    if (r == kIONoScanResult) return ScanEmpty;
    return r == KERN_SUCCESS && n == sizeof(entry) ? ScanVisible : ScanUnknown;
}

// itlwm presents an Ethernet interface. A "Wi-Fi" service left over from AirportItlwm can
// carry the same BSD name; only a service of the live interface's type configures the adapter.
static NSString *liveType(NSString *bsd) {
    NSArray *interfaces = CFBridgingRelease(SCNetworkInterfaceCopyAll());
    for (id item in interfaces) {
        SCNetworkInterfaceRef iface = (__bridge SCNetworkInterfaceRef)item;
        if ([bsd isEqual:(__bridge NSString *)SCNetworkInterfaceGetBSDName(iface)])
            return [(__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface) copy];
    }
    return nil;
}
static BOOL serves(SCNetworkServiceRef service, NSString *bsd, NSString *type) {
    SCNetworkInterfaceRef iface = SCNetworkServiceGetInterface(service);
    return iface && [bsd isEqual:(__bridge NSString *)SCNetworkInterfaceGetBSDName(iface)] &&
        (!type || [type isEqual:(__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface)]);
}
static SCNetworkServiceRef copyService(NSString *bsd) CF_RETURNS_RETAINED;
static SCNetworkServiceRef copyService(NSString *bsd) {
    SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("ZenBook Wi-Fi"), NULL);
    SCNetworkSetRef set = prefs ? SCNetworkSetCopyCurrent(prefs) : NULL;
    NSArray *services = set ? CFBridgingRelease(SCNetworkSetCopyServices(set)) : nil;
    NSString *type = liveType(bsd);
    SCNetworkServiceRef selected = NULL;
    for (id item in services) {
        SCNetworkServiceRef service = (__bridge SCNetworkServiceRef)item;
        if (SCNetworkServiceGetEnabled(service) && serves(service, bsd, type)) {
            selected = (SCNetworkServiceRef)CFRetain(service); break;
        }
    }
    if (set) CFRelease(set);
    if (prefs) CFRelease(prefs);
    return selected;
}
static void inspectAddresses(Snapshot *s) {
    struct ifaddrs *head = NULL;
    BOOL v4 = NO;
    if (getifaddrs(&head) == 0) {
        for (struct ifaddrs *p = head; p; p = p->ifa_next) {
            if (!p->ifa_addr || strcmp(s.iface.UTF8String, p->ifa_name)) continue;
            switch (p->ifa_addr->sa_family) {
                case AF_LINK:
                    if (p->ifa_data) s.received = ((struct if_data *)p->ifa_data)->ifi_ipackets;
                    break;
                case AF_INET: {
                    uint32_t addr = ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr);
                    if (addr && (addr >> 16) != 0xa9fe) v4 = YES;
                    break;
                }
                case AF_INET6: {
                    struct in6_addr addr = ((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
                    if ((addr.s6_addr[0] & 0xe0) == 0x20 || (addr.s6_addr[0] & 0xfe) == 0xfc) s.ipv6 = YES;
                    break;
                }
            }
        }
        freeifaddrs(head);
    }
    SCNetworkServiceRef service = copyService(s.iface);
    if (!service) { s.state = NoService; return; }
    SCNetworkProtocolRef proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4);
    if (proto && SCNetworkProtocolGetEnabled(proto)) {
        NSDictionary *cfg = (__bridge NSDictionary *)SCNetworkProtocolGetConfiguration(proto);
        s.dhcp = [cfg[(__bridge NSString *)kSCPropNetIPv4ConfigMethod] isEqual:(__bridge NSString *)kSCValNetIPv4ConfigMethodDHCP];
    }
    if (proto) CFRelease(proto);
    NSString *key = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkServiceEntity(NULL, kSCDynamicStoreDomainState,
        SCNetworkServiceGetServiceID(service), kSCEntNetIPv4));
    NSDictionary *state = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, (__bridge CFStringRef)key));
    s.router = state[(__bridge NSString *)kSCPropNetIPv4Router];
    CFRelease(service);
    s.state = (v4 || s.ipv6) ? LocalUnknown : NoAddress;
}
static Snapshot *snapshot(void) {
    Snapshot *s = [Snapshot new];
    io_connect_t c = adapter();
    if (!c) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("itlwm"));
        s.state = service ? Unready : Missing;
        if (service) IOObjectRelease(service);
        return s;
    }
    struct ioctl_driver_info driver = {0};
    struct ioctl_power power = {0};
    struct ioctl_state state = {0};
    s.state = Unready;
    if (readMethod(c, IOCTL_80211_DRIVER_INFO, &driver, sizeof(driver))) {
        if (driver.version != IOCTL_VERSION) s.state = Incompatible;
        else if (memchr(driver.bsd_name, 0, sizeof(driver.bsd_name)) && if_nametoindex(driver.bsd_name) &&
                 readMethod(c, IOCTL_80211_POWER, &power, sizeof(power))) {
            s.iface = @(driver.bsd_name);
            if (!power.enabled) s.state = RadioOff;
            else if (readMethod(c, IOCTL_80211_STATE, &state, sizeof(state))) {
                switch (state.state) {
                    case ITL80211_S_RUN: {
                        struct ioctl_sta_info sta = {0};
                        if (readMethod(c, IOCTL_80211_STA_INFO, &sta, sizeof(sta)) && sta.version == IOCTL_VERSION) {
                            s.channel = sta.channel; s.width = sta.band_width; s.rssi = sta.rssi;
                            if (sta.op_mode == ITL80211_MODE_11AC || sta.op_mode == ITL80211_MODE_11N) s.rate = sta.rate;
                        }
                        struct ioctl_nw_bssid ap = {0};
                        if (readMethod(c, IOCTL_80211_NW_BSSID, &ap, sizeof(ap))) {
                            // Used in memory only to distinguish access points with the same gateway.
                            s.network = [[NSData dataWithBytes:ap.bssid length:sizeof(ap.bssid)] base64EncodedStringWithOptions:0];
                        }
                        inspectAddresses(s);
                        break;
                    }
                    case ITL80211_S_INIT: case ITL80211_S_SCAN:
                        s.state = Searching; s.scan = cachedScan(c); break;
                    case ITL80211_S_ASSOC: case ITL80211_S_AUTH: s.state = Joining; break;
                }
            }
        }
    }
    IOServiceClose(c);
    return s;
}
static BOOL tcpReply(NSString *iface, NSString *address, uint16_t port) {
    unsigned index = if_nametoindex(iface.UTF8String);
    struct sockaddr_in dst = { .sin_len = sizeof(dst), .sin_family = AF_INET, .sin_port = htons(port) };
    if (!index || !address.length || inet_pton(AF_INET, address.UTF8String, &dst.sin_addr) != 1) return NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    BOOL ok = NO;
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, sizeof(index)) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0) {
        int result = connect(fd, (struct sockaddr *)&dst, sizeof(dst));
        if (result == 0 || errno == ECONNREFUSED) ok = YES;
        else if (errno == EINPROGRESS) {
            struct pollfd pollfd = { .fd = fd, .events = POLLOUT };
            int error = 0; socklen_t len = sizeof(error);
            ok = poll(&pollfd, 1, 750) > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 &&
                 (error == 0 || error == ECONNREFUSED);
        }
    }
    close(fd);
    return ok;
}
// Keep one opaque fingerprint so a router known to answer before a reboot can
// still be recognized after login. Never record an SSID, BSSID or IP in the report.
static NSString *networkToken(NSString *key) {
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}
static BOOL localReply(Snapshot *s) {
    if (tcpReply(s.iface, s.router, 443)) return YES;
    if (tcpReply(s.iface, s.router, 80)) return YES;
    if (tcpReply(s.iface, s.router, 53)) return YES;
    if (tcpReply(s.iface, @"8.8.8.8", 53)) return YES;
    if (tcpReply(s.iface, @"1.1.1.1", 53)) return YES;
    struct in_addr address;
    if (!s.router.length || inet_pton(AF_INET, s.router.UTF8String, &address) != 1) return NO;
    NSTask *ping = [NSTask new];
    ping.executableURL = [NSURL fileURLWithPath:@"/sbin/ping"];
    ping.arguments = @[@"-n", @"-b", s.iface, @"-c", @"1", @"-t", @"2", s.router];
    ping.standardOutput = ping.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![ping launchAndReturnError:NULL]) return NO;
    [ping waitUntilExit];
    return ping.terminationStatus == 0;
}
// Called only by the root DHCP job when itlwm is associated. A disabled service
// expresses user intent. Only create a service if the current location has none for this interface.
static BOOL restoreMissingService(NSString *bsd) {
    SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("ZenBook Wi-Fi"), NULL);
    if (!prefs) return NO;
    if (!SCPreferencesLock(prefs, false)) { CFRelease(prefs); return NO; }
    SCPreferencesSynchronize(prefs);
    SCNetworkSetRef set = SCNetworkSetCopyCurrent(prefs);
    BOOL exists = NO, result = NO;
    NSArray *services = set ? CFBridgingRelease(SCNetworkSetCopyServices(set)) : nil;
    NSString *type = liveType(bsd);
    for (id item in services)
        if (serves((__bridge SCNetworkServiceRef)item, bsd, type)) exists = YES;
    if (set && !exists) {
        NSArray *interfaces = CFBridgingRelease(SCNetworkInterfaceCopyAll());
        for (id item in interfaces) {
            SCNetworkInterfaceRef iface = (__bridge SCNetworkInterfaceRef)item;
            if (![bsd isEqual:(__bridge NSString *)SCNetworkInterfaceGetBSDName(iface)]) continue;
            SCNetworkServiceRef service = SCNetworkServiceCreate(prefs, iface);
            result = service && SCNetworkServiceEstablishDefaultConfiguration(service) &&
                SCNetworkSetAddService(set, service) && SCPreferencesCommitChanges(prefs) &&
                SCPreferencesApplyChanges(prefs);
            if (service) CFRelease(service);
            break;
        }
    }
    if (set) CFRelease(set);
    SCPreferencesUnlock(prefs); CFRelease(prefs);
    return exists || result;
}
static int retryDHCP(void) {
    if (geteuid() != 0) return 1;
    Snapshot *s = snapshot();
    if (s.state == NoService) return restoreMissingService(s.iface) ? 0 : 1;
    if (!s.dhcp || s.state != NoAddress) return 0;
    SCNetworkServiceRef service = copyService(s.iface);
    if (!service) return 0;
    SCNetworkInterfaceRef iface = SCNetworkServiceGetInterface(service);
    BOOL refreshed = iface && SCNetworkInterfaceForceConfigurationRefresh(iface);
    CFRelease(service);
    return refreshed ? 0 : 1;
}

static NSURL *homePath(NSString *relative) {
    return [[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES] URLByAppendingPathComponent:relative];
}
static NSString *linkDetails(Snapshot *s) {
    if (!s.channel) return @"";
    NSString *rate = s.rate ? [NSString stringWithFormat:@", driver TX rate %u Mbps", s.rate] : @"";
    return [NSString stringWithFormat:@"%@, channel %u, %u MHz, signal %d dBm%@",
        s.channel <= 14 ? @"2.4 GHz" : @"5 GHz", s.channel, s.width, s.rssi, rate];
}
// Use a cache refresh only with an associated radio. itlwm 2.3 ignores
// background scan requests in INIT and SCAN. Keep benchmarks free of scans.
static BOOL refreshScan(void) {
    io_connect_t c = adapter();
    if (!c) return NO;
    struct ioctl_driver_info info = {0};
    struct ioctl_scan scan = { .version = IOCTL_VERSION };
    BOOL ok = readMethod(c, IOCTL_80211_DRIVER_INFO, &info, sizeof(info)) && info.version == IOCTL_VERSION &&
        IOConnectCallStructMethod(c, IOCTL_MASK | IOCTL_80211_SCAN, &scan, sizeof(scan), NULL, NULL) == KERN_SUCCESS;
    IOServiceClose(c);
    return ok;
}
static BOOL strongAlternative(const struct ioctl_network_info *current, const struct ioctl_network_info *other) {
    return current->ssid[0] && current->channel > 0 && current->channel <= 14 &&
        other->channel >= 36 && other->channel <= 177 && other->rssi < 0 && other->rssi >= -67 &&
        other->rssi >= current->rssi - 10 && current->rsn_protos && current->rsn_protos == other->rsn_protos &&
        current->rsn_akms && current->rsn_akms == other->rsn_akms &&
        current->rsn_ciphers == other->rsn_ciphers && current->rsn_groupcipher == other->rsn_groupcipher &&
        memcmp(current->ssid, other->ssid, NWID_LEN) == 0;
}
static BOOL canTry5GHz(Snapshot *s) {
    if (!s.channel || s.channel > 14 || !s.network.length) return NO;
    io_connect_t c = adapter();
    if (!c) return NO;
    struct ioctl_sta_info sta = {0};
    struct ioctl_network_info rows[128] = {0};
    NSUInteger count = 0;
    const struct ioctl_network_info *current = NULL;
    if (readMethod(c, IOCTL_80211_STA_INFO, &sta, sizeof(sta)) && sta.version == IOCTL_VERSION &&
        sta.channel == s.channel && [s.network isEqualToString:
            [[NSData dataWithBytes:sta.bssid length:sizeof(sta.bssid)] base64EncodedStringWithOptions:0]]) {
        while (count < 128 && readMethod(c, IOCTL_80211_SCAN_RESULT, &rows[count], sizeof(rows[count]))) {
            if (memcmp(rows[count].bssid, sta.bssid, sizeof(sta.bssid)) == 0) current = &rows[count];
            count++;
        }
    }
    IOServiceClose(c);
    if (current) for (NSUInteger i = 0; i < count; i++)
        if (strongAlternative(current, &rows[i])) return YES;
    return NO;
}
static unsigned scanCount(int *best) {   // networks in the driver's cache and the strongest signal
    io_connect_t c = adapter();
    unsigned n = 0; *best = 0;
    if (!c) return 0;
    struct ioctl_network_info row;
    while (n < 256) {
        memset(&row, 0, sizeof(row));
        if (!readMethod(c, IOCTL_80211_SCAN_RESULT, &row, sizeof(row))) break;
        if (!*best || row.rssi > *best) *best = row.rssi;
        n++;
    }
    IOServiceClose(c);
    return n;
}
static NSString *describe(LinkStatus state);
static NSString *driverVersion(void) {   // 2.5: proves which itlwm build is running
    io_connect_t c = adapter();
    if (!c) return nil;
    struct ioctl_driver_info d = {0};
    NSString *v = nil;
    if (readMethod(c, IOCTL_80211_DRIVER_INFO, &d, sizeof(d)) &&
        memchr(d.driver_version, 0, sizeof(d.driver_version)) && memchr(d.fw_version, 0, sizeof(d.fw_version)))
        v = [NSString stringWithFormat:@"itlwm %s, firmware %s", d.driver_version, d.fw_version];
    IOServiceClose(c);
    return v;
}
static NSString *linkLine(void) {
    Snapshot *s = snapshot();
    int best = 0; unsigned n = s.state >= Searching ? scanCount(&best) : 0;
    NSMutableString *line = [describe(s.state) mutableCopy];
    if (s.channel) [line appendFormat:@" | %@", linkDetails(s)];
    if (s.state >= Searching) [line appendFormat:@" | driver list: %u networks%@", n, n ? [NSString stringWithFormat:@", strongest %d dBm", best] : @""];
    return line;
}
static NSString *describe(LinkStatus state) {
    switch (state) {
        case Missing: return @"Intel itlwm driver missing from this boot";
        case Incompatible: return @"Incompatible itlwm driver API";
        case Unready: return @"Intel driver present, waiting for a usable interface";
        case RadioOff: return @"Intel radio off";
        case Searching: return @"Radio on, searching for a network";
        case Joining: return @"Authenticating or associating";
        case NoService: return @"Joined, but macOS has no enabled network service for the Intel interface";
        case NoAddress: return @"Joined, waiting for a usable IP address";
        case LocalUnknown: return @"IP configured; router reply unconfirmed";
        case LocalOK: return @"IP configured; local router replied over Intel Wi-Fi";
        case LocalStall: return @"Previously reachable router silent; no incoming packets or independent TCP reply";
    }
}
static NSRunningApplication *client(void) {
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:clientID])
        if ([app.bundleURL.path isEqualToString:clientPath] && !app.terminated) return app;
    return nil;
}
static void openClient(void) {
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:clientPath]
        configuration:config completionHandler:nil];
}
// 2.4: tell the user when the card is frozen - a frozen AX201 needs the lid (sleep) or a real
// Shut Down (power off); a restart does not always reset it.
static void notifyUser(NSString *title, NSString *text) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[@"-e", [NSString stringWithFormat:@"display alert \"%@\" message \"%@\"", title, text]];
    t.standardOutput = t.standardError = NSFileHandle.fileHandleWithNullDevice;
    [t launchAndReturnError:NULL];
}
static BOOL hasService(const char *cls) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
    if (svc) IOObjectRelease(svc);
    return svc != IO_OBJECT_NULL;
}
static NSString *const frozenText = @"The Intel Wi-Fi card stopped hearing any network and a radio restart did not revive it. Close the lid for 15 seconds, then open it. If Wi-Fi is still gone: Apple menu > Shut Down (NOT Restart), wait 30 seconds, turn the laptop on.";
static NSString *const missingText = @"The Intel Wi-Fi card did not start (it is still frozen from before). Apple menu > Shut Down (NOT Restart), wait 30 seconds, then turn the laptop on again.";
@interface Monitor : NSObject
- (void)begin:(NSString *)event;
- (void)tick;
- (void)prepareForSleep;
- (void)resumeAfterSleep:(NSString *)event;
@end
@implementation Monitor {
    RecoveryPolicy _policy;
    NSString *_network, *_previous;
    BOOL _baseline, _havePackets, _wantOn;
    uint64_t _received;
    double _lastLog;
    NSURL *_log, *_request;
    NSUserDefaults *_prefs;
    double _missingSince;
    BOOL _missingNotified, _frozen, _frozenNotified, _checkAfterWake;
}
- (instancetype)init {
    if ((self = [super init])) {
        _prefs = [[NSUserDefaults alloc] initWithSuiteName:@"local.zenbook.wifi.recovery"];
        NSURL *logs = homePath(@"Library/Logs/ZenBook Wi-Fi");
        NSURL *settings = homePath(support);
        for (NSURL *dir in @[logs, settings])
            [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        _log = [logs URLByAppendingPathComponent:@"Last Wake.txt"];
        _request = [settings URLByAppendingPathComponent:@"Repair requested"];
    }
    return self;
}
- (void)record:(NSString *)message {
    NSString *line = [NSString stringWithFormat:@"%@   %@\n", NSDate.date, message];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attr = [fm attributesOfItemAtPath:_log.path error:NULL];
    if ([attr fileSize] >= 65536) {
        NSURL *previous = [[_log URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Previous.txt"];
        [fm removeItemAtURL:previous error:NULL];
        [fm moveItemAtURL:_log toURL:previous error:NULL];
    }
    if (![fm fileExistsAtPath:_log.path]) [fm createFileAtPath:_log.path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *f = [NSFileHandle fileHandleForWritingToURL:_log error:NULL];
    [f seekToEndOfFile]; [f writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile];
}
- (void)begin:(NSString *)event {
    startWindow(&_policy, uptime());
    _previous = nil; _havePackets = NO;
    NSDate *joined = [_prefs objectForKey:@"LastJoined"];
    if (([joined isKindOfClass:NSDate.class] && joined.timeIntervalSinceNow > -7*86400) ||
        (!joined && [_prefs objectForKey:@"LastReachableRouter"]))
        _policy.wasJoined = true;
    _wantOn = [_prefs boolForKey:@"LastRadioOn"];
    _frozenNotified = NO;
    NSString *dv = driverVersion();
    [self record:dv ? [NSString stringWithFormat:@"%@ (%@)", event, dv] : event];
}
- (void)tick {
    uid_t active = 0;
    CFStringRef user = SCDynamicStoreCopyConsoleUser(NULL, &active, NULL);
    if (user) CFRelease(user);
    if (active != getuid()) return;
    BOOL manual = [NSFileManager.defaultManager removeItemAtURL:_request error:NULL];
    Snapshot *s = snapshot();
    NSURL *bandRequest = [homePath(support) URLByAppendingPathComponent:@"Band retry.plist"];
    NSDictionary *band = [NSDictionary dictionaryWithContentsOfURL:bandRequest];
    if (band && [NSFileManager.defaultManager removeItemAtURL:bandRequest error:NULL]) {
        NSDate *until = band[@"expires"];
        if ([until isKindOfClass:NSDate.class] && until.timeIntervalSinceNow > 0 &&
            s.network.length && [networkToken(s.network) isEqual:band[@"link"]] && canTry5GHz(s)) {
            manual = YES;
            [self record:@"Requested band retry with a strong 5 GHz access point for the same saved network"];
        } else [self record:@"Skipped band retry because the connection or available access points changed"];
    }
    double now = uptime();
    if (s.state >= NoService && (_policy.last < NoService || !_policy.wasJoined)) {
        [_prefs setObject:NSDate.date forKey:@"LastJoined"];
    }
    observeScan(&_policy, s.state, s.scan, now);
    if (s.state == LocalUnknown && s.router.length) {
        NSString *key = [NSString stringWithFormat:@"%@/%@/%@", s.iface, s.network ?: @"", s.router];
        if (![key isEqualToString:_network]) {
            _network = key; _havePackets = NO;
            _baseline = s.network.length && [networkToken(key) isEqual:[_prefs objectForKey:@"LastReachableRouter"]];
        }
        if (localReply(s)) {
            s.state = LocalOK;
            if (!_baseline && s.network.length) [_prefs setObject:networkToken(key) forKey:@"LastReachableRouter"];
            _baseline = YES;
        }
        else if (_baseline) {
            // Keep LocalOK if router/network was reachable; do not flag stall on idle traffic
            s.state = LocalOK;
        }
        _received = s.received; _havePackets = YES;
    } else { _havePackets = NO; }
    NSString *detail = describe(s.state);
    if (s.state == Searching) {
        NSString *cache = s.scan == ScanEmpty ? @"empty" : s.scan == ScanVisible ? @"networks visible" : @"read failed";
        detail = [detail stringByAppendingFormat:@". Driver scan list %@", cache];
    }
    if (s.state == Missing) {
        io_service_t other = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AirportItlwm"));
        if (other) { detail = @"AirportItlwm is active. Boot the SSD profile installed by the HeliPort package"; IOObjectRelease(other); }
    }
    NSRunningApplication *app = client();
    NSString *status = [NSString stringWithFormat:@"%@. HeliPort %@.", detail, app ? @"running" : @"closed"];
    if (![_previous isEqualToString:status] || now - _lastLog >= 120 || manual) {
        [self record:[NSString stringWithFormat:@"+%.0f s  %@ %@", now - _policy.epoch, status, linkDetails(s)]];
        _previous = status; _lastLog = now;
    }
    // 2.4: driver missing for a minute (not AirportItlwm) = card frozen since before this start
    if (s.state == Missing && !hasService("AirportItlwm")) {
        if (!_missingSince) _missingSince = now;
        if (now - _missingSince >= 60 && !_missingNotified) {
            _missingNotified = YES;
            [self record:@"FROZEN: the itlwm driver did not start - Shut Down (not Restart) resets the card"];
            notifyUser(@"Wi-Fi card did not start", missingText);
        }
    } else { _missingSince = 0; }
    // 2.4: was the card frozen before this sleep? record whether the lid revived it
    if (_checkAfterWake && now - _policy.epoch >= 30) {
        _checkAfterWake = NO;
        BOOL alive = s.state >= Joining || (s.state == Searching && s.scan == ScanVisible);
        [self record:alive ? @"LID RESET WORKED: the card was frozen before the sleep and hears networks again"
                           : @"LID RESET DID NOT WORK: the card is still frozen after the sleep - Shut Down (not Restart) needed"];
        if (alive) _frozen = NO;
        else notifyUser(@"Wi-Fi card is still frozen", missingText);
    }
    if (s.state >= Joining) _frozen = NO;
    // Finish a reset interrupted between off and on, including across agent restarts.
    NSDate *pending = [_prefs objectForKey:@"PendingOnUntil"];
    BOOL finish = pending && pending.timeIntervalSinceNow > 0 && s.state == RadioOff;
    if (pending && (pending.timeIntervalSinceNow <= 0 || (s.state > RadioOff))) [_prefs removeObjectForKey:@"PendingOnUntil"];
    // Once the radio has been seen on, a subsequent manual off is respected even during the wake grace period.
    if (s.state > RadioOff) _policy.restored = true;
    RecoveryAction action = finish ? TurnOn : decide(&_policy, s.state, now, app != nil, _wantOn, manual);
    if (s.state > RadioOff || (s.state == RadioOff && action != TurnOn)) {
        if (s.state > RadioOff || !_wantOn || _policy.restored || now - _policy.epoch > 120) {
            _wantOn = s.state != RadioOff;
            [_prefs setBool:_wantOn forKey:@"LastRadioOn"];
        }
    }
    switch (action) {
        case Launch: openClient(); [self record:@"Requested the installed HeliPort after driver initialization"]; break;
        case Rejoin:
            [self record:app.terminate ? @"Requested a fresh HeliPort saved-network scan" : @"HeliPort declined to quit"];
            break;
        case TurnOn:
            if (setRadio(YES)) { [self record:@"Requested Intel radio on"]; if ([app terminate]) _policy.nextAction = 0; }
            else [self record:@"Driver declined radio-on request"];
            break;
        case Cycle: {
            if (!manual) {
                Snapshot *latest = snapshot();
                BOOL stillEmpty = s.state == Searching && latest.state == Searching && latest.scan == ScanEmpty;
                BOOL stillStalled = s.state == LocalStall && latest.state == LocalUnknown &&
                    [s.router isEqual:latest.router] && latest.received == s.received;
                if (![s.iface isEqual:latest.iface] || (!stillEmpty && !stillStalled)) {
                    [self record:@"Link changed during the probe; skipped radio reset"];
                    _policy.cycles--; _policy.nextCycle = 0;
                    break;
                }
                if (stillEmpty) [self record:[NSString stringWithFormat:@"Intel scan list stayed empty while disconnected for %d seconds; restarting the radio (%d of %d)", EmptyScanSeconds, _policy.cycles, MaxCycles]];
                if (stillEmpty && _policy.cycles >= 2) {
                    _frozen = YES;
                    [self record:@"FROZEN: still no networks after a radio restart - the card needs the lid (sleep) or a Shut Down"];
                    if (!_frozenNotified) { _frozenNotified = YES; notifyUser(@"Wi-Fi card froze", frozenText); }
                }
                else [self record:[NSString stringWithFormat:@"Router silent, no packets for %d seconds; restarting the radio (%d of %d)", StallSeconds, _policy.cycles, MaxCycles]];
            }
            [_prefs setObject:[NSDate dateWithTimeIntervalSinceNow:120] forKey:@"PendingOnUntil"];
            [_prefs synchronize];
            if (!setRadio(NO)) { [_prefs removeObjectForKey:@"PendingOnUntil"]; [self record:@"Driver declined radio reset"]; break; }
            [NSThread sleepForTimeInterval:1];
            BOOL on = setRadio(YES);
            [self record:on ? @"Cycled Intel radio; requesting a saved-network scan" : @"Radio-on pending; will retry"];
            [app terminate];
            break;
        }
        case Wait: break;
    }
}
// 2.3: itlwm 2.3's own sleep/wake handler only acknowledges power changes and never stops or
// re-initialises the card (pm.cpp). Stop the radio cleanly before sleep and restart it after
// wake - the power ioctl runs the full stop / firmware init path - so every wake starts fresh.
- (void)prepareForSleep {
    Snapshot *s = snapshot();
    if (s.state <= RadioOff) { [self record:@"Sleep: radio already off or driver unavailable; left as it is"]; return; }
    [_prefs setObject:@YES forKey:@"LastRadioOn"];
    if (setRadio(NO)) {
        [_prefs setObject:@YES forKey:@"OffForSleep"];
        [self record:@"Sleep: Intel radio stopped cleanly; it restarts with fresh firmware after wake"];
    } else [self record:@"Sleep: driver declined the radio stop"];
    [_prefs synchronize];
}
- (void)resumeAfterSleep:(NSString *)event {
    BOOL restart = [[_prefs objectForKey:@"OffForSleep"] boolValue];
    [_prefs removeObjectForKey:@"OffForSleep"];
    _checkAfterWake = _frozen;
    [self begin:event];
    if (restart && snapshot().state == RadioOff) {
        [NSThread sleepForTimeInterval:1];
        if (setRadio(YES)) {
            [self record:@"Wake: Intel radio restarted with fresh firmware; HeliPort rejoins"];
            NSRunningApplication *app = client();
            if ([app terminate]) _policy.nextAction = 0;   // a fresh HeliPort runs its saved-network join
        } else {
            [_prefs setObject:[NSDate dateWithTimeIntervalSinceNow:120] forKey:@"PendingOnUntil"];
            [self record:@"Wake: radio-on pending; will retry"];
        }
    }
    [self tick];
}
@end
static NSString *speedLine(NSDictionary *data, NSString *bitsKey, NSString *mbpsKey) {
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *value = data[bitsKey];
    double divisor = 1e6;
    if (![value isKindOfClass:NSNumber.class]) { value = data[mbpsKey]; divisor = 1; }
    if (![value isKindOfClass:NSNumber.class] || !isfinite(value.doubleValue) || value.doubleValue <= 0) return nil;
    return [NSString stringWithFormat:@"%.1f Mbps", value.doubleValue / divisor];
}
static void testSpeed(Snapshot *before) {
    NSAlert *message = [NSAlert new];
    if (!before.iface.length || before.state < LocalUnknown) {
        message.messageText = @"Connect with HeliPort first";
        message.informativeText = describe(before.state);
        [message runModal]; return;
    }
    NSURL *temp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createFileAtPath:temp.path contents:nil attributes:@{NSFilePosixPermissions:@0600}]) return;
    NSFileHandle *out = [NSFileHandle fileHandleForWritingToURL:temp error:NULL];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/networkQuality"];
    task.arguments = @[@"-I", before.iface, @"-s", @"-c"];
    task.standardOutput = out; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (!out || ![task launchAndReturnError:&error]) {
        [fm removeItemAtURL:temp error:NULL];
        if (error) [[NSAlert alertWithError:error] runModal]; return;
    }
    [out closeFile];
    message.messageText = @"Testing internet speed over Intel Wi-Fi";
    message.informativeText = linkDetails(before);
    [message addButtonWithTitle:@"Cancel"];
    NSModalSession session = [NSApp beginModalSessionForWindow:message.window];
    double deadline = uptime() + 90;
    BOOL cancelled = NO;
    while (task.running && uptime() < deadline) {
        if ([NSApp runModalSession:session] != NSModalResponseContinue) { cancelled = YES; break; }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    BOOL timeout = task.running && !cancelled;
    if (task.running) [task terminate];
    [task waitUntilExit];
    NSDictionary *data = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:temp] ?: [NSData data] options:0 error:NULL];
    [fm removeItemAtURL:temp error:NULL];
    Snapshot *after = snapshot();
    BOOL same = before.network.length && [before.network isEqual:after.network] && [before.iface isEqual:after.iface];
    BOOL retry = NO;
    if (!cancelled && same && after.channel && after.channel <= 14 && refreshScan()) {
        message.messageText = @"Checking for a stronger 5 GHz connection";
        double until = uptime() + 5;
        while (uptime() < until) {
            if ([NSApp runModalSession:session] != NSModalResponseContinue) { cancelled = YES; break; }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        if (!cancelled) retry = canTry5GHz(after);
    }
    [NSApp endModalSession:session]; [message.window orderOut:nil];
    if (cancelled) return;
    NSString *down = speedLine(data, @"dl_throughput", @"downlink_capacity_mbps");
    NSString *up = speedLine(data, @"ul_throughput", @"uplink_capacity_mbps");
    NSString *result;
    if (task.terminationStatus || timeout || !down || !up)
        result = @"The internet test did not complete both directions. Throughput is unconfirmed.";
    else result = [NSString stringWithFormat:@"Download %@   •   Upload %@", down, up];
    NSString *tip = @"Compare another device in the same room on the same router and band.";
    if (!same) tip = @"The Wi-Fi connection changed during the test. Repeat once the link is stable.";
    else if (retry) tip = @"The scan found a strong 5 GHz access point for this network. Try 5 GHz briefly reconnects Wi-Fi and lets the Intel driver select a band. Run Test Speed again to compare.";
    else if (after.channel && after.channel <= 14) tip = @"You are using 2.4 GHz. If your router has a separately named 5 GHz network, choose it in HeliPort near the router, then repeat this test.";
    NSString *report = [NSString stringWithFormat:@"%@\n%@\nBefore  %@\nAfter  %@ %@\n%@", NSDate.date, result,
        linkDetails(before), describe(after.state), linkDetails(after), tip];
    NSURL *url = homePath(@"Library/Logs/ZenBook Wi-Fi/Speed Test.txt");
    [fm createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    BOOL saved = [report writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    message = [NSAlert new]; message.messageText = result;
    message.informativeText = [NSString stringWithFormat:@"%@\n\n%@%@", linkDetails(after), tip,
        saved ? @"\n\nSaved as Speed Test.txt beside Last Wake.txt." : @"\n\nCould not save Speed Test.txt."];
    [message addButtonWithTitle:retry ? @"Try 5 GHz" : @"Done"];
    if (retry) [message addButtonWithTitle:@"Keep Connection"];
    if ([message runModal] == NSAlertFirstButtonReturn && retry) {
        NSDictionary *request = @{@"expires":[NSDate dateWithTimeIntervalSinceNow:45], @"link":networkToken(after.network)};
        NSURL *url = [homePath(support) URLByAppendingPathComponent:@"Band retry.plist"];
        message = [NSAlert new];
        message.messageText = [request writeToURL:url atomically:YES] ? @"Band retry requested" : @"Could not save the band request";
        message.informativeText = @"Open the repair app again to see the band the router and adapter selected.";
        [message runModal];
    }
}

static void showReport(void) {
    NSURL *log = homePath(@"Library/Logs/ZenBook Wi-Fi/Last Wake.txt");
    NSString *wake = [NSString stringWithContentsOfURL:log encoding:NSUTF8StringEncoding error:NULL];
    NSAlert *alert = [NSAlert new];
    if (!wake) {
        alert.messageText = @"No wake report yet";
        alert.informativeText = @"Sign in to macOS after installing the Wi-Fi package.";
        [alert runModal]; return;
    }
    alert.messageText = @"Wi-Fi report";
    alert.informativeText = @"Save a copy of the wake log and your latest speed test together. You can choose the USB in Finder.";
    [alert addButtonWithTitle:@"Save a Copy…"]; [alert addButtonWithTitle:@"Show on SSD"];
    if ([alert runModal] == NSAlertSecondButtonReturn) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[log]]; return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"ZenBook Wi-Fi Report.txt";
    NSURL *usb = [NSURL fileURLWithPath:@"/Volumes/Install macOS Sonoma/UX325EA-RESCUE/TEST-RESULTS" isDirectory:YES];
    if ([NSFileManager.defaultManager isWritableFileAtPath:usb.path]) panel.directoryURL = usb;
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *speed = [NSString stringWithContentsOfURL:homePath(@"Library/Logs/ZenBook Wi-Fi/Speed Test.txt")
        encoding:NSUTF8StringEncoding error:NULL];
    NSString *report = [NSString stringWithFormat:@"ZenBook Wi-Fi 2.5\n\n%@\n\n%@",
        speed ?: @"No speed test recorded.", wake];
    NSError *error = nil;
    if (![report writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error])
        [[NSAlert alertWithError:error] runModal];
    else [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[panel.URL]];
}
static int showRepair(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp activateIgnoringOtherApps:YES];
    Snapshot *s = snapshot();
    NSAlert *alert = [NSAlert new]; alert.messageText = @"ZenBook Wi-Fi";
    alert.informativeText = [NSString stringWithFormat:@"%@. %@\n\nTest Speed measures internet download and upload on Intel Wi-Fi and uses data. Reconnect restarts the connection.", describe(s.state), linkDetails(s)];
    [alert addButtonWithTitle:@"Test Speed"]; [alert addButtonWithTitle:@"Show Report"];
    [alert addButtonWithTitle:@"Reconnect"]; [alert addButtonWithTitle:@"Close"];
    NSModalResponse choice = alert.runModal;
    if (choice == NSAlertFirstButtonReturn) testSpeed(s);
    else if (choice == NSAlertSecondButtonReturn) {
        showReport();
    } else if (choice == NSAlertThirdButtonReturn) {
        NSURL *request = [homePath(support) URLByAppendingPathComponent:@"Repair requested"];
        NSError *error = nil;
        if (s.state == Missing || s.state == Incompatible || s.state == Unready) {
            alert = [NSAlert new]; alert.messageText = describe(s.state);
            alert.informativeText = @"The login agent keeps checking for the adapter. If it stays unavailable after startup, open Show Report and share Last Wake.txt.";
            [alert runModal];
        } else if (![[NSData data] writeToURL:request options:NSDataWritingAtomic error:&error]) {
            [[NSAlert alertWithError:error] runModal];
        } else {
            alert = [NSAlert new]; alert.messageText = @"Reconnect requested";
            alert.informativeText = @"The Wi-Fi agent checks within 15 seconds. Open HeliPort if your network still needs to be saved.";
            [alert runModal];
        }
    }
    return 0;
}
static Monitor *monitorRef;
static dispatch_queue_t monitorQueue;
static BOOL sleeping;
static io_connect_t rootPort;
static void powerChanged(void *refcon, io_service_t service, natural_t type, void *arg) {
    switch (type) {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(rootPort, (long)arg); break;
        case kIOMessageSystemWillSleep:   // runs before the system may sleep (it waits for IOAllowPowerChange)
            dispatch_sync(monitorQueue, ^{ sleeping = YES; @autoreleasepool { [monitorRef prepareForSleep]; } });
            IOAllowPowerChange(rootPort, (long)arg); break;
        case kIOMessageSystemWillNotSleep:
            dispatch_async(monitorQueue, ^{ sleeping = NO; @autoreleasepool { [monitorRef resumeAfterSleep:@"Sleep cancelled"]; } }); break;
        case kIOMessageSystemHasPoweredOn:
            dispatch_async(monitorQueue, ^{ sleeping = NO; @autoreleasepool { [monitorRef resumeAfterSleep:@"System wake"]; } }); break;
    }
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--retry-ip") == 0) return retryDHCP();
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"local.zenbook.wifi.repair"]) return showRepair();
    if (argc == 2 && strcmp(argv[1], "--status") == 0) { puts(describe(snapshot().state).UTF8String); return 0; }
    if (argc == 2 && strcmp(argv[1], "--link") == 0) { puts(linkLine().UTF8String); return 0; }
    if (geteuid() == 0) return 1;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    Monitor *monitor = [Monitor new];
    dispatch_queue_t q = dispatch_queue_create("local.zenbook.wifi.recovery", DISPATCH_QUEUE_SERIAL);
    monitorRef = monitor; monitorQueue = q;
    IONotificationPortRef port = NULL; io_object_t notifier = IO_OBJECT_NULL;
    rootPort = IORegisterForSystemPower(NULL, &port, powerChanged, &notifier);
    if (rootPort) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
    else {   // fallback (2.2 behaviour): no clean stop before sleep
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(q, ^{ sleeping = YES; });
        }];
        [center addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(q, ^{ sleeping = NO; [monitor begin:@"System wake"]; [monitor tick]; });
        }];
    }
    // also finishes a restart if the agent itself was restarted between sleep and wake
    dispatch_async(q, ^{ [monitor resumeAfterSleep:rootPort ? @"Login agent started" : @"Login agent started (no sleep hook)"]; });
    __attribute__((objc_precise_lifetime)) dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), 15*NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { if (!sleeping) [monitor tick]; } });
    dispatch_resume(timer);
    [NSApp run];
    return 0;
}}
