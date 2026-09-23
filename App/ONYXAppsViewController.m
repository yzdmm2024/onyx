#import "ONYXAppsViewController.h"
#import <objc/runtime.h>

static NSString *const kDomain = @"com.yzdmm.onyx";

@interface ONYXAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *bundleLabel;
@property (nonatomic, strong) UISwitch *sw;
@end

@implementation ONYXAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 9;
        _iconView.layer.masksToBounds = YES;
        _iconView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        [self.contentView addSubview:_nameLabel];

        _bundleLabel = [[UILabel alloc] init];
        _bundleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _bundleLabel.font = [UIFont systemFontOfSize:12];
        _bundleLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_bundleLabel];

        _sw = [[UISwitch alloc] init];
        _sw.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_sw];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:40],
            [_iconView.heightAnchor constraintEqualToConstant:40],

            [_sw.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_sw.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:14],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sw.leadingAnchor constant:-12],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],

            [_bundleLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_bundleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sw.leadingAnchor constant:-12],
            [_bundleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
            [_bundleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-11]
        ]];
    }
    return self;
}

@end

#pragma mark - Search helper

@interface ONYXAppsViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, assign) BOOL isSearching;
@end

@implementation ONYXAppsViewController

+ (NSArray<NSDictionary *> *)allApplications {
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class ws = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = [ws performSelector:@selector(defaultWorkspace)];
        NSArray *proxies = [workspace performSelector:@selector(allApplications)];
        NSMutableArray *out = [NSMutableArray array];
        for (id proxy in proxies) {
            NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
            NSString *name = [proxy performSelector:@selector(localizedName)];
            if (!bid.length) continue;
            [out addObject:@{
                @"bid": bid,
                @"name": name ?: bid
            }];
        }
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedStandardCompare:)]]];
        cached = [out copy];
    });
    return cached;
}

+ (UIImage *)iconForBundleIdentifier:(NSString *)bid {
    if (!bid.length) return nil;
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSApplicationProxy) return nil;
    id proxy = [LSApplicationProxy performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bid];
    if (!proxy) return nil;

    // 多尝试几个 variant/options，不同 iOS 版本/系统应用/用户应用接口不同
    NSData *data = nil;
    struct { int variant; int options; } combos[] = {
        {2, 0}, {0, 0}, {1, 0}, {4, 0}, {6, 0}, {7, 0}, {8, 0},
        {2, 1}, {0, 1}, {6, 1}, {7, 1}, {8, 1},
    };
    for (NSUInteger i = 0; i < sizeof(combos)/sizeof(combos[0]); i++) {
        if ([proxy respondsToSelector:NSSelectorFromString(@"iconDataForVariant:withOptions:")]) {
            data = [proxy performSelector:NSSelectorFromString(@"iconDataForVariant:withOptions:")
                               withObject:@(combos[i].variant) withObject:@(combos[i].options)];
        } else if ([proxy respondsToSelector:NSSelectorFromString(@"iconDataForVariant:")]) {
            data = [proxy performSelector:NSSelectorFromString(@"iconDataForVariant:")
                               withObject:@(combos[i].variant)];
        }
        if ([data isKindOfClass:[NSData class]] && data.length) break;
    }
    if (data && [data isKindOfClass:[NSData class]]) {
        UIImage *img = [UIImage imageWithData:data];
        if (img) return img;
    }
    if ([proxy respondsToSelector:NSSelectorFromString(@"iconImageForDescription:")]) {
        id img = [proxy performSelector:NSSelectorFromString(@"iconImageForDescription:") withObject:nil];
        if ([img isKindOfClass:[UIImage class]]) return img;
    }
    return nil;
}

+ (UIImage *)placeholderIconForName:(NSString *)name {
    CGFloat s = 40;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    [[UIColor colorWithWhite:0.9 alpha:1] setFill];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:9];
    [path fill];
    NSString *letter = @"";
    if (name.length) letter = [name substringToIndex:1].uppercaseString;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor grayColor]
    };
    CGSize ts = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:CGPointMake((s - ts.width)/2, (s - ts.height)/2) withAttributes:attrs];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择应用";
    self.tableView.rowHeight = 64;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 70, 0, 0);
    [self.tableView registerClass:[ONYXAppCell class] forCellReuseIdentifier:@"app"];

    // 搜索
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索应用名或 bundle id";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // 导航按钮：清除 / 完成
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清除"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(clearTapped:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                               style:UIBarButtonItemStyleDone
                                                                              target:self
                                                                              action:@selector(doneTapped:)];

    self.apps = [[self class] allApplications];
    self.filteredApps = self.apps;

    // 关键修复：和 saveSelected 一样从 CFPreferences 读，而不是 NSUserDefaults
    CFPropertyListRef arr = CFPreferencesCopyValue(CFSTR("SelectedApps"), CFSTR("com.yzdmm.onyx"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (arr) {
        self.selected = [NSMutableSet setWithArray:(__bridge NSArray *)arr];
        CFRelease(arr);
    } else {
        self.selected = [NSMutableSet set];
    }
}

#pragma mark - data source

- (NSArray<NSDictionary *> *)currentApps {
    return self.isSearching ? self.filteredApps : self.apps;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentApps].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ONYXAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app" forIndexPath:indexPath];
    NSDictionary *app = [self currentApps][indexPath.row];
    NSString *bid = app[@"bid"];
    NSString *name = app[@"name"];
    cell.nameLabel.text = name;
    cell.bundleLabel.text = bid;

    UIImage *icon = [[self class] iconForBundleIdentifier:bid];
    if (!icon) icon = [[self class] placeholderIconForName:name];
    cell.iconView.image = icon;

    cell.sw.on = [self.selected containsObject:bid];
    cell.sw.tag = indexPath.row;
    [cell.sw removeTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [cell.sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSArray *list = [self currentApps];
    if (sender.tag >= (NSInteger)list.count) return;
    NSDictionary *app = list[sender.tag];
    NSString *bid = app[@"bid"];
    if (sender.on) [self.selected addObject:bid];
    else [self.selected removeObject:bid];
    [self saveSelected];
}

- (void)saveSelected {
    CFStringRef domain = CFSTR("com.yzdmm.onyx");
    CFPreferencesSetValue(CFSTR("SelectedApps"), (__bridge CFArrayRef)[self.selected allObjects], domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
}

- (void)clearTapped:(id)sender {
    if (self.selected.count == 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除选择"
                                                                   message:@"确定清空所有已选应用？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self.selected removeAllObjects];
        [self saveSelected];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)doneTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text ?: @"";
    text = [text lowercaseString];
    if (!text.length) {
        self.isSearching = NO;
        self.filteredApps = self.apps;
    } else {
        self.isSearching = YES;
        self.filteredApps = [self.apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary *bindings) {
            NSDictionary *app = obj;
            NSString *name = [app[@"name"] lowercaseString];
            NSString *bid = [app[@"bid"] lowercaseString];
            return [name containsString:text] || [bid containsString:text];
        }]];
    }
    [self.tableView reloadData];
}

@end
