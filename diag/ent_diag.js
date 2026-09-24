// Onyx 网络连通性诊断：
// 判定 OnyxApp 进程内是【完全无网络】还是【仅 DNS 失败但可直连 IP】。
'use strict';

var _socket = new NativeFunction(Module.findExportByName(null,"socket"), 'int', ['int','int','int']);
var _connect = new NativeFunction(Module.findExportByName(null,"connect"), 'int', ['int','pointer','int']);
var _close = new NativeFunction(Module.findExportByName(null,"close"), 'int', ['int']);
var _getaddrinfo = Module.findExportByName(null,"getaddrinfo");
var gaF = new NativeFunction(_getaddrinfo, 'int', ['pointer','pointer','pointer','pointer']);

function ba2u32(b,host){ Memory.writeU32(host, b); } // 网序写入

function tcpTest(ip_ints, port, label){
    var fd = _socket(2,1,0);
    if (fd < 0) { console.log("[TCP] " + label + " socket FAIL errno=" + fd); return; }
    var sa = Memory.alloc(16);
    sa.add(0).writeU32(0).writeU8(0);          // padding
    sa.add(0).writeU8(2);                       // family=AF_INET  (offset 0 for sockaddr_in at bytes: family 2 bytes at 0)
    // sockaddr_in: family(2) port(2) addr(4) zero(8)
    sa.add(2).writeU16(0).writeU16(port);       // place port at offset 4? 手写更稳:
    sa.add(0).writeU8(2); sa.add(1).writeU8(0);
    sa.add(2).writeU16(port);                   // big-endian port
    sa.add(4).writeU32(ip_ints);                // addr
    sa.add(8).writeU32(0); sa.add(12).writeU32(0);
    var r = _connect(fd, sa, 16);
    console.log("[TCP] " + label + " connect=" + r + (r===0?" OK":" err"));
    _close(fd);
}

// 8.8.8.8:53, 1.1.1.1:80, 223.5.5.5:53(阿里国内DNS)
tcpTest(0x08080808, 53, "8.8.8.8:53 googleDNS");
tcpTest(0x05050501, 80, "1.1.1.1:80 cloudflare");
tcpTest(0x050505df, 53, "223.5.5.5:53 阿里DNS");

// getaddrinfo 到强制用 IP 的瓦片源?
console.log("--- DNS 直测 ---");
["8.8.8.8","223.5.5.5"].forEach(function(ip){
    var hints=Memory.alloc(64); Memory.writeU32(hints,0);
    var res=Memory.alloc(128);
    var r=gaF(Memory.allocUtf8String(ip),NULL,hints,res);
    console.log("[getaddrinfo " + ip + "] -> " + r);
});

// 直接尝试读取系统 DNS 配置 (resolv)
try {
    var pconf = new NativeFunction(Module.findExportByName(null,"res_9_ninit"), 'int', ['pointer']);
    var ns = Memory.alloc(4096);
    Memory.writeU32(ns,4096); // 需要正确结构，简化
} catch(e){}

console.log("done");