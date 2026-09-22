#import "ONYXCoordTransform.h"
#include <math.h>

static BOOL _outOfChina(CLLocationCoordinate2D coord) {
    if (coord.longitude < 72.004 || coord.longitude > 137.8347) return YES;
    if (coord.latitude < 0.8293 || coord.latitude > 55.8271) return YES;
    return NO;
}

static double _transformLat(double x, double y) {
    double ret = -100.0 + 2.0*x + 3.0*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(fabs(x));
    ret += (20.0*sin(6.0*x*M_PI) + 20.0*sin(2.0*x*M_PI)) * 2.0 / 3.0;
    ret += (20.0*sin(y*M_PI) + 40.0*sin(y/3.0*M_PI)) * 2.0 / 3.0;
    ret += (160.0*sin(y/12.0*M_PI) + 320.0*sin(y*M_PI/30.0)) * 2.0 / 3.0;
    return ret;
}

static double _transformLng(double x, double y) {
    double ret = 300.0 + x + 2.0*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(fabs(x));
    ret += (20.0*sin(6.0*x*M_PI) + 20.0*sin(2.0*x*M_PI)) * 2.0 / 3.0;
    ret += (20.0*sin(x*M_PI) + 40.0*sin(x/3.0*M_PI)) * 2.0 / 3.0;
    ret += (150.0*sin(x/12.0*M_PI) + 300.0*sin(x/30.0*M_PI)) * 2.0 / 3.0;
    return ret;
}

@implementation ONYXCoordTransform

+ (CLLocationCoordinate2D)convert:(CLLocationCoordinate2D)coord fromSystem:(OnyxCoordSystem)from toSystem:(OnyxCoordSystem)to {
    if (from == to) return coord;
    if (from == OnyxCoordSystemWGS84 && to == OnyxCoordSystemGCJ02) return [self gcj02FromWgs84:coord];
    if (from == OnyxCoordSystemGCJ02 && to == OnyxCoordSystemWGS84) return [self wgs84FromGcj02:coord];
    if (from == OnyxCoordSystemGCJ02 && to == OnyxCoordSystemBD09)  return [self bd09FromGcj02:coord];
    if (from == OnyxCoordSystemBD09  && to == OnyxCoordSystemGCJ02) return [self gcj02FromBd09:coord];
    if (from == OnyxCoordSystemWGS84 && to == OnyxCoordSystemBD09)  return [self bd09FromWgs84:coord];
    if (from == OnyxCoordSystemBD09  && to == OnyxCoordSystemWGS84) return [self wgs84FromBd09:coord];
    return coord;
}

+ (CLLocationCoordinate2D)gcj02FromWgs84:(CLLocationCoordinate2D)coord {
    if (_outOfChina(coord)) return coord;
    double dLat = _transformLat(coord.longitude - 105.0, coord.latitude - 35.0);
    double dLng = _transformLng(coord.longitude - 105.0, coord.latitude - 35.0);
    double radLat = coord.latitude / 180.0 * M_PI;
    double magic = sin(radLat);
    magic = 1 - 0.00669342162296594323 * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((6378245.0 * (1 - 0.00669342162296594323)) / (magic * sqrtMagic) * M_PI);
    dLng = (dLng * 180.0) / (6378245.0 / sqrtMagic * cos(radLat) * M_PI);
    return CLLocationCoordinate2DMake(coord.latitude + dLat, coord.longitude + dLng);
}

+ (CLLocationCoordinate2D)wgs84FromGcj02:(CLLocationCoordinate2D)coord {
    if (_outOfChina(coord)) return coord;
    CLLocationCoordinate2D approx = [self gcj02FromWgs84:coord];
    double dLat = approx.latitude - coord.latitude;
    double dLng = approx.longitude - coord.longitude;
    return CLLocationCoordinate2DMake(coord.latitude - dLat, coord.longitude - dLng);
}

+ (CLLocationCoordinate2D)bd09FromGcj02:(CLLocationCoordinate2D)coord {
    double x = coord.longitude, y = coord.latitude;
    double z = sqrt(x*x + y*y) + 0.00002*sin(y*M_PI*3000.0/180.0);
    double theta = atan2(y, x) + 0.000003*cos(x*M_PI*3000.0/180.0);
    return CLLocationCoordinate2DMake(z*sin(theta) + 0.006, z*cos(theta) + 0.0065);
}

+ (CLLocationCoordinate2D)gcj02FromBd09:(CLLocationCoordinate2D)coord {
    double x = coord.longitude - 0.0065, y = coord.latitude - 0.006;
    double z = sqrt(x*x + y*y) - 0.00002*sin(y*M_PI*3000.0/180.0);
    double theta = atan2(y, x) - 0.000003*cos(x*M_PI*3000.0/180.0);
    return CLLocationCoordinate2DMake(z*sin(theta), z*cos(theta));
}

+ (CLLocationCoordinate2D)wgs84FromBd09:(CLLocationCoordinate2D)coord {
    CLLocationCoordinate2D gcj = [self gcj02FromBd09:coord];
    return [self wgs84FromGcj02:gcj];
}

+ (CLLocationCoordinate2D)bd09FromWgs84:(CLLocationCoordinate2D)coord {
    CLLocationCoordinate2D gcj = [self gcj02FromWgs84:coord];
    return [self bd09FromGcj02:gcj];
}

@end
