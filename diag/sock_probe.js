// 极简连通性诊断：直接用 C socket 建连（不走 NSURLSession/getaddrinfo hook，避免误报）
'use strict';

var socket = new NativeFunction(Module.findExportByName(null,"socket"), 'int', ['int','int','int']);
var connect = new NativeFunction(Module.findExportByName(null,"connect"), 'int', ['int','pointer','int']);
var close = new NativeFunction(Module.findExportByName(null,"close"), 'int', ['int']);
var write = new NativeFunction(Module.findExportByName(null,"write"), 'int', ['int','pointer','int']);
var read = new NativeFunction(Module.findExportByName(null,"read"), 'int', ['int','pointer','int']);
var getaddrinfo = new NativeFunction(Module.findExportByName(null,"getaddrinfo"), 'int', ['pointer','pointer','pointer','pointer']);

function sockaddrIn(ip_uint_be, port_be) {
    var sa = Memory.alloc(16);
    sa.writeU8(2).add(1).writeU8(0);      // family AF_INET
    sa.add(2).writeU16(port_be);          // port big-endian
    sa.add(4).writeU32(ip_uint_be);       // addr big-endian
    return sa;
}

function testConnect(ipStr, ipBe, port, label) {
    var fd = socket(2, 1, 0); // AF_INET=SOCK_STREAM
    if (fd < 0) { console.log("[%s] socket()=%d (底层socket被拒)", label, fd); return; }
    var sa = sockaddrIn(ipBe, port);
    var r = connect(fd, sa, 16);
    console.log("[%s] %s connect()=%d %s", label, ipStr, r, r===0?"=>OK":">失败");
    close(fd);
}

console.log("===== 原生 socket 连通测试 (无 hook 依赖) =====");
testConnect("8.8.8.8:53",   0x08080808, 0x0035,  "googleDNS");
testConnect("223.5.5.5:53", 0x05050523, 0x0035,  "aliDNS(国内)");
testConnect("114.114.114.114:80", 0x72727272, 0x0050, "114DNS:80");
testConnect("1.1.1.1:443",  0x01010101, 0x01bb,  "cloudflare:443");
console.log("done");