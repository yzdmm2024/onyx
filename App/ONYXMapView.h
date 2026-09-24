#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@protocol ONYXMapViewDelegate <NSObject>
// 用户在提示面板点击“手动输入坐标”后，把坐标回传
- (void)onyxMapViewDidPickCoordinate:(CLLocationCoordinate2D)coord;
// 诊断/提示信息
- (void)onyxMapViewDidUpdateStats:(NSString *)stats;
@optional
- (void)onyxMapViewDidFailWithError:(NSString *)error;
@end

// jailbreak 自签 App 无法加载系统地图瓦片，这里用状态面板替代地图，
// 直观显示：状态、已选应用数、目标坐标、最后更新时间。
@interface ONYXMapView : UIView
@property (nonatomic, weak) id<ONYXMapViewDelegate> delegate;
- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)setStatusRunning:(BOOL)running selectedCount:(NSInteger)count lastUpdated:(NSString *)lastUpdated;
- (void)clearMarker;
- (void)zoomIn;
- (void)zoomOut;
- (void)setShowsUserLocation:(BOOL)show;
@end
