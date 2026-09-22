#import <UIKit/UIKit.h>

@interface ONYXAppsViewController : UITableViewController

+ (NSArray<NSDictionary *> *)allApplications;
+ (UIImage *)iconForBundleIdentifier:(NSString *)bid;

@end
