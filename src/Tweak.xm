// Onyx Tweak — 白名单模式：只注入 SpringBoard + 选定的 App，钉钉等不注入即检测不到。
// 定位模拟：per-app hook（CLLocationManager + 三家 SDK），只有勾选的 App 才生效
// 瓦片代拉：只在 SpringBoard 进程内启动（SpringBoard 是 platformized 可联网）
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
#define kDomainCF CFSTR("com.yzdmm.onyx")
static NSString *const kChanged = @"com.yzdmm.onyx/changed";
static NSHashTable<CLLocationManager *> *s_mgrs = nil;

static double s_lat = 0, s_lng = 0;
static BOOL s_hasCoord = NO;
static BOOL s_enabled = NO;
static NSSet<NSString *> *s_excludedApps = nil;
static NSString *s_readFromPath = nil; // 诊断：最后一次读到配置的路径

// 直接读取 plist，绕过 cfprefsd 在 rootless / RootHide 下的跨进程隔离
// 优先读 Tweak 同目录（dylib 能从这里加载，就一定能读同目录的文件），
// 再试 /var/tmp 公共路径，最后回退标准 Preferences 路径。
static NSDictionary *_onyxLoadPlist(void) {
    NSArray<NSString *> *cands = @[
        // Tweak 同目录（rootless 路径优先）——dylib 能被加载就一定能读
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        // 公共 tmp 路径
        @"/var/tmp/com.yzdmm.onyx.plist",
        // Preferences 标准路径
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/jb/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/jb/var/root/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *p in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            s_readFromPath = p;
            return d;
        }
    }
    s_readFromPath = nil;
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
        NSArray *sel = d[@"ExcludedApps"];
        s_excludedApps = [sel isKindOfClass:[NSArray class]] ? [NSSet setWithArray:sel] : nil;
        s_lastRead = CFAbsoluteTimeGetCurrent();
        return;
    }
    // 兜底：CFPreferences
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
    CFPropertyListRef arr = CFPreferencesCopyValue(CFSTR("ExcludedApps"), kDomainCF,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (arr) { s_excludedApps = [NSSet setWithArray:(__bridge NSArray *)arr]; CFRelease(arr); }
    else { s_excludedApps = nil; }
    s_lastRead = CFAbsoluteTimeGetCurrent();
}

static void _readPrefsThrottled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - s_lastRead > 1.0) _readPrefs();
}

// 黑名单模式：默认所有被注入的 App 都模拟定位，
// 只有 ExcludedApps（黑名单）里的 App 用真实位置
static BOOL _active(void) {
    _readPrefsThrottled();
    if (!s_enabled || !s_hasCoord) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) return NO;
    // 黑名单：在排除列表里 → 不用虚拟定位 → 返回 NO
    if (s_excludedApps && [s_excludedApps containsObject:bid]) return NO;
    // 不在排除列表里 → 用虚拟定位
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
    }
}

static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _readPrefs();
    if (s_enabled && s_hasCoord) {
        for (CLLocationManager *m in s_mgrs) {
            if (m && [m respondsToSelector:@selector(_onyxFakePush)]) {
                [m performSelector:@selector(_onyxFakePush)];
            }
        }
    }
    NSLog(@"[Onyx] prefs changed: enabled=%d hasCoord=%d selected=%@",
          s_enabled, s_hasCoord, s_excludedApps.allObjects);
}

%group OnyxHooks

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
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestLocation {
    if (_active()) {
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
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestAlwaysAuthorization {
    %orig;
    if (_active()) {
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

// 高德定位 SDK（AMapLocationManager）
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
    NSString *procName = NSProcessInfo.processInfo.processName;
    BOOL isSpringBoard = [procName isEqualToString:@"SpringBoard"];

    // SpringBoard 里只跑瓦片代拉，不做任何定位 hook
    // （SpringBoard 的定位 hook 可能会影响系统定位服务，导致全局位置被改）
    if (isSpringBoard) {
        [[OnyxTileProxy shared] startObserving];
        NSLog(@"[Onyx] loaded (SpringBoard) - tile proxy only, no location hooks");
        return;
    }

    // 非 SpringBoard 进程：初始化定位 hook
    s_mgrs = [NSHashTable weakObjectsHashTable];
    _readPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        onChanged, (CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    %init(OnyxHooks);
    %init(BaiduHooks);
    %init(AMapHooks);
    %init(TencentHooks);

    NSLog(@"[Onyx] loaded (app=%@) enabled=%d hasCoord=%d active=%d readFrom=%@ excluded=%@",
          procName, s_enabled, s_hasCoord, _active(), s_readFromPath ?: @"(none)", s_excludedApps.allObjects);
}

