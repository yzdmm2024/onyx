#import <UIKit/UIKit.h>

@interface ONYXAppsViewController : UITableViewController

+ (NSArray<NSDictionary *> *)allApplications;
+ (UIImage *)iconForBundleIdentifier:(NSString *)bid;
+ (UIImage *)placeholderIconForName:(NSString *)name;

@end
