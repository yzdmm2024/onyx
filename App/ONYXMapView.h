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

// 由于 jailbreak 自签 App 无法加载系统地图瓦片，也不再自己取瓦片，
// 这里用一个静态提示面板替代地图，引导用户用搜索或手动输入坐标。
@interface ONYXMapView : UIView
@property (nonatomic, weak) id<ONYXMapViewDelegate> delegate;
- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker;
- (void)clearMarker;
- (void)zoomIn;
- (void)zoomOut;
- (void)setShowsUserLocation:(BOOL)show;
@end
