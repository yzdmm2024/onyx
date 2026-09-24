// 用 C 层 access()/stat() 裸测 OnyxApp 的路径可达性与可写性（避开 ObjC runtime 调用坑）
'use strict';
var access = new NativeFunction(Module.findExportByName(null, "access"), 'int', ['pointer','int']);
var mkdir = new NativeFunction(Module.findExportByName(null, "mkdir"), 'int', ['pointer','int']);
var rmdir = new NativeFunction(Module.findExportByName(null, "rmdir"), 'int', ['pointer']);
var F_OK=0, W_OK=2, R_OK=4, X_OK=1;
function t(p){
    var pb = Memory.allocUtf8String(p);
    var r_ok = access(pb,R_OK)===0;
    var w_ok = access(pb,W_OK)===0;
    console.log("[fs] " + p + " R=" + (r_ok?"Y":"n") + " W=" + (w_ok?"Y":"n"));
}
["/var/mobile/Media","/var/mobile/Documents","/tmp","/var/mobile/Containers",
 "/var/jb/var/mobile","/var/jb/var/mobile/Library/Preferences","/var/jb",
 "/var/mobile/Library/Preferences","/var/mobile/Library"].forEach(t);
// 实测目录: 创建则W可用，失败则errno
function tryMkdir(p){
    var pb=Memory.allocUtf8String(p);
    mkdir(pb,0x1ed); // 0755
    var e=ObjC.api.__error? (-1):-1;
    t(p);
}
// 尽量不真的建目录，仅测父目录可写即可
console.log("done");