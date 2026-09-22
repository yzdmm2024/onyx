#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ONYXLocationSimulator : NSObject

+ (instancetype)sharedSimulator;

// 启动系统级定位模拟（注入 locationd，对所有 App 生效）
- (BOOL)startSimulationWithLatitude:(double)latitude longitude:(double)longitude;

// 停止系统级定位模拟
- (void)stopSimulation;

@property (nonatomic, readonly, assign, getter=isSimulating) BOOL simulating;
@property (nonatomic, readonly, copy) NSString *lastError;

@end

NS_ASSUME_NONNULL_END