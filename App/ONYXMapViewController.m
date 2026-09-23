#import "ONYXMapViewController.h"
#import "ONYXCoordTransform.h"
#import "ONYXAppsViewController.h"
#import "ONYXMapView.h"
#import "ONYXAMapView.h"
#import "ONYXLocationSimulator.h"
#import <CoreLocation/CoreLocation.h>
#import <math.h>

static NSString *const kDomain = @"com.yzdmm.onyx";
static NSString *const kRecentCoordsKey = @"com.yzdmm.onyx.recentCoords";

@interface ONYXMapViewController () <ONYXMapViewDelegate, ONYXAMapViewDelegate, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) ONYXAMapView *amapView;
@property (nonatomic, strong) ONYXMapView *statusCard;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIScrollView *sheet;
@property (nonatomic, strong) UIView *sheetContent;

@property (nonatomic, strong) UILabel *latLabel;
@property (nonatomic, strong) UILabel *lngLabel;
@property (nonatomic, strong) UISegmentedControl *systemControl;
@property (nonatomic, strong) UITextField *quickField;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UILabel *mapStatLabel;
@property (nonatomic, strong) UISegmentedControl *recentControl;

@property (nonatomic, assign) CLLocationCoordinate2D currentCoord; // WGS-84
@property (nonatomic, assign) OnyxCoordSystem currentSystem;
@property (nonatomic, assign) BOOL running;
@end

@implementation ONYXMapViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"定位模拟";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentSystem = OnyxCoordSystemWGS84;
    self.currentCoord = CLLocationCoordinate2DMake(31.230416, 121.473701); // 上海人民广场
    self.running = NO;

    [self setupNav];
    [self setupMap];
    [self setupSheet];
    [self loadState];
    [self updateLabels];
    [self pushCurrentToMap:11];
    [self refreshStatusPanel];
}

#pragma mark - 坐标语义
// 内部 currentCoord 为 WGS-84（与原模板一致）。

- (void)setupNav {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStylePlain target:self action:@selector(openAppsList:)];
}

- (void)setupMap {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"搜索地址，或输入 纬度,经度";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [self.view addSubview:self.searchBar];

    // 原生苹果地图（MKMapView），坐标为 WGS-84，与内部 currentCoord 一致
    self.amapView = [[ONYXAMapView alloc] initWithFrame:CGRectZero];
    self.amapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.amapView.delegate = self;
    [self.view addSubview:self.amapView];

    // 状态卡片（保持原有"定位模拟状态"面板，放到地图下方）
    self.statusCard = [[ONYXMapView alloc] initWithFrame:CGRectZero];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.delegate = self;
    [self.view addSubview:self.statusCard];

    // 地图状态标签
    self.mapStatLabel = [[UILabel alloc] init];
    self.mapStatLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapStatLabel.font = [UIFont systemFontOfSize:12];
    self.mapStatLabel.textColor = [UIColor whiteColor];
    self.mapStatLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5];
    self.mapStatLabel.layer.cornerRadius = 7;
    self.mapStatLabel.clipsToBounds = YES;
    self.mapStatLabel.text = @"地图：加载中";
    self.mapStatLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.mapStatLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.searchBar.heightAnchor constraintEqualToConstant:44],

        [self.amapView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.amapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.amapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.amapView.heightAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.38],
        [self.amapView.heightAnchor constraintGreaterThanOrEqualToConstant:180],

        [self.statusCard.topAnchor constraintEqualToAnchor:self.amapView.bottomAnchor],
        [self.statusCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.statusCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.statusCard.heightAnchor constraintEqualToConstant:190],

        [self.mapStatLabel.leadingAnchor constraintEqualToAnchor:self.amapView.leadingAnchor constant:10],
        [self.mapStatLabel.topAnchor constraintEqualToAnchor:self.amapView.topAnchor constant:10],
        [self.mapStatLabel.widthAnchor constraintEqualToConstant:100],
        [self.mapStatLabel.heightAnchor constraintEqualToConstant:22]
    ]];
}

- (void)zoomIn:(id)sender { [self.amapView zoomIn]; }
- (void)zoomOut:(id)sender { [self.amapView zoomOut]; }

- (void)setupSheet {
    self.sheet = [[UIScrollView alloc] init];
    self.sheet.translatesAutoresizingMaskIntoConstraints = NO;
    self.sheet.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.sheet];

    self.sheetContent = [[UIView alloc] init];
    self.sheetContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sheet addSubview:self.sheetContent];

    [NSLayoutConstraint activateConstraints:@[
        [self.sheet.topAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor],
        [self.sheet.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sheet.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sheet.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.sheetContent.topAnchor constraintEqualToAnchor:self.sheet.topAnchor],
        [self.sheetContent.leadingAnchor constraintEqualToAnchor:self.sheet.leadingAnchor],
        [self.sheetContent.trailingAnchor constraintEqualToAnchor:self.sheet.trailingAnchor],
        [self.sheetContent.bottomAnchor constraintEqualToAnchor:self.sheet.bottomAnchor],
        [self.sheetContent.widthAnchor constraintEqualToAnchor:self.sheet.widthAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.layoutMargins = UIEdgeInsetsMake(16, 16, 24, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    [self.sheetContent addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.sheetContent.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.sheetContent.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.sheetContent.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.sheetContent.bottomAnchor]
    ]];

    UIView *coordRow = [[UIView alloc] init];
    coordRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.latLabel = [self label:@"纬度" value:@"0.000000"];
    self.lngLabel = [self label:@"经度" value:@"0.000000"];
    [coordRow addSubview:self.latLabel];
    [coordRow addSubview:self.lngLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.latLabel.leadingAnchor constraintEqualToAnchor:coordRow.leadingAnchor],
        [self.latLabel.topAnchor constraintEqualToAnchor:coordRow.topAnchor],
        [self.latLabel.bottomAnchor constraintEqualToAnchor:coordRow.bottomAnchor],
        [self.latLabel.widthAnchor constraintEqualToAnchor:coordRow.widthAnchor multiplier:0.48],
        [self.lngLabel.trailingAnchor constraintEqualToAnchor:coordRow.trailingAnchor],
        [self.lngLabel.topAnchor constraintEqualToAnchor:coordRow.topAnchor],
        [self.lngLabel.bottomAnchor constraintEqualToAnchor:coordRow.bottomAnchor],
        [self.lngLabel.widthAnchor constraintEqualToAnchor:coordRow.widthAnchor multiplier:0.48]
    ]];
    [stack addArrangedSubview:coordRow];

    self.systemControl = [[UISegmentedControl alloc] initWithItems:@[@"WGS-84", @"GCJ-02", @"BD-09"]];
    self.systemControl.selectedSegmentIndex = 0;
    [self.systemControl addTarget:self action:@selector(systemChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.systemControl];

    UILabel *quickTitle = [[UILabel alloc] init];
    quickTitle.text = @"快速定位";
    quickTitle.textColor = [UIColor systemBlueColor];
    quickTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [stack addArrangedSubview:quickTitle];

    self.quickField = [[UITextField alloc] init];
    self.quickField.borderStyle = UITextBorderStyleRoundedRect;
    self.quickField.placeholder = @"输入地址 或 纬度,经度";
    self.quickField.returnKeyType = UIReturnKeySearch;
    self.quickField.delegate = self;
    self.quickField.font = [UIFont systemFontOfSize:15];
    [stack addArrangedSubview:self.quickField];

    // 最近坐标
    UILabel *recentTitle = [[UILabel alloc] init];
    recentTitle.text = @"最近坐标";
    recentTitle.textColor = [UIColor systemBlueColor];
    recentTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [stack addArrangedSubview:recentTitle];

    self.recentControl = [[UISegmentedControl alloc] initWithItems:@[@"无"]];
    self.recentControl.selectedSegmentIndex = 0;
    [self.recentControl addTarget:self action:@selector(recentChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.recentControl];

    self.saveButton = [self buttonWithTitle:@"保存并应用" color:[UIColor systemBlueColor] action:@selector(saveTapped:)];
    [stack addArrangedSubview:self.saveButton];

    self.addressLabel = [[UILabel alloc] init];
    self.addressLabel.numberOfLines = 0;
    self.addressLabel.text = @"当前：";
    self.addressLabel.font = [UIFont systemFontOfSize:14];
    self.addressLabel.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:self.addressLabel];

    self.applyButton = [self buttonWithTitle:@"一键修改到此位置" color:[UIColor systemBlueColor] action:@selector(applyTapped:)];
    [stack addArrangedSubview:self.applyButton];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"状态：已停止";
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    [stack addArrangedSubview:self.statusLabel];

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    btnRow.spacing = 12;
    self.startButton = [self buttonWithTitle:@"开始模拟" color:[UIColor systemGreenColor] action:@selector(startTapped:)];
    self.stopButton = [self buttonWithTitle:@"停止模拟" color:[UIColor systemRedColor] action:@selector(stopTapped:)];
    [btnRow addArrangedSubview:self.startButton];
    [btnRow addArrangedSubview:self.stopButton];
    [stack addArrangedSubview:btnRow];
}

- (UILabel *)label:(NSString *)title value:(NSString *)value {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:15];
    l.text = [NSString stringWithFormat:@"%@  %@", title, value];
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    return l;
}

- (UIButton *)buttonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = color;
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - ONYXAMapViewDelegate

- (void)amapView:(ONYXAMapView *)mapView didPickCoordinate:(CLLocationCoordinate2D)coord {
    // AMap 回调是 GCJ-02，已转 WGS-84
    self.currentCoord = coord;
    [self updateLabels];
    [self reverseGeocode:coord];
}

- (void)amapView:(ONYXAMapView *)mapView didUpdateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.mapStatLabel.text = [@"地图：" stringByAppendingString:status ?: @"就绪"];
    });
}

- (void)amapView:(ONYXAMapView *)mapView didFailWithError:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.mapStatLabel.text = @"地图：失败";
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"地图加载失败"
            message:[NSString stringWithFormat:@"%@\n\n可继续用顶部「搜索」或底部手动输入 纬度,经度 定位。", error ?: @""]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

// 更新地图中心、状态卡片、标记
- (void)pushCurrentToMap:(NSInteger)zoom {
    [self.amapView setCenterCoordinate:self.currentCoord zoom:zoom showMarker:YES];
}

#pragma mark - State

- (void)loadState {
    CFPropertyListRef lat = CFPreferencesCopyAppValue(CFSTR("Latitude"), CFSTR("com.yzdmm.onyx"));
    CFPropertyListRef lng = CFPreferencesCopyAppValue(CFSTR("Longitude"), CFSTR("com.yzdmm.onyx"));
    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.yzdmm.onyx"));
    if (lat && lng) {
        double la = [(__bridge NSNumber *)lat doubleValue];
        double ln = [(__bridge NSNumber *)lng doubleValue];
        self.currentCoord = CLLocationCoordinate2DMake(la, ln);
    }
    if (en) self.running = [(__bridge NSNumber *)en boolValue];
    if (lat) CFRelease(lat);
    if (lng) CFRelease(lng);
    if (en) CFRelease(en);
    if (self.running) {
        [[ONYXLocationSimulator sharedSimulator] startSimulationWithLatitude:self.currentCoord.latitude longitude:self.currentCoord.longitude];
    }
    [self updateStatus];
    [self loadRecent];
}

- (void)saveState {
    CFPreferencesSetAppValue(CFSTR("Latitude"), (__bridge CFNumberRef)@(self.currentCoord.latitude), CFSTR("com.yzdmm.onyx"));
    CFPreferencesSetAppValue(CFSTR("Longitude"), (__bridge CFNumberRef)@(self.currentCoord.longitude), CFSTR("com.yzdmm.onyx"));
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFNumberRef)@(self.running), CFSTR("com.yzdmm.onyx"));
    CFPreferencesAppSynchronize(CFSTR("com.yzdmm.onyx"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
    [self saveRecent];
}

- (void)updateLabels {
    CLLocationCoordinate2D display = [ONYXCoordTransform convert:self.currentCoord fromSystem:OnyxCoordSystemWGS84 toSystem:self.currentSystem];
    self.latLabel.text = [NSString stringWithFormat:@"纬度  %.6f", display.latitude];
    self.lngLabel.text = [NSString stringWithFormat:@"经度  %.6f", display.longitude];
}

- (void)updateStatus {
    self.statusLabel.text = self.running ? @"状态：运行中" : @"状态：已停止";
    self.startButton.alpha = self.running ? 0.5 : 1.0;
    self.stopButton.alpha = self.running ? 1.0 : 0.5;
    [self refreshStatusPanel];
}

- (void)refreshStatusPanel {
    CFPropertyListRef arr = CFPreferencesCopyAppValue(CFSTR("SelectedApps"), CFSTR("com.yzdmm.onyx"));
    NSInteger count = 0;
    if (arr) {
        count = [(__bridge NSArray *)arr count];
        CFRelease(arr);
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *time = [fmt stringFromDate:[NSDate date]];
    [self.statusCard setStatusRunning:self.running selectedCount:count lastUpdated:time];
    self.mapStatLabel.text = self.running
        ? [NSString stringWithFormat:@"已启用 · %ld App", (long)count]
        : @"未启用";
}

- (void)placePinAt:(CLLocationCoordinate2D)coord {
    self.currentCoord = coord;
    [self pushCurrentToMap:14];
    [self.amapView setMarkerCoordinate:coord];
}

#pragma mark - Actions

- (void)systemChanged:(UISegmentedControl *)sender {
    self.currentSystem = (OnyxCoordSystem)sender.selectedSegmentIndex;
    [self updateLabels];
}

- (void)saveTapped:(UIButton *)sender {
    self.running = YES;
    [self saveState];
    BOOL ok = [[ONYXLocationSimulator sharedSimulator] startSimulationWithLatitude:self.currentCoord.latitude longitude:self.currentCoord.longitude];
    [self updateStatus];
    NSString *msg = ok
        ? @"系统级定位模拟已开启。所有使用系统定位的 App（包括百度/高德/微信等）都会收到此坐标。"
        : [NSString stringWithFormat:@"保存成功，但系统级定位模拟启动失败：%@。可能是 entitlement 未生效或 iOS 版本不支持。", [ONYXLocationSimulator sharedSimulator].lastError ?: @"未知错误"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存并应用" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyTapped:(UIButton *)sender {
    self.running = YES;
    [self saveState];
    [[ONYXLocationSimulator sharedSimulator] startSimulationWithLatitude:self.currentCoord.latitude longitude:self.currentCoord.longitude];
    [self updateStatus];
}

- (void)startTapped:(UIButton *)sender {
    self.running = YES;
    [self saveState];
    [[ONYXLocationSimulator sharedSimulator] startSimulationWithLatitude:self.currentCoord.latitude longitude:self.currentCoord.longitude];
    [self updateStatus];
}

- (void)stopTapped:(UIButton *)sender {
    self.running = NO;
    [self saveState];
    [[ONYXLocationSimulator sharedSimulator] stopSimulation];
    [self updateStatus];
}

- (void)openAppsList:(id)sender {
    ONYXAppsViewController *vc = [[ONYXAppsViewController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Search（CLGeocoder 正向/反向地理编码，走系统 locationd）

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *text = searchBar.text;
    if (!text.length) return;

    // 1) 先试坐标输入："lat,lng" 或 "lat lng"
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double lat = 0, lng = 0;
    BOOL coordInput = [scanner scanDouble:&lat] && lat >= -90 && lat <= 90;
    if (coordInput) {
        [scanner scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@", "] intoString:nil];
        coordInput = [scanner scanDouble:&lng] && lng >= -180 && lng <= 180;
        if (coordInput) {
            self.currentSystem = OnyxCoordSystemWGS84;
            self.systemControl.selectedSegmentIndex = 0;
            self.currentCoord = CLLocationCoordinate2DMake(lat, lng);
            [self updateLabels];
            [self placePinAt:self.currentCoord];
            [self reverseGeocode:self.currentCoord];
            return;
        }
    }

    self.addressLabel.text = @"正在搜索…";
    // 2) CLGeocoder 正向地理编码（Apple，国内可搜县级以上/知名地点）
    CLGeocoder *coder = [[CLGeocoder alloc] init];
    [coder geocodeAddressString:text completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        if (placemarks.count) {
            [self applyPlacemark:placemarks.firstObject name:text];
            return;
        }
        self.addressLabel.text = [NSString stringWithFormat:@"未找到「%@」，可改输 纬度,经度", text];
    }];
}

- (void)applyPlacemark:(CLPlacemark *)p name:(NSString *)name {
    self.currentCoord = p.location.coordinate;
    [self updateLabels];
    [self placePinAt:self.currentCoord];
    NSMutableArray *parts = [NSMutableArray array];
    if (p.locality) [parts addObject:p.locality];
    if (p.subLocality) [parts addObject:p.subLocality];
    if (p.thoroughfare) [parts addObject:p.thoroughfare];
    if (p.name) [parts addObject:p.name];
    self.addressLabel.text = [NSString stringWithFormat:@"当前：%@", parts.count ? [parts componentsJoinedByString:@" "] : name];
}

- (void)reverseGeocode:(CLLocationCoordinate2D)coord {
    CLGeocoder *coder = [[CLGeocoder alloc] init];
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
    [coder reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        if (placemarks.firstObject) {
            [self applyPlacemark:placemarks.firstObject name:[NSString stringWithFormat:@"%.4f, %.4f", coord.latitude, coord.longitude]];
        }
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    self.searchBar.text = textField.text;
    [self searchBarSearchButtonClicked:self.searchBar];
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 最近坐标

- (void)saveRecent {
    if (!CLLocationCoordinate2DIsValid(self.currentCoord)) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *recents = [[defaults objectForKey:kRecentCoordsKey] mutableCopy] ?: [NSMutableArray array];
    NSDictionary *entry = @{
        @"lat": @(self.currentCoord.latitude),
        @"lng": @(self.currentCoord.longitude),
        @"time": @([[NSDate date] timeIntervalSince1970])
    };
    // 去重：若已有相同坐标移到最前
    NSUInteger idx = [recents indexOfObjectPassingTest:^BOOL(id obj, NSUInteger i, BOOL *stop) {
        NSDictionary *d = obj;
        double la = [d[@"lat"] doubleValue];
        double ln = [d[@"lng"] doubleValue];
        return fabs(la - self.currentCoord.latitude) < 0.0001 && fabs(ln - self.currentCoord.longitude) < 0.0001;
    }];
    if (idx != NSNotFound) [recents removeObjectAtIndex:idx];
    [recents insertObject:entry atIndex:0];
    if (recents.count > 5) [recents removeObjectsInRange:NSMakeRange(5, recents.count - 5)];
    [defaults setObject:recents forKey:kRecentCoordsKey];
    [defaults synchronize];
    [self loadRecent];
}

- (void)loadRecent {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *recents = [defaults objectForKey:kRecentCoordsKey] ?: @[];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"无"];
    for (NSDictionary *d in recents) {
        double la = [d[@"lat"] doubleValue];
        double ln = [d[@"lng"] doubleValue];
        NSString *title = [NSString stringWithFormat:@"%.4f, %.4f", la, ln];
        [titles addObject:title];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.recentControl removeAllSegments];
        for (NSString *t in titles) {
            [self.recentControl insertSegmentWithTitle:t atIndex:self.recentControl.numberOfSegments animated:NO];
        }
        self.recentControl.selectedSegmentIndex = 0;
    });
}

- (void)recentChanged:(UISegmentedControl *)sender {
    NSInteger idx = sender.selectedSegmentIndex;
    if (idx <= 0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *recents = [defaults objectForKey:kRecentCoordsKey] ?: @[];
    if (idx - 1 < (NSInteger)recents.count) {
        NSDictionary *d = recents[idx - 1];
        double la = [d[@"lat"] doubleValue];
        double ln = [d[@"lng"] doubleValue];
        self.currentSystem = OnyxCoordSystemWGS84;
        self.systemControl.selectedSegmentIndex = 0;
        self.currentCoord = CLLocationCoordinate2DMake(la, ln);
        [self updateLabels];
        [self placePinAt:self.currentCoord];
        self.addressLabel.text = [NSString stringWithFormat:@"当前：最近坐标 %.6f, %.6f", la, ln];
    }
}

@end
