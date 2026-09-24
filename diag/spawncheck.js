// spawn 方式读版本 + 轻量网络检查（不依赖进程在前台存活）
'use strict';
console.log("=== SPAWN OnyxApp 版本+网络 ===");
try {
    var main = ObjC.classes.NSBundle.mainBundle();
    var ver = main.objectForInfoDictionaryKey_("CFBundleShortVersionString");
    console.log("[version] short = " + (ver ? ver.toString() : "(nil)"));
    var bver = main.objectForInfoDictionaryKey_("CFBundleVersion");
    console.log("[version] build = " + (bver ? bver.toString() : "(nil)"));
    console.log("[bundlePath] " + main.bundlePath().toString());
} catch(e){ console.log("ver ERR " + e); }

// 网络
try {
    var ga = new NativeFunction(Module.findExportByName(null,"getaddrinfo"), 'int', ['pointer','pointer','pointer','pointer']);
    var hints=Memory.alloc(256); Memory.writeU32(hints,0);
    var res=Memory.alloc(512);
    var r=ga(Memory.allocUtf8String("webrd01.is.autonavi.com"),NULL,hints,res);
    console.log("[DNS-高德] " + (r===0?"OK":"FAIL("+r+")"));
    var r2=ga(Memory.allocUtf8String("tile.openstreetmap.org"),NULL,hints,res);
    console.log("[DNS-OSM] " + (r2===0?"OK":"FAIL("+r2+")"));
} catch(e){ console.log("net ERR " + e); }
console.log("done");