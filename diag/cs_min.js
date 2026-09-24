// 调试：定位 csops 探针中"expected a pointer"的来源
'use strict';
try {
    console.log("A: pid=" + Process.id);
    var csops = new NativeFunction(Module.findExportByName(null, "csops"), 'int', ['int', 'int', 'pointer', 'ulong']);
    console.log("B: csops bound ok");
    var stat = Memory.alloc(4);
    console.log("C: alloc ok");
    var r = csops(Process.id, 0, stat, 4);
    console.log("D: csops r=" + r + " flags=0x" + stat.readU32().toString(16));
} catch (e) {
    console.log("ERR at: " + e);
}