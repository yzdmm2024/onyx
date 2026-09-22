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

static NSString *const kUA = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1";

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
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:real
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:12];
    [req setValue:kUA forHTTPHeaderField:@"User-Agent"];
    // 高德对 Referer/UA 敏感，带一个常见移动端 Referer 降低被拦概率
    [req setValue:@"https://www.amap.com/" forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *dt = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *realResp = (NSHTTPURLResponse *)resp;
        NSInteger code = realResp ? realResp.statusCode : 0;
        if (err) {
            [urlSchemeTask didFailWithError:err];
            return;
        }
        if (code != 200 || !data || data.length == 0) {
            // 非 200（403/404 等）或空响应：明确失败，让网页切到高德/OSM 直连兜底
            NSError *e = [NSError errorWithDomain:@"onyx" code:code
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"高德返回状态 %ld", (long)code]}];
            [urlSchemeTask didFailWithError:e];
            return;
        }
        // 强制 image/png，避免 WebView 因 content-type 拒显
        NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
        [hdrs setValue:@"image/png" forKey:@"Content-Type"];
        [hdrs setValue:[NSString stringWithFormat:@"%lu", (unsigned long)data.length] forKey:@"Content-Length"];
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url
                                                          statusCode:200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:hdrs];
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
