// Onyx Tweak — 只注入 SpringBoard，用 CLSimulationManager 系统级定位模拟。
// 不再 hook 任何 App 内的 CLLocationManager / 地图 SDK，避免被钉钉等反作弊检测。
// 瓦片代拉也在 SpringBoard 进程内承载（6 并发 + 请求目录队列化）。
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "OnyxTileProxy.h"

// CLSimulationManager 私有 API 声明
@interface CLSimulationManager : NSObject
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
@end

static NSString *const kDomain  = @"com.yzdmm.onyx";
#define kDomainCF CFSTR("com.yzdmm.onyx")
static NSString *const kChanged = @"com.yzdmm.onyx/changed";

static double s_lat = 0, s_lng = 0;
static BOOL s_hasCoord = NO;
static BOOL s_enabled = NO;

static CLSimulationManager *s_simMgr = nil;
static BOOL s_simulating = NO;

// 直接读取 plist 文件，绕过 cfprefsd 在 rootless / RootHide 下的跨进程隔离
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

static void _readPrefs(void) {
    NSDictionary *d = _onyxLoadPlist();
    if (d) {
        s_enabled = [d[@"enabled"] boolValue];
        NSNumber *la = d[@"Latitude"], *ln = d[@"Longitude"];
        s_hasCoord = (la && ln);
        if (s_hasCoord) { s_lat = [la doubleValue]; s_lng = [ln doubleValue]; }
        return;
    }
    // 兜底：CFPreferences（极少走到）
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
}

// 启停系统级定位模拟
static void _applySimulation(void) {
    if (s_enabled && s_hasCoord) {
        // 开启模拟
        if (!s_simMgr) {
            Class cls = NSClassFromString(@"CLSimulationManager");
            if (!cls) {
                NSLog(@"[Onyx] CLSimulationManager class not found");
                return;
            }
            s_simMgr = [[cls alloc] init];
        }
        if (!s_simMgr) return;

        CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
        if (s_simulating) {
            // 已经在模拟中，直接 append 新坐标（更新位置）
            [s_simMgr appendSimulatedLocation:loc];
            NSLog(@"[Onyx] simulation updated -> %.6f,%.6f", s_lat, s_lng);
        } else {
            [s_simMgr appendSimulatedLocation:loc];
            [s_simMgr startLocationSimulation];
            s_simulating = YES;
            NSLog(@"[Onyx] simulation started -> %.6f,%.6f", s_lat, s_lng);
        }
    } else {
        // 关闭模拟，恢复真实位置
        if (s_simulating && s_simMgr) {
            [s_simMgr stopLocationSimulation];
            s_simulating = NO;
            NSLog(@"[Onyx] simulation stopped, restored real location");
        }
    }
}

// Darwin 通知回调：App 改了配置
static void onChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    _readPrefs();
    _applySimulation();
    NSLog(@"[Onyx] prefs changed: enabled=%d hasCoord=%d lat=%.6f lng=%.6f",
          s_enabled, s_hasCoord, s_lat, s_lng);
}

%ctor {
    _readPrefs();
    // 监听配置变化
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        onChanged, (CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    // 启动时按当前配置立即生效
    _applySimulation();
    // 瓦片代拉代理（SpringBoard 是 platformized 可联网进程）
    [[OnyxTileProxy shared] startObserving];
    NSLog(@"[Onyx] loaded (SpringBoard) enabled=%d hasCoord=%d simulating=%d",
          s_enabled, s_hasCoord, s_simulating);
}
