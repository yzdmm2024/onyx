#import "ONYXMapView.h"

@interface ONYXMapView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *coordLabel;
@property (nonatomic, assign) CLLocationCoordinate2D currentCoord;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, assign) BOOL showMarker;
@end

@implementation ONYXMapView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _zoom = 11;
        _currentCoord = CLLocationCoordinate2DMake(31.230416, 121.473701);
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
    _titleLabel.text = @"地图在此设备不可用";
    _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 0;
    _detailLabel.text = @"jailbreak 自签 App 无法加载系统地图瓦片。请使用顶部「搜索」查找地点，或底部「快速定位」直接输入 纬度,经度。";
    _detailLabel.font = [UIFont systemFontOfSize:14];
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:_detailLabel];

    _coordLabel = [[UILabel alloc] init];
    _coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _coordLabel.numberOfLines = 0;
    _coordLabel.textAlignment = NSTextAlignmentCenter;
    _coordLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _coordLabel.textColor = [UIColor systemBlueColor];
    [card addSubview:_coordLabel];

    [self updateCoordLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:28],
        [card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-28],

        [_titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:12],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_coordLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:16],
        [_coordLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [_coordLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [_coordLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22]
    ]];
}

- (void)updateCoordLabel {
    _coordLabel.text = [NSString stringWithFormat:@"当前坐标：%.6f, %.6f", _currentCoord.latitude, _currentCoord.longitude];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coord zoom:(NSInteger)zoom showMarker:(BOOL)showMarker {
    if (CLLocationCoordinate2DIsValid(coord)) {
        _currentCoord = coord;
        _zoom = MAX(3, MIN(18, zoom));
        _showMarker = showMarker;
        [self updateCoordLabel];
    }
}

- (void)clearMarker { _showMarker = NO; }
- (void)zoomIn { _zoom = MIN(18, _zoom + 1); }
- (void)zoomOut { _zoom = MAX(3, _zoom - 1); }
- (void)setShowsUserLocation:(BOOL)show { /* no-op */ }

@end
