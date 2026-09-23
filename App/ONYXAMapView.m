#import "ONYXAMapView.h"
#import "ONYXCoordTransform.h"
#import <math.h>

// 坐标语义：高德瓦片为 GCJ-02，故 MKMapView 的地图空间按 GCJ-02 理解；
// 对外（面板/模拟）仍为 WGS-84，进出处互转，保证标记与高德瓦片对齐、模拟坐标准确。
// 采用传统高德瓦片端点（webrd04.is.autonavi.com），不依赖高德 SDK，iOS 无法直连苹果瓦片时也能出图。
@interface ONYXAMapView () <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *marker;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, assign) CLLocationCoordinate2D lastUserCoordinate;
@property (nonatomic, strong) UILabel *coordLabel; // 常驻坐标横幅：瓦片不可用时也可见，便于验证模拟
@end

@implementation ONYXAMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupMap];
    }
    return self;
}

- (void)setupMap {
    _mapView = [[MKMapView alloc] initWithFrame:self.bounds];
    _mapView.translatesAutoresizingMaskIntoConstraints = NO;
    _mapView.delegate = self;
    _mapView.mapType = MKMapTypeStandard;
    _mapView.showsBuildings = YES;
    _mapView.showsUserLocation = YES; // 蓝点跟随系统定位：开始模拟后跳出到目标点 = 修改成功
    _mapView.showsCompass = YES;
    _mapView.showsScale = YES;
    [self addSubview:_mapView];

    // 高德瓦片叠加层：出图不依赖苹果地图服务（原在此设备为空白）。style=8 为标准矢量样式。
    MKTileOverlay *tiles = [[MKTileOverlay alloc] initWithURLTemplate:
        @"https://webrd04.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}"];
    tiles.canReplaceMapContent = YES;
    tiles.minimumZ = 0;
    tiles.maximumZ = 19;
    [_mapView addOverlay:tiles level:MKOverlayLevelAboveRoads];

    [NSLayoutConstraint activateConstraints:@[
        [_mapView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_mapView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_mapView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_mapView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];

    // 首次请求定位权限，保证蓝点可显示
    _locationManager = [[CLLocationManager alloc] init];
    [_locationManager requestWhenInUseAuthorization];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [_mapView addGestureRecognizer:tap];

    // 常驻坐标横幅：叠加在地图上，瓦片/定位不可用时也能看到目标坐标
    _coordLabel = [UILabel new];
    _coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _coordLabel.textColor = [UIColor labelColor];
    _coordLabel.backgroundColor = [UIColor systemBackgroundColor];
    _coordLabel.layer.cornerRadius = 14;
    _coordLabel.layer.masksToBounds = YES;
    _coordLabel.layer.borderWidth = 0.3;
    _coordLabel.layer.borderColor = [UIColor separatorColor].CGColor;
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_coordLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_coordLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_coordLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_coordLabel.leftAnchor constraintGreaterThanOrEqualToAnchor:self.leftAnchor constant:8],
        [_coordLabel.rightAnchor constraintLessThanOrEqualToAnchor:self.rightAnchor constant:-8],
        [_coordLabel.heightAnchor constraintEqualToConstant:28]
    ]];

    _lastUserCoordinate = kCLLocationCoordinate2DInvalid;
    if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
        [self.delegate amapView:self didUpdateStatus:@"地图就绪"];
    }
}

#pragma mark - 坐标系互转（对外 WGS-84，地图空间 GCJ-02）

// WGS-84 -> GCJ-02（高德瓦片坐标）
- (CLLocationCoordinate2D)toGCJ:(CLLocationCoordinate2D)coord {
    return [ONYXCoordTransform gcj02FromWgs84:coord];
}
// GCJ-02（高德瓦片坐标） -> WGS-84
- (CLLocationCoordinate2D)toWGS:(CLLocationCoordinate2D)coord {
    return [ONYXCoordTransform wgs84FromGcj02:coord];
}

#pragma mark - 交互

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint pt = [g locationInView:_mapView];
    CLLocationCoordinate2D gcjCoord = [_mapView convertPoint:pt toCoordinateFromView:_mapView];
    CLLocationCoordinate2D coord = [self toWGS:gcjCoord];
    [self placeMarkerAt:coord];
    if ([self.delegate respondsToSelector:@selector(amapView:didPickCoordinate:)]) {
        [self.delegate amapView:self didPickCoordinate:coord];
    }
}

- (void)placeMarkerAt:(CLLocationCoordinate2D)coord {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    CLLocationCoordinate2D m = [self toGCJ:coord];
    if (self.marker) {
        _marker.coordinate = m;
    } else {
        _marker = [[MKPointAnnotation alloc] init];
        _marker.coordinate = m;
        _marker.title = @"模拟位置";
        [_mapView addAnnotation:_marker];
    }
    [self updateCoordLabel:coord];
}

- (void)updateCoordLabel:(CLLocationCoordinate2D)coord {
    if (_coordLabel) {
        _coordLabel.text = [NSString stringWithFormat:@"目标 %.6f, %.6f", coord.latitude, coord.longitude];
    }
}

// zoom(3~18) → 跨度数，越大越精细
- (CLLocationDegrees)latitudeDeltaForZoom:(NSInteger)zoom {
    double z = MAX(3, MIN(18, zoom));
    return 170.0 / pow(2.0, z - 3.0);
}

#pragma mark - MKMapViewDelegate

// 渲染高德瓦片叠加层
- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKTileOverlay class]]) {
        return [[MKTileOverlayRenderer alloc] initWithOverlay:overlay];
    }
    return nil;
}

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation {
    CLLocationCoordinate2D c = userLocation.coordinate;
    if (!CLLocationCoordinate2DIsValid(c)) return;
    // 跟随蓝点：初始或发生明显跳变（开始模拟/切换坐标）时把地图平移到蓝点在瓦片上的位置，
    // 即可直接看到模拟是否生效；静止时不打扰用户平移浏览。
    BOOL first = !CLLocationCoordinate2DIsValid(_lastUserCoordinate);
    CLLocationDistance moved = 0;
    if (!first) {
        CLLocation *last = [[CLLocation alloc] initWithCoordinate:_lastUserCoordinate
                                                         altitude:0 horizontalAccuracy:0 verticalAccuracy:0 timestamp:nil];
        moved = [userLocation.location distanceFromLocation:last];
    }
    if (first || moved > 50) {
        [_mapView setCenterCoordinate:[self toGCJ:c] animated:YES];
    }
    _lastUserCoordinate = c;
}

#pragma mark - public

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    CLLocationCoordinate2D m = [self toGCJ:coord];
    if (zoom >= 3) {
        CLLocationDegrees d = [self latitudeDeltaForZoom:zoom];
        MKCoordinateRegion region = MKCoordinateRegionMake(m, MKCoordinateSpanMake(d, d));
        [_mapView setRegion:region animated:YES];
    } else {
        [_mapView setCenterCoordinate:m animated:YES];
    }
    if (showMarker) [self placeMarkerAt:coord];
}

- (void)setMarkerCoordinate:(CLLocationCoordinate2D)coord {
    [self placeMarkerAt:coord];
}

- (void)zoomIn {
    MKCoordinateRegion r = _mapView.region;
    MKCoordinateSpan s = MKCoordinateSpanMake(r.span.latitudeDelta * 0.5, r.span.longitudeDelta * 0.5);
    [_mapView setRegion:MKCoordinateRegionMake(r.center, s) animated:YES];
}

- (void)zoomOut {
    MKCoordinateRegion r = _mapView.region;
    MKCoordinateSpan s = MKCoordinateSpanMake(r.span.latitudeDelta * 2.0, r.span.longitudeDelta * 2.0);
    [_mapView setRegion:MKCoordinateRegionMake(r.center, s) animated:YES];
}

@end