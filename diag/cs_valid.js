// 运行时查进程代码签名状态(CS_VALID / CS_PLATFORMIZED) + 核心网络 entitlement 是否被系统认可。
// 用于判断"ldid 签名是否被 amfid/网络策略层接受" —— 这是信任链修复后的最终判据。
'use strict';
try {
    var csops = new NativeFunction(Module.findExportByName(null,"csops"), 'int', ['int','int','pointer','ulong']);
    var pid = Process.id;
    console.log("[proc] pid=" + pid);

    // CS_OPS_STATUS = 0, CS_RUNTIME_STATUS = 1
    var stat = Memory.alloc(4);
    var r0 = csops(pid, 0, stat, 4);
    var cs = stat.readU32();
    console.log("[csops STATUS] r=" + r0 + " cs_flags=0x" + cs.toString(16) + " (0x"+cs+")");

    var CS_VALID = 0x00000001;
    var CS_ADHOC = 0x00000002;
    var CS_GET_TASK_ALLOW = 0x00000004;
    var CS_INSTALLER = 0x00000008;
    var CS_FORCED_LV = 0x00000010;
    var CS_PLATFORM_BINARY = 0x04000000;
    var CS_PLATFORMIZED = 0x08000000;
    var CS_DEBUGGED = 0x00000800;
    var CS_SIGNED = 0x10000000;

    function bit(f) { return (cs & f) ? "+" : "-"; }
    console.log("  VALID=" + bit(CS_VALID) + " ADHOC=" + bit(CS_ADHOC) + " GTA=" + bit(CS_GET_TASK_ALLOW)
        + " DEBUGGED=" + bit(CS_DEBUGGED) + " PLATFORM_BIN=" + bit(CS_PLATFORM_BINARY)
        + " PLATFORMIZED=" + bit(CS_PLATFORMIZED) + " SIGNED=" + bit(CS_SIGNED));

    var rt = Memory.alloc(4);
    var r1 = csops(pid, 1, rt, 4);
    console.log("[csops RUNTIME] r=" + r1 + " flags=0x" + rt.readU32().toString(16));

    // 关键网络 entitlement(运行时真实判定)
    var SecTaskCreateFromSelf = new NativeFunction(Module.findExportByName(null,"SecTaskCreateFromSelf"), 'pointer', ['pointer','pointer']);
    var SecTaskCopyValueForEntitlement = new NativeFunction(Module.findExportByName(null,"SecTaskCopyValueForEntitlement"), 'pointer', ['pointer','pointer','pointer']);
    var CFRelease = new NativeFunction(Module.findExportByName(null,"CFRelease"), 'void', ['pointer']);
    var CFBooleanGetValue = new NativeFunction(Module.findExportByName(null,"CFBooleanGetValue"), 'uchar', ['pointer']);
    var CFGetTypeID = new NativeFunction(Module.findExportByName(null,"CFGetTypeID"), 'ulong', ['pointer']);
    var BoolType = new NativeFunction(Module.findExportByName(null,"CFBooleanGetTypeID"), 'ulong', []);
    var CFStringCreate = new NativeFunction(Module.findExportByName(null,"CFStringCreateWithCString"), 'pointer',['pointer','pointer','ulong']);
    var kUTF8 = ulong(0x08000100);
    var task = SecTaskCreateFromSelf(NULL, NULL);
    if (!task.isNull()) {
        var err = Memory.alloc(4);
        ["com.apple.security.network.client","com.apple.security.network.server",
         "com.apple.private.security.no-sandbox","platform-application",
         "get-task-allow","com.apple.locationd.simulation"].forEach(function(n){
            var key = CFStringCreate(NULL, Memory.allocUtf8String(n), kUTF8);
            var val = SecTaskCopyValueForEntitlement(task, key, err);
            var out = val.isNull() ? "MISSING" : (CFGetTypeID(val) === BoolType() ? (CFBooleanGetValue(val)?"YES":"NO") : "non-bool");
            if (!val.isNull()) CFRelease(val);
            CFRelease(key);
            console.log("[ent] " + n + " = " + out);
        });
        CFRelease(task);
    }
    console.log("done");
} catch(e){ console.log("ERR " + e); }