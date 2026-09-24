// 判断网络到底被哪层拒绝：hook sandbox_check + necp 关键入口，并在进程内做一次真实 connect。
// 若能 hook 到 sandbox_check 且 network-outbound 被 deny → 沙盒层（可绕过）
// 若 sandbox_check 返回 allow 但 connect 失败 → NECP/网络策略层（需 platformized）
'use strict';
try {
    console.log("[dbg] start pid=" + Process.id);
    var socket = new NativeFunction(Module.findExportByName(null,"socket"), 'int', ['int','int','int']);
    var connect = new NativeFunction(Module.findExportByName(null,"connect"), 'int', ['int','pointer','int']);
    var close = new NativeFunction(Module.findExportByName(null,"close"), 'int', ['int']);
    var errnoP = Module.findExportByName(null, "__error");

    // 尝试 hook sandbox_check / sandbox_check_by_audit_token
    var sb = Module.findExportByName(null, "sandbox_check");
    if (sb) {
        Interceptor.attach(sb, {
            onEnter: function(args) {
                // args[0]=pid, args[1]=operation(const char*)
                try {
                    var op = Memory.readUtf8String(args[1]);
                    if (op && op.indexOf("network") >= 0) {
                        this.op = op;
                        console.log("[sandbox_check] '" + op + "'");
                    }
                } catch(e){}
            },
            onLeave: function(ret) {
                if (this.op) console.log("[sandbox_check] '" + this.op + "' -> " + ret.toInt32());
            }
        });
        console.log("hooked sandbox_check @" + sb);
    } else {
        console.log("sandbox_check not exported");
    }

    // 等 hook 就绪做一次真实 connect 看 hook 是否被触发
    setTimeout(function(){
        console.log("--- doing real connect ---");
        var fd = socket(2,1,0);
        var sa = Memory.alloc(16);
        sa.writeU8(2).add(1).writeU8(0);
        sa.add(2).writeU16(0x0050); // port 80
        sa.add(4).writeU32(0x08080808); // 8.8.8.8
        var r = connect(fd, sa, 16);
        var e = (errnoP) ? (new NativeFunction(errnoP, 'pointer', []))().readS32() : -999;
        console.log("[connect 8.8.8.8:80] r=" + r + " errno=" + e);
        close(fd);
    }, 2000);
} catch(e){ console.log("ERR " + e); }