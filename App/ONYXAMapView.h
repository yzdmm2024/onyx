#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

// MKMapView + 高德瓦片叠加封装：iOS 无法直连苹果瓦片时仍能出图。
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
@property (nonatomic, readonly) MKMapView *mapView;

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)setMarkerCoordinate:(CLLocationCoordinate2D)coord;
- (void)zoomIn;
- (void)zoomOut;
@end