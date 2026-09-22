#import "ONYXAppDelegate.h"
#import "ONYXMapViewController.h"

@implementation ONYXAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    ONYXMapViewController *root = [[ONYXMapViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
