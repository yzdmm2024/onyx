// Onyx Tile Proxy — 由独立 root daemon(OnyxNetDaemon, platform-application 可联网)代拉瓦片，
// 落盘到共享目录供 OnyxApp(无法联网的沙盒 mobile App)读取。
//
// 协议：
//   OnyxApp 写一批请求到 /var/mobile/Library/OnyxTileReq/<uuid>.plist
//       { "urls": ["http://..."] }
//   然后发 Darwin 通知 "com.yzdmm.onyx/tilereq"
//
//   daemon 扫描请求目录，收集所有 pending 请求，去重后并行下载（6并发）
//   下载完成后每完成一批就发 "com.yzdmm.onyx/tileok" 通知 App 来读缓存
//   缓存路径：/var/mobile/Library/OnyxTileCache/<sha1(url)>
//
//   App 收到 tileok 后扫自己的 inflight 瓦片，能从缓存读到就显示
//   （不再依赖写回 results，直接以共享缓存文件为准，避免 plist 并发竞争）
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <string.h>
#import <sys/stat.h>
#import <stdlib.h>

@interface OnyxTileProxy : NSObject
+ (instancetype)shared;
- (void)startObserving;
@end

static void OnyxTileProxyNotification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef userInfo);

static const NSInteger kMaxConcurrent = 6;   // 最大并发下载数
static const NSTimeInterval kTileTimeout = 15.0; // 单张瓦片超时

@implementation OnyxTileProxy {
    dispatch_queue_t _queue;          // 串行调度队列
    NSMutableSet<NSString *> *_downloading; // 正在下载的 url（去重）
    NSURLSession *_session;
    BOOL _scheduled;                  // 是否已经安排了一次 drain
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

static NSString *ReqDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/OnyxTileReq";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.yzdmm.onyx.tileproxy", DISPATCH_QUEUE_SERIAL);
        _downloading = [NSMutableSet set];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.HTTPMaximumConnectionsPerHost = kMaxConcurrent;
        cfg.timeoutIntervalForRequest = kTileTimeout;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];
        _scheduled = NO;
    }
    return self;
}

// 收到 OnyxApp 的瓦片请求通知：安排一次 drain（节流）
- (void)_onTileRequest {
    dispatch_async(_queue, ^{
        if (_scheduled) return;  // 已有 drain 安排，等它跑完
        _scheduled = YES;
        [self _drainRequests];
    });
}

// 扫描请求目录，收集所有 url，去重后并行下载
- (void)_drainRequests {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *allUrls = [NSMutableSet set];
    
    // 扫所有请求 plist
    NSArray *files = [fm contentsOfDirectoryAtPath:ReqDir() error:NULL];
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"plist"]) continue;
        NSString *p = [ReqDir() stringByAppendingPathComponent:f];
        NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:p];
        NSArray *urls = req[@"urls"];
        if ([urls isKindOfClass:[NSArray class]]) {
            for (NSString *u in urls) {
                if ([u isKindOfClass:[NSString class]] && u.length > 0) {
                    [allUrls addObject:u];
                }
            }
        }
        // 读完立即删掉请求文件（不管成功失败，避免堆积）
        [fm removeItemAtPath:p error:NULL];
    }
    
    if (allUrls.count == 0) {
        _scheduled = NO;
        return;
    }
    
    // 过滤掉已经在下载的 + 已经有缓存的
    NSMutableArray<NSString *> *toDownload = [NSMutableArray array];
    for (NSString *u in allUrls) {
        @synchronized (_downloading) {
            if ([_downloading containsObject:u]) continue;
        }
        NSString *cachePath = [CacheDir() stringByAppendingPathComponent:[[self class] _sha1:u]];
        if ([fm fileExistsAtPath:cachePath]) continue;
        [toDownload addObject:u];
        @synchronized (_downloading) {
            [_downloading addObject:u];
        }
    }
    
    if (toDownload.count == 0) {
        // 全部已有缓存，仍通知 App 去读
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.yzdmm.onyx/tileok"), NULL, NULL, YES);
        _scheduled = NO;
        return;
    }
    
    NSLog(@"[OnyxTileProxy] downloading %lu tiles (concurrent=%ld)",
          (unsigned long)toDownload.count, (long)kMaxConcurrent);
    
    // 并行下载：用 dispatch_semaphore 控制并发数
    dispatch_semaphore_t concurrencyLimiter = dispatch_semaphore_create(kMaxConcurrent);
    dispatch_group_t group = dispatch_group_create();
    
    for (NSString *url in toDownload) {
        dispatch_semaphore_wait(concurrencyLimiter, DISPATCH_TIME_FOREVER);
        dispatch_group_enter(group);
        
        NSString *cachePath = [CacheDir() stringByAppendingPathComponent:[[self class] _sha1:url]];
        NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                          timeoutInterval:kTileTimeout];
        
        NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e){
            NSHTTPURLResponse *h = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)resp : nil;
            BOOL ok = (!e && d.length > 0 && h.statusCode < 400);
            if (ok) {
                [d writeToFile:cachePath atomically:YES];
            }
            @synchronized (self->_downloading) {
                [self->_downloading removeObject:url];
            }
            dispatch_semaphore_signal(concurrencyLimiter);
            dispatch_group_leave(group);
        }];
        [task resume];
    }
    
    // 全部完成后通知 App 并清理调度标记
    dispatch_group_notify(group, _queue, ^{
        // 通知 App 来读缓存（每完成一整批通知一次，App 侧轮询补漏）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.yzdmm.onyx/tileok"), NULL, NULL, YES);
        
        _scheduled = NO;
        
        // 再查一次：如果期间又有新请求进来，继续 drain
        NSArray *newFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ReqDir() error:NULL];
        if (newFiles.count > 0) {
            _scheduled = YES;
            [self _drainRequests];
        }
    });
}

- (void)startObserving {
    // CFNotificationCenterAddObserver 只接受 C 函数指针(不支持 block)
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        OnyxTileProxyNotification,
        CFSTR("com.yzdmm.onyx/tilereq"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
@end

// Darwin 通知回调：OnyxApp 提交了新的瓦片代拉请求
static void OnyxTileProxyNotification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    OnyxTileProxy *proxy = (__bridge OnyxTileProxy *)observer;
    [proxy _onTileRequest];
}
