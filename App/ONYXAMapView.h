#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

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
