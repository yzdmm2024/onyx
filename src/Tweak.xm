// Onyx Tweak — 按 App 控制指定系统返回值（per-app 注入 + App 内配置）
// 读取 prefs 域 com.yzdmm.onyx 的：enabled(总开关)、Latitude/Longitude(WGS-84)、SelectedApps(字符串数组)
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "OnyxTileProxy.h"

// ---- 第三方定位 SDK 的最小桩声明（仅编译期需要，运行期 Hook 真实类） ----
// 这些类的真实头文件在编译期不可见，theos 只会生成 @class 前向声明，
// 导致无法访问 .delegate 属性、也无法向 delegate 回调假坐标而报错。
// 这里只声明最小桩让编译通过；设备上 Hook 的是真实存在的类。
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
#define kDomainCF CFSTR("com.yzdmm.onyx")
static NSString *const kChanged = @"com.yzdmm.onyx/changed";
static NSHashTable<CLLocationManager *> *s_mgrs = nil;

static double s_lat = 0, s_lng = 0;
static BOOL s_hasCoord = NO;
static BOOL s_enabled = NO;
static NSSet<NSString *> *s_selectedApps = nil;

// 直接读取 plist 文件，绕过 cfprefsd 在 rootless / RootHide（relaxin）下可能出现的
// 「写入进程能写、但注入到目标 App 的 Tweak 读不到」的跨进程隔离问题。
// 优先尝试 rootless 路径，再回退标准路径；都失败才退回 CFPreferences。
static NSDictionary *_onyxLoadPlist(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/jb/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/jb/var/root/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *p in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) return d;
    }
    return nil;
}

static CFAbsoluteTime s_lastRead = 0;
static void _readPrefs(void) {
    NSDictionary *d = _onyxLoadPlist();
    if (d) {
        s_enabled = [d[@"enabled"] boolValue];
        NSNumber *la = d[@"Latitude"], *ln = d[@"Longitude"];
        s_hasCoord = (la && ln);
        if (s_hasCoord) { s_lat = [la doubleValue]; s_lng = [ln doubleValue]; }
        NSArray *sel = d[@"SelectedApps"];
        s_selectedApps = [sel isKindOfClass:[NSArray class]] ? [NSSet setWithArray:sel] : nil;
        return;
    }
    // 兜底：仍用 CFPreferences（理论与实测都极少走到这里）
    CFPreferencesAppSynchronize(kDomainCF);
    CFPropertyListRef e = CFPreferencesCopyValue(CFSTR("enabled"), kDomainCF,
                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    s_enabled = e ? [(__bridge NSNumber *)e boolValue] : NO;
    if (e) CFRelease(e);
    CFPropertyListRef la = CFPreferencesCopyValue(CFSTR("Latitude"), kDomainCF,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef ln = CFPreferencesCopyValue(CFSTR("Longitude"), kDomainCF,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    s_hasCoord = (la && ln);
    if (s_hasCoord) { s_lat = [(__bridge NSNumber *)la doubleValue]; s_lng = [(__bridge NSNumber *)ln doubleValue]; }
    if (la) CFRelease(la);
    if (ln) CFRelease(ln);
    CFPropertyListRef arr = CFPreferencesCopyValue(CFSTR("SelectedApps"), kDomainCF,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (arr) { s_selectedApps = [NSSet setWithArray:(__bridge NSArray *)arr]; CFRelease(arr); }
    else { s_selectedApps = nil; }
}

// 限制磁盘读取频率（每秒最多一次），避免热点方法里频繁读文件；
// 同时让 Tweak 在 App 改了配置后能自愈（无需依赖 Darwin 通知一定送达）。
static void _readPrefsThrottled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - s_lastRead > 1.0) { _readPrefs(); s_lastRead = now; }
}

static BOOL s_logNoEnabled = NO, s_logEmpty = NO, s_logMismatch = NO;
static BOOL _active(void) {
    _readPrefsThrottled();
    if (!s_enabled || !s_hasCoord) {
        if (!s_logNoEnabled) { NSLog(@"[Onyx] _active=NO (enabled=%d hasCoord=%d) bid=%@",
                                     s_enabled, s_hasCoord, NSBundle.mainBundle.bundleIdentifier); s_logNoEnabled = YES; }
        return NO;
    }
    // 恢复 0.5.0 全局模拟语义：enabled 且坐标有效即对所有 App 生效，
    // 不再要求先在「应用列表」勾选。系统级 CLSimulationManager 同为全局生效，
    // Tweak 的 hook 作兜底拦截，确保系统定位与三类定位 SDK 都返回假坐标；
    // 需要回到真实位置时由 App 内「恢复到真实位置」按钮把 enabled 置 0。
    return YES;
}

static CLLocationCoordinate2D _fakeCoord(void) {
    return CLLocationCoordinate2DMake(s_lat, s_lng);
}

static CLLocation *_fakeLocation(void) {
    return [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
}

static void _pushToDelegate(CLLocationManager *mgr) {
    if (!_active()) return;
    id del = mgr.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        CLLocation *loc = _fakeLocation();
        [del locationManager:mgr didUpdateLocations:@[loc]];
        NSLog(@"[Onyx] pushed fake CLLocation to delegate: %@ -> %.6f,%.6f", mgr, s_lat, s_lng);
    }
}

static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _readPrefs();
    // 配置变化后立即给本进程内存活的所有 CLLocationManager 推一次假坐标，
    // 让「选中的应用」立刻生效，无需等下一次位置请求。
    if (s_enabled && s_hasCoord) {
        for (CLLocationManager *m in s_mgrs) {
            if (m && [m respondsToSelector:@selector(_onyxFakePush)]) {
                [m performSelector:@selector(_onyxFakePush)];
            }
        }
    }
    NSLog(@"[Onyx] reloaded enabled=%d hasCoord=%d bid=%@ selected=%@", s_enabled, s_hasCoord, NSBundle.mainBundle.bundleIdentifier, s_selectedApps.allObjects);
}

%group OnyxHooks

%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocation.coordinate -> %.6f,%.6f", s_lat, s_lng);
        return _fakeCoord();
    }
    return %orig;
}
- (id)initWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocation initWithLatitude -> %.6f,%.6f", s_lat, s_lng);
        return %orig(s_lat, s_lng);
    }
    return %orig;
}
+ (id)locationWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocation +locationWithLatitude -> %.6f,%.6f", s_lat, s_lng);
        return %orig(s_lat, s_lng);
    }
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
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocationManager.location -> %.6f,%.6f", s_lat, s_lng);
        return _fakeLocation();
    }
    return %orig;
}
- (void)setDelegate:(id)delegate {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] CLLocationManager.delegate set, pushing fake location");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestLocation {
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocationManager.requestLocation -> %.6f,%.6f", s_lat, s_lng);
        id del = self.delegate;
        if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [del locationManager:self didUpdateLocations:@[_fakeLocation()]];
        }
        return;
    }
    %orig;
}
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] hooked CLLocationManager.startUpdatingLocation -> %.6f,%.6f", s_lat, s_lng);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestWhenInUseAuthorization {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] CLLocationManager.requestWhenInUseAuthorization, pushing fake location");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestAlwaysAuthorization {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] CLLocationManager.requestAlwaysAuthorization, pushing fake location");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
%new
- (void)_onyxFakePush {
    if (!_active()) return;
    id del = self.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:self didUpdateLocations:@[_fakeLocation()]];
        NSLog(@"[Onyx] _onyxFakePush -> %.6f,%.6f", s_lat, s_lng);
    }
}
%end
%end

// 百度定位 SDK（BMKLocationManager）
%group BaiduHooks
%hook BMKLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] BMKLocationManager.startUpdatingLocation -> %.6f,%.6f", s_lat, s_lng);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:@selector(delegate)]) {
                id del = self.delegate;
                if (del && [del respondsToSelector:@selector(didUpdateLocation:)]) {
                    CLLocation *loc = _fakeLocation();
                    [del didUpdateLocation:loc];
                }
            }
        });
    }
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)block {
    if (_active()) {
        NSLog(@"[Onyx] BMKLocationManager.requestLocationWithReGeocode -> %.6f,%.6f", s_lat, s_lng);
        CLLocation *loc = _fakeLocation();
        if (block) {
            void (^cb)(CLLocation *l, id error, BOOL regeo) = (id)block;
            cb(loc, nil, reGeocode);
        }
        return;
    }
    %orig;
}
- (void)requestLocationWithReGeocode:(BOOL)reGeocode locModelWithOption:(id)option completionBlock:(id)block {
    if (_active()) {
        NSLog(@"[Onyx] BMKLocationManager.requestLocationWithReGeocode:locModelWithOption -> %.6f,%.6f", s_lat, s_lng);
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
    if (_active()) {
        NSLog(@"[Onyx] BMKLocation.coordinate -> %.6f,%.6f", s_lat, s_lng);
        return _fakeCoord();
    }
    return %orig;
}
- (CLLocation *)location {
    if (_active()) {
        NSLog(@"[Onyx] BMKLocation.location -> %.6f,%.6f", s_lat, s_lng);
        return _fakeLocation();
    }
    return %orig;
}
%end
%end

// 高德定位 SDK（AMapLocationManager）
%group AMapHooks
%hook AMapLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] AMapLocationManager.startUpdatingLocation -> %.6f,%.6f", s_lat, s_lng);
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
        NSLog(@"[Onyx] AMapLocationManager.requestLocationWithReGeocode -> %.6f,%.6f", s_lat, s_lng);
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
    if (_active()) {
        NSLog(@"[Onyx] AMapLocation.coordinate -> %.6f,%.6f", s_lat, s_lng);
        return _fakeCoord();
    }
    return %orig;
}
%end
%end

// 腾讯定位 SDK
%group TencentHooks
%hook TencentLocationManager
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        NSLog(@"[Onyx] TencentLocationManager.startUpdatingLocation -> %.6f,%.6f", s_lat, s_lng);
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
        NSLog(@"[Onyx] TencentLocationManager.requestLocationWithCompletionBlock -> %.6f,%.6f", s_lat, s_lng);
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
    s_mgrs = [NSHashTable weakObjectsHashTable];
    _readPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        onChanged, (CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    %init(OnyxHooks);
    %init(BaiduHooks);
    %init(AMapHooks);
    %init(TencentHooks);
    // 瓦片代拉代理：注入 SpringBoard（platformized 可联网），6 并发 + 请求目录队列化
    [[OnyxTileProxy shared] startObserving];
    NSLog(@"[Onyx] loaded (enabled=%d hasCoord=%d bid=%@ selected=%@)", s_enabled, s_hasCoord, NSBundle.mainBundle.bundleIdentifier, s_selectedApps.allObjects);
}
