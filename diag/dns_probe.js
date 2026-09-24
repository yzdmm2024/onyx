// 通用 DNS 探测（attach 到任何进程）
'use strict';
var ga = Module.findExportByName(null,"getaddrinfo");
var gaF = new NativeFunction(ga, 'int', ['pointer','pointer','pointer','pointer']);
["www.baidu.com","8.8.8.8","webrd01.is.autonavi.com"].forEach(function(h){
    var hints=Memory.alloc(256); Memory.writeU32(hints,0);
    var res=Memory.alloc(512);
    var r=gaF(Memory.allocUtf8String(h),NULL,hints,res);
    console.log("[DNS-" + h + "] -> " + r + (r===0?" (OK)":""));
});