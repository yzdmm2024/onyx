// Onyx Tweak — 极简版：只注入 SpringBoard
// 定位模拟：CLSimulationManager 系统级（跟 LocSim 同款），钉钉检测不到
// 瓦片代拉：SpringBoard 进程内启动（platformized 可联网）
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
static BOOL s_simulating = NO;
static CLSimulationManager *s_simMgr = nil;

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

// 启动模拟
static void _startSimulation(void) {
    if (s_simulating) return;
    Class simClass = objc_getClass("CLSimulationManager");
    if (!simClass) {
        NSLog(@"[Onyx] CLSimulationManager class not found");
        return;
    }
    s_simMgr = [[simClass alloc] init];
    if (!s_simMgr) {
        NSLog(@"[Onyx] failed to init CLSimulationManager");
        return;
    }
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:s_lat longitude:s_lng];
    [s_simMgr appendSimulatedLocation:loc];
    [s_simMgr startLocationSimulation];
    s_simulating = YES;
    NSLog(@"[Onyx] simulation started: %.5f, %.5f", s_lat, s_lng);
}

// 停止模拟
static void _stopSimulation(void) {
    if (!s_simulating) return;
    [s_simMgr stopLocationSimulation];
    s_simMgr = nil;
    s_simulating = NO;
    NSLog(@"[Onyx] simulation stopped");
}

// 应用配置
static void _applyPrefs(void) {
    NSDictionary *prefs = _loadPrefs();
    if (!prefs) {
        NSLog(@"[Onyx] no prefs found");
        return;
    }

    NSNumber *en = prefs[@"enabled"];
    NSNumber *lat = prefs[@"Latitude"];
    NSNumber *lng = prefs[@"Longitude"];

    s_enabled = en.boolValue;
    s_lat = lat.doubleValue;
    s_lng = lng.doubleValue;
    BOOL hasCoord = (lat != nil && lng != nil && fabs(s_lat) > 0.0001);

    if (s_enabled && hasCoord) {
        if (s_simulating) {
            // 已经在模拟，更新位置（重新来一次）
            _stopSimulation();
        }
        _startSimulation();
    } else if (s_simulating) {
        _stopSimulation();
    }
}

// Darwin 通知回调
static void _prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    _applyPrefs();
}

static void _stopSimCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                              const void *object, CFDictionaryRef userInfo) {
    _stopSimulation();
    s_enabled = NO;
}

%ctor {
    @autoreleasepool {
        NSString *procName = [[NSProcessInfo processInfo] processName];
        BOOL isSpringBoard = [procName isEqualToString:@"SpringBoard"];

        if (isSpringBoard) {
            // 1. 定位模拟：系统级 CLSimulationManager
            _applyPrefs();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, _prefsChanged, CFSTR("com.yzdmm.onyx/changed"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, _stopSimCallback, CFSTR("com.yzdmm.onyx/stop"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            // 2. 瓦片代拉：SpringBoard 可联网，代 OnyxApp 下载地图瓦片
            [[OnyxTileProxy shared] startObserving];

            NSLog(@"[Onyx] loaded in SpringBoard, simulating=%d", s_simulating);
        }
    }
}
