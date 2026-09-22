// Onyx Tweak — 按 App 控制指定系统返回值（per-app 注入 + 开关）
// 读取 prefs 域 com.yzdmm.onyx 的：enabled(总开关)、<bundleId>(每 App 开关)、X/Y(两个数值)
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain  = @"com.yzdmm.onyx";
#define kDomainCF CFSTR("com.yzdmm.onyx")
static NSString *const kChanged = @"com.yzdmm.onyx/changed";

static double s_x = 0, s_y = 0;
static BOOL s_hasXY = NO;
static BOOL s_enabled = NO;

static BOOL _hasXY(void) {
    CFPropertyListRef cx = CFPreferencesCopyAppValue(CFSTR("X"), kDomainCF);
    CFPropertyListRef cy = CFPreferencesCopyAppValue(CFSTR("Y"), kDomainCF);
    BOOL ok = (cx && cy);
    if (ok) { s_x = [(__bridge NSNumber *)cx doubleValue]; s_y = [(__bridge NSNumber *)cy doubleValue]; }
    if (cx) CFRelease(cx);
    if (cy) CFRelease(cy);
    return ok;
}

static void _reload(void) {
    CFPropertyListRef e = CFPreferencesCopyAppValue(CFSTR("enabled"), kDomainCF);
    s_enabled = e ? [(__bridge NSNumber *)e boolValue] : NO;
    if (e) CFRelease(e);
    s_hasXY = _hasXY();
}

static BOOL _appOn(NSString *bid) {
    if (!bid.length) return NO;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)bid, kDomainCF);
    BOOL on = v ? [(__bridge NSNumber *)v boolValue] : NO;
    if (v) CFRelease(v);
    return on;
}

// 当前 App 是否在「总开关开 + 已设 X/Y + 本 App 开关开」状态
static BOOL _active(void) {
    if (!s_enabled || !s_hasXY) return NO;
    return _appOn(NSBundle.mainBundle.bundleIdentifier);
}

static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _reload();
}

%group OnyxHooks

%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (_active()) return CLLocationCoordinate2DMake(s_x, s_y);
    return %orig;
}
- (id)initWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) return %orig(s_x, s_y);
    return %orig;
}
+ (id)locationWithLatitude:(double)lat longitude:(double)lng {
    if (_active()) return %orig(s_x, s_y);
    return %orig;
}
%end

%hook CLLocationManager
- (CLLocation *)location {
    if (_active()) return [[CLLocation alloc] initWithLatitude:s_x longitude:s_y];
    return %orig;
}
- (void)requestLocation {
    if (_active()) {
        id del = self.delegate;
        if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_x longitude:s_y];
            [del locationManager:self didUpdateLocations:@[loc]];
        }
        return;
    }
    %orig;
}
- (void)startUpdatingLocation {
    %orig;
    if (_active()) {
        [self performSelector:@selector(_onyxFakePush) withObject:nil afterDelay:0.6];
    }
}
%new
- (void)_onyxFakePush {
    if (!_active()) return;
    id del = self.delegate;
    if (del && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_x longitude:s_y];
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
    NSLog(@"[Onyx] loaded (enabled=%d hasXY=%d)", s_enabled, s_hasXY);
}
