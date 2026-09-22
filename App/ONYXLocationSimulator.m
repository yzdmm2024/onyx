#import "ONYXLocationSimulator.h"
#import <CoreLocation/CoreLocation.h>

@interface ONYXLocationSimulator ()
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

- (BOOL)startSimulationWithLatitude:(double)latitude longitude:(double)longitude {
    Class cls = NSClassFromString(@"CLSimulationManager");
    if (!cls) {
        self.lastError = @"CLSimulationManager 不存在（iOS 版本不支持或 entitlement 未生效）";
        NSLog(@"[OnyxSim] CLSimulationManager class not found");
        return NO;
    }

    id mgr = [[cls alloc] init];
    if (!mgr) {
        self.lastError = @"CLSimulationManager 初始化失败";
        NSLog(@"[OnyxSim] CLSimulationManager init failed");
        return NO;
    }

    NSLog(@"[OnyxSim] starting simulation -> %.6f, %.6f", latitude, longitude);

    // 配置行为（参考 locsim/LSAction 用法）
    // 0 = pass through: locations delivered immediately without filtering
    // 1 = consider other factors
    [self _callSelector:@selector(setLocationDeliveryBehavior:) onObject:mgr withUInteger:0];
    // 1 = repeat last location indefinitely
    [self _callSelector:@selector(setLocationRepeatBehavior:) onObject:mgr withUInteger:1];

    // 停止并清空旧位置
    [self _callVoidSelector:@selector(stopLocationSimulation) onObject:mgr];
    [self _callVoidSelector:@selector(clearSimulatedLocations) onObject:mgr];

    // 追加目标位置
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
    [self _callSelector:@selector(appendSimulatedLocation:) onObject:mgr withLocation:loc];

    // 启动模拟
    [self _callVoidSelector:@selector(startLocationSimulation) onObject:mgr];
    [self _callVoidSelector:@selector(flush) onObject:mgr];

    self.simulating = YES;
    self.lastError = nil;
    NSLog(@"[OnyxSim] simulation started");
    return YES;
}

- (void)stopSimulation {
    Class cls = NSClassFromString(@"CLSimulationManager");
    if (!cls) return;
    id mgr = [[cls alloc] init];
    if (!mgr) return;

    NSLog(@"[OnyxSim] stopping simulation");
    [self _callVoidSelector:@selector(stopLocationSimulation) onObject:mgr];
    [self _callVoidSelector:@selector(clearSimulatedLocations) onObject:mgr];
    [self _callVoidSelector:@selector(flush) onObject:mgr];
    self.simulating = NO;
}

@end