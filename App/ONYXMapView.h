#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

@protocol ONYXMapViewDelegate <NSObject>
// 回传 WGS-84 坐标（MKMapView 坐标系）
- (void)onyxMapViewDidPickCoordinate:(CLLocationCoordinate2D)coord;
// 诊断：地图加载状态
- (void)onyxMapViewDidUpdateStats:(NSString *)stats;
@optional
- (void)onyxMapViewDidFailWithError:(NSString *)error;
@end

@interface ONYXMapView : UIView <MKMapViewDelegate>
@property (nonatomic, weak) id<ONYXMapViewDelegate> delegate;
// coord 为 WGS-84（苹果地图坐标系）
- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)clearMarker;
- (void)zoomIn;
- (void)zoomOut;
- (void)setShowsUserLocation:(BOOL)show;
@end
