#import "ONYXHistoryViewController.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kHistoryRecentKey = @"com.yzdmm.onyx.recentCoords";

@interface ONYXHistoryViewController ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@end

@implementation ONYXHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(doneTapped)];
    [self loadRecents];
    [self setupMemorySwitch];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)loadRecents {
    NSArray *a = [[NSUserDefaults standardUserDefaults] objectForKey:kHistoryRecentKey] ?: @[];
    _recents = [NSMutableArray arrayWithArray:a];
    [self.tableView reloadData];
}

#pragma mark - 记忆功能开关

- (void)setupMemorySwitch {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 64)];
    footer.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UILabel *lab = [[UILabel alloc] init];
    lab.text = @"记忆功能（开启后下次打开自动恢复上次定位）";
    lab.font = [UIFont systemFontOfSize:14];
    lab.numberOfLines = 0;
    lab.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:lab];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.onTintColor = [UIColor systemBlueColor]; // 开启为蓝色，关闭为灰色
    CFPropertyListRef mem = CFPreferencesCopyAppValue(CFSTR("MemoryEnabled"), CFSTR("com.yzdmm.onyx"));
    sw.on = mem ? [(__bridge NSNumber *)mem boolValue] : YES;
    if (mem) CFRelease(mem);
    [sw addTarget:self action:@selector(memorySwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [footer addSubview:sw];

    [lab setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [lab.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [lab.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-12],
        [lab.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16],
        [sw.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    ]];

    self.tableView.tableFooterView = footer;
}

- (void)memorySwitchChanged:(UISwitch *)sw {
    CFPreferencesSetAppValue(CFSTR("MemoryEnabled"), (__bridge CFNumberRef)@(sw.on), CFSTR("com.yzdmm.onyx"));
    CFPreferencesAppSynchronize(CFSTR("com.yzdmm.onyx"));
    // 立即应用：开启=恢复上次模拟状态；关闭=停止模拟（下次进入也停）
    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.yzdmm.onyx"));
    BOOL running = sw.on && en ? [(__bridge NSNumber *)en boolValue] : NO;
    if (en) CFRelease(en);
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFNumberRef)@(running), CFSTR("com.yzdmm.onyx"));
    CFPreferencesAppSynchronize(CFSTR("com.yzdmm.onyx"));
    // 让 Tweak（各 App 进程）立即生效
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
    // 通知 MapVC 刷新界面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OnyxMemoryChanged" object:nil];
}

#pragma mark - dataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.recents.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    NSDictionary *d = self.recents[indexPath.row];
    double la = [d[@"lat"] doubleValue];
    double ln = [d[@"lng"] doubleValue];
    NSString *name = d[@"name"];
    NSString *note = d[@"note"];
    NSString *coordStr = [NSString stringWithFormat:@"%.6f, %.6f", la, ln];
    NSString *title = (name.length && ![name isEqualToString:@"(null)"]) ? name : coordStr;
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = note.length ? [NSString stringWithFormat:@"%@ · %@", note, coordStr].copy : coordStr;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - edit

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) wself = self;

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *action, UIView *view, void (^completionHandler)(BOOL)) {
            __strong typeof(self) s = wself;
            if (!s) { completionHandler(NO); return; }
            [s.recents removeObjectAtIndex:indexPath.row];
            [s persistAndSaveToDefaults];
            [s.tableView deleteRowsAtIndexPaths:@[indexPath]
                               withRowAnimation:UITableViewRowAnimationAutomatic];
            completionHandler(YES);
        }];

    UIContextualAction *note = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"备注" handler:^(UIContextualAction *action, UIView *view, void (^completionHandler)(BOOL)) {
            __strong typeof(self) s = wself;
            if (!s) { completionHandler(NO); return; }
            [s editNoteForRow:indexPath.row];
            completionHandler(YES);
        }];
    note.backgroundColor = [UIColor systemBlueColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[del, note]];
}

- (void)editNoteForRow:(NSInteger)row {
    NSDictionary *d = self.recents[row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"备注"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = d[@"note"] ?: @"";
        tf.placeholder = @"为此定位添加备注";
    }];
    __weak typeof(self) wself = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UITextField *tf = alert.textFields.firstObject;
        NSString *txt = [[tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        __strong typeof(self) s = wself;
        if (!s) return;
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:s.recents[row]];
        m[@"note"] = txt;
        s.recents[row] = m;
        [s persistAndSaveToDefaults];
        [s.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)persistAndSaveToDefaults {
    [[NSUserDefaults standardUserDefaults] setObject:self.recents forKey:kHistoryRecentKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - select

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.recents[indexPath.row];
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake([d[@"lat"] doubleValue], [d[@"lng"] doubleValue]);
    if (self.onSelect) self.onSelect(c);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end