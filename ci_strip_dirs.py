#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ci_strip_dirs.py — 从 deb 的 data.tar.xz 里剥离 var/jb/Library 子树的目录条目。

背景（relaxin/RootHide 设备实证，参照 roothide/ellekit injector.c 与 VCamPlus 事故复盘）：
  1. ellekit deb 把 <jb>/Library/MobileSubstrate/DynamicLibraries 布成指向
     usr/lib/TweakInject 的符号链接；RootHide 版 ellekit 的 injector 在每个
     .app 进程启动时强制 lstat 校验它必须是 symlink，否则 abort 弹
     "Ellekit files are corrupted ... reinstalling the ellekit package"。
  2. theos 出的 deb 会带上 ./var/jb/Library/MobileSubstrate/DynamicLibraries
     的 DIR 条目；在 RootHide 上 ellekit 包内记录的路径前缀与本包不一致，
     dpkg 卸载本包做"空目录回收"时跨包保护失效，可能把 ellekit 的符号链接
     一并删掉 → 一 respring 就弹 corrupted。
  3. 所以 data.tar 里一律不带 var/jb/Library 子树的目录条目（文件条目保留，
     dpkg 解包时会自动创建父目录，且不会把未记录的父目录纳入本包文件清单，
     卸载时也就不会回收它们）。

用法: python3 ci_strip_dirs.py <deb> [<deb> ...]
必须在所有 dpkg-deb -x/-b 重打包步骤之后执行（dpkg-deb -b 会重建目录条目）。
"""
import io
import lzma
import sys


def strip_deb(path: str) -> None:
    data = open(path, "rb").read()
    if data[:8] != b"!<arch>\n":
        raise SystemExit(f"{path}: not a deb (ar) file")

    # --- 解析 ar 成员 ---
    off = 8
    members = []  # (name, body)
    while off < len(data):
        hdr = data[off:off + 60]
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode("ascii", "replace").strip()
        size = int(hdr[48:58].decode().strip())
        body = data[off + 60:off + 60 + size]
        members.append((name, body))
        off += 60 + size + (size % 2)

    stripped = 0
    out_members = []
    for name, body in members:
        if name == "data.tar.xz":
            tf = tarfile_open_r_xz(body)
            buf = io.BytesIO()
            ntf = tarfile.open(fileobj=buf, mode="w:xz")
            for m in tf.getmembers():
                n = m.name[2:] if m.name.startswith("./") else m.name
                if m.isdir() and (n == "var/jb/Library" or n.startswith("var/jb/Library/")):
                    stripped += 1
                    continue
                if m.isreg():
                    ntf.addfile(m, tf.extractfile(m))
                else:
                    ntf.addfile(m)
            ntf.close()
            out_members.append((name, buf.getvalue()))
        else:
            out_members.append((name, body))

    # --- 重拼 ar ---
    ar = io.BytesIO()
    ar.write(b"!<arch>\n")
    for name, body in out_members:
        hdr = name.ljust(16).encode("ascii")
        hdr += b"0".ljust(12)          # mtime
        hdr += b"0".ljust(6)           # uid
        hdr += b"0".ljust(6)           # gid
        hdr += b"100644".ljust(8)      # mode
        hdr += str(len(body)).encode().ljust(10)
        hdr += b"`\n"
        ar.write(hdr)
        ar.write(body)
        if len(body) % 2:
            ar.write(b"\n")
    open(path, "wb").write(ar.getvalue())
    print(f"stripped {stripped} DIR entries: {path}")


def tarfile_open_r_xz(body: bytes):
    import tarfile
    return tarfile.open(fileobj=io.BytesIO(lzma.decompress(body)))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        strip_deb(p)
