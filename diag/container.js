// 冷静验证: OnyxApp 的 HOME(jbroot 重映射) 下到底能读写什么; 直接测容器关键路径
'use strict';
var access = new NativeFunction(Module.findExportByName(null, "access"), 'int', ['pointer','int']);
var R_OK=4, W_OK=2, X_OK=1;
function t(p){
    var pb = Memory.allocUtf8String(p);
    var ok = access(pb,pb? 0:0)===0;
    var r_ok = access(pb,R_OK)===0;
    var w_ok = access(pb,W_OK)===0;
    console.log("[fs] " + p + " R=" + (r_ok?"Y":"n") + " W=" + (w_ok?"Y":"n"));
}
// HOME 及其子路径（Relaxin .jbroot 映射）
[
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5/var/mobile",
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5",
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5/var/jb",
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5/usr/lib",
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5/Library",
 "/var/containers/Bundle/Application/.jbroot-17F30F2D8A8009C5/tmp",
 "/var/mobile",
 "/var/mobile/Library"
].forEach(t);
console.log("done");