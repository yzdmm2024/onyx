// OnyxSettingsController.m — 设置面板主控制器 + 自定义应用行 cell
// 路径：设置 → Onyx。总开关 + 参数 X/Y + 按 App 开关（显示名 + bundle id，总开关关时整组置灰）。
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

static NSString *const kDomain  = @"com.yzdmm.onyx";
static NSString *const kChanged = @"com.yzdmm.onyx/changed";

// 应用清单：显示名(n) + bundle id(b)。必须与根目录 Onyx.plist 的 Filter Bundles 保持一致！
static NSArray *kAppList(void) {
    return @[
        @{@"n":@"地图",      @"b":@"com.apple.Maps"},
        @{@"n":@"天气",      @"b":@"com.apple.weather"},
        @{@"n":@"查找",      @"b":@"com.apple.findmy.findmyapp"},
        @{@"n":@"提醒事项",  @"b":@"com.apple.reminders"},
        @{@"n":@"日历",      @"b":@"com.apple.mobilecal"},
        @{@"n":@"照片",      @"b":@"com.apple.mobileslideshow"},
        @{@"n":@"Safari",    @"b":@"com.apple.mobilesafari"},
        @{@"n":@"相机",      @"b":@"com.apple.camera"},
        @{@"n":@"信息",      @"b":@"com.apple.MobileSMS"},
        @{@"n":@"邮件",      @"b":@"com.apple.mobilemail"},
        @{@"n":@"微信",      @"b":@"com.tencent.xin"},
        @{@"n":@"QQ",        @"b":@"com.tencent.mqq"},
        @{@"n":@"高德地图",  @"b":@"com.autonavi.amap"},
        @{@"n":@"百度地图",  @"b":@"com.baidu.BaiduMap"},
        @{@"n":@"滴滴出行",  @"b":@"com.sdu.didi.psnger"},
        @{@"n":@"美团",      @"b":@"com.meituan.imeituan"},
        @{@"n":@"大众点评",  @"b":@"com.dianping.dpscope"},
        @{@"n":@"抖音",      @"b":@"com.ss.iphone.ugc.Aweme"},
        @{@"n":@"快手",      @"b":@"com.smile.gifmaker"},
        @{@"n":@"小红书",    @"b":@"com.xingin.xhs"},
        @{@"n":@"微博",      @"b":@"com.sina.weibo"},
        @{@"n":@"支付宝",    @"b":@"com.alipay.iphoneclient"},
        @{@"n":@"淘宝",      @"b":@"com.taobao.taobao4iphone"},
        @{@"n":@"京东",      @"b":@"com.jingdong.app.mall"},
        @{@"n":@"钉钉",      @"b":@"com.laiwang.DingTalk"},
        @{@"n":@"哔哩哔哩",  @"b":@"tv.danmaku.bili"},
        @{@"n":@"百度",      @"b":@"com.baidu.BaiduMobile"},
    ];
}

#pragma mark - 自定义应用行 cell（显示名 + bundle id + 开关，宽松排版，总开关关时置灰）

@interface OnyxAppCell : PSTableCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UISwitch *sw;
@end

@implementation OnyxAppCell

- (id)initWithStyle:(int)style reuseIdentifier:(NSString *)rid specifier:(PSSpecifier *)spec {
    self = [super initWithStyle:style reuseIdentifier:rid specifier:spec];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:17];
        _titleLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabel];
        _subLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subLabel.font = [UIFont systemFontOfSize:12];
        _subLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_subLabel];
        _sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        [_sw addTarget:self action:@selector(_onToggle) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _sw;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect r = self.contentView.bounds;
    CGFloat left = 16, w = r.size.width - left - 16;
    _titleLabel.frame = CGRectMake(left, 10, w, 22);   // 第一行：显示名
    _subLabel.frame  = CGRectMake(left, 34, w, 18);    // 第二行：bundle id，宽松不紧凑
}

- (void)setSpecifier:(PSSpecifier *)spec {
    [super setSpecifier:spec];
    _titleLabel.text = [spec propertyForKey:@"displayName"] ?: @"";
    _subLabel.text   = [spec propertyForKey:@"bundleId"] ?: @"";
    _sw.on = [self _readBool:[spec propertyForKey:@"key"]];
    id e = [spec propertyForKey:@"enabled"];
    BOOL on = e ? [e boolValue] : YES;
    self.userInteractionEnabled = on;
    _sw.enabled = on;
    self.contentView.alpha = on ? 1.0 : 0.4;   // 总开关关 -> 整行置灰
}

- (BOOL)_readBool:(NSString *)key {
    if (!key.length) return NO;
    id v = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] objectForKey:key];
    if (!v) {
        CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain);
        if (cv) v = CFBridgingRelease(cv);
    }
    return v ? [v boolValue] : NO;
}

- (void)_onToggle {
    NSString *key = [self.specifier propertyForKey:@"key"];
    if (!key.length) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:@(_sw.on) forKey:key]; [d synchronize];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(_sw.on), (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kChanged, NULL, NULL, true);
}

@end

#pragma mark - 主控制器

@interface OnyxSettingsController : PSListController
@end

@implementation OnyxSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        for (NSDictionary *a in kAppList()) {
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:a[@"n"]
                                                         target:self set:NULL get:NULL
                                                        detail:nil cell:[OnyxAppCell class]
                                                        edit:NULL];
            [s setProperty:a[@"n"] forKey:@"displayName"];
            [s setProperty:a[@"b"] forKey:@"bundleId"];
            [s setProperty:a[@"b"] forKey:@"key"];   // 开关 key = bundle id（与 tweak 侧读取一致）
            [s setProperty:@YES forKey:@"enabled"];
            [_specifiers addObject:s];
        }
    }
    return _specifiers;
}

// 跨进程读写 domain（tweak 侧用同一 domain 读取）
- (id)readPreferenceValue:(PSSpecifier *)sp {
    NSString *k = [sp propertyForKey:@"key"];
    if (!k.length) return nil;
    id v = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] objectForKey:k];
    if (!v) {
        CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)kDomain);
        if (cv) v = CFBridgingRelease(cv);
    }
    return v ?: [sp propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)sp {
    NSString *k = [sp propertyForKey:@"key"];
    if (!k.length) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [d setObject:value forKey:k]; [d synchronize];
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kChanged, NULL, NULL, true);
    if ([k isEqualToString:@"enabled"]) [self _refreshAppEnabled:[value boolValue]];
}

- (void)_refreshAppEnabled:(BOOL)on {
    for (PSSpecifier *s in _specifiers) {
        if ([[s propertyForKey:@"bundleId"] length]) [s setProperty:@(on) forKey:@"enabled"];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self respondsToSelector:@selector(reloadData)]) [(UITableView *)self.view reloadData];
    });
}

@end
