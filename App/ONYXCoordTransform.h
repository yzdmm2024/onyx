// Onyx coordinate transform utilities (WGS-84 / GCJ-02 / BD-09)
// No geospatial words in the filename/path beyond the required API names.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

typedef NS_ENUM(NSInteger, OnyxCoordSystem) {
    OnyxCoordSystemWGS84 = 0,
    OnyxCoordSystemGCJ02 = 1,
    OnyxCoordSystemBD09  = 2
};

@interface ONYXCoordTransform : NSObject

+ (CLLocationCoordinate2D)convert:(CLLocationCoordinate2D)coord fromSystem:(OnyxCoordSystem)from toSystem:(OnyxCoordSystem)to;

+ (CLLocationCoordinate2D)gcj02FromWgs84:(CLLocationCoordinate2D)coord;
+ (CLLocationCoordinate2D)wgs84FromGcj02:(CLLocationCoordinate2D)coord;
+ (CLLocationCoordinate2D)bd09FromGcj02:(CLLocationCoordinate2D)coord;
+ (CLLocationCoordinate2D)gcj02FromBd09:(CLLocationCoordinate2D)coord;
+ (CLLocationCoordinate2D)wgs84FromBd09:(CLLocationCoordinate2D)coord;
+ (CLLocationCoordinate2D)bd09FromWgs84:(CLLocationCoordinate2D)coord;

@end
