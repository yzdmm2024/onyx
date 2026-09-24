// 读取 OnyxApp 版本号，确认是否已更新到 0.5.9.2
'use strict';
try {
    var main = ObjC.classes.NSBundle.mainBundle();
    var v = main.infoDictionary().objectForKey_(ObjC.selector('CFBundleShortVersionString') || nil);
    var ver = main.objectForInfoDictionaryKey_("CFBundleShortVersionString");
    console.log("[version] short = " + (ver ? ver.toString() : "(nil)"));
    var bver = main.objectForInfoDictionaryKey_("CFBundleVersion");
    console.log("[version] build = " + (bver ? bver.toString() : "(nil)"));
    var path = main.bundlePath();
    console.log("[bundlePath] " + path.toString());
} catch(e){ console.log("ERR " + e); }