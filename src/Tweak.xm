// Onyx Tweak
// 定位模拟：双管齐下
//   1) SpringBoard 内 CLSimulationManager 系统级模拟（跟 LocSim 同款，隐身，能下发的 App 走这条）
//   2) 各 App 进程内 Hook CoreLocation，直接注入假坐标（兜底，覆盖系统模拟未生效的第三方 App）
// 瓦片代拉：SpringBoard 进程内启动（platformized 可联网）
//
// v1.0.3：修复「其他 App 一直显示真实定位」——旧版只在 SpringBoard 跑系统模拟，
//         第三方 App 的 CoreLocation 管线拿不到假坐标。现在每个 App 进程内直接
//         Hook CLLocationManager（location 取值 / startUpdatingLocation / requestLocation /
//         setDelegate 回调），保证所有 App 都读到假坐标。
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "OnyxTileProxy.h"

// CLSimulationManager 私有 API（跟 LocSim 同款）
@interface CLSimulationManager : NSObject
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
@end

static double s_lat = 0, s_lng = 0;
static BOOL s_enabled = NO;
static BOOL s_hasCoord = NO;
static BOOL s_simulating = NO;
static BOOL s_isSpringBoard = NO;
static CLSimulationManager *s_simMgr = nil;

// 读配置：Tweak 同目录优先（dylib 能加载就能读），再回退公共路径与 Preferences
// ⚠️ relaxin/RootHide 上 OnyxApp 唯一写得动的是 /var/tmp（v1.0.2 找回）。
static NSDictionary *_loadPrefs(void) {
    NSArray *paths = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/var/tmp/com.yzdmm.onyx.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) return d;
    }
    return nil;
}

// 生成带合理精度的假坐标（horizontalAccuracy=5m，避免被 App 因无效精度丢弃）
static CLLocation *_fakeLocation(void) {
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(s_lat, s_lng);
    return [[CLLocation alloc] initWithCoordinate:c
                                         altitude:0
                               horizontalAccuracy:5
                                 verticalAccuracy:-1
                                           course:-1
                                            speed:-1
                                        timestamp:[NSDate date]];
}

// 启动系统级模拟（仅 SpringBoard）
static void _startSimulation(void) {
    if (s_simulating) return;
    Class simClass = objc_getClass("CLSimulationManager");
    if (!simClass) { NSLog(@"[Onyx] CLSimulationManager not found"); return; }
    s_simMgr = [[simClass alloc] init];
    if (!s_simMgr) { NSLog(@"[Onyx] init CLSimulationManager failed"); return; }
    [s_simMgr appendSimulatedLocation:_fakeLocation()];
    [s_simMgr startLocationSimulation];
    s_simulating = YES;
    NSLog(@"[Onyx] sim started %.5f, %.5f", s_lat, s_lng);
}

// 停止系统级模拟（仅 SpringBoard）
static void _stopSimulation(void) {
    if (!s_simulating) return;
    [s_simMgr stopLocationSimulation];
    s_simMgr = nil;
    s_simulating = NO;
    NSLog(@"[Onyx] sim stopped");
}

// 应用配置：所有进程都会调用（读 plist），但系统级模拟只由 SpringBoard 驱动
static void _applyPrefs(void) {
    NSDictionary *prefs = _loadPrefs();
    if (!prefs) { NSLog(@"[Onyx] no prefs found"); return; }

    NSNumber *en = prefs[@"enabled"];
    NSNumber *lat = prefs[@"Latitude"];
    NSNumber *lng = prefs[@"Longitude"];

    s_enabled = en.boolValue;
    s_lat = lat.doubleValue;
    s_lng = lng.doubleValue;
    s_hasCoord = (lat != nil && lng != nil && fabs(s_lat) > 0.0001);

    if (s_isSpringBoard) {
        if (s_enabled && s_hasCoord) {
            if (s_simulating) _stopSimulation();
            _startSimulation();
        } else if (s_simulating) {
            _stopSimulation();
        }
    }
    NSLog(@"[Onyx] applyPrefs enabled=%d hasCoord=%d", s_enabled, s_hasCoord);
}

#pragma mark - App 级 CoreLocation Hook 辅助

static NSMutableDictionary *s_origMap = nil;   // key:"ClassName_selname" -> NSNumber(IMP)
static NSLock *s_mapLock = nil;

static NSString *_onyxKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s_%s", class_getName(cls), sel_getName(sel)];
}
static IMP _onyxOrig(Class cls, SEL sel) {
    NSString *k = _onyxKey(cls, sel);
    NSNumber *v;
    [s_mapLock lock]; v = [s_origMap objectForKey:k]; [s_mapLock unlock];
    return (IMP)[v unsignedLongLongValue];
}
// 把 delegate 的某个回调方法换成我们的版本（每个类只换一次）
static void _onyxSwizzle(Class cls, SEL sel, IMP newImp) {
    if (!class_respondsToSelector(cls, sel)) return;
    NSString *k = _onyxKey(cls, sel);
    [s_mapLock lock];
    if (![s_origMap objectForKey:k]) {
        Method m = class_getInstanceMethod(cls, sel);
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, newImp);
        [s_origMap setObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)orig] forKey:k];
    }
    [s_mapLock unlock];
}

// 替换后的 delegate 回调：把真实坐标洗成假坐标
static void _onyxDidUpdateLocations(id self, SEL _cmd, CLLocationManager *mgr, NSArray *locations) {
    IMP orig = _onyxOrig(object_getClass(self), _cmd);
    if (s_enabled && s_hasCoord) {
        locations = @[_fakeLocation()];
    }
    if (orig) ((void(*)(id, SEL, id, NSArray *))orig)(self, _cmd, mgr, locations);
}
// 兼容老的 -locationManager:didUpdateToLocation:fromLocation:（iOS 6 以前）
static void _onyxDidUpdateToLocation(id self, SEL _cmd, CLLocationManager *mgr,
                                     CLLocation *newLoc, CLLocation *oldLoc) {
    IMP orig = _onyxOrig(object_getClass(self), _cmd);
    if (s_enabled && s_hasCoord) {
        newLoc = _fakeLocation();
        oldLoc = _fakeLocation();
    }
    if (orig) ((void(*)(id, SEL, id, id, id))orig)(self, _cmd, mgr, newLoc, oldLoc);
}

// 主动向 delegate 推一帧假坐标
static void _pushFakeToDelegate(CLLocationManager *mgr) {
    if (!s_enabled || !s_hasCoord) return;
    id del = mgr.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[_fakeLocation()]];
    }
}

%hook CLLocationManager

// 直接读 .location 属性的 App 走这条
- (CLLocation *)location {
    if (!s_isSpringBoard && s_enabled && s_hasCoord) {
        return _fakeLocation();
    }
    return %orig;
}

// 开始更新 / 单次请求 / 显著位置变化：先放行，再补推一帧假坐标
- (void)startUpdatingLocation {
    %orig;
    if (!s_isSpringBoard) _pushFakeToDelegate(self);
}
- (void)requestLocation {
    %orig;
    if (!s_isSpringBoard) _pushFakeToDelegate(self);
}
- (void)startMonitoringSignificantLocationChanges {
    %orig;
    if (!s_isSpringBoard) _pushFakeToDelegate(self);
}

// 接管 delegate 回调：真实坐标一律洗成假坐标（覆盖系统模拟下不到的 App）
- (void)setDelegate:(id)delegate {
    if (delegate && !s_isSpringBoard) {
        _onyxSwizzle(object_getClass(delegate),
                     @selector(locationManager:didUpdateLocations:),
                     (IMP)_onyxDidUpdateLocations);
        _onyxSwizzle(object_getClass(delegate),
                     @selector(locationManager:didUpdateToLocation:fromLocation:),
                     (IMP)_onyxDidUpdateToLocation);
    }
    %orig;
}

%end

#pragma mark - 通知回调

static void _prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    _applyPrefs();
}
static void _stopSimCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    _stopSimulation();
    s_enabled = NO;
    s_hasCoord = NO;
}

%ctor {
    @autoreleasepool {
        s_origMap = [NSMutableDictionary dictionary];
        s_mapLock = [[NSLock alloc] init];

        NSString *procName = [[NSProcessInfo processInfo] processName];
        s_isSpringBoard = [procName isEqualToString:@"SpringBoard"];

        // 每个进程都读一次配置，保证 App 进程知道要不要注入假坐标
        _applyPrefs();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _prefsChanged, CFSTR("com.yzdmm.onyx/changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _stopSimCallback, CFSTR("com.yzdmm.onyx/stop"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        if (s_isSpringBoard) {
            // 瓦片代拉：SpringBoard 可联网，代 OnyxApp 下载地图瓦片
            [[OnyxTileProxy shared] startObserving];
            NSLog(@"[Onyx] loaded in SpringBoard, simulating=%d", s_simulating);
        } else {
            NSLog(@"[Onyx] loaded in %@, enabled=%d hasCoord=%d", procName, s_enabled, s_hasCoord);
        }
    }
}
