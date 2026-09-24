// Onyx Tweak — 极简版：只注入 SpringBoard
// 定位模拟：CLSimulationManager 系统级（跟 LocSim 同款），钉钉检测不到
// 瓦片代拉：SpringBoard 进程内启动（platformized 可联网）
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import "OnyxTileProxy.h"

static NSString *const kDomain = @"com.yzdmm.onyx";

// CLSimulationManager 私有类声明（SpringBoard 进程内可访问）
@interface CLSimulationManager : NSObject
+ (id)sharedSimulationManager;
- (void)startSimulationWithLocation:(CLLocation *)location;
- (void)stopSimulation;
- (void)updateLocation:(CLLocation *)location;
- (BOOL)isSimulationActive;
@end

static double s_lat = 0, s_lng = 0;
static BOOL s_enabled = NO;
static BOOL s_simulating = NO;

// 读配置：Tweak 同目录优先（dylib 能加载就能读），再回退 Preferences
static NSDictionary *_loadPrefs(void) {
    NSArray *paths = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) return d;
    }
    return nil;
}

// 应用配置：开启/停止系统级模拟
static void _applyPrefs(void) {
    NSDictionary *prefs = _loadPrefs();
    if (!prefs) return;

    NSNumber *en = prefs[@"Enabled"];
    NSNumber *lat = prefs[@"Latitude"];
    NSNumber *lng = prefs[@"Longitude"];

    s_enabled = en.boolValue;
    s_lat = lat.doubleValue;
    s_lng = lng.doubleValue;
    BOOL hasCoord = (lat != nil && lng != nil && fabs(s_lat) > 0.0001);

    CLSimulationManager *sim = objc_getClass("CLSimulationManager") ?
        [objc_getClass("CLSimulationManager") sharedSimulationManager] : nil;

    if (!sim) {
        NSLog(@"[Onyx] CLSimulationManager not available");
        return;
    }

    if (s_enabled && hasCoord) {
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
        if (s_simulating) {
            [sim updateLocation:loc];
        } else {
            [sim startSimulationWithLocation:loc];
            s_simulating = YES;
        }
        NSLog(@"[Onyx] simulation active: %.5f, %.5f", s_lat, s_lng);
    } else if (s_simulating) {
        [sim stopSimulation];
        s_simulating = NO;
        NSLog(@"[Onyx] simulation stopped");
    }
}

// Darwin 通知回调：配置变化时重新应用
static void _prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    _applyPrefs();
}

// 卸载时停止模拟
static void _stopSimulation(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    CLSimulationManager *sim = objc_getClass("CLSimulationManager") ?
        [objc_getClass("CLSimulationManager") sharedSimulationManager] : nil;
    if (sim && s_simulating) {
        [sim stopSimulation];
        s_simulating = NO;
        s_enabled = NO;
        NSLog(@"[Onyx] simulation stopped (uninstall)");
    }
}

%ctor {
    @autoreleasepool {
        // 只在 SpringBoard 里干活
        NSString *procName = [[NSProcessInfo processInfo] processName];
        BOOL isSpringBoard = [procName isEqualToString:@"SpringBoard"];

        if (isSpringBoard) {
            // 1. 定位模拟：系统级 CLSimulationManager
            _applyPrefs();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, _prefsChanged, CFSTR("com.yzdmm.onyx/changed"), NULL,
                kCFNotificationDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, _stopSimulation, CFSTR("com.yzdmm.onyx/stop"), NULL,
                kCFNotificationDeliverImmediately);

            // 2. 瓦片代拉：SpringBoard 可联网，代 OnyxApp 下载地图瓦片
            [[OnyxTileProxy shared] startObserving];

            NSLog(@"[Onyx] loaded in SpringBoard, simulating=%d", s_simulating);
        }
    }
}
