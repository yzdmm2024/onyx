#import "ONYXMapView.h"

static const NSInteger TILE = 256;

// 原生地图：App 主进程 NSURLSession 取瓦片，直接平铺到 UIImageView。
// 绕开 WKWebView / WebContent 子进程（自签越狱 App 的 WebContent 网络被限）。
// 取图失败会经 delegate 弹出具体 error，便于定位是「沙箱无网络权限」还是「设备无外网」。

@interface ONYXMapView ()
@property (nonatomic, strong) UIView *tilesContainer;
@property (nonatomic, strong) UIView *markerView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *tileViews;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *cache;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, assign) double clng;   // GCJ-02
@property (nonatomic, assign) double clat;
@property (nonatomic, assign) double mlng;
@property (nonatomic, assign) double mlat;
@property (nonatomic, assign) BOOL showMarker;
@property (nonatomic, assign) NSInteger ok;
@property (nonatomic, assign) NSInteger fail;
@property (nonatomic, assign) CGPoint panStartWorld;
@property (nonatomic, copy) NSString *lastErr;
@end

@implementation ONYXMapView

+ (NSURLSession *)sharedSession {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.allowsCellularAccess = YES;
        c.waitsForConnectivity = NO;
        c.timeoutIntervalForRequest = 15;
        c.timeoutIntervalForResource = 30;
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _zoom = 11;
        _clng = 121.4737;
        _clat = 31.2304;
        _showMarker = NO;
        _ok = 0;
        _fail = 0;
        _tileViews = [NSMutableDictionary dictionary];
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 400;

        _tilesContainer = [[UIView alloc] initWithFrame:self.bounds];
        _tilesContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_tilesContainer];

        _markerView = [self makeMarker];
        _markerView.hidden = YES;
        [self addSubview:_markerView];

        self.backgroundColor = [UIColor colorWithRed:0.68 green:0.85 blue:1.0 alpha:1.0];
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:pan];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
        [self addGestureRecognizer:pinch];
    }
    return self;
}

- (UIView *)makeMarker {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 40)];
    v.userInteractionEnabled = NO;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
    dot.layer.cornerRadius = 13;
    dot.layer.borderWidth = 2.5;
    dot.layer.borderColor = [[UIColor whiteColor] CGColor];
    UIView *stem = [[UIView alloc] initWithFrame:CGRectMake(12, 23, 2, 17)];
    stem.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
    [v addSubview:dot];
    [v addSubview:stem];
    return v;
}

#pragma mark - 坐标数学（Web Mercator）

- (CGPoint)worldForLng:(double)lng lat:(double)lat zoom:(NSInteger)z {
    double n = pow(2, z);
    double x = (lng + 180.0) / 360.0 * n * TILE;
    double s = sin(lat * M_PI / 180.0);
    double y = (0.5 - log((1.0 + s) / (1.0 - s)) / (4.0 * M_PI)) * n * TILE;
    return CGPointMake(x, y);
}

- (CLLocationCoordinate2D)lngLatForWorldX:(double)x y:(double)y zoom:(NSInteger)z {
    double n = pow(2, z);
    double lng = x / TILE / n * 360.0 - 180.0;
    double lat = atan(sinh(M_PI - (2.0 * y / TILE / n * M_PI * 2.0))) * 180.0 / M_PI;
    return CLLocationCoordinate2DMake(lat, lng);
}

#pragma mark - 布局瓦片

- (void)layoutTiles {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 1 || h < 1) return;
    CGPoint c = [self worldForLng:_clng lat:_clat zoom:_zoom];
    CGFloat ox = w / 2.0 - c.x, oy = h / 2.0 - c.y;
    NSInteger n = (NSInteger)pow(2, _zoom);
    NSInteger minX = (NSInteger)floor(-ox / TILE), maxX = (NSInteger)floor((w - ox) / TILE);
    NSInteger minY = (NSInteger)floor(-oy / TILE), maxY = (NSInteger)floor((h - oy) / TILE);

    NSMutableSet *needed = [NSMutableSet set];
    for (NSInteger tx = minX; tx <= maxX; tx++) {
        for (NSInteger ty = minY; ty <= maxY; ty++) {
            if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
            NSString *key = [NSString stringWithFormat:@"%ld/%ld/%ld", (long)_zoom, (long)tx, (long)ty];
            [needed addObject:key];
            UIImageView *iv = _tileViews[key];
            CGRect fr = CGRectMake(ox + tx * TILE, oy + ty * TILE, TILE, TILE);
            if (iv) {
                iv.frame = fr;
            } else {
                iv = [[UIImageView alloc] initWithFrame:fr];
                iv.contentMode = UIViewContentModeScaleToFill;
                iv.backgroundColor = [UIColor colorWithRed:0.68 green:0.85 blue:1.0 alpha:1.0];
                [_tilesContainer addSubview:iv];
                _tileViews[key] = iv;
                [self loadTile:key x:tx y:ty z:_zoom];
            }
        }
    }
    for (NSString *key in [_tileViews.allKeys copy]) {
        if (![needed containsObject:key]) {
            [_tileViews[key] removeFromSuperview];
            [_tileViews removeObjectForKey:key];
        }
    }
    [self layoutMarkerWithOx:ox oy:oy];
}

- (void)layoutMarkerWithOx:(CGFloat)ox oy:(CGFloat)oy {
    if (!_showMarker) { _markerView.hidden = YES; return; }
    CGPoint m = [self worldForLng:_mlng lat:_mlat zoom:_zoom];
    _markerView.hidden = NO;
    _markerView.center = CGPointMake(ox + m.x, oy + m.y - 13);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _tilesContainer.frame = self.bounds;
    [self layoutTiles];
}

#pragma mark - 取图（高德优先，失败回 OSM 兜底）

- (void)loadTile:(NSString *)key x:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    UIImage *img = [_cache objectForKey:key];
    if (img) {
        UIImageView *iv = _tileViews[key];
        if (iv) { iv.image = img; iv.backgroundColor = [UIColor clearColor]; }
        [self incrOk];
        return;
    }
    [self fetchTile:key x:x y:y z:z gaode:YES];
}

- (void)fetchTile:(NSString *)key x:(NSInteger)x y:(NSInteger)y z:(NSInteger)z gaode:(BOOL)gaode {
    NSURL *url;
    if (gaode) {
        NSInteger sub = 1 + ((x + y) % 4);
        NSString *u = [NSString stringWithFormat:
            @"https://webrd0%ld.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x=%ld&y=%ld&z=%ld",
            (long)sub, (long)x, (long)y, (long)z];
        url = [NSURL URLWithString:u];
    } else {
        NSString *u = [NSString stringWithFormat:
            @"https://tile.openstreetmap.org/%ld/%ld/%ld.png", (long)z, (long)x, (long)y];
        url = [NSURL URLWithString:u];
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    if (gaode) [req setValue:@"https://www.amap.com/" forHTTPHeaderField:@"Referer"];

    NSURLSession *sess = [ONYXMapView sharedSession];
    [sess dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        if (!err && hr.statusCode == 200 && data.length) {
            UIImage *image = [UIImage imageWithData:data];
            if (image) {
                [self.cache setObject:image forKey:key];
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImageView *iv = self->_tileViews[key];
                    if (iv) { iv.image = image; iv.backgroundColor = [UIColor clearColor]; }
                    [self incrOk];
                });
                return;
            }
        }
        if (gaode) { [self fetchTile:key x:x y:y z:z gaode:NO]; return; }
        // 高德 + OSM 均失败：记录具体错误
        NSString *desc;
        if (err) {
            desc = [NSString stringWithFormat:@"%@ (code %ld)", err.localizedDescription, (long)err.code];
        } else {
            desc = [NSString stringWithFormat:@"HTTP %ld 空响应", (long)hr.statusCode];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lastErr = desc;
            [self incrFail];
            if (self->_ok == 0 &&
                [self->_delegate respondsToSelector:@selector(onyxMapViewDidFailWithError:)]) {
                [self->_delegate onyxMapViewDidFailWithError:desc];
            }
        });
    }];
}

- (void)incrOk { _ok++; [self reportStats]; }
- (void)incrFail { _fail++; [self reportStats]; }
- (void)reportStats {
    NSString *s = [NSString stringWithFormat:@"成功 %ld / 失败 %ld", (long)_ok, (long)_fail];
    if (_fail > 0 && _lastErr) s = [s stringByAppendingFormat:@" · %@", _lastErr];
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
        [_delegate onyxMapViewDidUpdateStats:s];
    }
}

#pragma mark - 手势

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStartWorld = [self worldForLng:_clng lat:_clat zoom:_zoom];
    }
    CGPoint t = [g translationInView:self];
    CGPoint nc = CGPointMake(_panStartWorld.x - t.x, _panStartWorld.y - t.y);
    CLLocationCoordinate2D nl = [self lngLatForWorldX:nc.x y:nc.y zoom:_zoom];
    _clng = nl.longitude; _clat = nl.latitude;
    [self layoutTiles];
    if (g.state == UIGestureRecognizerStateEnded) {
        if (hypot(t.x, t.y) < 10) {
            CGPoint p = [g locationInView:self];
            [self pickAt:p];
        }
    }
}

- (void)onPinch:(UIPinchGestureRecognizer *)g {
    static NSInteger startZoom = 0;
    if (g.state == UIGestureRecognizerStateBegan) startZoom = _zoom;
    NSInteger dz = (NSInteger)round(log2(g.scale));
    NSInteger nz = MAX(3, MIN(18, startZoom + dz));
    if (nz != _zoom) { _zoom = nz; [self layoutTiles]; }
}

- (void)pickAt:(CGPoint)p {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGPoint c = [self worldForLng:_clng lat:_clat zoom:_zoom];
    CGFloat ox = w / 2.0 - c.x, oy = h / 2.0 - c.y;
    CGPoint wp = CGPointMake(ox + p.x, oy + p.y);
    CLLocationCoordinate2D coord = [self lngLatForWorldX:wp.x y:wp.y zoom:_zoom];
    _mlng = coord.longitude; _mlat = coord.latitude; _showMarker = YES;
    [self layoutTiles];
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidPickCoordinate:)]) {
        [_delegate onyxMapViewDidPickCoordinate:coord];
    }
}

#pragma mark - 公开接口

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    _zoom = MAX(3, MIN(18, zoom));
    _clng = coord.longitude; _clat = coord.latitude;
    _mlng = coord.longitude; _mlat = coord.latitude; _showMarker = showMarker;
    [self layoutTiles];
}

- (void)clearMarker { _showMarker = NO; _markerView.hidden = YES; }

- (void)zoomIn { _zoom = MIN(18, _zoom + 1); [self layoutTiles]; }
- (void)zoomOut { _zoom = MAX(3, _zoom - 1); [self layoutTiles]; }

@end
