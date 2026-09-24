// 读取 OnyxApp 进程的 entitlements 字典（用 SecTaskCopyValueForEntitlement）
'use strict';
try {
    var SecTaskCreateFromSelf = new NativeFunction(Module.findExportByName(null,"SecTaskCreateFromSelf"), 'pointer', ['pointer','pointer']);
    var SecTaskCopyValueForEntitlement = new NativeFunction(Module.findExportByName(null,"SecTaskCopyValueForEntitlement"), 'pointer', ['pointer','pointer','pointer']);
    var CFRelease = new NativeFunction(Module.findExportByName(null,"CFRelease"), 'void', ['pointer']);
    var CFBooleanGetValue = new NativeFunction(Module.findExportByName(null,"CFBooleanGetValue"), 'uchar', ['pointer']);
    var CFGetTypeID = new NativeFunction(Module.findExportByName(null,"CFGetTypeID"), 'ulong', ['pointer']);
    var BoolType = new NativeFunction(Module.findExportByName(null,"CFBooleanGetTypeID"), 'ulong', []);
    var StringType = new NativeFunction(Module.findExportByName(null,"CFStringGetTypeID"), 'ulong', []);
    var CFStringGetCStringPtr = new NativeFunction(Module.findExportByName(null,"CFStringGetCStringPtr"), 'pointer', ['pointer','ulong']);
    var kUTF8 = ulong(0x08000100);

    var task = SecTaskCreateFromSelf(NULL, NULL);
    if (task.isNull()) { console.log("SecTaskCreateFromSelf NULL"); return; }
    var err = Memory.alloc(4);
    var names = ["com.apple.security.network.client","com.apple.security.network.server","get-task-allow","com.apple.private.network.dns_settings","com.apple.security.container"];
    names.forEach(function(n){
        var key = new NativeFunction(Module.findExportByName(null,"CFStringCreateWithCString"), 'pointer',['pointer','pointer','ulong'])(NULL, Memory.allocUtf8String(n), kUTF8);
        var val = SecTaskCopyValueForEntitlement(task, key, err);
        var out;
        if (val.isNull()) out = "MISSING";
        else {
            var t = CFGetTypeID(val);
            if (t === BoolType()) out = CFBooleanGetValue(val) ? "bool=YES" : "bool=NO";
            else if (t === StringType()) { var p = CFStringGetCStringPtr(val, kUTF8); out = p.isNull()? "string(len?)" : "string="+p.readUtf8String(); }
            else out = "typeid="+t;
            CFRelease(val);
        }
        CFRelease(key);
        console.log("[ent] "+n+" = "+out);
    });
    CFRelease(task);
    console.log("done");
} catch(e){ console.log("ERR " + e); }