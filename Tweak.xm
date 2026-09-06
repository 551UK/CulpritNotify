#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>

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
@end

@interface BBAction : NSObject
+ (id)actionWithLaunchBundleID:(NSString *)bundleID callblock:(id)block;
@end

@interface BBServer : NSObject
- (id)initWithQueue:(id)queue;
- (id)initWithQueue:(id)queue
 dataProviderManager:(id)dataProviderManager
          syncService:(id)syncService
    dismissalSyncCache:(id)dismissalSyncCache
     observerListener:(id)observerListener
    utilitiesListener:(id)utilitiesListener
      conduitListener:(id)conduitListener
  systemStateListener:(id)systemStateListener
      settingsListener:(id)settingsListener;
- (void)_addObserver:(id)observer;
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations;
@end

static __weak BBServer *gBBServer = nil;
static dispatch_queue_t gMonitorQueue;
static dispatch_source_t gMonitorTimer;
static NSMutableOrderedSet<NSString *> *gRecentReports;
static NSTimeInterval gLastCheck = 0;

static NSString *const kCNSectionID = @"jp.dcsyhi.culprit";
static NSString *const kCNStatePath = @"/var/mobile/Library/Preferences/com.551.culpritnotify.state.plist";
static NSString *const kCNCrashDirectory = @"/var/mobile/Library/Logs/CrashReporter";

static dispatch_queue_t CNBBServerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(NULL, RTLD_GLOBAL);
        if (handle) {
            dispatch_queue_t __weak *pointer = (__weak dispatch_queue_t *)dlsym(handle, "__BBServerQueue");
            if (pointer) queue = *pointer;
            dlclose(handle);
        }
    });
    return queue;
}

static BOOL CNPostBulletin(NSString *title, NSString *message) {
    BBServer *server = gBBServer;
    if (!server || !title.length || !message.length) return NO;

    Class bulletinClass = NSClassFromString(@"BBBulletin");
    Class actionClass = NSClassFromString(@"BBAction");
    if (!bulletinClass) return NO;

    BBBulletin *bulletin = [[bulletinClass alloc] init];
    NSDate *now = [NSDate date];
    NSString *unique = [[NSProcessInfo processInfo] globallyUniqueString];

    bulletin.title = title;
    bulletin.message = message;
    bulletin.sectionID = kCNSectionID;
    bulletin.bulletinID = unique;
    bulletin.recordID = unique;
    bulletin.publisherBulletinID = unique;
    bulletin.date = now;
    bulletin.publicationDate = now;
    bulletin.lastInterruptDate = now;
    bulletin.clearable = YES;
    bulletin.showsMessagePreview = YES;

    if (actionClass && [actionClass respondsToSelector:@selector(actionWithLaunchBundleID:callblock:)]) {
        bulletin.defaultAction = [actionClass actionWithLaunchBundleID:kCNSectionID callblock:nil];
    }

    dispatch_queue_t queue = CNBBServerQueue();
    void (^publishBlock)(void) = ^{
        BBServer *currentServer = gBBServer;
        if (currentServer && [currentServer respondsToSelector:@selector(publishBulletin:destinations:)]) {
            [currentServer publishBulletin:bulletin destinations:15];
        }
    };

    if (queue) {
        dispatch_async(queue, publishBlock);
    } else {
        dispatch_async(dispatch_get_main_queue(), publishBlock);
    }
    return YES;
}

static void CNSaveState(void) {
    if (!gRecentReports) return;
    NSArray *recent = gRecentReports.array;
    if (recent.count > 100) {
        recent = [recent subarrayWithRange:NSMakeRange(recent.count - 100, 100)];
    }
    NSDictionary *state = @{
        @"LastCheck": @(gLastCheck),
        @"RecentReports": recent ?: @[]
    };
    [state writeToFile:kCNStatePath atomically:YES];
}

static void CNLoadState(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kCNStatePath];
    NSArray *recent = [state[@"RecentReports"] isKindOfClass:[NSArray class]] ? state[@"RecentReports"] : @[];
    gRecentReports = [[NSMutableOrderedSet alloc] initWithArray:recent];
    gLastCheck = [state[@"LastCheck"] doubleValue];

    if (gLastCheck <= 0) {
        gLastCheck = [[NSDate date] timeIntervalSince1970];
        CNSaveState();
    }
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
                    [lowerPath containsString:@"/tweakinject/"] ||
                    [lowerPath containsString:@"/var/jb/"];
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
        BOOL injected = [lower containsString:@"mobilesubstrate/dynamiclibraries/"] || [lower containsString:@"/tweakinject/"];
        if (!injected || ![lower containsString:@".dylib"]) return;

        NSRange dylibRange = [lower rangeOfString:@".dylib"];
        if (dylibRange.location == NSNotFound) return;
        NSString *prefix = [line substringToIndex:NSMaxRange(dylibRange)];
        NSArray *parts = [prefix componentsSeparatedByString:@"/"];
        NSString *name = parts.lastObject;
        NSString *lowerName = name.lowercaseString;
        if ([lowerName containsString:@"culpritnotify"] || [lowerName containsString:@"ellekit"] || [lowerName containsString:@"libhooker"]) return;
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
    NSRange resourceRange = [name rangeOfString:@"." options:NSBackwardsSearch];
    if (resourceRange.location != NSNotFound && resourceRange.location > 0) {
        name = [name substringToIndex:resourceRange.location];
    }
    return name.length ? name : @"Unknown process";
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

    NSString *process = [body[@"procName"] isKindOfClass:[NSString class]] ? body[@"procName"] : nil;
    if (!process.length) process = [header[@"app_name"] isKindOfClass:[NSString class]] ? header[@"app_name"] : nil;
    if (!process.length) process = CNFallbackProcessName(path);

    NSString *filename = path.lastPathComponent;
    NSString *lowerFilename = filename.lowercaseString;
    NSString *culprit = CNCulpritFromBody(body ?: @{});
    if (!culprit.length) culprit = CNCulpritFromText(text);

    NSDictionary *exception = [body[@"exception"] isKindOfClass:[NSDictionary class]] ? body[@"exception"] : nil;
    NSString *exceptionType = [exception[@"type"] isKindOfClass:[NSString class]] ? exception[@"type"] : nil;
    NSString *bugType = [header[@"bug_type"] description];

    NSString *title = nil;
    NSString *message = nil;

    if ([lowerFilename containsString:@"jetsamevent"]) {
        NSString *largest = [body[@"largestProcess"] isKindOfClass:[NSString class]] ? body[@"largestProcess"] : nil;
        title = largest.length ? [NSString stringWithFormat:@"Jetsam: %@", largest] : @"Jetsam event";
        message = @"iOS generated a memory-pressure termination report.";
    } else if ([lowerFilename containsString:@"wakeups_resource"]) {
        title = [NSString stringWithFormat:@"%@ wakeups limit", process];
        message = @"iOS generated a wakeups resource report.";
    } else if ([lowerFilename containsString:@"cpu_resource"]) {
        title = [NSString stringWithFormat:@"%@ CPU limit", process];
        message = @"iOS generated a CPU resource report.";
    } else if ([lowerFilename containsString:@"memory_resource"]) {
        title = [NSString stringWithFormat:@"%@ memory limit", process];
        message = @"iOS generated a memory resource report.";
    } else if (exceptionType.length || body[@"faultingThread"] || body[@"threads"]) {
        title = [NSString stringWithFormat:@"%@ crashed", process];
        NSString *reason = exceptionType.length ? exceptionType : @"Crash detected";
        message = culprit.length ? [NSString stringWithFormat:@"%@ • Culprit: %@", reason, culprit]
                                 : [NSString stringWithFormat:@"%@ • Culprit: Unknown", reason];
    } else {
        title = [NSString stringWithFormat:@"%@ crash report", process];
        message = bugType.length ? [NSString stringWithFormat:@"New iOS crash report (bug type %@).", bugType]
                                 : @"New iOS crash report detected.";
    }

    return @{ @"title": title, @"message": message };
}

static NSString *CNReportKey(NSString *path, NSDictionary *attributes) {
    NSDate *date = attributes[NSFileModificationDate];
    NSNumber *size = attributes[NSFileSize];
    return [NSString stringWithFormat:@"%@|%.0f|%@", path.lastPathComponent, date.timeIntervalSince1970, size ?: @0];
}

static void CNTrimRecent(void) {
    while (gRecentReports.count > 100) {
        [gRecentReports removeObjectAtIndex:0];
    }
}

static void CNScanCrashReports(void) {
    if (!gBBServer) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:kCNCrashDirectory error:&error];
    if (error || !files.count) {
        gLastCheck = [[NSDate date] timeIntervalSince1970];
        CNSaveState();
        return;
    }

    NSArray<NSString *> *sorted = [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *name in sorted) {
        NSString *lower = name.lowercaseString;
        if (![lower hasSuffix:@".ips"] && ![lower hasSuffix:@".crash"]) continue;

        NSString *path = [kCNCrashDirectory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!modified) continue;

        NSTimeInterval modifiedTime = modified.timeIntervalSince1970;
        if (modifiedTime < gLastCheck - 1.0) continue;

        NSString *reportKey = CNReportKey(path, attributes);
        if ([gRecentReports containsObject:reportKey]) continue;

        NSDictionary *notification = CNBuildNotificationForReport(path);
        if (!notification) continue;

        if (CNPostBulletin(notification[@"title"], notification[@"message"])) {
            [gRecentReports addObject:reportKey];
            CNTrimRecent();
        }
    }

    gLastCheck = [[NSDate date] timeIntervalSince1970];
    CNSaveState();
}

static void CNStartMonitor(void) {
    if (gMonitorTimer) return;
    CNLoadState();

    gMonitorQueue = dispatch_queue_create("com.551.culpritnotify.monitor", DISPATCH_QUEUE_SERIAL);
    gMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gMonitorQueue);
    dispatch_source_set_timer(gMonitorTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              3 * NSEC_PER_SEC,
                              500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gMonitorTimer, ^{
        @autoreleasepool {
            CNScanCrashReports();
        }
    });
    dispatch_resume(gMonitorTimer);
}

%hook BBServer

- (id)initWithQueue:(id)queue {
    id result = %orig;
    gBBServer = result;
    return result;
}

- (id)initWithQueue:(id)queue
 dataProviderManager:(id)dataProviderManager
          syncService:(id)syncService
    dismissalSyncCache:(id)dismissalSyncCache
     observerListener:(id)observerListener
    utilitiesListener:(id)utilitiesListener
      conduitListener:(id)conduitListener
  systemStateListener:(id)systemStateListener
      settingsListener:(id)settingsListener {
    id result = %orig;
    gBBServer = result;
    return result;
}

- (void)_addObserver:(id)observer {
    gBBServer = self;
    %orig;
}

- (void)dealloc {
    if (gBBServer == self) gBBServer = nil;
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CNStartMonitor();
        });

        static int testToken = 0;
        notify_register_dispatch("com.551.culpritnotify/test", &testToken, dispatch_get_main_queue(), ^(int token) {
            CNPostBulletin(@"CulpritNotify", @"Test notification — crash monitoring is active.");
        });
    }
}
