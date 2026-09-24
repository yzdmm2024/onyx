#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 deb 内 OnyxApp 二进制的 entitlements（不依赖 ldid）。
解 deb=ar archive -> data.tar.xz -> 提取 app binary -> 读 Mach-O LC_CODE_SIGNATURE
解析 CMS/blob 取 entitlements plist。
"""
import io, struct, tarfile, lzma, re, plistlib, os, sys

DEB = sys.argv[1] if len(sys.argv)>1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "onyx.deb")

# --- 1. 解析 ar (deb) ---
def read_ar(path):
    with open(path,'rb') as f:
        data=f.read()
    # deb 是 ar 归档：8字节 magic + 每条目 60字节 header
    assert data[:8]==b'!<arch>\n', 'not ar'
    off=8; pieces={}
    while off < len(data):
        if off+60>len(data): break
        hdr=data[off:off+60]
        name=hdr[0:16].decode().strip()
        size=int(hdr[48:58].decode().strip())
        body=data[off+60:off+60+size]
        pieces[name]=body
        off += 60 + size + (size&1)
    return pieces

pieces=read_ar(DEB)
print("ar entries:", list(pieces.keys()))
data_tar_xz=pieces.get('data.tar.xz')
assert data_tar_xz, 'no data.tar.xz'
data_tar=lzma.decompress(data_tar_xz)

# --- 2. 从 tar 提取 OnyxApp 二进制 ---
binpath=None; binbody=None
tf=tarfile.open(fileobj=io.BytesIO(data_tar), mode='r')
for m in tf.getmembers():
    if m.isfile() and m.name.endswith('.app/OnyxApp'):
        binbody=tf.extractfile(m).read()
        binpath=m.name
        break
tf.close()
assert binbody, 'OnyxApp not found'
print("binary:", binpath, len(binbody), "bytes")

# --- 3. 解析 Mach-O entitlement (blob)，先处理 fat ---
def parse_fat_or_thin(b):
    # Fat 头部识别: magic CAFEBABE/FEEDFACF
    m=b[:4]
    if m in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        narch=struct.unpack('>I', b[4:8])[0]
        print("  [dbg] FAT binary, narch=%d" % narch)
        for i in range(narch):
            name=b[8+i*20:8+i*20+16].rstrip(b'\x00').decode(errors='ignore')
            cputype,cpusub,offset,size=struct.unpack('>IIII', b[8+i*20:24+i*20])
            print("  [dbg]   arch=%d name=%s cputype=%d off=%d size=%d" % (i, name, cputype, offset, size))
            slice_b=b[offset:offset+size]
            e=parse_macho_entitlements(slice_b)
            if e: return e
        return None
    else:
        return parse_macho_entitlements(b)

def parse_macho_entitlements(b):
    print("  [dbg] slice magic=%s len=%d" % (b[:4].hex(), len(b)))
    if b[:4]==b'\xcf\xfa\xed\xfe': # MH_MAGIC_64 (64-bit)
        ncmds=struct.unpack('<I', b[16:20])[0]
        print("  [dbg] ncmds=%d" % ncmds)
        off=32
        for _ in range(ncmds):
            cmd,cmdsize=struct.unpack('<II', b[off:off+8])
            if cmd==0x1d: # LC_CODE_SIGNATURE
                dataoff,datasize=struct.unpack('<II', b[off+8:off+16])
                print("  [dbg] found LC_CODE_SIGNATURE dataoff=%d datasize=%d" % (dataoff,datasize))
                blob=b[dataoff:dataoff+datasize]
                return parse_superblob(blob)
            if cmd==0x80000000|0x1d: print("  [dbg] found LC_RPATH-like"); pass
            off+=cmdsize
    else:
        print("  [dbg] not MH_MAGIC_64, first uint32=%08x" % (struct.unpack('<I',b[:4])[0] if len(b)>=4 else 0))
    return None

def parse_superblob(blob):
    magic=struct.unpack('>I', blob[0:4])[0]
    print("  [dbg] superblob magic=%08x len=%d" % (magic, len(blob)))
    if magic in (0x0a0a0000, 0xfade0cc0): # CSGenericBlob/superblob
        count=struct.unpack('>I', blob[8:12])[0]
        print("  [dbg] sb count=%d" % count)
        for i in range(count):
            if 12+i*12+12 > len(blob): break
            typ,doff,dsize=struct.unpack('>III', blob[12+i*12:24+i*12])
            print("  [dbg]   slot i=%d typ=%d doff=%d dsize=%d" % (i, typ, doff, dsize))
            if typ==5: # CSSLOT_ENTITLEMENTS
                ent_blob=blob[doff:doff+dsize]
                xml=ent_blob[20:] if len(ent_blob)>=20 else ent_blob
                print("  [dbg]   entblob magic=%s dsize=%d len=%d" % (ent_blob[:4].hex(), dsize, len(ent_blob)))
                s=xml.split(b'</plist>')[0]+b'</plist>'
                try:
                    d=plistlib.loads(s)
                    return d
                except Exception as e:
                    return {'__parse_err__':str(e), 'xml': xml[:300]}
    return None

ents=parse_fat_or_thin(binbody)
print("\n===== OnyxApp 二进制内嵌 entitlements =====")
if ents:
    for k in sorted(ents.keys()):
        print("  %-40s = %s" % (k, ents[k]))
else:
    print("  (解析失败或未找到)")