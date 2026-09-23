#import "ONYXActiveAppsViewController.h"
#import "ONYXAppsViewController.h"

@interface ONYXAAAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *bundleLabel;
@end

@implementation ONYXAAAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 10;
        _iconView.layer.masksToBounds = YES;
        _iconView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        [self.contentView addSubview:_nameLabel];

        _bundleLabel = [[UILabel alloc] init];
        _bundleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _bundleLabel.font = [UIFont systemFontOfSize:12];
        _bundleLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_bundleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:44],
            [_iconView.heightAnchor constraintEqualToConstant:44],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:14],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],

            [_bundleLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_bundleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_bundleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
            [_bundleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

@end

@interface ONYXActiveAppsViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSMutableArray<NSString *> *selected;
@end

@implementation ONYXActiveAppsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行中的应用";
    self.tableView.rowHeight = 68;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 74, 0, 0);
    [self.tableView registerClass:[ONYXAAAppCell class] forCellReuseIdentifier:@"aa"];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                               style:UIBarButtonItemStyleDone
                                                                              target:self
                                                                              action:@selector(doneTapped:)];

    [self loadSelected];
    // 监听 SelectedApps 变化，若从外部移除则同步刷新
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(prefsChanged:)
                                                 name:@"com.yzdmm.onyx/changed"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)prefsChanged:(NSNotification *)note {
    if ([note.name isEqualToString:@"com.yzdmm.onyx/changed"]) {
        [self loadSelected];
    }
}

- (void)loadSelected {
    NSArray *all = [self.class allApplications];
    CFPropertyListRef arr = CFPreferencesCopyValue(CFSTR("SelectedApps"), CFSTR("com.yzdmm.onyx"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSArray *bids = nil;
    if (arr) {
        bids = (__bridge NSArray *)arr;
        CFRelease(arr);
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *bid in bids) {
        NSDictionary *match = nil;
        for (NSDictionary *app in all) {
            if ([app[@"bid"] isEqualToString:bid]) { match = app; break; }
        }
        if (match) {
            [ordered addObject:@{
                @"bid": bid,
                @"name": match[@"name"] ?: bid
            }];
        } else {
            [ordered addObject:@{ @"bid": bid, @"name": bid }];
        }
    }
    self.selected = [bids mutableCopy] ?: [NSMutableArray array];
    self.apps = ordered;
    [self.tableView reloadData];
}

+ (NSArray<NSDictionary *> *)allApplications {
    return [ONYXAppsViewController allApplications];
}

#pragma mark - Data Source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ONYXAAAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"aa" forIndexPath:indexPath];
    NSDictionary *app = self.apps[indexPath.row];
    NSString *bid = app[@"bid"];
    NSString *name = app[@"name"];
    cell.nameLabel.text = name;
    cell.bundleLabel.text = bid;

    UIImage *icon = [ONYXAppsViewController iconForBundleIdentifier:bid];
    if (!icon) icon = [ONYXAppsViewController placeholderIconForName:name];
    cell.iconView.image = icon;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"移除"
                                                                       handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self removeAppAtIndex:indexPath.row];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

- (void)removeAppAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.selected.count) return;
    NSString *bid = self.selected[index];
    [self.selected removeObjectAtIndex:index];

    CFStringRef domain = CFSTR("com.yzdmm.onyx");
    CFPreferencesSetValue(CFSTR("SelectedApps"), (__bridge CFArrayRef)[self.selected copy], domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);

    if (self.onRemove) self.onRemove();
}

- (void)doneTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end