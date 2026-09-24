#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

// 历史记录列表：显示地名+坐标，左滑删除/备注，点击跳转到该定位
@interface ONYXHistoryViewController : UITableViewController
@property (nonatomic, copy, nullable) void (^onSelect)(CLLocationCoordinate2D coord);
@end

NS_ASSUME_NONNULL_END
