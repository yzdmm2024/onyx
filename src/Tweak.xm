// Onyx Tweak — 按 App 控制指定系统返回值（per-app 注入 + App 内配置）
// 读取 prefs 域 com.yzdmm.onyx 的：enabled(总开关)、Latitude/Longitude(WGS-84)、SelectedApps(字符串数组)
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain  = @"com.yzdmm.onyx";
#define kDomainCF CFSTR("com.yzdmm.onyx")
static NSString *const kChanged = @"com.yzdmm.onyx/changed";

static double s_lat = 0, s_lng = 0;
static BOOL s_hasCoord = NO;
static BOOL s_enabled = NO;
static NSSet<NSString *> *s_selectedApps = nil;

static void _reload(void) {
    CFPropertyListRef e = CFPreferencesCopyAppValue(CFSTR("enabled"), kDomainCF);
    s_enabled = e ? [(__bridge NSNumber *)e boolValue] : NO;
    if (e) CFRelease(e);

    CFPropertyListRef la = CFPreferencesCopyAppValue(CFSTR("Latitude"), kDomainCF);
    CFPropertyListRef ln = CFPreferencesCopyAppValue(CFSTR("Longitude"), kDomainCF);
    s_hasCoord = (la && ln);
    if (s_hasCoord) {
        s_lat = [(__bridge NSNumber *)la doubleValue];
        s_lng = [(__bridge NSNumber *)ln doubleValue];
    }
    if (la) CFRelease(la);
    if (ln) CFRelease(ln);

    CFPropertyListRef arr = CFPreferencesCopyAppValue(CFSTR("SelectedApps"), kDomainCF);
    if (arr) {
        s_selectedApps = [NSSet setWithArray:(__bridge NSArray *)arr];
        CFRelease(arr);
    } else {
        s_selectedApps = nil;
    }
}

static BOOL _active(void) {
    if (!s_enabled || !s_hasCoord) return NO;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid.length) return NO;
    if (s_selectedApps && ![s_selectedApps containsObject:bid]) return NO;
    return YES;
}

static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _reload();
    NSLog(@"[Onyx] reloaded enabled=%d hasCoord=%d bid=%@", s_enabled, s_hasCoord, NSBundle.mainBundle.bundleIdentifier);
}

%group OnyxHooks

%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) return CLLocationCoordinate2DMake(s_lat, s_lng);
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
- (CLLocation *)location {
    if (_active()) return [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
    return %orig;
}
- (void)setDelegate:(id)delegate {
    %orig;
    if (_active()) {
        // delegate 设好后立即推一次，确保冷启动时也能拿到假位置
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
- (void)requestLocation {
    if (_active()) {
        id del = self.delegate;
        if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
            [del locationManager:self didUpdateLocations:@[loc]];
        }
        return;
    }
    %orig;
}
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        // 立即推（不延迟），多次推确保地图初始化后也被覆盖
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self performSelector:@selector(_onyxFakePush) withObject:nil];
        });
    }
}
%new
- (void)_onyxFakePush {
    if (!_active()) return;
    id del = self.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
        [del locationManager:self didUpdateLocations:@[loc]];
    }
}
%end

%end

%ctor {
    _reload();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        onChanged, (CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    %init(OnyxHooks);
    NSLog(@"[Onyx] loaded (enabled=%d hasCoord=%d bid=%@)", s_enabled, s_hasCoord, NSBundle.mainBundle.bundleIdentifier);
}
