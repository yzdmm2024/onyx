#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// 自定义 scheme: onyx://tile?x=&y=&z=
// WKWebView 页面内的瓦片请求走这个 scheme，由 App 原生 NSURLSession
// 去高德取图再回灌，彻底绕开 file:// 跨域 / ATS / WebContent 网络限制。
@interface ONYXTileSchemeHandler : NSObject <WKURLSchemeHandler>
@end
