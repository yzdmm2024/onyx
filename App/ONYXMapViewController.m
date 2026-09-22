#import "ONYXMapViewController.h"
#import "ONYXCoordTransform.h"
#import "ONYXAppsViewController.h"
#import "ONYXMapView.h"
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

static NSString *const kDomain = @"com.yzdmm.onyx";

@interface ONYXMapViewController () <ONYXMapViewDelegate, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) ONYXMapView *mapView;
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
}

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

    // 原生地图视图：App 主进程 NSURLSession 平铺瓦片，绕开受限的 WebContent 子进程。
    self.mapView = [[ONYXMapView alloc] initWithFrame:CGRectZero];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    [self.view addSubview:self.mapView];

    // 缩放按钮
    UIButton *zin = [UIButton buttonWithType:UIButtonTypeSystem];
    zin.translatesAutoresizingMaskIntoConstraints = NO;
    [zin setTitle:@"＋" forState:UIControlStateNormal];
    zin.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
    [zin setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    zin.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    zin.layer.cornerRadius = 10;
    [zin addTarget:self action:@selector(zoomIn:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:zin];

    UIButton *zout = [UIButton buttonWithType:UIButtonTypeSystem];
    zout.translatesAutoresizingMaskIntoConstraints = NO;
    [zout setTitle:@"－" forState:UIControlStateNormal];
    zout.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
    [zout setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    zout.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    zout.layer.cornerRadius = 10;
    [zout addTarget:self action:@selector(zoomOut:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:zout];

    // 诊断标签（原生，始终可见，显示瓦片取图成功/失败）
    self.mapStatLabel = [[UILabel alloc] init];
    self.mapStatLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapStatLabel.font = [UIFont systemFontOfSize:12];
    self.mapStatLabel.textColor = [UIColor whiteColor];
    self.mapStatLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5];
    self.mapStatLabel.layer.cornerRadius = 7;
    self.mapStatLabel.clipsToBounds = YES;
    self.mapStatLabel.text = @"地图：加载中…";
    self.mapStatLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.mapStatLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.searchBar.heightAnchor constraintEqualToConstant:44],

        [self.mapView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.mapView.heightAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.5],
        [self.mapView.heightAnchor constraintGreaterThanOrEqualToConstant:240],

        [zin.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:-12],
        [zin.topAnchor constraintEqualToAnchor:self.mapView.topAnchor constant:14],
        [zin.widthAnchor constraintEqualToConstant:40],
        [zin.heightAnchor constraintEqualToConstant:40],
        [zout.trailingAnchor constraintEqualToAnchor:self.mapView.trailingAnchor constant:-12],
        [zout.topAnchor constraintEqualToAnchor:zin.bottomAnchor constant:8],
        [zout.widthAnchor constraintEqualToConstant:40],
        [zout.heightAnchor constraintEqualToConstant:40],

        [self.mapStatLabel.leadingAnchor constraintEqualToAnchor:self.mapView.leadingAnchor constant:10],
        [self.mapStatLabel.bottomAnchor constraintEqualToAnchor:self.mapView.bottomAnchor constant:-10],
        [self.mapStatLabel.widthAnchor constraintEqualToConstant:170],
        [self.mapStatLabel.heightAnchor constraintEqualToConstant:24]
    ]];
}

- (void)zoomIn:(id)sender { [self.mapView zoomIn]; }
- (void)zoomOut:(id)sender { [self.mapView zoomOut]; }

- (void)setupSheet {
    self.sheet = [[UIScrollView alloc] init];
    self.sheet.translatesAutoresizingMaskIntoConstraints = NO;
    self.sheet.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.sheet];

    self.sheetContent = [[UIView alloc] init];
    self.sheetContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sheet addSubview:self.sheetContent];

    [NSLayoutConstraint activateConstraints:@[
        [self.sheet.topAnchor constraintEqualToAnchor:self.mapView.bottomAnchor],
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

#pragma mark - ONYXMapViewDelegate

- (void)onyxMapViewDidPickCoordinate:(CLLocationCoordinate2D)coord {
    // 回传的是高德(GCJ-02)坐标，转回 WGS-84 存内部
    CLLocationCoordinate2D wgs = [ONYXCoordTransform convert:coord fromSystem:OnyxCoordSystemGCJ02 toSystem:OnyxCoordSystemWGS84];
    self.currentCoord = wgs;
    [self updateLabels];
    [self reverseGeocode:wgs];
}

- (void)onyxMapViewDidUpdateStats:(NSString *)stats {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.mapStatLabel.text = [@"地图：" stringByAppendingString:stats ?: @""];
    });
}

- (void)onyxMapViewDidFailWithError:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"地图瓦片加载失败"
            message:[NSString stringWithFormat:@"%@\n\n多为：App 直接联网被沙箱限制（缺 network.client 授权）或设备无外网。高德与 OSM 两条源均已尝试失败。", error ?: @""]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

// 把内部 WGS-84 坐标推到原生地图（底图是高德 GCJ-02）
- (void)pushCurrentToMap:(NSInteger)zoom {
    CLLocationCoordinate2D gcj = [ONYXCoordTransform convert:self.currentCoord fromSystem:OnyxCoordSystemWGS84 toSystem:OnyxCoordSystemGCJ02];
    [self.mapView setCenterCoordinate:gcj zoom:zoom showMarker:YES];
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
    [self updateStatus];
}

- (void)saveState {
    CFPreferencesSetAppValue(CFSTR("Latitude"), (__bridge CFNumberRef)@(self.currentCoord.latitude), CFSTR("com.yzdmm.onyx"));
    CFPreferencesSetAppValue(CFSTR("Longitude"), (__bridge CFNumberRef)@(self.currentCoord.longitude), CFSTR("com.yzdmm.onyx"));
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFNumberRef)@(self.running), CFSTR("com.yzdmm.onyx"));
    CFPreferencesAppSynchronize(CFSTR("com.yzdmm.onyx"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
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
}

- (void)placePinAt:(CLLocationCoordinate2D)coord {
    self.currentCoord = coord;
    [self pushCurrentToMap:14];
}

#pragma mark - Actions

- (void)systemChanged:(UISegmentedControl *)sender {
    self.currentSystem = (OnyxCoordSystem)sender.selectedSegmentIndex;
    [self updateLabels];
}

- (void)saveTapped:(UIButton *)sender {
    [self saveState];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存" message:@"坐标已保存并通知 Tweak 生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyTapped:(UIButton *)sender {
    self.running = YES;
    [self saveState];
    [self updateStatus];
}

- (void)startTapped:(UIButton *)sender {
    self.running = YES;
    [self saveState];
    [self updateStatus];
}

- (void)stopTapped:(UIButton *)sender {
    self.running = NO;
    [self saveState];
    [self updateStatus];
}

- (void)openAppsList:(id)sender {
    ONYXAppsViewController *vc = [[ONYXAppsViewController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Search（CLGeocoder 优先，MKLocalSearch 兜底，覆盖中国区）

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
        // 3) 兜底 MKLocalSearch（周边/英文更稳）
        MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
        req.naturalLanguageQuery = text;
        req.region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(35.0, 105.0), 5000000, 5000000);
        MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:req];
        [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *err2) {
            if (response.mapItems.count) {
                MKMapItem *item = response.mapItems.firstObject;
                self.currentCoord = item.placemark.coordinate;
                [self updateLabels];
                [self placePinAt:self.currentCoord];
                self.addressLabel.text = [NSString stringWithFormat:@"当前：%@", item.name ?: text];
            } else {
                self.addressLabel.text = [NSString stringWithFormat:@"未找到「%@」，可改输 纬度,经度", text];
            }
        }];
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

@end
