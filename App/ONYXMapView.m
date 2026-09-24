#import "ONYXMapView.h"

@interface ONYXMapView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *coordLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, assign) CLLocationCoordinate2D currentCoord;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, assign) BOOL showMarker;
@property (nonatomic, assign) NSInteger selectedCount;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *lastUpdated;
@end

@implementation ONYXMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _zoom = 11;
        _currentCoord = CLLocationCoordinate2DMake(31.230416, 121.473701);
        _selectedCount = 0;
        _running = NO;
        _lastUpdated = @"-";
        self.backgroundColor = [UIColor colorWithRed:0.92 green:0.94 blue:0.97 alpha:1.0];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 2);
    card.layer.shadowOpacity = 0.08;
    card.layer.shadowRadius = 6;
    [self addSubview:card];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = @"定位模拟状态";
    _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_titleLabel];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_statusLabel];

    _countLabel = [[UILabel alloc] init];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [UIFont systemFontOfSize:14];
    _countLabel.textColor = [UIColor secondaryLabelColor];
    _countLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_countLabel];

    _coordLabel = [[UILabel alloc] init];
    _coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _coordLabel.numberOfLines = 0;
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    _coordLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _coordLabel.textColor = [UIColor systemBlueColor];
    [card addSubview:_coordLabel];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.font = [UIFont systemFontOfSize:12];
    _timeLabel.textColor = [UIColor tertiaryLabelColor];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_timeLabel];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hintLabel.numberOfLines = 0;
    _hintLabel.font = [UIFont systemFontOfSize:13];
    _hintLabel.textColor = [UIColor secondaryLabelColor];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.text = @"提示：保存后需彻底关闭并重新打开目标 App 才会生效。";
    [card addSubview:_hintLabel];

    [self updateLabels];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:28],
        [card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-28],

        [_titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_statusLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:14],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_countLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:8],
        [_countLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_countLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_coordLabel.topAnchor constraintEqualToAnchor:_countLabel.bottomAnchor constant:12],
        [_coordLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_coordLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_timeLabel.topAnchor constraintEqualToAnchor:_coordLabel.bottomAnchor constant:8],
        [_timeLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_timeLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_hintLabel.topAnchor constraintEqualToAnchor:_timeLabel.bottomAnchor constant:14],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [_hintLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22]
    ]];
}

- (void)updateLabels {
    if (_running) {
        _statusLabel.text = @"运行中";
        _statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        _statusLabel.text = @"已停止";
        _statusLabel.textColor = [UIColor systemRedColor];
    }
    _countLabel.text = [NSString stringWithFormat:@"已选 %ld 个应用", (long)_selectedCount];
    _coordLabel.text = [NSString stringWithFormat:@"目标坐标：%.6f, %.6f", _currentCoord.latitude, _currentCoord.longitude];
    _timeLabel.text = [NSString stringWithFormat:@"最后更新：%@", _lastUpdated ?: @"-"];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    if (CLLocationCoordinate2DIsValid(coord)) {
        _currentCoord = coord;
        _zoom = MAX(3, MIN(18, zoom));
        _showMarker = showMarker;
        [self updateLabels];
    }
}

- (void)setStatusRunning:(BOOL)running selectedCount:(NSInteger)count lastUpdated:(NSString *)lastUpdated {
    _running = running;
    _selectedCount = count;
    if (lastUpdated.length) _lastUpdated = [lastUpdated copy];
    [self updateLabels];
}

- (void)clearMarker { _showMarker = NO; }
- (void)zoomIn { _zoom = MIN(18, _zoom + 1); }
- (void)zoomOut { _zoom = MAX(3, _zoom - 1); }
- (void)setShowsUserLocation:(BOOL)show { /* no-op */ }

@end
