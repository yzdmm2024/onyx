#import "ONYXHistoryViewController.h"

static NSString *const kHistoryRecentKey = @"com.yzdmm.onyx.recentCoords";

@interface ONYXHistoryViewController ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@end

@implementation ONYXHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(doneTapped)];
    [self loadRecents];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)loadRecents {
    NSArray *a = [[NSUserDefaults standardUserDefaults] objectForKey:kHistoryRecentKey] ?: @[];
    _recents = [NSMutableArray arrayWithArray:a];
    [self.tableView reloadData];
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