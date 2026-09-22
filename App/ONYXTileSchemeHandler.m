#import "ONYXTileSchemeHandler.h"

// 高德栅格瓦片真实地址构造
static NSURL *realTileURL(NSInteger x, NSInteger y, NSInteger z) {
    NSInteger sub = 1 + ((x + y) % 4);
    // 用 webrd0X 移动端 + style=7（中文标注、道路网），与 curl 实测 200 一致
    NSString *s = [NSString stringWithFormat:
        @"https://webrd0%ld.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x=%ld&y=%ld&z=%ld",
        (long)sub, (long)x, (long)y, (long)z];
    return [NSURL URLWithString:s];
}

@implementation ONYXTileSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURL *url = urlSchemeTask.request.URL;
    NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSInteger x = 0, y = 0, z = 0;
    for (NSURLQueryItem *it in comp.queryItems) {
        if ([it.name isEqualToString:@"x"]) x = [it.value integerValue];
        else if ([it.name isEqualToString:@"y"]) y = [it.value integerValue];
        else if ([it.name isEqualToString:@"z"]) z = [it.value integerValue];
    }
    if (x < 0 || y < 0 || z < 0 || z > 18) {
        NSError *e = [NSError errorWithDomain:@"onyx" code:400 userInfo:@{NSLocalizedDescriptionKey:@"bad tile params"}];
        [urlSchemeTask didFailWithError:e];
        return;
    }
    NSURL *real = realTileURL(x, y, z);
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dt = [session dataTaskWithURL:real completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data || data.length == 0) {
            [urlSchemeTask didFailWithError:err ?: [NSError errorWithDomain:@"onyx" code:500 userInfo:@{NSLocalizedDescriptionKey:@"empty tile"}]];
            return;
        }
        // 强制 image/png，避免 WebView 因 content-type 拒显
        NSHTTPURLResponse *realResp = (NSHTTPURLResponse *)resp;
        NSInteger code = realResp ? realResp.statusCode : 200;
        NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
        [hdrs setValue:@"image/png" forKey:@"Content-Type"];
        [hdrs setValue:[NSString stringWithFormat:@"%lu", (unsigned long)data.length] forKey:@"Content-Length"];
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:hdrs];
        [urlSchemeTask didReceiveResponse:r];
        [urlSchemeTask didReceiveData:data];
        [urlSchemeTask didFinish];
    }];
    [dt resume];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    // 简单实现：忽略取消
}

@end
