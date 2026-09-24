// Onyx Tweak v1.2.0
//
// 定位模拟（per-app 直注）：
//   ★v1.2.0 关键修正：不再「保留真实定位 + 额外推一帧假坐标」。
//     旧版 startUpdatingLocation 先 %orig（真的启动 GPS），再推假坐标，
//     结果 App 的 delegate 同时收到真/假两帧，真实那帧后到 → 覆盖假坐标，
//     表现为「改了定位 App 还是显示真实位置」。
//   v1.2.0 改为：启用时【完全不启动真实定位】，接管 delegate 回调直接替换坐标。
//
// 覆盖路径：
//   1) delegate 回调 locationManager:didUpdateLocations: —— 运行时扫描全类替换坐标（最关键）
//   2) CLLocationManager：location / startUpdatingLocation / requestLocation / startMonitoring…
//   3) iOS15+ requestLocationWithCompletionHandler: 直接回调假坐标
//   4) 授权伪装：locationServicesEnabled / +authorizationStatus 返回 AuthorizedAlways
//   5) 三家地图 SDK（百度 BMK / 高德 AMap / 腾讯）
//   6) SpringBoard：仅瓦片代拉 + 可选 CLSimulationManager 兜底
//
// 黑名单 ExcludedApps：App 内添加「不改定位」的 App；Onyx 自身默认排除。
//
// 诊断日志：/var/tmp/onyx_debug.log
//   · 每次加载强制写一行 BOOT（证明 dylib 是否真的注入 + 配置是否被读到）
//   · 其后记录 plist 命中路径 / CLLocationManager 生命周期 / delegate 回调 / 调用栈
//   · App 里「诊断日志」按钮可直接查看（ONYXMapViewController → openDiagLog:）
//
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
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

// ---------------- 诊断日志 ----------------
#define ONYX_LOG_PATH @"/var/tmp/onyx_debug.log"
static NSUInteger s_logBytes = 0;

static void OWrite(NSString *line) {
    const char *s = line.UTF8String;
    size_t len = strlen(s);
    int fd = open("/var/tmp/onyx_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    // 超过 512KB 自动截断，避免拖慢 App / 占满磁盘
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz > 512 * 1024) { ftruncate(fd, 0); sz = 0; }
    if (write(fd, s, len) < 0) { /* ignore */ }
    close(fd);
    s_logBytes = (NSUInteger)sz + len;
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
static void OLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[Onyx %@] %@\n",
                      [[NSProcessInfo processInfo] processName], msg];
    OWrite(line);
}
// 用当前进程名标记「这条日志属于哪个 App —— 排查时一眼看出 App 有没有在调 CoreLocation」
static void OLogStack(NSString *tag) {
    OLog(@"%@ stack: %@", tag, OnyxStack());
}

// 读配置：/var/tmp 公共路径优先（relaxin 上 App 唯一写得动），多路径回退
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
            OLog(@"plist hit: %@", p);
            return d;
        }
    }
    OLog(@"plist MISS: no candidate file readable");
    return nil;
}

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

// ---------------- delegate 回调接管（v1.2.0 核心） ----------------
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

// 运行时扫描全类：任何实现该 delegate 方法的类都会被接管
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
            SEL sel = NSSelectorFromString(@"locationManager:didUpdateLocations:");
            if (!class_getInstanceMethod(c, sel)) continue;
            OnyxEnsureRecCap(g_recN + 1);
            if (g_recN >= g_recCap) break;
            OnyxHookDelegateClass(c);
        }
        free(cls);
    }
    s_scanning = NO;
}

static void ony_didUpdate(id self, SEL _cmd, id mgr, NSArray *locs) {
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
        // 兜底：极少数类未被接管时，仍尝试走原实现
        SEL sel = NSSelectorFromString(@"locationManager:didUpdateLocations:");
        IMP cur = method_getImplementation(class_getInstanceMethod(object_getClass(self), sel));
        if (cur && cur != (IMP)ony_didUpdateLocations) {
            ((void (*)(id, SEL, id, id))cur)(self, _cmd, mgr, outArr);
        }
    }
}

// 主动向 delegate 推一帧假坐标（不启动真实定位）
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

#pragma mark - SpringBoard 系统级模拟（兜底）

@interface CLSimulationManager : NSObject
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
@end
static CLSimulationManager *s_simMgr = nil;
static BOOL s_simulating = NO;

static void _applySimulation(void) {
    if (!s_isSpringBoard) return;
    if (s_enabled && s_hasCoord) {
        if (!s_simMgr) {
            Class c = NSClassFromString(@"CLSimulationManager");
            if (!c) { NSLog(@"[Onyx] CLSimulationManager not found"); return; }
            s_simMgr = [[c alloc] init];
        }
        if (!s_simMgr) return;
        [s_simMgr appendSimulatedLocation:_fakeLocation()];
        if (!s_simulating) { [s_simMgr startLocationSimulation]; s_simulating = YES; }
        NSLog(@"[Onyx] sim started -> %.6f,%.6f", s_lat, s_lng);
    } else if (s_simulating) {
        [s_simMgr stopLocationSimulation]; s_simulating = NO; s_simMgr = nil;
        NSLog(@"[Onyx] sim stopped");
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
    NSLog(@"[Onyx] changed: enabled=%d hasCoord=%d", s_enabled, s_hasCoord);
}
static void onStop(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    s_enabled = NO; s_hasCoord = NO;
    _applySimulation();
    NSLog(@"[Onyx] stopped");
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
    // 立刻接管 delegate 所属类（App 常动态生成 VC 作为 delegate）
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
// ★启用时完全不启动真实定位，只推假坐标
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
// iOS 15+
- (void)requestLocationWithCompletionHandler:(void (^)(CLLocation *, NSError *))completionHandler {
    OLogStack(@"requestLocationWithCompletionHandler");
    if (_active()) {
        if (completionHandler) completionHandler(_fakeLocation(), nil);
        return;
    }
    %orig;
}
// 授权伪装：App 常见「先查权限再请求」的分支，必须放行
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

        // 强制自检日志：确认 dylib 是否真的注入 + 配置是否被读到
        if (!s_bootLogged) {
            s_bootLogged = YES;
            NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: procName;
            NSDictionary *d = _onyxLoadPlist();
            OWrite([NSString stringWithFormat:
                   @"=== Onyx v1.2.0 BOOT proc=%@ bundle=%@ plist=%@ enabled=%d hasCoord=%d lat=%.6f lng=%.6f ===\n",
                   procName, bid, d ? @"hit" : @"MISS", (int)s_enabled, (int)s_hasCoord, s_lat, s_lng]);
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onChanged, kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onStop, kStop, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (s_isSpringBoard) {
            [[OnyxTileProxy shared] startObserving];
            _applySimulation();
            NSLog(@"[Onyx] loaded (SpringBoard) simulating=%d", s_simulating);
        } else {
            %init(OnyxHooks);
            %init(BaiduHooks);
            %init(AMapHooks);
            %init(TencentHooks);
            NSLog(@"[Onyx] loaded (app=%@) enabled=%d hasCoord=%d active=%d excluded=%@",
                  procName, s_enabled, s_hasCoord, _active(),
                  s_excluded ? s_excluded.allObjects : @[]);
        }
    }
}
