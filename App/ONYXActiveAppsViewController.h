#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

/// 运行中应用列表：展示当前已选并参与定位模拟的应用，支持左滑移除并同步回 OnyxApp 的 SelectedApps。
@interface ONYXActiveAppsViewController : UITableViewController
@property (nonatomic, copy) void (^onRemove)(void);
@end