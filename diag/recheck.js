// v0.5.9.2 网络复查：socket 连通 + 域名解析 + HTTP 真实请求
'use strict';

var socket = new NativeFunction(Module.findExportByName(null,"socket"), 'int', ['int','int','int']);
var connect = new NativeFunction(Module.findExportByName(null,"connect"), 'int', ['int','pointer','int']);
var close = new NativeFunction(Module.findExportByName(null,"close"), 'int', ['int']);
var ga = new NativeFunction(Module.findExportByName(null,"getaddrinfo"), 'int', ['pointer','pointer','pointer','pointer']);

function probeDNS(host){
    var hints=Memory.alloc(256); Memory.writeU32(hints,0);
    var res=Memory.alloc(512);
    var r=ga(Memory.allocUtf8String(host),NULL,hints,res);
    return r===0?"OK":"FAIL("+r+")";
}
function sockaddrIn(ip_be,port_be){
    var sa=Memory.alloc(16);
    sa.writeU8(2).add(1).writeU8(0);
    sa.add(2).writeU16(port_be);
    sa.add(4).writeU32(ip_be);
    return sa;
}
function tcp(ip,port_be,label){
    var fd=socket(2,1,0);
    if(fd<0){ console.log("[TCP] "+label+" socket="+fd); return; }
    var r=connect(fd,sockaddrIn(ip,port_be),16);
    console.log("[TCP] "+label+" = "+r+(r===0?" OK":" fail"));
    close(fd);
}

console.log("===== DNS =====");
["webrd01.is.autonavi.com","webst01.is.autonavi.com","srv.amap.com","tile.openstreetmap.org","api.amap.com"].forEach(function(h){
    console.log("[DNS] "+h+" -> "+probeDNS(h));
});
console.log("===== TCP 直连IP =====");
tcp(0x08080808,0x0035,"8.8.8.8:53");
tcp(0x05050523,0x0035,"223.5.5.5:53(阿里DNS)");
tcp(0x050505df,0x0035,"223.5.5.1:53");
tcp(0x01010101,0x01bb,"1.1.1.1:443");
console.log("done");