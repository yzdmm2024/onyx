#import "ONYXAMapView.h"
#import "ONYXCoordTransform.h"
#import <math.h>
#import <CommonCrypto/CommonDigest.h>

// 自绘瓦片地图（无 MKMapView）。
// 布局：self 上先放 _tileLayer（瓦片画布），再放标记 _pin，最后放常驻坐标横幅 _coordLabel。
// 坐标：对外统一 WGS-84；瓦片投影随源而定——高德(GCJ-02) / OSM(Web Mercator WGS-84)。
// 0.3.6 修复：越狱 platform-app 下 NSURLSession 自定义 configuration 经常无法出站，
// 改用 [NSURLSession sharedSession]，并支持 HTTPS->HTTP 自动降级。
// 0.3.8 新增：瓦片多源自动回退（高德 webrd -> 高德 webst -> OSM），
// 直连连通性各环境不同，失败达到阈值自动切源，不开 VPN 也能出图。

static const CGFloat kTile = 256.0;      // 每张瓦片边长(px)
static const NSInteger kMinZoom = 3;
static const NSInteger kMaxZoom = 18;

typedef NS_ENUM(NSInteger, OnyxTileProj) {
    OnyxTileProjGCJ = 0,   // 高德：经纬度带偏移，需 GCJ-02
    OnyxTileProjWGS = 1    // OSM：标准 Web Mercator (WGS-84)
};

static const NSInteger kSourceCount = 3;   // 0=高德webrd, 1=高德webst, 2=OSM
static const NSInteger kFailThreshold = 3; // 连续失败张数达到此值才切源，避免抖动

#pragma mark - 墨卡托工具（输入即目标系经纬度）

static double onyx_worldSize(NSInteger zoom) { return kTile * pow(2.0, zoom); }

static double onyx_clampLat(double lat) {
    if (lat > 85.0511) return 85.0511;
    if (lat < -85.0511) return -85.0511;
    return lat;
}

// 经纬度 -> 世界像素坐标（标准 Web Mercator，zoom 影响精度）
static CGPoint onyx_lonlatToWorld(CLLocationCoordinate2D c, NSInteger zoom) {
    double ws = onyx_worldSize(zoom);
    double lat = onyx_clampLat(c.latitude);
    double x = (c.longitude + 180.0) / 360.0 * ws;
    double latRad = lat * M_PI / 180.0;
    double y = (1.0 - asinh(tan(latRad)) / M_PI) / 2.0 * ws;
    return CGPointMake(x, y);
}

// 世界像素坐标 -> 经纬度（反解）
static CLLocationCoordinate2D onyx_worldToLonlat(CGPoint p, NSInteger zoom) {
    double ws = onyx_worldSize(zoom);
    double lon = p.x / ws * 360.0 - 180.0;
    double n = M_PI * (1.0 - 2.0 * p.y / ws);
    double lat = atan(sinh(n)) * 180.0 / M_PI;
    return CLLocationCoordinate2DMake(lat, lon);
}

// 程序化绘制一个红色定位图钉
static UIImage *onyx_pinImage(void) {
    CGFloat w = 30, h = 38;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor systemRedColor] setFill];
    // 头部圆
    CGContextAddEllipseInRect(ctx, CGRectMake(15 - 13, 14 - 13, 26, 26));
    CGContextFillPath(ctx);
    // 尖端三角
    CGContextMoveToPoint(ctx, 5, 22);
    CGContextAddLineToPoint(ctx, 25, 22);
    CGContextAddLineToPoint(ctx, 15, 37);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    // 中心白点
    [[UIColor whiteColor] setFill];
    CGContextAddEllipseInRect(ctx, CGRectMake(15 - 4.5, 14 - 4.5, 9, 9));
    CGContextFillPath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@interface ONYXAMapView () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *tileLayer;                 // 瓦片画布
@property (nonatomic, strong) UIImageView *offlineBaseView;      // 离线程序化底图
@property (nonatomic, strong) UIView *offlineCrossView;          // 离线定位十字线
@property (nonatomic, strong) UIImageView *pin;                  // 标记
@property (nonatomic, strong) UILabel *coordLabel;               // 常驻坐标横幅
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *tileViews; // key "z-x-y"
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imgCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *inflight;
@property (nonatomic, strong) NSURLSession *session;

@property (nonatomic, strong) NSMutableSet<NSString *> *proxyInFlight;  // 已提交代拉的瓦片 key
@property (nonatomic, assign) NSTimeInterval proxyLastRequestAt;        // 批量提交节流
@property (nonatomic, assign) BOOL hasProxyWaitStarted;                 // 代拉结果轮询已开始(30s超时计时)

@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, assign) CGPoint origin;                    // 世界像素坐标(自左上角)，坐标系随源
@property (nonatomic, assign) BOOL originValid;
@property (nonatomic, assign) CLLocationCoordinate2D centerWGS;  // 当前显示中心（对外 WGS-84，不随源改变）
@property (nonatomic, assign) BOOL showMarker;
@property (nonatomic, assign) BOOL hasCenter;
@property (nonatomic, assign) NSInteger srcIndex;                // 当前源 0..kSourceCount-1
@property (nonatomic, assign) BOOL wgsTiles;                     // 当前源是否 WGS 投影(OSM)
@property (nonatomic, assign) NSInteger tileOkCount;
@property (nonatomic, assign) NSUInteger tileFailCount;
@property (nonatomic, assign) NSUInteger consecFail;             // 连续失败张数
@property (nonatomic, assign) BOOL reportedFail;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) BOOL offlineMode;                         // 在线程为离线底图模式
@property (nonatomic, assign) BOOL offlineRefreshed;

@property (nonatomic, assign) CGPoint panStartOrigin;
@property (nonatomic, assign) CGFloat pinchStartZoom;
@property (nonatomic, assign) CGFloat selfScale;
@end

// Darwin 通知回调：daemon 完成瓦片代拉后通知 App 去读共享缓存
static void ONYXAMapViewTileOK(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo);

@implementation ONYXAMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self setup];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setup];
    return self;
}

- (void)setup {
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor colorWithRed:0.90 green:0.92 blue:0.95 alpha:1.0];

    _zoom = 14;
    _origin = CGPointZero;
    _originValid = NO;
    _showMarker = YES;
    _hasCenter = NO;
    _srcIndex = 0;
    _wgsTiles = NO;
    _tileOkCount = 0;
    _tileFailCount = 0;
    _consecFail = 0;
    _reportedFail = NO;
    _offlineMode = NO;
    _offlineRefreshed = NO;

    _tileViews = [NSMutableDictionary dictionary];
    _imgCache = [[NSCache alloc] init];
    _inflight = [NSMutableSet set];
    _proxyInFlight = [NSMutableSet set];
    _proxyLastRequestAt = 0;
    // 坑：越狱 platform-app/container-required=false 的 App，使用自定义
    // NSURLSessionConfiguration 时可能无法建立出站连接（系统代理/ATS 被绕过）。
    // [NSURLSession sharedSession] 走系统默认通道，反而更容易成功。
    _session = [NSURLSession sharedSession];

    _tileLayer = [[UIView alloc] initWithFrame:self.bounds];
    _tileLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tileLayer.clipsToBounds = YES;
    [self addSubview:_tileLayer];

    // 离线程序化底图：仅离线模式可见，网络极端不可用时绘制经纬网格兜底，永不空白
    _offlineBaseView = [[UIImageView alloc] initWithFrame:self.bounds];
    _offlineBaseView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _offlineBaseView.contentMode = UIViewContentModeScaleToFill;
    _offlineBaseView.hidden = YES;
    [self addSubview:_offlineBaseView];

    _offlineCrossView = [[UIView alloc] initWithFrame:CGRectZero];
    _offlineCrossView.hidden = YES;
    _offlineCrossView.userInteractionEnabled = NO;
    [self addSubview:_offlineCrossView];

    _pin = [[UIImageView alloc] initWithImage:onyx_pinImage()];
    _pin.hidden = YES;
    [self addSubview:_pin];

    _coordLabel = [[UILabel alloc] init];
    _coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _coordLabel.textColor = [UIColor labelColor];
    _coordLabel.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.92];
    _coordLabel.layer.cornerRadius = 14;
    _coordLabel.layer.masksToBounds = YES;
    _coordLabel.layer.borderWidth = 0.3;
    _coordLabel.layer.borderColor = [UIColor separatorColor].CGColor;
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    _coordLabel.text = @"定位模拟地图";
    [self addSubview:_coordLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_coordLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_coordLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_coordLabel.leftAnchor constraintGreaterThanOrEqualToAnchor:self.leftAnchor constant:8],
        [_coordLabel.rightAnchor constraintLessThanOrEqualToAnchor:self.rightAnchor constant:-8],
        [_coordLabel.heightAnchor constraintEqualToConstant:26]
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.delegate = self;
    [self addGestureRecognizer:pinch];

    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    dbl.delegate = self;
    [self addGestureRecognizer:dbl];

    // 监听代拉瓦片结果（daemon 下载完成后发 Darwin 通知）
    // 注意：CFNotificationCenterAddObserver 只接受 C 函数指针，observer 参数传 self 作为上下文
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        ONYXAMapViewTileOK,
        CFSTR("com.yzdmm.onyx/tileok"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    UILongPressGestureRecognizer *longp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longp.minimumPressDuration = 0.5;
    longp.delegate = self;
    [self addGestureRecognizer:longp];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = self;
    [tap requireGestureRecognizerToFail:dbl]; // 明确单击才选点，双击用于缩放
    [self addGestureRecognizer:tap];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _tileLayer.frame = self.bounds;
    if (!_originValid) {
        CLLocationCoordinate2D def = CLLocationCoordinate2DMake(31.230416, 121.473701); // 上海人民广场 WGS-84
        [self recenterOnWGS:def zoom:_zoom animated:NO];
        _originValid = YES;
    }
    [self updateVisibleTiles];
    [self refreshPin];
    if (_offlineMode) {
        [self drawOfflineBase];
        [self updateOfflineCross];
    }
}

#pragma mark - 源与投影

- (void)applySourceIndex:(NSInteger)idx animated:(BOOL)animated {
    BOOL newWgs = (idx == 2);
    _srcIndex = idx;
    if (_wgsTiles != newWgs) {
        _wgsTiles = newWgs;
        // 投影变化：保持屏幕中心为同一真实地点，重算世界坐标
        CGPoint c = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
        CLLocationCoordinate2D disp = [self displayCenter];
        CGPoint wp = onyx_lonlatToWorld(disp, _zoom);
        _origin = CGPointMake(wp.x - c.x, wp.y - c.y);
    }
    _reportedFail = NO;
    [self resetTiles];
}

// 清空所有瓦片状态并重载（切源/投影时调用）
- (void)resetTiles {
    NSArray *keys = [_tileViews allKeys];
    for (NSString *key in keys) {
        [_tileViews[key] removeFromSuperview];
    }
    [_tileViews removeAllObjects];
    [_imgCache removeAllObjects];
    [_inflight removeAllObjects];
    _consecFail = 0;
    [self updateVisibleTiles];
    [self updateCoordLabel];
}

// 当前源投影下，显示中心的经纬度（真实地点 _centerWGS 映射到当前系）
- (CLLocationCoordinate2D)displayCenter {
    if (_wgsTiles) return _centerWGS;
    return [ONYXCoordTransform gcj02FromWgs84:_centerWGS];
}

// 把当前投影下读到的经纬度转回 WGS-84（对外）
- (CLLocationCoordinate2D)wgsFromDisplay:(CLLocationCoordinate2D)d {
    if (_wgsTiles) return d;
    return [ONYXCoordTransform wgs84FromGcj02:d];
}

- (NSString *)tileURLForX:(int)x y:(int)y z:(NSInteger)zoom https:(BOOL)https {
    NSString *scheme = https ? @"https" : @"http";
    long sub = (x + y + (long)zoom) % 4 + 1;
    switch (_srcIndex) {
        case 1:
            return [NSString stringWithFormat:@"%@://webst0%ld.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x=%d&y=%d&z=%ld",
                    scheme, sub, x, y, (long)zoom];
        case 2:
            // OSM 只支持 https
            return [NSString stringWithFormat:@"https://tile.openstreetmap.org/%ld/%d/%d.png",
                    (long)zoom, x, y];
        case 0:
        default:
            return [NSString stringWithFormat:@"%@://webrd0%ld.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x=%d&y=%d&z=%ld",
                    scheme, sub, x, y, (long)zoom];
    }
}

- (NSString *)sourceName {
    switch (_srcIndex) {
        case 1: return @"高德webst";
        case 2: return @"OSM";
        default: return @"高德webrd";
    }
}

#pragma mark - 手势

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStartOrigin = _origin;
    }
    _origin = CGPointMake(_panStartOrigin.x - t.x, _panStartOrigin.y - t.y);
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        CGPoint c = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
        CLLocationCoordinate2D disp = onyx_worldToLonlat(CGPointMake(_origin.x + c.x, _origin.y + c.y), _zoom);
        _centerWGS = [self wgsFromDisplay:disp];
    }
    [self updateVisibleTiles];
    [self refreshPin];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _pinchStartZoom = _zoom;
            _selfScale = 1.0;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat s = g.scale;
            // 限制单手势内能跨过的 zoom 档位，避免一下跳太远，像照片那样连续缩放
            CGFloat minS = pow(2.0, (double)kMinZoom - (double)_pinchStartZoom);
            CGFloat maxS = pow(2.0, (double)kMaxZoom - (double)_pinchStartZoom);
            s = MAX(minS, MIN(maxS, s));
            _selfScale = s;
            self.transform = CGAffineTransformMakeScale(s, s);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.transform = CGAffineTransformIdentity;
            CGFloat s = _selfScale;
            if (fabs(s - 1.0) > 0.03) {
                CGFloat desired = (double)_pinchStartZoom + log2(s);
                NSInteger newZoom = (NSInteger)lround(desired);
                newZoom = MAX(kMinZoom, MIN(kMaxZoom, newZoom));
                if (newZoom != _zoom) {
                    CGPoint c = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
                    CLLocationCoordinate2D anchor = onyx_worldToLonlat(CGPointMake(_origin.x + c.x, _origin.y + c.y), _zoom);
                    _zoom = newZoom;
                    CGPoint awp = onyx_lonlatToWorld(anchor, _zoom);
                    _origin = CGPointMake(awp.x - c.x, awp.y - c.y);
                    [self updateVisibleTiles];
                    [self refreshPin];
                    if (_offlineMode) [self drawOfflineBase];
                }
            }
            break;
        }
        default: break;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint p = [g locationInView:self];
    CLLocationCoordinate2D disp = onyx_worldToLonlat(CGPointMake(_origin.x + p.x, _origin.y + p.y), _zoom);
    _centerWGS = [self wgsFromDisplay:disp];
    _hasCenter = YES;
    [self refreshPin];
    [self updateCoordLabel];
    if ([self.delegate respondsToSelector:@selector(amapView:didPickCoordinate:)]) {
        [self.delegate amapView:self didPickCoordinate:_centerWGS];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    [self zoomIn];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:self];
    CLLocationCoordinate2D disp = onyx_worldToLonlat(CGPointMake(_origin.x + p.x, _origin.y + p.y), _zoom);
    _centerWGS = [self wgsFromDisplay:disp];
    _hasCenter = YES;
    [self refreshPin];
    [self updateCoordLabel];
    if ([self.delegate respondsToSelector:@selector(amapView:didPickCoordinate:)]) {
        [self.delegate amapView:self didPickCoordinate:_centerWGS];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return NO;
}

#pragma mark - 瓦片渲染

- (void)updateVisibleTiles {
    CGRect b = self.bounds;
    if (b.size.width <= 1 || b.size.height <= 1) return;
    NSInteger z = _zoom;
    int startTx = (int)floor(_origin.x / kTile);
    int startTy = (int)floor(_origin.y / kTile);
    int across = (int)ceil(b.size.width / kTile) + 2;
    int down = (int)ceil(b.size.height / kTile) + 2;

    NSMutableSet *keep = [NSMutableSet set];
    for (int iy = 0; iy < down; iy++) {
        for (int ix = 0; ix < across; ix++) {
            int tx = startTx + ix;
            int ty = startTy + iy;
            NSString *key = [NSString stringWithFormat:@"%ld-%d-%d", (long)z, tx, ty];
            [keep addObject:key];
            CGFloat fx = tx * kTile - _origin.x;
            CGFloat fy = ty * kTile - _origin.y;
            UIImageView *iv = _tileViews[key];
            if (!iv) {
                iv = [[UIImageView alloc] initWithFrame:CGRectMake(fx, fy, kTile, kTile)];
                iv.contentMode = UIViewContentModeScaleToFill;
                _tileViews[key] = iv;
                [_tileLayer addSubview:iv];
            } else {
                iv.frame = CGRectMake(fx, fy, kTile, kTile);
            }
            UIImage *img = [_imgCache objectForKey:key];
            if (img) {
                iv.image = img;
            } else {
                iv.image = nil;
                if (![_inflight containsObject:key]) {
                    [self loadTileForKey:key x:tx y:ty z:z];
                }
            }
        }
    }
    for (NSString *key in [_tileViews allKeys]) {
        if (![keep containsObject:key]) {
            [_tileViews[key] removeFromSuperview];
            [_tileViews removeObjectForKey:key];
        }
    }
}

- (void)loadTileForKey:(NSString *)key x:(int)x y:(int)y z:(NSInteger)z {
    // 高德(0/1)源支持 https 先试、失败降级 http
    [self loadTileForKey:key x:x y:y z:z https:(_srcIndex < 2)];
}

- (void)loadTileForKey:(NSString *)key x:(int)x y:(int)y z:(NSInteger)z https:(BOOL)https {
    [_inflight addObject:key];
    NSString *urlstr = [self tileURLForX:x y:y z:z https:https];

    // 先查共享缓存（注入进程可能已代拉好）
    UIImage *cached = [self _tileFromSharedCache:urlstr];
    if (cached) {
        [_imgCache setObject:cached forKey:key];
        [_inflight removeObject:key];
        _tileOkCount++;
        UIImageView *iv = _tileViews[key];
        if (iv) iv.image = cached;
        if (_offlineMode) [self leaveOfflineMode];
        [self updateCoordLabel];
        return;
    }

    // 不在缓存：交给注入进程代拉（OnyxApp 自身在此环境无法出站联网）
    [self _submitProxyRequests:@[urlstr]];

    // 原直连 NSURLSession 保底：若设备其实能联网（如无越狱沙盒限制的环境）仍可用
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlstr]
                                                       cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                   timeoutInterval:15];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            forHTTPHeaderField:@"User-Agent"];
    NSLog(@"[OnyxTile] direct fetch %@", urlstr);
    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(self) s = wself;
        if (!s) return;
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSLog(@"[OnyxTile] direct resp %@ status=%ld data=%lu err=%@", urlstr, (long)(http.statusCode), (unsigned long)data.length, error);
        if (error || !data.length || (http && http.statusCode >= 400)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![s->_inflight containsObject:key]) return; // 已切源，忽略
                // 直连失败：不立即判失败，交给代拉机制（等 tileok）
                s->_lastError = error;
                // 高德源 https 失败先降级 http（同步给代理请求）
                if (https && s->_srcIndex < 2) {
                    [s loadTileForKey:key x:x y:y z:z https:NO];
                    return;
                }
            });
            return;
        }
        UIImage *img = [UIImage imageWithData:data];
        if (!img) {
            NSLog(@"[OnyxTile] direct not image: %@ bytes=%lu", urlstr, (unsigned long)data.length);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![s->_inflight containsObject:key]) return; // 已切源，忽略旧请求
            [s->_inflight removeObject:key];
            @synchronized (s->_proxyInFlight) { [s->_proxyInFlight removeObject:urlstr]; }
            s->_consecFail = 0;
            [s->_imgCache setObject:img forKey:key];
            s->_tileOkCount++;
            if (s->_offlineMode) [s leaveOfflineMode];
            UIImageView *iv = s->_tileViews[key];
            if (iv) iv.image = img;
            if (s->_tileOkCount == 1) {
                if ([s.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
                    [s.delegate amapView:s didUpdateStatus:[NSString stringWithFormat:@"瓦片已加载(%@)", [s sourceName]]];
                }
            }
            [s updateCoordLabel];
        });
    }];
    [task resume];
}

// ---------- Tweak 代拉瓦片：OnyxApp 无法自联网络，由注入进程帮忙下载 ----------

static NSString *OnyxTileCacheDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/OnyxTileCache";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

static NSString *OnyxTileReqDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/OnyxTileReq";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

static NSString *OnyxTileSHA1(NSString *s) {
    const char *cstr = [s UTF8String];
    unsigned char digest[20];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:40];
    for (int i=0;i<20;i++) [out appendFormat:@"%02x", digest[i]];
    return out;
}

// 共享缓存路径（与注入进程一致：/var/mobile/Library/OnyxTileCache/<sha1(url)>）
- (NSString *)_sharedCachePathForURL:(NSString *)url {
    return [OnyxTileCacheDir() stringByAppendingPathComponent:OnyxTileSHA1(url)];
}

// 从共享缓存读瓦片（已由注入进程代拉下载好）
- (UIImage *)_tileFromSharedCache:(NSString *)url {
    NSString *p = [self _sharedCachePathForURL:url];
    NSData *d = [NSData dataWithContentsOfFile:p];
    return d.length ? [UIImage imageWithData:d] : nil;
}

// 提交代拉请求：把一批瓦片 URL 写成独立请求 plist 放到请求目录，并发 Darwin 通知
// 用独立文件而非单文件，避免滚动时多次请求互相覆盖
- (void)_submitProxyRequests:(NSArray<NSString *> *)urls {
    if (!urls.count) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    _proxyLastRequestAt = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 过滤掉已在 inflight 的
        NSMutableArray *fresh = [NSMutableArray array];
        @synchronized (_proxyInFlight) {
            for (NSString *u in urls) {
                if ([_proxyInFlight containsObject:u]) continue;
                [_proxyInFlight addObject:u];
                [fresh addObject:u];
            }
        }
        if (!fresh.count) return;
        // 写成独立请求文件：uuid.plist，daemon 扫目录去重并并行下载
        NSString *token = [[NSUUID UUID] UUIDString];
        NSString *reqPath = [OnyxTileReqDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.plist", token]];
        NSDictionary *req = @{@"urls": fresh, @"token": token};
        @try {
            [req writeToFile:reqPath atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.yzdmm.onyx/tilereq"), NULL, NULL, YES);
        } @catch (NSException *e) {
            NSLog(@"[OnyxTile] submit proxy request err %@", e);
        }
    });
}

// daemon 完成下载后：重查共享缓存，能读到的瓦片直接显示
// 超时策略：每有新瓦片成功就重置计时；只有 30 秒内一张新瓦片都没拿到才放弃
- (void)handleProxyResult {
    static NSDate *lastProgressAt; // 上次有瓦片成功的时间
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastProgressAt = nil; });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_hasProxyWaitStarted) {
            _hasProxyWaitStarted = YES;
            lastProgressAt = [NSDate date];
        }
        // 遍历当前在等待代拉的 inflight key，尝试读共享缓存
        NSArray *allKeys = [_inflight allObjects];
        NSInteger newHit = 0;
        NSMutableArray *remaining = [NSMutableArray array];
        for (NSString *key in allKeys) {
            int x, y; NSInteger z;
            if (sscanf(key.UTF8String, "%ld-%d-%d", &z, &x, &y) != 3) continue;
            NSString *url = [self tileURLForX:x y:y z:z https:(_srcIndex < 2)];
            UIImage *img = [self _tileFromSharedCache:url];
            if (img) {
                [_imgCache setObject:img forKey:key];
                [_inflight removeObject:key];
                @synchronized (_proxyInFlight) { [_proxyInFlight removeObject:url]; }
                _tileOkCount++;
                newHit++;
                UIImageView *iv = _tileViews[key];
                if (iv) iv.image = img;
                if (_offlineMode) [self leaveOfflineMode];
            } else {
                [remaining addObject:key];
            }
        }
        if (newHit > 0) {
            // 有新瓦片到了，重置进度计时
            lastProgressAt = [NSDate date];
        }
        // 30 秒无任何新进展才判失败（滚动过程中持续有新请求进来时不应超时）
        BOOL stuck = lastProgressAt && -[lastProgressAt timeIntervalSinceNow] > 30.0;
        if (stuck && remaining.count) {
            // 代拉彻底卡住：回到离线网格底图兜底
            _hasProxyWaitStarted = NO;
            lastProgressAt = nil;
            _reportedFail = NO;
            [_inflight removeAllObjects];
            @synchronized (_proxyInFlight) { [_proxyInFlight removeAllObjects]; }
            [self handleTileFail];
            [self updateCoordLabel];
            if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
                [self.delegate amapView:self didUpdateStatus:@"代拉瓦片失败，已切换离线底图"];
            }
            return;
        }
        [self updateCoordLabel];
        // 仍有瓦片没到位，稍后再查（daemon 也会在完成一批时发 tileok 通知）
        if (remaining.count) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self handleProxyResult];
            });
        }
    });
}

- (void)handleTileFail {
    _consecFail++;
    // 已达到最后一个源（OSM）：任何一次失败都立即进离线底图，不再等 3 连（无网时应快速兜底）
    if (_srcIndex >= kSourceCount - 1) {
        if (!_reportedFail) {
            _reportedFail = YES;
            [self enterOfflineMode];
            NSString *msg;
            if (_lastError) {
                msg = [NSString stringWithFormat:@"%@瓦片加载失败 %@(%ld)，已切换离线底图", [self sourceName], _lastError.domain, (long)_lastError.code];
            } else if (_tileOkCount > 0) {
                msg = [NSString stringWithFormat:@"%@部分瓦片加载失败，已切换离线底图", [self sourceName]];
            } else {
                msg = [NSString stringWithFormat:@"缺少网络且瓦片加载失败，已切换离线底图", [self sourceName]];
            }
            if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
                [self.delegate amapView:self didUpdateStatus:msg];
            }
        }
        return;
    }
    if (_consecFail >= kFailThreshold && _srcIndex < kSourceCount - 1) {
        NSInteger next = _srcIndex + 1;
        [self applySourceIndex:next animated:YES];
        if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
            [self.delegate amapView:self didUpdateStatus:[NSString stringWithFormat:@"源切换 → %@", [self sourceName]]];
        }
        return;
    }
}

#pragma mark - 离线程序化底图

// 把世界屏幕坐标(相对 self.bounds)转成显示系经纬度(grid:是否网格线用)
- (void)drawOfflineBase {
    if (!_offlineBaseView) return;
    CGSize sz = self.bounds.size;
    if (sz.width <= 1 || sz.height <= 1) return;
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // 背景：淡色渐变（模拟陆地/海洋）
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat cols[8] = {0.93,0.96,1.0,1.0, 0.85,0.90,0.96,1.0};
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, cols, NULL, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0,0), CGPointMake(0, sz.height), 0);
    CGColorSpaceRelease(cs); CGGradientRelease(grad);

    // 当前可视世界像素矩形 -> 经纬度范围
    CGPoint topLeftWorld = CGPointMake(_origin.x, _origin.y);
    CGPoint botRightWorld = CGPointMake(_origin.x+sz.width, _origin.y+sz.height);
    CLLocationCoordinate2D tl = onyx_worldToLonlat(topLeftWorld, _zoom);
    CLLocationCoordinate2D bl = onyx_worldToLonlat(CGPointMake(topLeftWorld.x, botRightWorld.y), _zoom);

    // 依据 zoom 选网格间隔
    double step = 1.0;
    switch (_zoom) {
        case 0 ... 2: step = 45.0; break;
        case 3 ... 5: step = 10.0; break;
        case 6 ... 8: step = 5.0;  break;
        case 9 ... 11: step = 1.0; break;
        case 12 ... 13: step = 0.5; break;
        case 14: step = 0.2; break;
        case 15: step = 0.1; break;
        case 16: step = 0.05; break;
        default: step = 0.02; break;
    }
    // 屏幕上的经纬线像素密度阈值，防止太密
    double xPerDeg = sz.width / MAX(0.0001, (onyx_worldToLonlat(botRightWorld, _zoom).longitude - tl.longitude));
    while (step * xPerDeg < 18.0) step *= 2.0;

    // 纵向经线 + 横向纬线
    CGContextSetLineWidth(ctx, 1.0);
    // 经线
    double lonStart = floor(tl.longitude / step) * step;
    for (double lon = lonStart; lon <= (onyx_worldToLonlat(botRightWorld, _zoom).longitude); lon += step) {
        CGPoint wp = onyx_lonlatToWorld(CLLocationCoordinate2DMake(tl.latitude, lon), _zoom);
        CGFloat vx = wp.x - _origin.x;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.14].CGColor);
        CGContextMoveToPoint(ctx, vx, 0);
        CGContextAddLineToPoint(ctx, vx, sz.height);
        CGContextStrokePath(ctx);
    }
    // 纬线
    double latStart = floor(bl.latitude / step) * step;
    for (double lat = latStart; lat <= tl.latitude; lat += step) {
        CGPoint wp = onyx_lonlatToWorld(CLLocationCoordinate2DMake(lat, tl.longitude), _zoom);
        CGFloat vy = wp.y - _origin.y;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.14].CGColor);
        CGContextMoveToPoint(ctx, 0, vy);
        CGContextAddLineToPoint(ctx, sz.width, vy);
        CGContextStrokePath(ctx);
    }

    // 高清大网格（加粗的度线）
    double bigStep = 1.0;
    while (bigStep < step) bigStep *= 2.0;
    CGContextSetLineWidth(ctx, 1.2);
    double bigLon = floor(tl.longitude / bigStep) * bigStep;
    for (double lon = bigLon; lon <= (onyx_worldToLonlat(botRightWorld, _zoom).longitude); lon += bigStep) {
        CGPoint wp = onyx_lonlatToWorld(CLLocationCoordinate2DMake(tl.latitude, lon), _zoom);
        CGFloat vx = wp.x - _origin.x;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.26].CGColor);
        CGContextMoveToPoint(ctx, vx, 0); CGContextAddLineToPoint(ctx, vx, sz.height); CGContextStrokePath(ctx);
    }
    double bigLat = floor(bl.latitude / bigStep) * bigStep;
    for (double lat = bigLat; lat <= tl.latitude; lat += bigStep) {
        CGPoint wp = onyx_lonlatToWorld(CLLocationCoordinate2DMake(lat, tl.longitude), _zoom);
        CGFloat vy = wp.y - _origin.y;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.26].CGColor);
        CGContextMoveToPoint(ctx, 0, vy); CGContextAddLineToPoint(ctx, sz.width, vy); CGContextStrokePath(ctx);
    }

    // 中央定位十字
    CGContextSetLineWidth(ctx, 1.6);
    [[UIColor systemRedColor] setStroke];
    CGFloat cx = sz.width*0.5, cy = sz.height*0.5;
    CGContextMoveToPoint(ctx, cx-16, cy); CGContextAddLineToPoint(ctx, cx+16, cy); CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, cx, cy-16); CGContextAddLineToPoint(ctx, cx, cy+16); CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, [UIColor systemRedColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx-3, cy-3, 6, 6));

    // 中心坐标文字（离线底图直接标注当前位置坐标，非常醒目）
    NSString *ctrText;
    if (_hasCenter) {
        CLLocationCoordinate2D c = [self displayCenter];
        ctrText = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    } else if (_offlineRefreshed) {
        ctrText = @"离线底图 — 等待坐标";
    } else {
        ctrText = @"离线底图（无网络）";
    }
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
                            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.15 alpha:0.85]};
    NSDictionary *bgAttrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
                              NSForegroundColorAttributeName: [UIColor whiteColor]};
    CGSize ts = [ctrText sizeWithAttributes:attrs];
    CGFloat textW = ts.width, textH = ts.height;
    CGRect bar = CGRectMake(8, 8, textW + 16, textH + 8);
    [[UIColor colorWithWhite:1.0 alpha:0.82] setFill];
    CGContextRoundRect(ctx, bar, 8);
    CGContextFillPath(ctx);
    // 为文字加阴影便于阅读
    [ctrText drawInRect:CGRectInset(bar, 8, 4) withAttributes:attrs];

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    _offlineBaseView.image = img;
}

static void CGContextRoundRect(CGContextRef ctx, CGRect rect, CGFloat radius) {
    CGFloat x = CGRectGetMinX(rect), y = CGRectGetMinY(rect);
    CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);
    CGContextMoveToPoint(ctx, x + radius, y);
    CGContextAddArcToPoint(ctx, x + w, y, x + w, y + h, radius);
    CGContextAddArcToPoint(ctx, x + w, y + h, x, y + h, radius);
    CGContextAddArcToPoint(ctx, x, y + h, x, y, radius);
    CGContextAddArcToPoint(ctx, x, y, x + w, y, radius);
    CGContextClosePath(ctx);
}

// 更新离线定位十字（跟随真实 or 模拟坐标)
- (void)updateOfflineCross {
    if (!_offlineMode || !_hasCenter) {
        _offlineCrossView.hidden = YES;
        return;
    }
    CGPoint wp = onyx_lonlatToWorld([self displayCenter], _zoom);
    CGFloat vx = wp.x - _origin.x;
    CGFloat vy = wp.y - _origin.y;
    if (vx < -50 || vx > self.bounds.size.width+50 || vy < -50 || vy > self.bounds.size.height+50) {
        _offlineCrossView.hidden = YES;
        return;
    }
    _offlineCrossView.center = CGPointMake(vx, vy);
    _offlineCrossView.hidden = NO;
    [self addSubview:_offlineCrossView];
}

- (void)enterOfflineMode {
    if (_offlineMode) { [self drawOfflineBase]; return; }
    _offlineMode = YES;
    _offlineRefreshed = NO;
    [self drawOfflineBase];
    [self addSubview:_offlineBaseView];
    _offlineBaseView.hidden = NO;
    // 隐藏 tileLayer 避免空白瓦片闪烁
    _tileLayer.hidden = YES;
    [self updateOfflineCross];
}

- (void)leaveOfflineMode {
    if (!_offlineMode) return;
    _offlineMode = NO;
    _offlineBaseView.hidden = YES;
    _tileLayer.hidden = NO;
    _offlineCrossView.hidden = YES;
}

#pragma mark - 标记与坐标横幅

- (void)refreshPin {
    if (!_hasCenter || !_showMarker) {
        _pin.hidden = YES;
        [self updateOfflineCross];
        return;
    }
    CGPoint wp = onyx_lonlatToWorld([self displayCenter], _zoom);
    CGFloat vx = wp.x - _origin.x;
    CGFloat vy = wp.y - _origin.y;
    _pin.center = CGPointMake(vx, vy - 17); // 图钉尖端对准该点
    _pin.hidden = NO;
    // 离线模式下十字标记跟随同一坐标
    [self updateOfflineCross];
    if (_pin.superview != self) [self addSubview:_pin]; // 保证在最上层
}

- (void)updateCoordLabel {
    NSString *target = _hasCenter
        ? [NSString stringWithFormat:@"目标 %.6f, %.6f", _centerWGS.latitude, _centerWGS.longitude]
        : @"定位模拟地图";
    NSString *src = [self sourceName];
    if (_tileFailCount > _tileOkCount && _tileOkCount == 0) {
        _coordLabel.text = [NSString stringWithFormat:@"%@  ·  %@加载失败", target, src];
    } else {
        _coordLabel.text = [NSString stringWithFormat:@"%@  ·  %@", target, src];
    }
}

#pragma mark - public

- (void)recenterOnWGS:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom animated:(BOOL)animated {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    _centerWGS = coord;
    _hasCenter = YES;
    _zoom = MAX(kMinZoom, MIN(kMaxZoom, zoom));
    CGPoint wp = onyx_lonlatToWorld([self displayCenter], _zoom);
    _origin = CGPointMake(wp.x - self.bounds.size.width * 0.5,
                          wp.y - self.bounds.size.height * 0.5);
    [self updateVisibleTiles];
    [self refreshPin];
    [self updateCoordLabel];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    _showMarker = showMarker;
    [self recenterOnWGS:coord zoom:zoom animated:NO];
}

- (void)setMarkerCoordinate:(CLLocationCoordinate2D)coord {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    _centerWGS = coord;
    _hasCenter = YES;
    [self refreshPin];
    [self updateCoordLabel];
}

- (void)zoomIn {
    NSInteger nz = MIN(kMaxZoom, _zoom + 1);
    [self zoomTo:nz];
}
- (void)zoomOut {
    NSInteger nz = MAX(kMinZoom, _zoom - 1);
    [self zoomTo:nz];
}
- (void)zoomTo:(NSInteger)nz {
    if (nz == _zoom) return;
    CGPoint c = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
    // 以视口中心点为锚，保持该点经纬度不变
    CLLocationCoordinate2D anchor = onyx_worldToLonlat(CGPointMake(_origin.x + c.x, _origin.y + c.y), _zoom);
    _zoom = nz;
    CGPoint awp = onyx_lonlatToWorld(anchor, _zoom);
    _origin = CGPointMake(awp.x - c.x, awp.y - c.y);
    [self updateVisibleTiles];
    [self refreshPin];
    if (_offlineMode) [self drawOfflineBase];
}

// 网络环境变化（如刚开 VPN）后手动刷新：回到默认源并重新加载全部瓦片
- (void)reloadTiles {
    _tileOkCount = 0;
    _tileFailCount = 0;
    _consecFail = 0;
    _reportedFail = NO;
    _lastError = nil;
    [self leaveOfflineMode];
    [self applySourceIndex:0 animated:NO];
    [self updateCoordLabel];
    if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
        [self.delegate amapView:self didUpdateStatus:@"已刷新，重新加载瓦片中…"];
    }
}

@end
// Darwin 通知回调：daemon 完成瓦片代拉
static void ONYXAMapViewTileOK(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ONYXAMapView *mapView = (__bridge ONYXAMapView *)observer;
    [mapView handleProxyResult];
}
