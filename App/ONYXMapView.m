#import "ONYXMapView.h"

// 系统地图：用 MKMapView（com.apple.mapkit entitlement）。
// MKMapView 的瓦片由系统地图守护进程经系统通道提供，不经过 App 自身沙箱网络，
// 因此不受自签 deb App 的 network.client 不生效限制（之前 NSURLSession 取瓦片必 -1009）。
// 坐标均为 WGS-84（苹果地图名义坐标系），选点/显示直通，无需 GCJ-02 转换。

@interface ONYXOSMTileOverlay : MKTileOverlay
@end
@implementation ONYXOSMTileOverlay
- (instancetype)init {
    self = [super initWithURLTemplate:@"https://tile.openstreetmap.org/{z}/{x}/{y}.png"];
    if (self) {
        self.canReplaceMapContent = YES;
        self.maximumZ = 19;
        self.minimumZ = 3;
    }
    return self;
}
@end

@interface ONYXMapView () <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *annotation;
@property (nonatomic, strong) ONYXOSMTileOverlay *osmOverlay;
@property (nonatomic, assign) BOOL showMarker;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, assign) BOOL didFinishLoad;
@property (nonatomic, strong) NSTimer *fallbackTimer;
@end

@implementation ONYXMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _zoom = 11;
        _showMarker = NO;
        _didFinishLoad = NO;

        _mapView = [[MKMapView alloc] initWithFrame:self.bounds];
        _mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _mapView.delegate = self;
        _mapView.showsUserLocation = NO;
        _mapView.zoomEnabled = YES;
        _mapView.scrollEnabled = YES;
        _mapView.rotateEnabled = NO;
        _mapView.pitchEnabled = NO;
        _mapView.mapType = MKMapTypeStandard;
        [self addSubview:_mapView];

        // OSM 瓦片兜底：若系统地图瓦片出不来，用公开 OSM 瓦片覆盖
        _osmOverlay = [[ONYXOSMTileOverlay alloc] init];
        [_mapView addOverlay:_osmOverlay level:MKOverlayLevelAboveLabels];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        tap.numberOfTapsRequired = 1;
        [_mapView addGestureRecognizer:tap];

        self.backgroundColor = [UIColor colorWithRed:0.92 green:0.94 blue:0.97 alpha:1.0];

        // 超时兜底：10 秒后若系统地图仍未完成加载，提示用户改用搜索/手动输入
        _fallbackTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                            target:self
                                                          selector:@selector(fallbackTimeout:)
                                                          userInfo:nil
                                                           repeats:NO];
    }
    return self;
}

- (void)fallbackTimeout:(NSTimer *)timer {
    if (!_didFinishLoad) {
        NSString *msg = @"系统地图无瓦片（10s 超时）： jailbreak 下 MapKit 瓦片常被系统拒。请用顶部搜索或底部手动输入坐标。";
        if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
            [_delegate onyxMapViewDidUpdateStats:msg];
        }
        if ([_delegate respondsToSelector:@selector(onyxMapViewDidFailWithError:)]) {
            [_delegate onyxMapViewDidFailWithError:msg];
        }
    }
}

#pragma mark - 选点

- (void)onTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint p = [g locationInView:_mapView];
    CLLocationCoordinate2D coord = [_mapView convertPoint:p toCoordinateFromView:_mapView];
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    _showMarker = YES;
    [self setMarkerAt:coord];
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidPickCoordinate:)]) {
        [_delegate onyxMapViewDidPickCoordinate:coord];
    }
}

- (void)setMarkerAt:(CLLocationCoordinate2D)coord {
    if (!_annotation) {
        _annotation = [[MKPointAnnotation alloc] init];
        [_mapView addAnnotation:_annotation];
    }
    _annotation.coordinate = coord;
}

#pragma mark - 公开接口

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    _zoom = MAX(3, MIN(18, zoom));
    double span = 360.0 / pow(2.0, (double)_zoom);
    MKCoordinateRegion region = MKCoordinateRegionMake(coord, MKCoordinateSpanMake(span * 1.3, span * 1.3));
    region = [_mapView regionThatFits:region];
    [_mapView setRegion:region animated:YES];
    if (showMarker) { _showMarker = YES; [self setMarkerAt:coord]; }
}

- (void)clearMarker {
    if (_annotation) { [_mapView removeAnnotation:_annotation]; _annotation = nil; }
    _showMarker = NO;
}

- (void)zoomIn { _zoom = MIN(18, _zoom + 1); [self recenterKeepZoom]; }
- (void)zoomOut { _zoom = MAX(3, _zoom - 1); [self recenterKeepZoom]; }

- (void)setShowsUserLocation:(BOOL)show {
    _mapView.showsUserLocation = show;
}

- (void)recenterKeepZoom {
    CLLocationCoordinate2D c = _mapView.centerCoordinate;
    [self setCenterCoordinate:c zoom:_zoom showMarker:_showMarker];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) return nil;
    static NSString *pinID = @"onyxPin";
    MKPinAnnotationView *v = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:pinID];
    if (!v) {
        v = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:pinID];
        v.pinTintColor = [UIColor redColor];
        v.animatesDrop = YES;
        v.canShowCallout = NO;
    }
    return v;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKTileOverlay class]]) {
        return [[MKTileOverlayRenderer alloc] initWithTileOverlay:(MKTileOverlay *)overlay];
    }
    return nil;
}

- (void)mapViewWillStartLoadingMap:(MKMapView *)mapView {
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
        [_delegate onyxMapViewDidUpdateStats:@"系统地图加载中…"];
    }
}

- (void)mapViewDidFinishLoadingMap:(MKMapView *)mapView {
    _didFinishLoad = YES;
    [_fallbackTimer invalidate];
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
        [_delegate onyxMapViewDidUpdateStats:@"系统地图已加载 ✓"];
    }
}

- (void)mapViewDidFailLoadingMap:(MKMapView *)mapView withError:(NSError *)error {
    _didFinishLoad = YES;
    [_fallbackTimer invalidate];
    NSString *s = [NSString stringWithFormat:@"地图加载失败: %@ (code %ld)",
                   error.localizedDescription ?: @"", (long)error.code];
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
        [_delegate onyxMapViewDidUpdateStats:s];
    }
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidFailWithError:)]) {
        [_delegate onyxMapViewDidFailWithError:s];
    }
}

- (void)mapViewDidFinishRenderingMap:(MKMapView *)mapView fullyRendered:(BOOL)fullyRendered {
    NSString *s = fullyRendered ? @"系统地图渲染完成 ✓" : @"系统地图部分渲染";
    if ([_delegate respondsToSelector:@selector(onyxMapViewDidUpdateStats:)]) {
        [_delegate onyxMapViewDidUpdateStats:s];
    }
}

@end
