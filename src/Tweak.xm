// Onyx Tweak v1.1.0
//
// 定位模拟（per-app 直注，v0.7.1 验证可用）：
//   - hook CLLocation 类本体（coordinate / initWithLatitude:longitude: / locationWithLatitude:longitude:）
//     → 任何 App 读到 / 构造的 CLLocation 都拿到假坐标（覆盖 direct-read 场景）
//   - hook CLLocationManager（location 取值 / setDelegate / startUpdatingLocation / requestLocation …）
//   - hook 三家地图 SDK（百度 BMK / 高德 AMap / 腾讯 Tencent）→ 覆盖走 SDK 的 App
// 黑名单 ExcludedApps：用户在 App 里自行添加「不需要改定位」的 App（保持真实位置）。
// SpringBoard：仅跑瓦片代拉 + 可选 CLSimulationManager 系统级模拟（兜底，能下发的 App 自动生效）。
//
// 配置：直接读 /var/tmp/com.yzdmm.onyx.plist（relaxin 可写），多路径回退；
//       收到 Darwin 通知 com.yzdmm.onyx/changed 立即重读并推坐标。
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
static NSSet<NSString *> *s_excluded = nil;
static NSHashTable<CLLocationManager *> *s_mgrs = nil;
static CFAbsoluteTime s_lastRead = 0;

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
        if (d) return d;
    }
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
    if (s_excluded && [s_excluded containsObject:bid]) return NO;
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

// 主动向 delegate 推一帧假坐标
static void _pushToDelegate(CLLocationManager *mgr) {
    if (!_active()) return;
    id del = mgr.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[_fakeLocation()]];
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
            if (m && [m respondsToSelector:@selector(_onyxFakePush)]) {
                [m performSelector:@selector(_onyxFakePush)];
            }
        }
    }
    NSLog(@"[Onyx] changed: enabled=%d hasCoord=%d excluded=%@", s_enabled, s_hasCoord, s_excluded.allObjects);
}
static void onStop(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    s_enabled = NO; s_hasCoord = NO;
    _applySimulation();
    NSLog(@"[Onyx] stopped");
}

#pragma mark - Hooks

%group OnyxHooks

// —— 最关键：hook CLLocation 类本体，任何坐标对象都被洗成假坐标 ——
%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) return _fakeCoord();
    return %orig;
}
- (id)initWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) return %orig(s_lat, s_lng);
    return %orig;
}
+ (id)locationWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) return %orig(s_lat, s_lng);
    return %orig;
}
%end

%hook CLLocationManager
- (instancetype)init {
    CLLocationManager *m = %orig;
    if (m && s_mgrs) [s_mgrs addObject:m];
    return m;
}
- (void)dealloc {
    if (s_mgrs) [s_mgrs removeObject:self];
    %orig;
}
- (CLLocation *)location {
    if (_active()) return _fakeLocation();
    return %orig;
}
- (void)setDelegate:(id)delegate {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush)];
        });
    }
}
- (void)requestLocation {
    if (_active()) { _pushToDelegate(self); return; }
    %orig;
}
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self performSelector:@selector(_onyxFakePush)]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self performSelector:@selector(_onyxFakePush)]; });
    }
}
- (void)startMonitoringSignificantLocationChanges {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self performSelector:@selector(_onyxFakePush)]; });
    }
}
- (void)requestWhenInUseAuthorization {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self performSelector:@selector(_onyxFakePush)]; });
    }
}
- (void)requestAlwaysAuthorization {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self performSelector:@selector(_onyxFakePush)]; });
    }
}
%new
- (void)_onyxFakePush {
    if (!_active()) return;
    _pushToDelegate(self);
}
%end

%end // OnyxHooks

// 百度定位 SDK
%group BaiduHooks
%hook BMKLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:@selector(delegate)]) {
                id del = self.delegate;
                if (del && [del respondsToSelector:@selector(didUpdateLocation:)]) {
                    [del didUpdateLocation:_fakeLocation()];
                }
            }
        });
    }
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) { void (^cb)(CLLocation *l, id error, BOOL regeo) = (id)block; cb(loc, nil, reGeocode); }
        return;
    }
    %orig;
}
%end
%hook BMKLocation
- (CLLocationCoordinate2D)coordinate { if (_active()) return _fakeCoord(); return %orig; }
- (CLLocation *)location { if (_active()) return _fakeLocation(); return %orig; }
%end
%end

// 高德定位 SDK
%group AMapHooks
%hook AMapLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:@selector(delegate)]) {
                id del = self.delegate;
                if (del && [del respondsToSelector:@selector(amapLocationManager:didUpdateLocation:reGeocode:)]) {
                    [del amapLocationManager:self didUpdateLocation:_fakeLocation() reGeocode:nil];
                }
            }
        });
    }
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) { void (^cb)(CLLocation *l, id regeo, id error) = (id)block; cb(loc, nil, nil); }
        return;
    }
    %orig;
}
%end
%hook AMapLocation
- (CLLocationCoordinate2D)coordinate { if (_active()) return _fakeCoord(); return %orig; }
%end
%end

// 腾讯定位 SDK
%group TencentHooks
%hook TencentLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:@selector(delegate)]) {
                id del = self.delegate;
                if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocation:)]) {
                    [del locationManager:self didUpdateLocation:_fakeLocation()];
                }
            }
        });
    }
}
- (void)requestLocationWithCompletionBlock:(id)block {
    if (_active()) {
        CLLocation *loc = _fakeLocation();
        if (block) { void (^cb)(CLLocation *l, id error) = (id)block; cb(loc, nil); }
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

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onChanged, kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            onStop, kStop, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (s_isSpringBoard) {
            // SpringBoard 只跑瓦片代拉 + 系统级模拟兜底，不做任何 App 内定位 hook
            [[OnyxTileProxy shared] startObserving];
            _applySimulation();
            NSLog(@"[Onyx] loaded (SpringBoard) simulating=%d", s_simulating);
        } else {
            %init(OnyxHooks);
            %init(BaiduHooks);
            %init(AMapHooks);
            %init(TencentHooks);
            NSLog(@"[Onyx] loaded (app=%@) enabled=%d hasCoord=%d active=%d excluded=%@",
                  procName, s_enabled, s_hasCoord, _active(), s_excluded.allObjects);
        }
    }
}
