#import "ONYXAMapView.h"
#import "ONYXCoordTransform.h"
#import <math.h>

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
@property (nonatomic, strong) UIImageView *pin;                  // 标记
@property (nonatomic, strong) UILabel *coordLabel;               // 常驻坐标横幅
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *tileViews; // key "z-x-y"
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imgCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *inflight;
@property (nonatomic, strong) NSURLSession *session;

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

@property (nonatomic, assign) CGPoint panStartOrigin;
@property (nonatomic, assign) CGFloat pinchStartZoom;
@end

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

    _tileViews = [NSMutableDictionary dictionary];
    _imgCache = [[NSCache alloc] init];
    _inflight = [NSMutableSet set];
    // 坑：越狱 platform-app/container-required=false 的 App，使用自定义
    // NSURLSessionConfiguration 时可能无法建立出站连接（系统代理/ATS 被绕过）。
    // [NSURLSession sharedSession] 走系统默认通道，反而更容易成功。
    _session = [NSURLSession sharedSession];

    _tileLayer = [[UIView alloc] initWithFrame:self.bounds];
    _tileLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tileLayer.clipsToBounds = YES;
    [self addSubview:_tileLayer];

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

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = self;
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
    if (g.state == UIGestureRecognizerStateBegan) {
        _pinchStartZoom = _zoom;
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint focal = [g locationInView:self];
    CGFloat desired = _pinchStartZoom + log2(g.scale);
    NSInteger newZoom = (NSInteger)lround(desired);
    newZoom = MAX(kMinZoom, MIN(kMaxZoom, newZoom));
    if (newZoom != _zoom) {
        CLLocationCoordinate2D anchor = onyx_worldToLonlat(CGPointMake(_origin.x + focal.x, _origin.y + focal.y), _zoom);
        _zoom = newZoom;
        CGPoint awp = onyx_lonlatToWorld(anchor, _zoom);
        _origin = CGPointMake(awp.x - focal.x, awp.y - focal.y);
        _pinchStartZoom = _zoom;
        [self updateVisibleTiles];
        [self refreshPin];
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
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlstr]
                                                       cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                   timeoutInterval:15];
    // 模拟 Safari UA，部分 CDN 会校验
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            forHTTPHeaderField:@"User-Agent"];
    NSLog(@"[OnyxTile] fetch %@", urlstr);
    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(self) s = wself;
        if (!s) return;
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSLog(@"[OnyxTile] resp %@ status=%ld data=%lu err=%@", urlstr, (long)(http.statusCode), (unsigned long)data.length, error);
        if (error || !data.length || (http && http.statusCode >= 400)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![s->_inflight containsObject:key]) return; // 已切源，忽略
                [s->_inflight removeObject:key];
                s->_tileFailCount++;
                s->_lastError = error;
                // 高德源 https 失败先降级 http
                if (https && s->_srcIndex < 2) {
                    [s loadTileForKey:key x:x y:y z:z https:NO];
                    return;
                }
                [s handleTileFail];
            });
            return;
        }
        UIImage *img = [UIImage imageWithData:data];
        if (!img) {
            NSLog(@"[OnyxTile] not image: %@ bytes=%lu", urlstr, (unsigned long)data.length);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![s->_inflight containsObject:key]) return;
                [s->_inflight removeObject:key];
                s->_tileFailCount++;
                s->_lastError = [NSError errorWithDomain:@"OnyxTile" code:-2
                                                userInfo:@{NSLocalizedDescriptionKey: @"服务器返回非图片数据"}];
                if (https && s->_srcIndex < 2) {
                    [s loadTileForKey:key x:x y:y z:z https:NO];
                    return;
                }
                [s handleTileFail];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![s->_inflight containsObject:key]) return; // 已切源，忽略旧请求
            [s->_inflight removeObject:key];
            s->_consecFail = 0;
            [s->_imgCache setObject:img forKey:key];
            s->_tileOkCount++;
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

- (void)handleTileFail {
    _consecFail++;
    if (_consecFail >= kFailThreshold && _srcIndex < kSourceCount - 1) {
        NSInteger next = _srcIndex + 1;
        [self applySourceIndex:next animated:YES];
        if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
            [self.delegate amapView:self didUpdateStatus:[NSString stringWithFormat:@"源切换 → %@", [self sourceName]]];
        }
        return;
    }
    if (!_reportedFail) {
        _reportedFail = YES;
        NSString *msg;
        if (_lastError) {
            msg = [NSString stringWithFormat:@"%@瓦片加载失败 %@(%ld)", [self sourceName], _lastError.domain, (long)_lastError.code];
        } else if (_tileOkCount > 0) {
            msg = [NSString stringWithFormat:@"%@部分瓦片加载失败", [self sourceName]];
        } else {
            msg = [NSString stringWithFormat:@"%@瓦片加载失败(无网络?)", [self sourceName]];
        }
        if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
            [self.delegate amapView:self didUpdateStatus:msg];
        }
    }
}

#pragma mark - 标记与坐标横幅

- (void)refreshPin {
    if (!_hasCenter || !_showMarker) {
        _pin.hidden = YES;
        return;
    }
    CGPoint wp = onyx_lonlatToWorld([self displayCenter], _zoom);
    CGFloat vx = wp.x - _origin.x;
    CGFloat vy = wp.y - _origin.y;
    _pin.center = CGPointMake(vx, vy - 17); // 图钉尖端对准该点
    _pin.hidden = NO;
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
}

@end