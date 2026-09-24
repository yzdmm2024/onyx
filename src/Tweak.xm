// Onyx Tweak v1.4.0
//
// 定位模拟：★以 SpringBoard 系统级模拟为主（v1.3.0 方向调整后的加固）
//
// 为什么改方向（v1.2.0 日志实锤）：
//   真机诊断日志 /var/tmp/onyx_debug.log 里，只有
//     === Onyx v1.2.0 BOOT proc=SpringBoard bundle=com.apple.springboard ===
//   没有任何第三方 App 的 BOOT 行 —— 说明 Onyx dylib 在 relaxin 上
//   **只被注入 SpringBoard，第三方 App 进程压根没加载它**。
//   在 App 进程里做 CLLocationManager hook 的前提就不存在，v1.2.0 的
//   「不启动真实定位 + 接管 delegate」再正确也没机会执行。
//
// v1.3.0 真机日志已证明（用户发的 /var/tmp/onyx_debug.log）：
//   - SpringBoard 注入成功：plist hit / prefs: enabled=1 hasCoord=1 lat=26.894216 lng=112.572016
//   - CLSimulationManager 创建成功：sim: created <CLSimulationManager: 0x...>
//   - 启动成功：sim: START -> 26.894216,112.572016（开关状态机也正常：STOP/START）
//   - 黑名单读到：excluded=( "com.baidu.map")
//   但**日志里零个第三方 App 的 BOOT、零条 CLLocationManager 调用**
//   → App 进程确实没被注入，唯一能改的地方就是 SpringBoard 侧系统模拟。
//
// v1.4.0 要解决的唯一问题：「sim: START 打了」≠「locationd 真的在投递模拟点」。
// SpringBoard 可能压根没资格让 locationd 接受模拟请求，而这一步在日志里是静默的。
// 所以本版加**端到端回声自检**：SpringBoard 自己起一个 CLLocationManager 向
// locationd 要一次定位，拿到什么坐标直接判死：
//   ECHO: FAKE  -> 模拟生效，问题在 App 自身（彩云是 IP/城市定位而非 GPS）
//   ECHO: REAL  -> 模拟没生效，SpringBoard 的模拟请求被 locationd 无视
//   ECHO: ERROR/TIMEOUT -> SpringBoard 自己都拿不到定位，看错误码
//
// 诊断日志：/var/tmp/onyx_debug.log（写不进去自动换 /tmp/onyx_debug.log）
//   === Onyx v1.4.0 BOOT proc=xx img=<dylib 路径> ===   ← 有没有注入，看这行
//   sim: START / sim: STOP / sim: HB / ECHO: ...
//
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <substrate.h>
#import "OnyxTileProxy.h"

// ---- 第三方定位 SDK 的最小桩声明（仅编译期需要，运行期 Hook 真实类） ----
@interface BMKLocationManager : NSObject
@property (nonatomic, weak) id delegate;
@end
@interface AMapLocationManager : NSObject
@property (nonatomic, weak) id delegate;
@end
@interface TencentLocationManager : NSObject
@property (nonatomic, weak) id delegate;
@end

@protocol BMKLocationManagerDelegate <NSObject>
- (void)didUpdateLocation:(CLLocation *)location;
@end
@protocol AMapLocationManagerDelegate <NSObject>
- (void)amapLocationManager:(id)manager didUpdateLocation:(CLLocation *)location reGeocode:(id)reGeocode;
@end
@protocol TencentLocationManagerDelegate <NSObject>
- (void)locationManager:(id)manager didUpdateLocation:(CLLocation *)location;
@end

// ---- CLSimulationManager 私有接口（iOS 16 存在性未知，运行期探测） ----
@interface CLSimulationManager : NSObject
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)clearSimulatedLocation;
@end

// ---- 回声自检用的最小 delegate：SpringBoard 自己向 locationd 要一次定位 ----
// 目的：把「sim: START 打了」和「locationd 真的投递了模拟点」这两件事分开，
// 否则永远只能靠猜。
@interface OnyxEchoDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, copy) void (^onyx_done)(CLLocation *loc, NSError *err);
@end
@implementation OnyxEchoDelegate
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locs {
    void (^cb)(CLLocation *, NSError *) = self.onyx_done;
    self.onyx_done = nil;                       // 先清回调，避免超时分支重复触发
    if (cb) cb(locs.count ? locs.lastObject : nil, nil);
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    void (^cb)(CLLocation *, NSError *) = self.onyx_done;
    self.onyx_done = nil;
    if (cb) cb(nil, error);
}
@end

// 回声自检期间必须把 mgr / delegate 顶在静态变量上：CLLocationManager 的 delegate 是
// assign 不持有，方法一返回局部变量就被释放，5 秒后回调永远不会来（假 TIMEOUT）。
static CLLocationManager *s_echoMgr = nil;
static OnyxEchoDelegate  *s_echoDel = nil;

static NSString *const kDomain  = @"com.yzdmm.onyx";
#define kChanged CFSTR("com.yzdmm.onyx/changed")
#define kStop    CFSTR("com.yzdmm.onyx/stop")

static double s_lat = 0, s_lng = 0;
static BOOL s_enabled = NO;
static BOOL s_hasCoord = NO;
static BOOL s_isSpringBoard = NO;
static BOOL s_bootLogged = NO;
static NSSet<NSString *> *s_excluded = nil;
static NSHashTable<CLLocationManager *> *s_mgrs = nil;
static CFAbsoluteTime s_lastRead = 0;

// ---------------- 诊断日志（多路径，避免 App 沙箱里 /var/tmp 写不进） ----------------
static NSArray<NSString *> *OnyxLogPaths(void) {
    static NSArray<NSString *> *a = nil;
    if (!a) {
        a = @[@"/var/tmp/onyx_debug.log",
              @"/tmp/onyx_debug.log",
              @"/var/jb/tmp/onyx_debug.log"];
    }
    return a;
}
static BOOL OWrite(NSString *line) {
    const char *s = line.UTF8String;
    size_t len = strlen(s);
    for (NSString *p in OnyxLogPaths()) {
        int fd = open(p.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        off_t sz = lseek(fd, 0, SEEK_END);
        if (sz > 512 * 1024) { ftruncate(fd, 0); sz = 0; }
        if (write(fd, s, len) < 0) { /* ignore */ }
        close(fd);
        return YES;
    }
    return NO;
}
static NSString *OnyxStack(void) {
    NSArray<NSString *> *syms = [NSThread callStackSymbols];
    NSInteger n = (NSInteger)syms.count;
    if (n < 2) return @"";
    NSMutableArray *out = [NSMutableArray array];
    NSInteger start = n > 6 ? n - 6 : 1;
    for (NSInteger i = start; i < n; i++) {
        NSString *s = [syms[i] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRange r = [s rangeOfString:@"-["];
        if (r.location == NSNotFound) r = [s rangeOfString:@"+["];
        if (r.location != NSNotFound && r.location + 1 < s.length) {
            NSString *tail = [s substringFromIndex:r.location + 1];
            NSArray<NSString *> *p = [tail componentsSeparatedByString:@"]"];
            if (p.count) [out addObject:p[0]];
        }
    }
    return [out componentsJoinedByString:@" <- "];
}
static NSString *OnyxTimestamp(void) {
    time_t t = time(NULL);
    struct tm tmv; localtime_r(&t, &tmv);
    return [NSString stringWithFormat:@"%02d:%02d:%02d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec];
}
static void OLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // v1.4.1：每行带时间戳，否则多条线索之间没法对时间
    NSString *line = [NSString stringWithFormat:@"[Onyx %@ %@] %@\n",
                      [[NSProcessInfo processInfo] processName], OnyxTimestamp(), msg];
    OWrite(line);
}
static void OLogStack(NSString *tag) {
    OLog(@"%@ stack: %@", tag, OnyxStack());
}

// 读配置：/var/tmp 公共路径优先（relaxin 上 App 唯一写得动），多路径回退
static NSString *s_lastHitPath = nil;  // v1.4.1：路径没变就不再刷 plist hit（轮询每 3s 一次，刷屏会把 ECHO 判定冲掉）
static NSDictionary *_onyxLoadPlist(void) {
    NSArray<NSString *> *cands = @[
        @"/var/tmp/com.yzdmm.onyx.plist",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *p in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            if (!s_lastHitPath || ![s_lastHitPath isEqualToString:p]) {
                s_lastHitPath = p;
                OLog(@"plist hit: %@", p);
            }
            return d;
        }
    }
    s_lastHitPath = nil;
    OLog(@"plist MISS: no candidate file readable");
    return nil;
}

static NSDictionary *s_lastLoggedPrefs = nil;  // v1.4.1：内容没变不重复打 prefs 行
static void _readPrefs(void) {
    NSDictionary *d = _onyxLoadPlist();
    if (!d) {
        s_enabled = NO; s_hasCoord = NO; s_excluded = nil;
        s_lastRead = CFAbsoluteTimeGetCurrent();
        return;
    }
    s_enabled = [d[@"enabled"] boolValue];
    NSNumber *la = d[@"Latitude"], *ln = d[@"Longitude"];
    s_hasCoord = (la && ln && fabs([la doubleValue]) > 0.0001);
    if (s_hasCoord) { s_lat = [la doubleValue]; s_lng = [ln doubleValue]; }
    NSArray *ex = d[@"ExcludedApps"];
    s_excluded = [ex isKindOfClass:[NSArray class]] ? [NSSet setWithArray:ex] : nil;
    s_lastRead = CFAbsoluteTimeGetCurrent();
    if (s_lastLoggedPrefs && [d isEqualToDictionary:s_lastLoggedPrefs]) return;
    s_lastLoggedPrefs = d;
    OLog(@"prefs: enabled=%d hasCoord=%d lat=%.6f lng=%.6f excluded=%@",
         (int)s_enabled, (int)s_hasCoord, s_lat, s_lng,
         s_excluded ? s_excluded.allObjects : @[]);
}

static void _readPrefsThrottled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - s_lastRead > 1.0) _readPrefs();
}

// 当前进程是否应启用假坐标：黑名单（ExcludedApps）内的 App 用真实位置
static BOOL _active(void) {
    _readPrefsThrottled();
    if (!s_enabled || !s_hasCoord) return NO;
    if (s_isSpringBoard) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) bid = [[NSProcessInfo processInfo] processName];
    if ([bid isEqualToString:@"com.yzdmm.onyx.app"]) return NO;  // 自身 App 排除
    if (s_excluded && [s_excluded containsObject:bid]) {
        OLog(@"SKIP (blacklisted): %@", bid);
        return NO;
    }
    return YES;
}

static CLLocationCoordinate2D _fakeCoord(void) {
    return CLLocationCoordinate2DMake(s_lat, s_lng);
}
// 带合理精度（horizontalAccuracy=5m）的假坐标，避免被 App 因无效精度丢弃
static CLLocation *_fakeLocation(void) {
    return [[CLLocation alloc] initWithCoordinate:_fakeCoord()
                                         altitude:0
                               horizontalAccuracy:5
                                 verticalAccuracy:-1
                                           course:-1
                                            speed:-1
                                       timestamp:[NSDate date]];
}

// ---------------- delegate 回调接管（App 被注入时的核心路径） ----------------
static void ony_didUpdateLocations(id self, SEL _cmd, id mgr, NSArray *locs);

typedef struct { Class cls; IMP orig; } OnyxHookRec;
static OnyxHookRec *g_recs = NULL;
static int g_recCap = 0, g_recN = 0;

static void OnyxEnsureRecCap(int need) {
    if (g_recCap >= need) return;
    int cap = g_recCap ? g_recCap * 2 : 256;
    while (cap < need) cap *= 2;
    g_recs = (OnyxHookRec *)realloc(g_recs, sizeof(OnyxHookRec) * (size_t)cap);
    if (!g_recs) { g_recCap = 0; g_recN = 0; return; }
    g_recCap = cap;
}

static IMP OnyxFindOrig(id self) {
    Class c = object_getClass(self);
    for (int i = 0; i < g_recN; i++) {
        if (g_recs[i].cls == c) return g_recs[i].orig;
    }
    return NULL;
}

static void OnyxHookDelegateClass(Class c) {
    if (!c) return;
    SEL sel = NSSelectorFromString(@"locationManager:didUpdateLocations:");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (method_getImplementation(m) == (IMP)ony_didUpdateLocations) return;
    OnyxEnsureRecCap(g_recN + 1);
    if (g_recN >= g_recCap) return;
    g_recs[g_recN].cls  = c;
    g_recs[g_recN].orig = NULL;
    MSHookMessageEx(c, sel, (IMP)ony_didUpdateLocations, &g_recs[g_recN].orig);
    g_recN++;
    OLog(@"delegate hooked: [%@] (%d total)", c, g_recN);
}

static void OnyxScanAllDelegates(void) {
    static BOOL s_scanning = NO;
    if (s_scanning) return;
    s_scanning = YES;
    unsigned int n = 0;
    Class *cls = objc_copyClassList(&n);
    if (cls) {
        for (unsigned int i = 0; i < n; i++) {
            Class c = cls[i];
            if (!c) continue;
            if (!class_getInstanceMethod(c, NSSelectorFromString(@"locationManager:didUpdateLocations:"))) continue;
            OnyxEnsureRecCap(g_recN + 1);
            if (g_recN >= g_recCap) break;
            OnyxHookDelegateClass(c);
        }
        free(cls);
    }
    s_scanning = NO;
}

static void ony_didUpdateLocations(id self, SEL _cmd, id mgr, NSArray *locs) {
    BOOL act = _active();
    NSArray *outArr = locs;
    if (act) {
        outArr = @[_fakeLocation()];
        OLog(@"didUpdateLocations -> FAKE(%.6f,%.6f) [%@] stack: %@",
             s_lat, s_lng, object_getClass(self), OnyxStack());
    } else {
        OLog(@"didUpdateLocations -> REAL (not active) [%@]", object_getClass(self));
    }
    IMP o = OnyxFindOrig(self);
    if (o) {
        ((void (*)(id, SEL, id, id))o)(self, _cmd, mgr, outArr);
    } else if (!act) {
        SEL sel = NSSelectorFromString(@"locationManager:didUpdateLocations:");
        Method m = class_getInstanceMethod(object_getClass(self), sel);
        IMP cur = m ? method_getImplementation(m) : NULL;
        if (cur && cur != (IMP)ony_didUpdateLocations) {
            ((void (*)(id, SEL, id, id))cur)(self, _cmd, mgr, outArr);
        }
    }
}

static void _pushToDelegate(CLLocationManager *mgr) {
    if (!_active()) return;
    OnyxScanAllDelegates();
    id del = [mgr delegate];
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[_fakeLocation()]];
        OLog(@"pushed FAKE to [%@] stack: %@", object_getClass(del), OnyxStack());
    } else {
        OLog(@"push FAILED: delegate=%@ no didUpdateLocations impl", del);
    }
}

#pragma mark - SpringBoard 系统级模拟（v1.3.0 主力）

static CLSimulationManager *s_simMgr = nil;
static BOOL s_simulating = NO;
static BOOL s_echoBusy = NO;
static BOOL s_echoLastWasReal = NO;
static CFAbsoluteTime s_echoLastAt = 0;
static dispatch_source_t s_simTimer = nil;
static dispatch_source_t s_pollTimer = nil;

static void OnyxSimHeartbeat(void);
static void OnyxCancelSimTimer(void);
static void OnyxEchoTest(void);
static void _applySimulation(void);

// 端到端回声自检：SpringBoard 自己用 CLLocationManager 向 locationd 要一次定位。
// 拿到 FAKE 坐标 = 系统模拟真的在工作；拿到 REAL = 模拟请求被 locationd 无视。
static void OnyxEchoTest(void) {
    if (!s_isSpringBoard || s_echoBusy) return;
    if (!s_enabled || !s_hasCoord) return;
    // v1.4.1：被限流跳过也要留痕，否则日志里"没有 ECHO"分不清是没触发还是被限流
    if (s_echoLastAt > 0 && CFAbsoluteTimeGetCurrent() - s_echoLastAt < 90.0) {
        OLog(@"ECHO: skip (rate-limit, 距上次判定 %.0fs)", 90.0 - (CFAbsoluteTimeGetCurrent() - s_echoLastAt));
        return;
    }
    s_echoBusy = YES;

    s_echoMgr = [[CLLocationManager alloc] init];
    s_echoDel = [[OnyxEchoDelegate alloc] init];
    OnyxEchoDelegate *d = s_echoDel;
    d.onyx_done = ^(CLLocation *loc, NSError *err) {
        s_echoBusy = NO;
        s_echoLastAt = CFAbsoluteTimeGetCurrent();
        if (err) {
            OLog(@"ECHO: ERROR code=%ld domain=%@", (long)err.code, err.domain);
        } else if (!loc) {
            OLog(@"ECHO: TIMEOUT (5s 内 locationd 没回调任何坐标)");
        } else {
            BOOL fake = (fabs(loc.coordinate.latitude  - s_lat) < 0.0005 &&
                         fabs(loc.coordinate.longitude - s_lng) < 0.0005);
            s_echoLastWasReal = !fake;
            OLog(@"ECHO: %@ -> %.6f,%.6f  (target %.6f,%.6f) hAcc=%.0f  [%@]",
                 fake ? @"FAKE" : @"REAL",
                 loc.coordinate.latitude, loc.coordinate.longitude,
                 s_lat, s_lng, loc.horizontalAccuracy,
                 fake ? @"系统模拟生效" : @"系统模拟没生效，locationd 仍给真实坐标");
        }
    };
    s_echoMgr.delegate = d;
    OLog(@"ECHO: start, asking locationd for one fix...");
    [s_echoMgr startUpdatingLocation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (s_echoBusy) {
            s_echoBusy = NO;
            s_echoLastAt = CFAbsoluteTimeGetCurrent();
            OLog(@"ECHO: TIMEOUT (5s 内 locationd 没回调任何坐标)");
        }
    });
}

static void OnyxCancelSimTimer(void) {
    if (s_simTimer) { dispatch_source_cancel(s_simTimer); s_simTimer = nil; }
}

// 持续补帧：locationd 偶发丢模拟点时，靠心跳把假坐标钉住
// v1.4.0：心跳加日志（每 8 拍打一条，不刷屏）+ 模拟被 locationd 悄悄停掉时自动复活
static void OnyxSimHeartbeat(void) {
    if (!s_simMgr) return;
    SEL appendSel = NSSelectorFromString(@"appendSimulatedLocation:");
    if ([s_simMgr respondsToSelector:appendSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [s_simMgr performSelector:appendSel withObject:_fakeLocation()];
#pragma clang diagnostic pop
    }
    // 队列可能被 locationd 消费完而静默停止，这里补一刀
    if (!s_simulating && s_enabled && s_hasCoord) {
        SEL startSel = NSSelectorFromString(@"startLocationSimulation");
        if ([s_simMgr respondsToSelector:startSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [s_simMgr performSelector:startSel];
#pragma clang diagnostic pop
            s_simulating = YES;
            OLog(@"sim: RESTART (queue drained by locationd) -> %.6f,%.6f", s_lat, s_lng);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ OnyxEchoTest(); });
            return;
        }
    }
    static int beat = 0;
    if ((++beat % 8) == 0) {
        OLog(@"sim: HB #%d simulating=%d -> %.6f,%.6f", beat, (int)s_simulating, s_lat, s_lng);
    }
}

static void OnyxScheduleSimTimer(void) {
    OnyxCancelSimTimer();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!t) return;
    dispatch_source_set_event_handler(t, ^{ OnyxSimHeartbeat(); });
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                              (uint64_t)(3 * NSEC_PER_SEC), (int64_t)(1 * NSEC_PER_SEC));
    dispatch_resume(t);
    s_simTimer = t;
}

// SpringBoard 内定时重读 plist：通知万一丢了他也能自愈
static void OnyxPollPrefs(void) {
    CFAbsoluteTime last = s_lastRead;
    _readPrefs();
    if (s_lastRead != last) _applySimulation();
}

static void _applySimulation(void) {
    if (!s_isSpringBoard) return;
    if (s_enabled && s_hasCoord) {
        if (!s_simMgr) {
            Class c = NSClassFromString(@"CLSimulationManager");
            if (!c) {
                OLog(@"sim: CLSimulationManager class NOT FOUND on this iOS");
                return;
            }
            // v1.4.0：优先用系统单例。alloc/init 可能拿到一个没接上 locationd 的
            // 独立实例，那样后面所有调用都是空响。
            SEL sharedSel = NSSelectorFromString(@"sharedSimulationManager");
            if ([c respondsToSelector:sharedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id sh = [c performSelector:sharedSel];
#pragma clang diagnostic pop
                if (sh) {
                    OLog(@"sim: sharedSimulationManager -> %@", sh);
                    s_simMgr = (CLSimulationManager *)sh;
                }
            }
            if (!s_simMgr) {
                s_simMgr = [[c alloc] init];
                OLog(@"sim: created (alloc/init) %@", s_simMgr);
            }
        }
        if (!s_simMgr) return;

        SEL appendSel = NSSelectorFromString(@"appendSimulatedLocation:");
        if ([s_simMgr respondsToSelector:appendSel]) {
            // 先塞 3 帧，让 locationd 建立一段连续轨迹（单点会被当成静止点）
            for (int i = 0; i < 3; i++) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [s_simMgr performSelector:appendSel withObject:_fakeLocation()];
#pragma clang diagnostic pop
            }
        } else {
            OLog(@"sim: WARN appendSimulatedLocation: unavailable");
        }
        if (!s_simulating) {
            SEL startSel = NSSelectorFromString(@"startLocationSimulation");
            if ([s_simMgr respondsToSelector:startSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [s_simMgr performSelector:startSel];
#pragma clang diagnostic pop
                s_simulating = YES;
                OLog(@"sim: START -> %.6f,%.6f", s_lat, s_lng);
            } else {
                OLog(@"sim: WARN startLocationSimulation unavailable");
            }
        }
        // v1.4.0：模拟起来后做一次端到端回声，直接证明 locationd 有没有在投递
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ OnyxEchoTest(); });
        OnyxScheduleSimTimer();
    } else if (s_simulating) {
        OnyxCancelSimTimer();
        if (s_simMgr) {
            SEL stopSel = NSSelectorFromString(@"stopLocationSimulation");
            if ([s_simMgr respondsToSelector:stopSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [s_simMgr performSelector:stopSel];
#pragma clang diagnostic pop
            }
        }
        s_simulating = NO; s_simMgr = nil;
        OLog(@"sim: STOP");
    }
}

#pragma mark - 通知回调

static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _readPrefs();
    _applySimulation();
    if (_active()) {
        for (CLLocationManager *m in s_mgrs) {
            if (m) _pushToDelegate(m);
        }
    }
    OLog(@"changed: enabled=%d hasCoord=%d sim=%d", s_enabled, s_hasCoord, (int)s_simulating);
}
static void onStop(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    s_enabled = NO; s_hasCoord = NO;
    _applySimulation();
    OLog(@"stopped");
}

#pragma mark - Hooks

%group OnyxHooks

%hook CLLocationManager
- (instancetype)init {
    CLLocationManager *m = %orig;
    if (m && s_mgrs) [s_mgrs addObject:m];
    OLog(@"CLLocationManager init");
    return m;
}
- (void)dealloc {
    if (s_mgrs) [s_mgrs removeObject:self];
    %orig;
}
- (CLLocation *)location {
    if (_active()) {
        OLogStack(@"CLLocationManager.location read");
        return _fakeLocation();
    }
    return %orig;
}
- (void)setDelegate:(id)delegate {
    %orig;
    if (delegate) {
        OnyxHookDelegateClass(object_getClass(delegate));
        OLog(@"setDelegate: [%@]", object_getClass(delegate));
    }
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush)];
        });
    }
}
- (void)startUpdatingLocation {
    OnyxScanAllDelegates();
    OLogStack(@"startUpdatingLocation");
    if (_active()) {
        OLog(@"startUpdatingLocation -> SUPPRESS real GPS, push FAKE");
        [self performSelector:@selector(_onyxFakePush)];
        return;
    }
    %orig;
}
- (void)startMonitoringSignificantLocationChanges {
    OLogStack(@"startMonitoringSignificantLocationChanges");
    if (_active()) {
        [self performSelector:@selector(_onyxFakePush)];
        return;
    }
    %orig;
}
- (void)requestLocation {
    OLogStack(@"requestLocation");
    if (_active()) {
        [self performSelector:@selector(_onyxFakePush)];
        return;
    }
    %orig;
}
- (void)requestLocationWithCompletionHandler:(void (^)(CLLocation *, NSError *))completionHandler {
    OLogStack(@"requestLocationWithCompletionHandler");
    if (_active()) {
        if (completionHandler) completionHandler(_fakeLocation(), nil);
        return;
    }
    %orig;
}
+ (BOOL)locationServicesEnabled {
    if (s_enabled && s_hasCoord) return YES;
    return %orig;
}
+ (CLAuthorizationStatus)authorizationStatus {
    if (s_enabled && s_hasCoord) return kCLAuthorizationStatusAuthorizedAlways;
    return %orig;
}
- (CLAuthorizationStatus)authorizationStatus {
    if (s_enabled && s_hasCoord) return kCLAuthorizationStatusAuthorizedAlways;
    return %orig;
}
%new
- (void)_onyxFakePush {
    _pushToDelegate(self);
}
%end

%end // OnyxHooks

// 百度定位 SDK
%group BaiduHooks
%hook BMKLocationManager
- (void)startUpdatingLocation {
    if (_active()) {
        id del = self.delegate;
        OLog(@"Baidu startUpdatingLocation -> FAKE");
        if (del && [del respondsToSelector:@selector(didUpdateLocation:)]) {
            [del didUpdateLocation:_fakeLocation()];
        }
        return;
    }
    %orig;
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) {
            void (^cb)(CLLocation *l, id error, BOOL regeo) = (id)block;
            cb(loc, nil, reGeocode);
        }
        return;
    }
    %orig;
}
%end
%hook BMKLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) return _fakeCoord();
    return %orig;
}
- (CLLocation *)location {
    if (_active()) return _fakeLocation();
    return %orig;
}
%end
%end

// 高德定位 SDK
%group AMapHooks
%hook AMapLocationManager
- (void)startUpdatingLocation {
    if (_active()) {
        id del = self.delegate;
        OLog(@"AMap startUpdatingLocation -> FAKE");
        if (del && [del respondsToSelector:@selector(amapLocationManager:didUpdateLocation:reGeocode:)]) {
            [del amapLocationManager:self didUpdateLocation:_fakeLocation() reGeocode:nil];
        }
        return;
    }
    %orig;
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) {
            void (^cb)(CLLocation *l, id regeo, id error) = (id)block;
            cb(loc, nil, nil);
        }
        return;
    }
    %orig;
}
%end
%hook AMapLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) return _fakeCoord();
    return %orig;
}
%end
%end

// 腾讯定位 SDK
%group TencentHooks
%hook TencentLocationManager
- (void)startUpdatingLocation {
    if (_active()) {
        id del = self.delegate;
        OLog(@"Tencent startUpdatingLocation -> FAKE");
        if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocation:)]) {
            [del locationManager:self didUpdateLocation:_fakeLocation()];
        }
        return;
    }
    %orig;
}
- (void)requestLocationWithCompletionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) {
            void (^cb)(CLLocation *l, id error) = (id)block;
            cb(loc, nil);
        }
        return;
    }
    %orig;
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *procName = [[NSProcessInfo processInfo] processName];
        s_isSpringBoard = [procName isEqualToString:@"SpringBoard"];

        s_mgrs = [NSHashTable weakObjectsHashTable];
        _readPrefs();

        // 强制自检日志：dylib 自身是从哪个镜像路径加载进来的
        if (!s_bootLogged) {
            s_bootLogged = YES;
            NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: procName;
            NSString *imgPath = @"";
            uint32_t cnt = _dyld_image_count();
            NSMutableArray *found = [NSMutableArray array];
            for (uint32_t i = 0; i < cnt; i++) {
                const char *nm = _dyld_get_image_name(i);
                if (!nm) continue;
                NSString *s = [NSString stringWithUTF8String:nm];
                if ([s rangeOfString:@"onyx" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [found addObject:s];
                }
            }
            imgPath = [found componentsJoinedByString:@","];
            if (!imgPath.length) imgPath = @"(not in dyld image list)";
            OWrite([NSString stringWithFormat:
                   @"=== Onyx v1.4.3 BOOT pid=%d proc=%@ bundle=%@ plist=%@ enabled=%d hasCoord=%d lat=%.6f lng=%.6f simNow=%d img=%@ ===\n",
                   (int)getpid(),
                   procName, bid, (s_enabled ? @"hit" : @"?"), (int)s_enabled, (int)s_hasCoord,
                   s_lat, s_lng, (int)s_simulating, imgPath]);
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onChanged, kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onStop, kStop, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (s_isSpringBoard) {
            [[OnyxTileProxy shared] startObserving];
            _applySimulation();
            // 3 秒轮询兜底：Darwin 通知偶尔丢，靠轮询自愈
            s_pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            if (s_pollTimer) {
                dispatch_source_set_event_handler(s_pollTimer, ^{ OnyxPollPrefs(); });
                dispatch_source_set_timer(s_pollTimer,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                    (uint64_t)(3 * NSEC_PER_SEC), (int64_t)(1 * NSEC_PER_SEC));
                dispatch_resume(s_pollTimer);
            }
            OLog(@"loaded (SpringBoard) simulating=%d", (int)s_simulating);
        } else {
            %init(OnyxHooks);
            %init(BaiduHooks);
            %init(AMapHooks);
            %init(TencentHooks);
            OLog(@"loaded (app=%@) enabled=%d hasCoord=%d active=%d",
                 procName, s_enabled, s_hasCoord, _active());
        }
    }
}
