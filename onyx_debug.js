// OnyxApp 调试脚本（修正版）
// 关键背景：v0.2.4 起瓦片走 onyx:// scheme，由 App 原生 NSURLSession 取高德图，
//   所以瓦片请求发生在【OnyxApp 进程】，本脚本能直接抓到。
//   （旧版用 <img src=https://...> 时，请求在 WebContent 进程，frida -n OnyxApp 抓不到）
//
// 用法（在装有 frida 的 Mac/PC 上，iPhone 已开 Onyx 并越狱+装 frida server）：
//   frida -U -n OnyxApp -l onyx_debug.js --no-pause
// 若 --no-pause 不支持： frida -U -n OnyxApp -l onyx_debug.js
//
// 更准的另一种方式（无需 frida）：Mac Safari → 开发 → <你的iPhone> → OnyxApp → Web Inspector

function log(t, m){ console.log('[' + t + '] ' + m); }

// 1) App 原生 NSURLSession 发出的所有请求（含 onyx:// 触发的瓦片请求）
var NSURLSession = ObjC.classes.NSURLSession;
if (NSURLSession && NSURLSession['- dataTaskWithRequest:completionHandler:']) {
  Interceptor.attach(NSURLSession['- dataTaskWithRequest:completionHandler:'].implementation, {
    onEnter: function(args) {
      var req = ObjC.Object(args[2]);
      var url = req.URL().absoluteString().toString();
      if (url.indexOf('autonavi.com') !== -1 || url.indexOf('amap') !== -1) {
        log('REQ', req.HTTPMethod().toString() + ' ' + url);
      }
    }
  });
}

// 2) NSURLSessionTask 收到响应（看 HTTP 状态码 / 失败）
var NSURLSessionTask = ObjC.classes.NSURLSessionTask;
if (NSURLSessionTask && NSURLSessionTask['- setResponse:']) {
  Interceptor.attach(NSURLSessionTask['- setResponse:'].implementation, {
    onEnter: function(args) {
      var resp = ObjC.Object(args[2]);
      if (!resp.isKindOfClass_(ObjC.classes.NSHTTPURLResponse)) return;
      var status = resp.statusCode();
      var url = ObjC.Object(args[0]).originalRequest().URL().absoluteString().toString();
      if (url.indexOf('autonavi.com') !== -1 || url.indexOf('amap') !== -1) {
        log('RESP', status.toString() + ' ' + url);
      }
    }
  });
}
if (NSURLSessionTask && NSURLSessionTask['- setError:']) {
  Interceptor.attach(NSURLSessionTask['- setError:'].implementation, {
    onEnter: function(args) {
      var err = ObjC.Object(args[2]);
      if (!err) return;
      var url = ObjC.Object(args[0]).originalRequest().URL().absoluteString().toString();
      if (url.indexOf('autonavi.com') !== -1 || url.indexOf('amap') !== -1) {
        log('ERR', err.localizedDescription().toString() + ' ' + url);
      }
    }
  });
}

// 3) WKWebView 加载了哪个 HTML
var WKWebView = ObjC.classes.WKWebView;
if (WKWebView && WKWebView['- loadFileURL:allowingReadAccessToURL:']) {
  Interceptor.attach(WKWebView['- loadFileURL:allowingReadAccessToURL:'].implementation, {
    onEnter: function(args) {
      log('LOAD', 'file=' + ObjC.Object(args[2]).absoluteString().toString());
    }
  });
}

// 4) 注入的 JS（看原生给网页推了什么坐标）
if (WKWebView && WKWebView['- evaluateJavaScript:completionHandler:']) {
  Interceptor.attach(WKWebView['- evaluateJavaScript:completionHandler:'].implementation, {
    onEnter: function(args) {
      log('JS>', ObjC.Object(args[2]).toString());
    }
  });
}

// 5) inspectable 是否生效（Safari 能否远程调试）
if (WKWebView && WKWebView['- setInspectable:']) {
  Interceptor.attach(WKWebView['- setInspectable:'].implementation, {
    onEnter: function(args) { log('INSP', 'inspectable=' + args[2]); }
  });
}

log('INIT', 'Onyx debug attached. 打开 App 看 REQ/RESP/ERR，或 Mac Safari 远程调试。');
