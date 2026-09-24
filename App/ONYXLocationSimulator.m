#import "ONYXLocationSimulator.h"
#import <CoreLocation/CoreLocation.h>

@interface ONYXLocationSimulator () {
    id _manager;          // 复用同一个 CLSimulationManager 实例
    SEL _selSetLocation;  // setSimulatedLocation: / appendSimulatedLocation:
    SEL _selStart;        // startLocationSimulation / startSimulation
    SEL _selStop;         // stopLocationSimulation
    SEL _selClear;        // clearSimulatedLocations
    SEL _selFlush;        // flush / flushSimulatedLocations
}
@property (nonatomic, assign, getter=isSimulating) BOOL simulating;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation ONYXLocationSimulator

+ (instancetype)sharedSimulator {
    static ONYXLocationSimulator *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[self alloc] init];
    });
    return inst;
}

#pragma mark - low-level invocations

- (void)_callSelector:(SEL)sel onObject:(id)obj withUInteger:(NSUInteger)value {
    if (!obj || sel == NULL) return;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:obj];
    [inv setSelector:sel];
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}

- (void)_callSelector:(SEL)sel onObject:(id)obj withLocation:(CLLocation *)loc {
    if (!obj || sel == NULL) return;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:obj];
    [inv setSelector:sel];
    [inv setArgument:&loc atIndex:2];
    [inv invoke];
}

- (void)_callVoidSelector:(SEL)sel onObject:(id)obj {
    if (!obj || sel == NULL) return;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:obj];
    [inv setSelector:sel];
    [inv invoke];
}

#pragma mark - manager lifecycle

- (BOOL)_ensureManager {
    if (_manager) return YES;
    Class cls = NSClassFromString(@"CLSimulationManager");
    if (!cls) {
        self.lastError = @"CLSimulationManager 不存在（iOS 版本不支持或 entitlement 未生效）";
        NSLog(@"[OnyxSim] CLSimulationManager class not found");
        return NO;
    }
    _manager = [[cls alloc] init];
    if (!_manager) {
        self.lastError = @"CLSimulationManager 初始化失败";
        NSLog(@"[OnyxSim] CLSimulationManager init failed");
        return NO;
    }
    // 探测实际可用的 selector（不同 iOS 版本有差异）
    [self _probeSelectors];
    return YES;
}

- (void)_probeSelectors {
    if (!_manager) return;
    if (!_selSetLocation) {
        SEL cands[] = {
            @selector(setSimulatedLocation:),
            @selector(appendSimulatedLocation:),
            @selector(setLocation:)
        };
        for (NSUInteger i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
            if ([_manager respondsToSelector:cands[i]]) { _selSetLocation = cands[i]; break; }
        }
    }
    if (!_selStart) {
        SEL cands[] = { @selector(startLocationSimulation), @selector(startSimulation) };
        for (NSUInteger i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
            if ([_manager respondsToSelector:cands[i]]) { _selStart = cands[i]; break; }
        }
    }
    if (!_selStop) {
        SEL cands[] = { @selector(stopLocationSimulation), @selector(stopSimulation) };
        for (NSUInteger i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
            if ([_manager respondsToSelector:cands[i]]) { _selStop = cands[i]; break; }
        }
    }
    if (!_selClear) {
        SEL cands[] = { @selector(clearSimulatedLocations), @selector(clearLocations) };
        for (NSUInteger i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
            if ([_manager respondsToSelector:cands[i]]) { _selClear = cands[i]; break; }
        }
    }
    if (!_selFlush) {
        SEL cands[] = { @selector(flush), @selector(flushSimulatedLocations) };
        for (NSUInteger i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
            if ([_manager respondsToSelector:cands[i]]) { _selFlush = cands[i]; break; }
        }
    }
    NSLog(@"[OnyxSim] selectors: set=%@ start=%@ stop=%@ clear=%@ flush=%@",
          NSStringFromSelector(_selSetLocation) ?: @"(none)",
          NSStringFromSelector(_selStart) ?: @"(none)",
          NSStringFromSelector(_selStop) ?: @"(none)",
          NSStringFromSelector(_selClear) ?: @"(none)",
          NSStringFromSelector(_selFlush) ?: @"(none)");
}

- (void)_postTimezoneUpdate {
    // 参考 locsim：坐标变化后触发系统自动时区更新，让 locationd 重新分发位置
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("AutomaticTimeZoneUpdateNeeded"), NULL, NULL, YES);
}

#pragma mark - public

- (BOOL)startSimulationWithLatitude:(double)latitude longitude:(double)longitude {
    if (![self _ensureManager]) return NO;
    if (!_selSetLocation || !_selStart) {
        self.lastError = @"CLSimulationManager 缺少 set/start selector";
        NSLog(@"[OnyxSim] missing set/start selector");
        return NO;
    }

    NSLog(@"[OnyxSim] starting simulation -> %.6f, %.6f", latitude, longitude);

    // 0 = pass through
    [self _callSelector:@selector(setLocationDeliveryBehavior:) onObject:_manager withUInteger:0];
    // 1 = repeat last location indefinitely（静态单点保持）
    [self _callSelector:@selector(setLocationRepeatBehavior:) onObject:_manager withUInteger:1];

    // 先停止/清空旧会话，避免位置叠加
    [self _callVoidSelector:_selStop onObject:_manager];
    [self _callVoidSelector:_selClear onObject:_manager];

    // 注入目标位置
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
    [self _callSelector:_selSetLocation onObject:_manager withLocation:loc];

    // 启动并 flush
    [self _callVoidSelector:_selStart onObject:_manager];
    [self _callVoidSelector:_selFlush onObject:_manager];
    [self _postTimezoneUpdate];

    self.simulating = YES;
    self.lastError = nil;
    NSLog(@"[OnyxSim] simulation started");
    return YES;
}

- (void)stopSimulation {
    if (![self _ensureManager]) return;
    NSLog(@"[OnyxSim] stopping simulation");

    // 把 repeat behavior 改成 0=unavailable 后再停止，避免 daemon 继续复用最后坐标
    [self _callSelector:@selector(setLocationRepeatBehavior:) onObject:_manager withUInteger:0];
    [self _callVoidSelector:_selStop onObject:_manager];
    [self _callVoidSelector:_selClear onObject:_manager];
    [self _callVoidSelector:_selFlush onObject:_manager];
    [self _postTimezoneUpdate];

    self.simulating = NO;
    NSLog(@"[OnyxSim] simulation stopped");
}

@end
