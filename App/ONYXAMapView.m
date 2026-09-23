#import "ONYXAMapView.h"
#import <math.h>

// 坐标语义：MKMapView 使用 WGS-84，直接使用面板内部 currentCoord，无需像高德那样转 GCJ-02。
@interface ONYXAMapView () <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *marker;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, assign) CLLocationCoordinate2D lastUserCoordinate;
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
    _mapView.showsUserLocation = YES; // 蓝点跟随系统定位：开始模拟后跳出到目标点 = 修改成功
    _mapView.showsCompass = YES;
    _mapView.showsScale = YES;
    [self addSubview:_mapView];

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

    _lastUserCoordinate = kCLLocationCoordinate2DInvalid;
    if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
        [self.delegate amapView:self didUpdateStatus:@"地图就绪"];
    }
}

#pragma mark - 交互

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint pt = [g locationInView:_mapView];
    CLLocationCoordinate2D coord = [_mapView convertPoint:pt toCoordinateFromView:_mapView];
    [self placeMarkerAt:coord];
    if ([self.delegate respondsToSelector:@selector(amapView:didPickCoordinate:)]) {
        [self.delegate amapView:self didPickCoordinate:coord];
    }
}

- (void)placeMarkerAt:(CLLocationCoordinate2D)coord {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    if (self.marker) {
        _marker.coordinate = coord;
    } else {
        _marker = [[MKPointAnnotation alloc] init];
        _marker.coordinate = coord;
        _marker.title = @"模拟位置";
        [_mapView addAnnotation:_marker];
    }
}

// zoom(3~18) → 跨度数，越大越精细
- (CLLocationDegrees)latitudeDeltaForZoom:(NSInteger)zoom {
    double z = MAX(3, MIN(18, zoom));
    return 170.0 / pow(2.0, z - 3.0);
}

#pragma mark - MKMapViewDelegate

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation {
    CLLocationCoordinate2D c = userLocation.coordinate;
    if (!CLLocationCoordinate2DIsValid(c)) return;
    // 跟随蓝点：初始或发生明显跳变（开始模拟/切换坐标）时把地图平移到蓝点，
    // 即可直接看到模拟是否生效；静止时不打扰用户平移浏览。
    BOOL first = !CLLocationCoordinate2DIsValid(_lastUserCoordinate);
    CLLocationDistance moved = 0;
    if (!first) {
        CLLocation *last = [[CLLocation alloc] initWithCoordinate:_lastUserCoordinate
                                                         altitude:0 horizontalAccuracy:0 verticalAccuracy:0 timestamp:nil];
        moved = [userLocation.location distanceFromLocation:last];
    }
    if (first || moved > 50) {
        [_mapView setCenterCoordinate:c animated:YES];
    }
    _lastUserCoordinate = c;
}

#pragma mark - public

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    if (zoom >= 3) {
        CLLocationDegrees d = [self latitudeDeltaForZoom:zoom];
        MKCoordinateRegion region = MKCoordinateRegionMake(coord, MKCoordinateSpanMake(d, d));
        [_mapView setRegion:region animated:YES];
    } else {
        [_mapView setCenterCoordinate:coord animated:YES];
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