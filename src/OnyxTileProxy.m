// Onyx Tile Proxy — 由注入进程(SpringBoard, platformized, 可联网)代拉瓦片，
// 落盘到共享目录供 OnyxApp(无法联网的沙盒 App)读取。
// OnyxApp -> Darwin通知 tilereq + 请求plist -> 本代理下载 -> 写共享缓存 -> Darwin通知 tileok
//
// 数据约定:
//   请求:  /var/mobile/Library/Preferences/com.yzdmm.onyx.tilereq.plist
//          { "urls": ["http://..."], "token": "uuid" }
//   缓存:  /var/mobile/Library/OnyxTileCache/<sha1(url)>
//   结果:  在 url 前加 "ok:" 或 "err:" 前缀写回同一个 tilereq plist,
//          然后 post "com.yzdmm.onyx/tileok"
#import <Foundation/Foundation.h>
#import <string.h>
#import <sys/stat.h>
#import <stdlib.h>

@interface OnyxTileProxy : NSObject
+ (instancetype)shared;
- (void)startObserving;
@end

@implementation OnyxTileProxy {
    dispatch_queue_t _queue;
    BOOL _processing;
}

+ (instancetype)shared {
    static OnyxTileProxy *i;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [OnyxTileProxy new]; });
    return i;
}

+ (NSString *)_sha1:(NSString *)s {
    const char *cstr = [s UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH*2];
    for (int i=0;i<CC_SHA1_DIGEST_LENGTH;i++) [out appendFormat:@"%02x", digest[i]];
    return out;
}

static NSString *CacheDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/OnyxTileCache";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.yzdmm.onyx.tileproxy", DISPATCH_QUEUE_SERIAL);
        _processing = NO;
    }
    return self;
}

// 收到 OnyxApp 的瓦片请求
- (void)_onTileRequest {
    dispatch_async(_queue, ^{
        if (_processing) return; // 一首处理完再来
        _processing = YES;
        NSMutableDictionary *req = [NSMutableDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.yzdmm.onyx.tilereq.plist"];
        NSArray *urls = req[@"urls"];
        NSString *token = req[@"token"];
        if (![urls isKindOfClass:[NSArray class]] || urls.count == 0) {
            _processing = NO;
            return;
        }
        NSMutableArray *results = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURLSession *session = [NSURLSession sharedSession];
        for (NSString *u in urls) {
            NSString *u2 = [u hasPrefix:@"ok:"] || [u hasPrefix:@"err:"] ? [u substringFromIndex:4] : u;
            NSString *cachePath = [CacheDir() stringByAppendingPathComponent:[[self class] _sha1:u2]];
            if ([fm fileExistsAtPath:cachePath]) {
                [results addObject:[@"ok:" stringByAppendingString:u]];
                continue;
            }
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL ok = NO;
            NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:u2] timeoutInterval:20];
            NSURLSessionDataTask *t = [session dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e){
                NSHTTPURLResponse *h = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)resp : nil;
                if (!e && d.length > 0 && h.statusCode < 400) {
                    [d writeToFile:cachePath atomically:YES];
                    ok = YES;
                }
                dispatch_semaphore_signal(sem);
            }];
            [t resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30ull*NSEC_PER_SEC));
            [results addObject:[NSString stringWithFormat:@"%@%@", ok?@"ok:":@"err:", u]];
        }
        // 写回结果
        [req setObject:results forKey:@"results"];
        [req setObject:token ? token : @"" forKey:@"token"];
        [req writeToFile:@"/var/mobile/Library/Preferences/com.yzdmm.onyx.tilereq.plist" atomically:YES];
        // 通知 OnyxApp 结果就绪
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.yzdmm.onyx/tileok"), NULL, NULL, YES);
        _processing = NO;
    });
}

- (void)startObserving {
    // 注意：observer 参数必须传 self，否则回调里的 context(o) 为 nil，请求永远不触发
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        ^(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u){
            OnyxTileProxy *p = (__bridge OnyxTileProxy *)o;
            [p _onTileRequest];
        },
        CFSTR("com.yzdmm.onyx/tilereq"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
@end