#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

// 自绘瓦片地图：用 NSURLSession 直连高德公开瓦片（webrdXX.is.autonavi.com/appmaptile），
// 完全脱离 MKMapView —— 苹果 MapKit 后端被屏蔽时依旧能出图、缩放、拖动。
// 地图空间按 GCJ-02，对外接口统一 WGS-84（与面板/模拟一致），内部自动互转。
@class ONYXAMapView;

@protocol ONYXAMapViewDelegate <NSObject>
@optional
- (void)amapView:(ONYXAMapView *)mapView didPickCoordinate:(CLLocationCoordinate2D)coord;
- (void)amapView:(ONYXAMapView *)mapView didUpdateStatus:(NSString *)status;
- (void)amapView:(ONYXAMapView *)mapView didFailWithError:(NSString *)error;
@end

@interface ONYXAMapView : UIView
@property (nonatomic, weak) id<ONYXAMapViewDelegate> delegate;

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)setMarkerCoordinate:(CLLocationCoordinate2D)coord;
- (void)zoomIn;
- (void)zoomOut;
@end