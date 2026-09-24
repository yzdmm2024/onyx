// 决定性网络测试：在 OnyxApp 进程里用 NSURLSession 发一个真实 HTTPS 请求
'use strict';

function syncFetch(urlStr, timeoutMs) {
    timeoutMs = timeoutMs || 5000;
    var NSURL = ObjC.classes.NSURL;
    var NSURLRequest = ObjC.classes.NSURLRequest;
    var NSURLSession = ObjC.classes.NSURLSession;
    var NSMutableURLRequest = ObjC.classes.NSMutableURLRequest;

    var url = NSURL.URLWithString_(urlStr);
    if (url.isNil()) return "BAD_URL";
    var req = NSMutableURLRequest.requestWithURL_(url);
    req.setTimeoutInterval_(timeoutMs / 1000.0);
    req.setHTTPMethod_("GET");

    // 同步：用 NSURLSession 的 dataTaskWithRequest:completionHandler: + dispatch_semaphore
    var dv = ObjC.classes.NSThread.isMainThread() ? 1 : 0;
    var sema = ObjC.select('dispatch_semaphore_create').call(null, [0]);
    var outRes = new ObjC.Object({handle: null});
    __blockResult = null;

    var handler = ObjC.block("void, id, id, id", function(data, response, error) {
        var status = -1, len = -1, errDesc = "nil";
        if (response) {
            try { if (response.respondsToSelector_(ObjC.selector('statusCode'))) status = response.statusCode(); } catch(e){}
        }
        if (data) len = data.length();
        if (error) errDesc = error.description().toString();
        __blockResult = "status=" + status + " len=" + len + " err=" + errDesc;
        ObjC.select('dispatch_semaphore_signal').call(null, [sema]);
    });

    var session = NSURLSession.sharedSession();
    session.dataTaskWithRequest_completionHandler_(req, handler);
    // 等最多 timeout+500ms
    var waited = 0;
    while (!__blockResult && waited < timeoutMs + 1500) {
        var done = ObjC.select('dispatch_semaphore_wait').call(null, [sema, 1000000]); // 1ms poll
        waited += 1;
        if (done === 0) break;
    }
    return __blockResult || "TIMEOUT_wait=" + waited;
}

console.log("===== 真实网络请求测试 (OnyxApp 内) =====");
[["https://www.baidu.com", "百度"],
 ["https://srv.amap.com", "高德"],
 ["https://tile.openstreetmap.org/1/0/0.png", "OSM瓦片"],
 ["https://8.8.8.8", "公共IP"]].forEach(function(p){
    var r = syncFetch(p[0]);
    console.log("[HTTP] " + p[1] + " (" + p[0] + ") -> " + r);
});
console.log("done");