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
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.masksToBounds = YES;
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

@interface ONYXAppsViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
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
                @"name": name ?: bid,
                @"system": @([[bid pathExtension] isEqualToString:@""]) // rough heuristic, not used
            }];
        }
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedStandardCompare:)]]];
        cached = [out copy];
    });
    return cached;
}

+ (UIImage *)iconForBundleIdentifier:(NSString *)bid {
    if (!bid.length) return nil;
    // Use LSApplicationProxy's iconDataForVariant: -> UIImage to avoid linker issues.
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSApplicationProxy) return nil;
    id proxy = [LSApplicationProxy applicationProxyForIdentifier:bid];
    if (!proxy) return nil;
    NSData *data = nil;
    if ([proxy respondsToSelector:@selector(iconDataForVariant:)]) {
        data = [proxy iconDataForVariant:2]; // 2 = default icon variant
    }
    if (!data && [proxy respondsToSelector:@selector(iconDataForVariant:withOptions:)]) {
        data = [proxy iconDataForVariant:2 withOptions:0];
    }
    if (data) {
        UIImage *img = [UIImage imageWithData:data];
        if (img) return img;
    }
    // Fallback: try iconImageForDescription: if available.
    if ([proxy respondsToSelector:@selector(iconImageForDescription:)]) {
        return [proxy iconImageForDescription:nil];
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"支持的应用";
    self.tableView.rowHeight = 64;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 70, 0, 0);
    [self.tableView registerClass:[ONYXAppCell class] forCellReuseIdentifier:@"app"];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(doneTapped:)];

    self.apps = [[self class] allApplications];
    self.selected = [NSMutableSet setWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedApps"] ?: @[]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ONYXAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app" forIndexPath:indexPath];
    NSDictionary *app = self.apps[indexPath.row];
    NSString *bid = app[@"bid"];
    cell.nameLabel.text = app[@"name"];
    cell.bundleLabel.text = bid;
    cell.iconView.image = [[self class] iconForBundleIdentifier:bid];
    cell.sw.on = [self.selected containsObject:bid];
    cell.sw.tag = indexPath.row;
    [cell.sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSDictionary *app = self.apps[sender.tag];
    NSString *bid = app[@"bid"];
    if (sender.on) [self.selected addObject:bid];
    else [self.selected removeObject:bid];
    [self saveSelected];
}

- (void)saveSelected {
    CFPreferencesSetAppValue(CFSTR("SelectedApps"), (__bridge CFArrayRef)[self.selected allObjects], CFSTR("com.yzdmm.onyx"));
    CFPreferencesAppSynchronize(CFSTR("com.yzdmm.onyx"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
}

- (void)doneTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
