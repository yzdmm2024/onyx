#import "ONYXMapViewController.h"
#import "ONYXCoordTransform.h"
#import "ONYXAppsViewController.h"
#import "ONYXTileSchemeHandler.h"
#import <WebKit/WebKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

static NSString *const kDomain = @"com.yzdmm.onyx";

@interface ONYXMapViewController () <WKScriptMessageHandler, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) WKWebView *webView;
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

    // 用 WKWebView + 高德栅格瓦片渲染地图。
    // 原因：MKMapView 加载瓦片需要 com.apple.mapkit 授权，adhoc/TrollStore 签名的 App 没有，
    // 瓦片请求会被拒（灰块）。网页地图只走普通 HTTPS 图片，无需该授权，自带中文标注。
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    [cfg.userContentController addScriptMessageHandler:self name:@"onyx"];
    // 瓦片走 onyx:// 自定义 scheme，由 App 原生 NSURLSession 取高德图回灌，
    // 彻底绕过 file:// 跨域 / ATS / WebContent 进程网络限制。
    [cfg setURLSchemeHandler:[[ONYXTileSchemeHandler alloc] init] forURLScheme:@"onyx"];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.scrollView.scrollEnabled = NO;
    self.webView.backgroundColor = [UIColor colorWithRed:0.68 green:0.85 blue:1.0 alpha:1.0];
    self.webView.opaque = NO;
    // iOS 16.4+ 允许 Mac Safari → 开发 → iPhone 远程调试此 WKWebView
    // 注意：theos 用的是 14.5 SDK，无 inspectable 属性声明，故用 selector 调用避免编译错误
    if (@available(iOS 16.4, *)) {
        SEL insp = NSSelectorFromString(@"setInspectable:");
        if ([self.webView respondsToSelector:insp]) {
            NSMethodSignature *sig = [self.webView methodSignatureForSelector:insp];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:insp];
            [inv setTarget:self.webView];
            BOOL yes = YES;
            [inv setArgument:&yes atIndex:2];
            [inv invoke];
        }
    }
    [self.view addSubview:self.webView];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"map" ofType:@"html"];
    if (htmlPath) {
        NSURL *url = [NSURL fileURLWithPath:htmlPath];
        NSURL *dir = [NSURL fileURLWithPath:[[NSBundle mainBundle] resourcePath] isDirectory:YES];
        [self.webView loadFileURL:url allowingReadAccessToURL:dir];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.searchBar.heightAnchor constraintEqualToConstant:44],

        [self.webView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.heightAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.5],
        [self.webView.heightAnchor constraintGreaterThanOrEqualToConstant:240]
    ]];
}

- (void)setupSheet {
    self.sheet = [[UIScrollView alloc] init];
    self.sheet.translatesAutoresizingMaskIntoConstraints = NO;
    self.sheet.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.sheet];

    self.sheetContent = [[UIView alloc] init];
    self.sheetContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sheet addSubview:self.sheetContent];

    [NSLayoutConstraint activateConstraints:@[
        [self.sheet.topAnchor constraintEqualToAnchor:self.webView.bottomAnchor],
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

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"onyx"]) return;
    NSDictionary *d = message.body;
    NSString *type = d[@"type"];
    if ([type isEqualToString:@"diag"]) {
        NSString *msg = d[@"msg"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.addressLabel.text = [@"地图诊断：" stringByAppendingString:msg ?: @""];
        });
        return;
    }
    if ([type isEqualToString:@"ready"]) {
        [self pushCurrentToMap:11];
        return;
    }
    if ([type isEqualToString:@"tap"]) {
        // JS 回传的是高德(GCJ-02)坐标，转回 WGS-84 存内部
        double lng = [d[@"lng"] doubleValue];
        double lat = [d[@"lat"] doubleValue];
        CLLocationCoordinate2D gcj = CLLocationCoordinate2DMake(lat, lng);
        CLLocationCoordinate2D wgs = [ONYXCoordTransform convert:gcj fromSystem:OnyxCoordSystemGCJ02 toSystem:OnyxCoordSystemWGS84];
        self.currentCoord = wgs;
        [self updateLabels];
        [self reverseGeocode:wgs];
    }
}

// 把内部 WGS-84 坐标推到网页地图（网页底图是高德 GCJ-02）
- (void)pushCurrentToMap:(NSInteger)zoom {
    CLLocationCoordinate2D gcj = [ONYXCoordTransform convert:self.currentCoord fromSystem:OnyxCoordSystemWGS84 toSystem:OnyxCoordSystemGCJ02];
    NSString *js = [NSString stringWithFormat:@"onyxSet(%@,%@,%ld,true)", @(gcj.longitude), @(gcj.latitude), (long)zoom];
    [self.webView evaluateJavaScript:js completionHandler:nil];
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

- (void)dealloc {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"onyx"];
}

@end
