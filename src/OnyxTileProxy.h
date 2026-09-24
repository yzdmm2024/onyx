#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

@interface OnyxTileProxy : NSObject
+ (instancetype)shared;
- (void)startObserving;
@end