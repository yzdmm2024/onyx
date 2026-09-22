#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@protocol ONYXMapViewDelegate <NSObject>
// 回传的是底图坐标系(GCJ-02)选中的经纬度
- (void)onyxMapViewDidPickCoordinate:(CLLocationCoordinate2D)coord;
// 诊断：瓦片取图成功/失败计数
- (void)onyxMapViewDidUpdateStats:(NSString *)stats;
@end

@interface ONYXMapView : UIView
@property (nonatomic, weak) id<ONYXMapViewDelegate> delegate;
// coord 为 GCJ-02（高德底图坐标）
- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)clearMarker;
- (void)zoomIn;
- (void)zoomOut;
@end
