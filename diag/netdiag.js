// Onyx 网络诊断 v3 —— 简洁可靠
'use strict';

function probeDNS(host) {
    try {
        var ga = Module.findExportByName(null, "getaddrinfo");
        if (!ga) return "no-getaddrinfo";
        var f = new NativeFunction(ga, 'int', ['pointer','pointer','pointer','pointer']);
        var hints = Memory.alloc(64); Memory.writeU32(hints, 0);
        var res = Memory.alloc(128);
        var hostBuf = Memory.allocUtf8String(host);
        var r = f(hostBuf, NULL, hints, res);
        return r === 0 ? "解析OK" : "解析FAIL(" + r + ")";
    } catch (e) { return "ERR:" + e.message; }
}

console.log("===== DNS 探测 =====");
["www.baidu.com","webrd01.is.autonavi.com","webst01.is.autonavi.com","tile.openstreetmap.org","gs-loc.apple.com","api.lbs.amap.com"].forEach(function(h){
    console.log("[DNS] " + h + " -> " + probeDNS(h));
});

console.log("===== hook NSURLSession 瓦片请求 =====");
try {
    var cls = ObjC.classes.NSURLSession;
    var imp = cls['- dataTaskWithRequest:completionHandler:'].implementation;
    Interceptor.attach(imp, {
        onEnter: function(args){
            try {
                var req = ObjC.Object(args[2]);
                var url = req.URL ? req.URL.absoluteString().toString() : "(nil)";
                this.url = url;
                this.cb = args[3];
                console.log("[REQ] " + url);
                var cb = this.cb;
                if (!cb.isNull()) {
                    var saved = url;
                    Interceptor.attach(ObjC.Object(cb).implementation, {
                        onEnter: function(a){
                            try {
                                var data = ObjC.Object(a[2]);
                                var resp = ObjC.Object(a[3]);
                                var err = ObjC.Object(a[4]);
                                var status = 0, len = 0;
                                if (resp && resp.respondsToSelector_(ObjC.selector('statusCode'))) status = resp.statusCode();
                                if (data) len = data.length();
                                var desc = (err && !err.isNull()) ? " err=" + err.description().toString() : "";
                                console.log("[RESP] " + saved + " status=" + status + " len=" + len + desc);
                            } catch(e){ console.log("[RESP err] " + e); }
                        }
                    });
                }
            } catch(e){ console.log("[REQ err] " + e); }
        }
    });
    console.log("[hook] OK");
} catch(e){ console.log("[hook FAIL] " + e); }