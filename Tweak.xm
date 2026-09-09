#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <fcntl.h>
#import <unistd.h>

@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *recordID;
@property (nonatomic, copy) NSString *publisherBulletinID;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, strong) NSDate *publicationDate;
@property (nonatomic, strong) NSDate *lastInterruptDate;
@property (nonatomic, strong) id defaultAction;
@property (nonatomic, assign, getter=isClearable) BOOL clearable;
@property (nonatomic, assign) BOOL showsMessagePreview;
@property (nonatomic, assign) BOOL turnsOnDisplay;
@end

@interface BBAction : NSObject
+ (id)actionWithLaunchBundleID:(NSString *)bundleID callblock:(id)block;
@end

@interface BBSectionInfo : NSObject
- (id)initWithDefaultsForSectionType:(long long)type;
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, assign) BOOL allowsNotifications;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL showsInLockScreen;
@property (nonatomic, assign) BOOL showsInNotificationCenter;
@property (nonatomic, assign) BOOL showsMessagePreview;
@property (nonatomic, assign) unsigned long long alertType;
@property (nonatomic, assign) unsigned long long pushSettings;
@end

@interface BBServer : NSObject
- (id)initWithQueue:(id)queue;
- (void)_addObserver:(id)observer;
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations;
- (id)_sectionInfoForSectionID:(id)sectionID effective:(BOOL)effective;
- (void)setSectionInfo:(id)sectionInfo forSectionID:(id)sectionID;
@end

static __weak BBServer *gBBServer = nil;
static dispatch_queue_t gMonitorQueue;
static dispatch_source_t gFallbackTimer;
static dispatch_source_t gDirectorySource;
static NSMutableOrderedSet<NSString *> *gRecentReports;
static int gCrashDirectoryFD = -1;
static dispatch_queue_t gBBQueue;

static NSString *const kCNFallbackBundleID = @"jp.dcsyhi.culprit";
static NSString *const kCNStatePath = @"/var/mobile/Library/Preferences/com.551.culpritnotify.state.plist";
static NSString *const kCNLogPath = @"/var/mobile/Library/Logs/CulpritNotify.log";
static NSString *const kCNCrashDirectory = @"/var/mobile/Library/Logs/CrashReporter";

static void CNLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message ?: @""];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kCNLogPath]) {
        [data writeToFile:kCNLogPath atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kCNLogPath];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
}

static NSString *CNCulpritBundleID(void) {
    static NSString *bundleID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithArray:@[
            @"/var/jb/Applications/Culprit.app/Info.plist",
            @"/Applications/Culprit.app/Info.plist"
        ]];

        NSArray<NSString *> *roots = @[@"/var/jb/Applications", @"/Applications"];
        for (NSString *root in roots) {
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:root error:nil];
            for (NSString *item in items) {
                if ([item.lowercaseString containsString:@"culprit"] && [item.pathExtension.lowercaseString isEqualToString:@"app"]) {
                    [paths addObject:[[root stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"]];
                }
            }
        }

        for (NSString *path in paths) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *candidate = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : nil;
            if (candidate.length) {
                bundleID = candidate;
                CNLog(@"Resolved Culprit bundle ID %@ from %@", bundleID, path);
                break;
            }
        }

        if (!bundleID.length) {
            bundleID = kCNFallbackBundleID;
            CNLog(@"Could not resolve Culprit app bundle ID; using fallback %@", bundleID);
        }
    });
    return bundleID;
}

// Resolve each time: BulletinBoard may not have initialized its queue at load time.
// Never substitute the main queue or the report-monitor queue.
static dispatch_queue_t CNBBServerQueue(void) {
    dispatch_queue_t __unsafe_unretained *pointer =
        (dispatch_queue_t __unsafe_unretained *)dlsym(RTLD_DEFAULT, "__BBServerQueue");
    if (pointer && *pointer) return *pointer;
    return gBBQueue; // Captured from BBServer's initializer, under the server lock.
}

static void CNEnsureNotificationSection(BBServer *server, NSString *sectionID) {
    if (!server || !sectionID.length) return;
    @try {
        BBSectionInfo *info = nil;
        if ([server respondsToSelector:@selector(_sectionInfoForSectionID:effective:)]) {
            info = [server _sectionInfoForSectionID:sectionID effective:NO];
        }
        if (!info) {
            Class sectionClass = NSClassFromString(@"BBSectionInfo");
            if (sectionClass) info = [[sectionClass alloc] initWithDefaultsForSectionType:0];
        }
        if (!info) return;

        info.sectionID = sectionID;
        info.displayName = @"Culprit";
        info.appName = @"Culprit";
        info.allowsNotifications = YES;
        info.enabled = YES;
        info.showsInLockScreen = YES;
        info.showsInNotificationCenter = YES;
        info.showsMessagePreview = YES;
        info.alertType = 1;
        info.pushSettings = 63;

        if ([server respondsToSelector:@selector(setSectionInfo:forSectionID:)]) {
            [server setSectionInfo:info forSectionID:sectionID];
            CNLog(@"Ensured BulletinBoard section for %@", sectionID);
        }
    } @catch (NSException *exception) {
        CNLog(@"Unable to configure BulletinBoard section: %@", exception.reason);
    }
}

static void CNPostBulletin(NSString *title, NSString *message, NSUInteger attempt) {
    if (!title.length || !message.length) return;
    BBServer *server;
    dispatch_queue_t queue;
    @synchronized(NSClassFromString(@"BBServer")) {
        server = gBBServer;
        queue = CNBBServerQueue();
    }
    if (!server || !queue) {
        if (attempt < 15) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                CNPostBulletin(title, message, attempt + 1);
            });
        } else {
            CNLog(@"Notification skipped: BulletinBoard server/queue unavailable after retries");
        }
        return;
    }

    dispatch_async(queue, ^{
        @synchronized(NSClassFromString(@"BBServer")) {
            if (gBBServer != server) {
                CNLog(@"Notification skipped: BulletinBoard server changed");
                return;
            }
        }
        // Section lookup asserts queue affinity; setup AND publishing belong here.
        @try {
            Class bulletinClass = NSClassFromString(@"BBBulletin");
            Class actionClass = NSClassFromString(@"BBAction");
            if (!bulletinClass) {
                CNLog(@"Bulletin skipped because BBBulletin class is unavailable");
                return;
            }

            NSString *culpritBundleID = CNCulpritBundleID();
            CNEnsureNotificationSection(server, culpritBundleID);

            BBBulletin *bulletin = [[bulletinClass alloc] init];
            NSDate *now = [NSDate date];
            NSString *unique = [[NSProcessInfo processInfo] globallyUniqueString];

            bulletin.title = title;
            bulletin.message = message;
            bulletin.sectionID = culpritBundleID;
            bulletin.bulletinID = unique;
            bulletin.recordID = unique;
            bulletin.publisherBulletinID = unique;
            bulletin.date = now;
            bulletin.publicationDate = now;
            bulletin.lastInterruptDate = now;
            bulletin.clearable = YES;
            bulletin.showsMessagePreview = YES;
            bulletin.turnsOnDisplay = YES;

            if (actionClass && [actionClass respondsToSelector:@selector(actionWithLaunchBundleID:callblock:)]) {
                bulletin.defaultAction = [actionClass actionWithLaunchBundleID:culpritBundleID callblock:nil];
            }

            if ([server respondsToSelector:@selector(publishBulletin:destinations:)]) {
                [server publishBulletin:bulletin destinations:15];
                CNLog(@"Published BulletinBoard notification: %@", title);
            }
        } @catch (NSException *exception) {
            CNLog(@"Notification delivery failed: %@", exception.reason);
        }
    });
}

static NSArray<NSString *> *CNCurrentReportNames(void) {
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kCNCrashDirectory error:nil];
    if (!files) return @[];
    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSString *name in files) {
        NSString *lower = name.lowercaseString;
        if ([lower hasSuffix:@".ips"] || [lower hasSuffix:@".crash"]) [reports addObject:name];
    }
    return reports;
}

static void CNSaveState(void) {
    if (!gRecentReports) return;
    NSArray *recent = gRecentReports.array;
    if (recent.count > 500) {
        recent = [recent subarrayWithRange:NSMakeRange(recent.count - 500, 500)];
    }
    NSDictionary *state = @{
        @"StateVersion": @2,
        @"RecentReports": recent ?: @[]
    };
    [state writeToFile:kCNStatePath atomically:YES];
}

static void CNLoadState(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kCNStatePath];
    NSInteger version = [state[@"StateVersion"] integerValue];
    NSArray *recent = [state[@"RecentReports"] isKindOfClass:[NSArray class]] ? state[@"RecentReports"] : nil;

    if (version != 2 || !recent) {
        recent = CNCurrentReportNames();
        CNLog(@"Initialised state with %lu existing crash reports", (unsigned long)recent.count);
    }

    gRecentReports = [[NSMutableOrderedSet alloc] initWithArray:recent ?: @[]];
    CNSaveState();
}

static NSDictionary *CNJSONDictionary(NSData *data) {
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *CNImageCulpritName(NSDictionary *image) {
    if (![image isKindOfClass:[NSDictionary class]]) return nil;
    NSString *path = [image[@"path"] isKindOfClass:[NSString class]] ? image[@"path"] : @"";
    NSString *name = [image[@"name"] isKindOfClass:[NSString class]] ? image[@"name"] : path.lastPathComponent;
    NSString *lowerPath = path.lowercaseString;
    NSString *lowerName = name.lowercaseString;

    BOOL injected = [lowerPath containsString:@"mobilesubstrate/dynamiclibraries/"] ||
                    [lowerPath containsString:@"/tweakinject/"];
    if (!injected) return nil;

    if ([lowerName containsString:@"culpritnotify"] ||
        [lowerName containsString:@"ellekit"] ||
        [lowerName containsString:@"libhooker"] ||
        [lowerName containsString:@"substrateloader"] ||
        [lowerName containsString:@"substrateinserter"]) {
        return nil;
    }

    return name.length ? name : nil;
}

static NSString *CNCulpritFromBody(NSDictionary *body) {
    NSArray *images = [body[@"usedImages"] isKindOfClass:[NSArray class]] ? body[@"usedImages"] : nil;
    NSArray *threads = [body[@"threads"] isKindOfClass:[NSArray class]] ? body[@"threads"] : nil;
    if (!images.count || !threads.count) return nil;

    NSDictionary *faultThread = nil;
    NSNumber *faultIndex = [body[@"faultingThread"] isKindOfClass:[NSNumber class]] ? body[@"faultingThread"] : nil;
    if (faultIndex && faultIndex.integerValue >= 0 && faultIndex.integerValue < (NSInteger)threads.count) {
        id candidate = threads[faultIndex.integerValue];
        if ([candidate isKindOfClass:[NSDictionary class]]) faultThread = candidate;
    }

    if (!faultThread) {
        for (id thread in threads) {
            if ([thread isKindOfClass:[NSDictionary class]] && [thread[@"triggered"] boolValue]) {
                faultThread = thread;
                break;
            }
        }
    }

    NSArray *frames = [faultThread[@"frames"] isKindOfClass:[NSArray class]] ? faultThread[@"frames"] : nil;
    for (id frame in frames) {
        if (![frame isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *imageIndex = [frame[@"imageIndex"] isKindOfClass:[NSNumber class]] ? frame[@"imageIndex"] : nil;
        if (!imageIndex) continue;
        NSInteger index = imageIndex.integerValue;
        if (index < 0 || index >= (NSInteger)images.count) continue;
        NSString *culprit = CNImageCulpritName(images[index]);
        if (culprit.length) return culprit;
    }
    return nil;
}

static NSString *CNCulpritFromText(NSString *text) {
    __block NSString *found = nil;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *lower = line.lowercaseString;
        BOOL injected = [lower containsString:@"mobilesubstrate/dynamiclibraries/"] ||
                        [lower containsString:@"/tweakinject/"];
        if (!injected || ![lower containsString:@".dylib"]) return;

        NSRange dylibRange = [lower rangeOfString:@".dylib"];
        if (dylibRange.location == NSNotFound) return;
        NSString *prefix = [line substringToIndex:NSMaxRange(dylibRange)];
        NSString *name = [prefix componentsSeparatedByString:@"/"].lastObject;
        NSString *lowerName = name.lowercaseString;
        if ([lowerName containsString:@"culpritnotify"] ||
            [lowerName containsString:@"ellekit"] ||
            [lowerName containsString:@"libhooker"]) return;

        found = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        *stop = YES;
    }];
    return found;
}

static NSString *CNFallbackProcessName(NSString *path) {
    NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
    NSRange dateRange = [name rangeOfString:@"-20"];
    if (dateRange.location != NSNotFound && dateRange.location > 0) {
        name = [name substringToIndex:dateRange.location];
    }
    return name.length ? name : @"Unknown process";
}

// Read anchored report fields, never words occurring inside sampled stacks.
static NSString *CNReportField(NSString *text, NSString *field) {
    __block NSString *value = nil;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) return;
        NSString *key = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([key caseInsensitiveCompare:field] != NSOrderedSame) return;
        value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        *stop = YES;
    }];
    return value;
}

static NSDictionary *CNBuildNotificationForReport(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) return nil;

    NSDictionary *header = nil;
    NSDictionary *body = nil;
    NSRange newline = [text rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
        NSString *headerString = [text substringToIndex:newline.location];
        NSString *bodyString = [text substringFromIndex:newline.location + 1];
        header = CNJSONDictionary([headerString dataUsingEncoding:NSUTF8StringEncoding]);
        body = CNJSONDictionary([bodyString dataUsingEncoding:NSUTF8StringEncoding]);
    } else {
        body = CNJSONDictionary(data);
    }

    if (!body && !header) body = CNJSONDictionary(data);

    NSString *process = [body[@"procName"] isKindOfClass:[NSString class]] ? body[@"procName"] : nil;
    if (!process.length) process = [header[@"app_name"] isKindOfClass:[NSString class]] ? header[@"app_name"] : nil;
    if (!process.length) process = CNReportField(text, @"Command");
    if (!process.length) process = CNReportField(text, @"Process");
    if (!process.length) process = CNFallbackProcessName(path);

    NSString *filename = path.lastPathComponent;
    NSString *lowerFilename = filename.lowercaseString;
    NSString *culprit = CNCulpritFromBody(body ?: @{});
    if (!culprit.length) culprit = CNCulpritFromText(text);

    NSDictionary *exception = [body[@"exception"] isKindOfClass:[NSDictionary class]] ? body[@"exception"] : nil;
    NSString *exceptionType = [exception[@"type"] isKindOfClass:[NSString class]] ? exception[@"type"] : nil;
    if (!exceptionType.length) exceptionType = CNReportField(text, @"Exception Type");
    NSString *bugType = [(header[@"bug_type"] ?: body[@"bug_type"]) description];
    NSString *event = CNReportField(text, @"Event").lowercaseString;
    NSString *action = CNReportField(text, @"Action taken").lowercaseString;
    BOOL noAction = [action isEqualToString:@"none"];
    NSString *resource = nil;
    if ([lowerFilename containsString:@"wakeups_resource"] || [event containsString:@"wakeups"] || [bugType isEqualToString:@"142"]) resource = @"wakeups";
    else if ([lowerFilename containsString:@"cpu_resource"] || [event isEqualToString:@"cpu usage"]) resource = @"CPU";
    else if ([lowerFilename containsString:@"memory_resource"]) resource = @"memory";
    else if ([lowerFilename containsString:@"_resource"] || [exceptionType hasPrefix:@"EXC_RESOURCE"]) resource = @"resource";


    NSString *title = nil;
    NSString *message = nil;

    if ([lowerFilename containsString:@"jetsamevent"]) {
        NSString *largest = [body[@"largestProcess"] isKindOfClass:[NSString class]] ? body[@"largestProcess"] : nil;
        title = largest.length ? [NSString stringWithFormat:@"Jetsam: %@", largest] : @"Jetsam event";
        message = @"Memory-pressure termination. Tap to open Culprit.";
    } else if (resource.length || noAction) {
        resource = resource ?: @"resource";
        // Sampling a loaded tweak is not evidence that it caused a resource event.
        BOOL terminated = [action isEqualToString:@"terminated"] || [action isEqualToString:@"killed"];
        title = [NSString stringWithFormat:@"%@ %@ %@", process, resource,
                 noAction ? @"warning" : (terminated ? @"termination" : @"report")];
        message = noAction ? @"iOS took no action; this report did not terminate the app. Tap to open Culprit."
                           : (terminated ? @"iOS terminated the process for resource use. Tap to open Culprit."
                                         : @"Resource limit reported; termination is not confirmed. Tap to open Culprit.");
    } else if (exceptionType.length || [body[@"faultingThread"] isKindOfClass:NSNumber.class]) {
        title = [NSString stringWithFormat:@"%@ crashed", process];
        NSString *reason = exceptionType.length ? exceptionType : @"Crash detected";
        message = culprit.length ? [NSString stringWithFormat:@"%@ • Culprit: %@", reason, culprit]
                                 : [NSString stringWithFormat:@"%@ • Culprit: Unknown", reason];
    } else {
        title = [NSString stringWithFormat:@"%@ diagnostic report", process];
        message = bugType.length ? [NSString stringWithFormat:@"New diagnostic report (bug type %@). Tap to open Culprit.", bugType]
                                 : @"New diagnostic report detected. Tap to open Culprit.";
    }

    return @{ @"title": title ?: @"Crash detected", @"message": message ?: @"Tap to open Culprit" };
}

static void CNTrimRecent(void) {
    while (gRecentReports.count > 500) [gRecentReports removeObjectAtIndex:0];
}

static void CNDeliverCrashAlert(NSDictionary *notification, NSString *reportName) {
    NSString *title = notification[@"title"] ?: @"Crash detected";
    NSString *message = notification[@"message"] ?: @"Tap to open Culprit";
    CNLog(@"Delivering alert for %@: %@ | %@", reportName, title, message);

    CNPostBulletin(title, message, 0);
}

static void CNScanCrashReports(void) {
    if (!gRecentReports) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:kCNCrashDirectory error:&error];
    if (error) {
        CNLog(@"CrashReporter scan failed: %@", error.localizedDescription);
        return;
    }

    for (NSString *name in files) {
        NSString *lower = name.lowercaseString;
        if (![lower hasSuffix:@".ips"] && ![lower hasSuffix:@".crash"]) continue;
        if ([gRecentReports containsObject:name]) continue;

        NSString *path = [kCNCrashDirectory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        NSNumber *size = attributes[NSFileSize];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!size || size.unsignedLongLongValue == 0 || !modified) continue;

        NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:modified];
        if (age < 0.15) continue;

        NSDictionary *notification = CNBuildNotificationForReport(path);
        if (!notification) {
            CNLog(@"Report not ready yet: %@ (%@ bytes)", name, size);
            continue;
        }

        [gRecentReports addObject:name];
        CNTrimRecent();
        CNSaveState();
        CNDeliverCrashAlert(notification, name);
    }
}

static void CNRequestScan(NSTimeInterval delay) {
    if (!gMonitorQueue) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gMonitorQueue, ^{
        @autoreleasepool {
            CNScanCrashReports();
        }
    });
}

static void CNStartDirectoryWatcher(void) {
    if (gDirectorySource || gCrashDirectoryFD >= 0) return;

    gCrashDirectoryFD = open(kCNCrashDirectory.fileSystemRepresentation, O_EVTONLY);
    if (gCrashDirectoryFD < 0) {
        CNLog(@"Could not open CrashReporter directory for vnode watching (errno %d)", errno);
        return;
    }

    unsigned long mask = DISPATCH_VNODE_WRITE |
                         DISPATCH_VNODE_EXTEND |
                         DISPATCH_VNODE_ATTRIB |
                         DISPATCH_VNODE_LINK |
                         DISPATCH_VNODE_RENAME |
                         DISPATCH_VNODE_DELETE |
                         DISPATCH_VNODE_REVOKE;

    gDirectorySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                               (uintptr_t)gCrashDirectoryFD,
                                               mask,
                                               gMonitorQueue);
    if (!gDirectorySource) {
        close(gCrashDirectoryFD);
        gCrashDirectoryFD = -1;
        CNLog(@"Failed to create CrashReporter vnode source");
        return;
    }

    dispatch_source_set_event_handler(gDirectorySource, ^{
        CNLog(@"CrashReporter directory changed");
        CNRequestScan(0.10);
        CNRequestScan(0.35);
        CNRequestScan(0.80);
    });

    dispatch_source_set_cancel_handler(gDirectorySource, ^{
        if (gCrashDirectoryFD >= 0) {
            close(gCrashDirectoryFD);
            gCrashDirectoryFD = -1;
        }
        gDirectorySource = nil;
        CNLog(@"CrashReporter vnode source cancelled");
    });

    dispatch_resume(gDirectorySource);
    CNLog(@"CrashReporter vnode watcher active");
}

static void CNStartMonitor(void) {
    if (gFallbackTimer) return;

    CNLoadState();
    gMonitorQueue = dispatch_queue_create("com.551.culpritnotify.monitor", DISPATCH_QUEUE_SERIAL);
    CNLog(@"CulpritNotify monitor starting");
    CNStartDirectoryWatcher();

    gFallbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gMonitorQueue);
    dispatch_source_set_timer(gFallbackTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              150 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gFallbackTimer, ^{
        @autoreleasepool {
            CNScanCrashReports();
            if (!gDirectorySource) CNStartDirectoryWatcher();
        }
    });
    dispatch_resume(gFallbackTimer);
}

%hook BBServer

- (id)initWithQueue:(id)queue {
    id result = %orig;
    @synchronized(NSClassFromString(@"BBServer")) {
        gBBServer = result;
        if (result) gBBQueue = queue;
    }
    CNLog(@"Captured BBServer from initWithQueue");
    return result;
}

- (void)_addObserver:(id)observer {
    @synchronized(NSClassFromString(@"BBServer")) { gBBServer = self; }
    CNLog(@"Captured BBServer from _addObserver");
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        CNLog(@"CulpritNotify dylib loaded in %@", [NSProcessInfo processInfo].processName);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CNStartMonitor();
        });

        static int testToken = 0;
        notify_register_dispatch("com.551.culpritnotify/test", &testToken, dispatch_get_main_queue(), ^(__unused int token) {
            CNPostBulletin(@"CulpritNotify test", @"Monitoring is active. Tap to open Culprit.", 0);
        });
    }
}
