#import "ONYXAMapView.h"
#import "ONYXCoordTransform.h"
#import <WebKit/WebKit.h>

static NSString *const kAMapKey = @"5357b002dca4cb8dd1046539e3cae85a";
static NSString *const kHandlerName = @"onyx";

@interface ONYXAMapView () <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation ONYXAMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _loaded = NO;
        [self setupWebView];
        [self setupOverlay];
        [self loadMapHTML];
    }
    return self;
}

- (void)setupWebView {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    WKUserContentController *uc = cfg.userContentController;
    [uc addScriptMessageHandler:self name:kHandlerName];

    _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:cfg];
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.navigationDelegate = self;
    _webView.backgroundColor = [UIColor colorWithRed:0.92 green:0.94 blue:0.97 alpha:1.0];
    _webView.opaque = NO;
    [self addSubview:_webView];

    [NSLayoutConstraint activateConstraints:@[
        [_webView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];
}

- (void)setupOverlay {
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.textColor = [UIColor labelColor];
    _statusLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    _statusLabel.layer.cornerRadius = 6;
    _statusLabel.clipsToBounds = YES;
    _statusLabel.text = @"地图加载中…";
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_statusLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton setTitle:@"重新加载地图" forState:UIControlStateNormal];
    [_retryButton addTarget:self action:@selector(retryTapped:) forControlEvents:UIControlEventTouchUpInside];
    _retryButton.hidden = YES;
    [self addSubview:_retryButton];

    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
        [_statusLabel.widthAnchor constraintEqualToConstant:120],
        [_statusLabel.heightAnchor constraintEqualToConstant:24],

        [_retryButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_retryButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];
}

- (void)loadMapHTML {
    NSURL *htmlURL = [[NSBundle mainBundle] URLForResource:@"amap" withExtension:@"html"];
    if (!htmlURL) {
        [self fail:@"本地地图资源缺失（amap.html）"];
        return;
    }
    NSString *html = [NSString stringWithContentsOfURL:htmlURL encoding:NSUTF8StringEncoding error:nil];
    if (!html) {
        [self fail:@"地图资源读取失败"];
        return;
    }
    html = [html stringByReplacingOccurrencesOfString:@"__AMAP_KEY__" withString:kAMapKey];
    NSURL *baseURL = [htmlURL URLByDeletingLastPathComponent];
    [_webView loadHTMLString:html baseURL:baseURL];
}

- (void)retryTapped:(UIButton *)sender {
    _retryButton.hidden = YES;
    _statusLabel.text = @"地图加载中…";
    [self loadMapHTML];
}

- (void)fail:(NSString *)msg {
    _statusLabel.text = msg;
    _retryButton.hidden = NO;
    _loaded = NO;
    if ([self.delegate respondsToSelector:@selector(amapView:didFailWithError:)]) {
        [self.delegate amapView:self didFailWithError:msg];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    _statusLabel.text = @"地图就绪";
    _loaded = YES;
    if ([self.delegate respondsToSelector:@selector(amapView:didUpdateStatus:)]) {
        [self.delegate amapView:self didUpdateStatus:@"地图已加载"];
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self fail:[NSString stringWithFormat:@"地图加载失败: %@", error.localizedDescription]];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self fail:[NSString stringWithFormat:@"地图初始化失败: %@", error.localizedDescription]];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kHandlerName]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"tap"]) {
        double lat = [body[@"lat"] doubleValue];
        double lng = [body[@"lng"] doubleValue];
        CLLocationCoordinate2D gcj = CLLocationCoordinate2DMake(lat, lng);
        CLLocationCoordinate2D wgs = [ONYXCoordTransform wgs84FromGcj02:gcj];
        if ([self.delegate respondsToSelector:@selector(amapView:didPickCoordinate:)]) {
            [self.delegate amapView:self didPickCoordinate:wgs];
        }
    } else if ([type isEqualToString:@"log"]) {
        NSString *txt = body[@"text"];
        NSLog(@"[OnyxAMapJS] %@", txt);
    } else if ([type isEqualToString:@"error"]) {
        [self fail:body[@"text"] ?: @"地图脚本错误"];
    }
}

#pragma mark - public

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    if (!_loaded || !CLLocationCoordinate2DIsValid(coord)) return;
    CLLocationCoordinate2D gcj = [ONYXCoordTransform gcj02FromWgs84:coord];
    NSString *script = [NSString stringWithFormat:@"setCenter(%.6f, %.6f, %ld, %@);",
                          gcj.longitude, gcj.latitude, (long)zoom, showMarker ? @"true" : @"false"];
    [_webView evaluateJavaScript:script completionHandler:nil];
}

- (void)setMarkerCoordinate:(CLLocationCoordinate2D)coord {
    if (!_loaded || !CLLocationCoordinate2DIsValid(coord)) return;
    CLLocationCoordinate2D gcj = [ONYXCoordTransform gcj02FromWgs84:coord];
    NSString *script = [NSString stringWithFormat:@"setMarker(%.6f, %.6f);", gcj.longitude, gcj.latitude];
    [_webView evaluateJavaScript:script completionHandler:nil];
}

- (void)zoomIn { [_webView evaluateJavaScript:@"zoomIn()" completionHandler:nil]; }
- (void)zoomOut { [_webView evaluateJavaScript:@"zoomOut()" completionHandler:nil]; }

- (void)dealloc {
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:kHandlerName];
}

@end
