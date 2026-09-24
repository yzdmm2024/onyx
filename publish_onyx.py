#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""publish_onyx.py — 用 GitHub API 把 0.5.7 双架构 deb 发布到越狱源 yzdmm2024/repo。
自包含：不再依赖旧机器上的 update.py，直接解析 DEBIAN/control 生成 stanza，
并重写 Packages / Packages.gz / Packages.bz2 / Release 四个索引文件。
"""
import json, base64, hashlib, gzip, bz2, os, re, struct, sys, subprocess, tarfile, io, io

REPO = "yzdmm2024/repo"
DEBS = []
REPO_ID = None

def gh(args, payload=None, raw=False):
    cmd = ["gh", "api"]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    if isinstance(args, str):
        args = [args]
    cmd += list(args)
    r = subprocess.run(cmd + (["--input", "-"] if payload is not None else []),
                       input=json.dumps(payload) if payload is not None else None,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("API失败: %s\n%s" % (r.stdout[:800], r.stderr[:800]))
    return r.stdout

def repo_id():
    global REPO_ID
    if not REPO_ID:
        REPO_ID = json.loads(gh("repos/%s" % REPO))["id"]
    return REPO_ID

def extract_control(deb):
    data = open(deb, "rb").read()
    i = 8
    entries = {}
    while i < len(data):
        size = int(data[i+48:i+58].decode().strip())
        body = data[i+60:i+60+size]
        name = data[i:i+16].decode("ascii", "replace").rstrip(" ").rstrip("/")
        entries[name] = body
        i = i + 60 + size
        if i % 2 == 1:
            i += 1
    for k in entries:
        if k.startswith("control.tar"):
            b = entries[k]
            if k.endswith(".gz"):
                b = gzip.decompress(b)
            tf = tarfile.open(fileobj=io.BytesIO(b))
            for m in tf.getmembers():
                if m.isfile() and m.name.endswith("control"):
                    return tf.extractfile(m).read().decode("utf-8", "replace")
    raise RuntimeError("control 未找到: %s" % deb)

def build_entry(ctrl, filename, size, md5, sha1, sha256):
    # 保留 control 的关键字段顺序，足够 Cydia/Sileo 使用
    order = ["Package", "Name", "Version", "Section", "Depends",
             "Maintainer", "Author", "Description", "Architecture"]
    lines = []
    for f in order:
        m = re.search(r"(?m)^%s: *(.*?)\s*$" % re.escape(f), ctrl)
        if m:
            lines.append("%s: %s" % (f, m.group(1)))
    lines += [
        "Filename: %s" % filename,
        "Size: %d" % size,
        "MD5sum: %s" % md5,
        "SHA1: %s" % sha1,
        "SHA256: %s" % sha256,
    ]
    return "\n".join(lines)

def split_stanzas(text):
    return [s for s in re.split(r"\n\n+", text) if s.strip()]

def main():
    debs = sys.argv[1:]
    if not debs:
        print("用法: python3 publish_onyx.py <deb1> [deb2 ...]")
        sys.exit(2)

    print(">> 拉取当前 Packages ...")
    pkgs = gh("repos/%s/contents/Packages?ref=main" % REPO, raw=True)
    stanzas = split_stanzas(pkgs)
    print("   现有 stanza:", len(stanzas))

    entries = []
    for deb in debs:
        deb_bytes = open(deb, "rb").read()
        deb_name = os.path.basename(deb)
        ctrl = extract_control(deb)
        pkg = re.search(r"(?m)^Package:\s*(.+)$", ctrl).group(1).strip()
        ver = re.search(r"(?m)^Version:\s*(.+)$", ctrl).group(1).strip()
        arch = re.search(r"(?m)^Architecture:\s*(.+)$", ctrl).group(1).strip()
        size = len(deb_bytes)
        md5 = hashlib.md5(deb_bytes).hexdigest()
        sha1 = hashlib.sha1(deb_bytes).hexdigest()
        sha2 = hashlib.sha256(deb_bytes).hexdigest()
        ce = build_entry(ctrl, "debs/" + deb_name, size, md5, sha1, sha2)
        entries.append((pkg, ver, arch, ce, deb_name, deb_bytes))

    # 用最新且轻量的实现替换所有 Onyx 条目（同包 + 同架构）
    kept = []
    for s in stanzas:
        m = re.search(r"(?m)^Package:\s*(.+)$", s)
        p = m.group(1).strip() if m else ""
        a = re.search(r"(?m)^Architecture:\s*(.+)$", s)
        aa = a.group(1).strip() if a else ""
        onyx = (p == "com.yzdmm.onyx")
        if onyx:
            # 会被新条目覆盖的同包同架构
            if any(x[0] == p and x[2] == aa for x in entries):
                continue
        kept.append(s)
    for (pkg, ver, arch, ce, deb_name, deb_bytes) in entries:
        kept.append(ce)
    new_pkgs = "\n\n".join(kept) + "\n"

    print(">> 新 sanity")
    for (pkg, ver, arch, ce, deb_name, deb_bytes) in entries:
        ok = all(k in ce for k in ("Filename:", "Size:", "MD5sum:", "SHA1:", "SHA256:"))
        print("   %s_%s_%s fields_ok=%s" % (pkg, ver, arch, ok))
        if not ok:
            sys.exit(1)

    # 组装 git tree 提交
    ref = json.loads(gh("repos/%s/git/ref/heads/main" % REPO))
    base = ref["object"]["sha"]
    c = json.loads(gh("repos/%s/git/commits/%s" % (REPO, base)))
    base_tree = c["tree"]["sha"]

    pkgs_utf8 = new_pkgs.encode("utf-8")
    gz = gzip.compress(pkgs_utf8, 9)
    bz = bz2.compress(pkgs_utf8, 9)
    from email.utils import formatdate
    now = formatdate(usegmt=True)
    head = (
        "Origin: Ac`ljcr\n"
        "Label: Ac`ljcr\n"
        "Suite: stable\n"
        "Codename: stable\n"
        "Version: 1.0\n"
        "Architectures: iphoneos-arm64 iphoneos-arm64e\n"
        "Components: main\n"
        "Description: Ac`ljcr 越狱插件源（定位模拟等）\n"
        "Date: %s\n" % now
    )
    bm5, bs1, bs256 = [], [], []
    for nm, d in (("Packages", pkgs_utf8), ("Packages.gz", gz), ("Packages.bz2", bz)):
        bm5.append(" %s %d %s" % (hashlib.md5(d).hexdigest(), len(d), nm))
        bs1.append(" %s %d %s" % (hashlib.sha1(d).hexdigest(), len(d), nm))
        bs256.append(" %s %d %s" % (hashlib.sha256(d).hexdigest(), len(d), nm))
    new_release = (head + "MD5Sum:\n" + "\n".join(bm5) + "\nSHA1:\n" + "\n".join(bs1) +
                   "\nSHA256:\n" + "\n".join(bs256) + "\n")

    # 收集上传文件 + 删除旧 deb
    files = {
        "Packages": pkgs_utf8,
        "Packages.gz": gz,
        "Packages.bz2": bz,
        "Release": new_release.encode("utf-8"),
    }
    for (pkg, ver, arch, ce, deb_name, deb_bytes) in entries:
        files["debs/" + deb_name] = deb_bytes

    # 清理 debs/ 里同包同架构的旧版本
    old_debs = []
    try:
        listing = json.loads(gh("repos/%s/contents/debs?ref=main" % REPO))
        for ent in listing:
            n = ent.get("name", "")
            if n.startswith("com.yzdmm.onyx_"):
                for (pkg, ver, arch, ce, deb_name, deb_bytes) in entries:
                    if n.endswith("_%s.deb" % arch) and n != deb_name:
                        old_debs.append("debs/" + n)
                        break
    except Exception as e:
        print("   [warn] 列 debs 失败:", e)
    old_debs = list(dict.fromkeys(old_debs))
    if old_debs:
        print("   删除旧 deb:", len(old_debs))

    blobs = {}
    for path, data in files.items():
        sha = json.loads(gh("repos/%s/git/blobs" % REPO,
                            payload={"content": base64.b64encode(data).decode(),
                                     "encoding": "base64"}))["sha"]
        blobs[path] = sha
    entries2 = [{"path": p, "mode": "100644", "type": "blob", "sha": s}
                for p, s in blobs.items()]
    for p in old_debs:
        entries2.append({"path": p, "mode": "100644", "type": "blob", "sha": None})
    tree = json.loads(gh("repos/%s/git/trees" % REPO,
                         payload={"base_tree": base_tree, "tree": entries2}))["sha"]
    commit = json.loads(gh("repos/%s/git/commits" % REPO,
                           payload={"message": "Onyx 1.4.3: 真正修复定位失效（Filter 改回 WildCard UIKit，per-app hook 生效）",
                                    "tree": tree, "parents": [base]}))["sha"]
    gh("repos/%s/git/refs/heads/main" % REPO, payload={"sha": commit, "force": False})
    print("PUSHED OK ->", commit)

if __name__ == "__main__":
    main()