#!/usr/env python3
# -*- coding: utf-8 -*-
"""push_deb.py — 把指定 deb 发布到越狱源 yzdmm2024/repo（Git Data API 增量提交）。

用法:
    python3 push_deb.py <path-to.deb> ["提交说明"]

会自动:
  1. 用 _archive/sources/repo-src/tools/update.py 解析 deb control 并生成 stanza
  2. 拉取仓库当前 Packages, 替换本包旧条目
  3. 重算 Packages / Packages.gz / Packages.bz2 / Release 哈希
  4. 上传 deb 到 debs/, 提交到 main
"""
import json, base64, hashlib, gzip, bz2, os, re, subprocess, sys, tempfile
from email.utils import formatdate

TOOLS = r"C:\Users\10131\Desktop\我自己写的插件\超级截图\_archive\sources\repo-src\tools"
sys.path.insert(0, TOOLS)
import update as U

REPO = "yzdmm2024/repo"

# v6.20.16 起统一用仓库 ID 调 API：GitHub 对 POST /repos/{slug}/... 会 307 重定向到
# repositories/{id}（gh 不跟随 POST 重定向 → 直接失败），GET 才会自动跟随。
REPO_ID = None


def _repo_id():
    global REPO_ID
    if not REPO_ID:
        REPO_ID = json.loads(gh("repos/%s" % REPO))["id"]
    return REPO_ID


def gh(args, payload=None, raw=False):
    cmd = ["gh", "api"]

# 包名 -> 图标文件名（相对 repo 根 ./icons/）。推包时自动写入 Icon: 字段。
ICON_MAP = {
    "com.axs.superscreenshot": "superscreenshot.png",
    "com.ntm.batteryanalyzer": "batteryanalyzer.png",
    "com.ntm.notifymanager": "notifymanager.png",
    "com.yzdmm.kkgameautologin": "kkgameautologin.png",
    "com.roa.randopenapp": "randopenapp.png",
    "com.ntm.privacymanager": "privacymanager.png",
}


def gh(args, payload=None, raw=False):
    cmd = ["gh", "api"]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    if isinstance(args, str):
        args = [args]
    cmd += list(args)
    if payload is not None:
        body = json.dumps(payload)
        r = subprocess.run(cmd + ["--input", "-"], input=body, capture_output=True, text=True)
    else:
        r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("API失败: %s\n%s" % (r.stdout[:800], r.stderr[:800]))
    return r.stdout


def split_stanzas(text):
    return [s for s in re.split(r"\n\n+", text) if s.strip()]


def main():
    if len(sys.argv) < 2:
        print("用法: python3 push_deb.py <deb路径> [提交说明]")
        sys.exit(2)
    DEB = sys.argv[1]
    MSG = sys.argv[2] if len(sys.argv) > 2 else None
    if not os.path.exists(DEB):
        raise RuntimeError("找不到 deb: %s" % DEB)

    deb_bytes = open(DEB, "rb").read()
    deb_name = os.path.basename(DEB)
    ctrl = U.extract_control(DEB)
    # 取包名 / 版本（用于替换旧条目 + 校验）
    def field(name):
        m = re.search(r"(?m)^%s:\s*(.+)$" % re.escape(name), ctrl)
        return m.group(1).strip() if m else ""
    PKG_ID = field("Package")
    NEW_VERSION = field("Version")
    if not PKG_ID or not NEW_VERSION:
        raise RuntimeError("control 缺少 Package/Version: %r" % ctrl[:200])

    ce = U.build_entry(ctrl, "debs/" + deb_name, len(deb_bytes),
                       hashlib.md5(deb_bytes).hexdigest(),
                       hashlib.sha1(deb_bytes).hexdigest(),
                       hashlib.sha256(deb_bytes).hexdigest())
    ce = "\n".join(l for l in ce.split("\n") if l.strip())
    if not ce.endswith("\n"):
        ce += "\n"
    # 自动带图标字段（图标文件需已通过 push_icons.py 推到 ./icons/）
    if PKG_ID in ICON_MAP:
        ce = ce.rstrip("\n") + "\nIcon: ./icons/" + ICON_MAP[PKG_ID] + "\n"

    print(">> 拉取仓库当前 Packages ...")
    pkgs = gh("repositories/%s/contents/Packages?ref=main" % _repo_id(), raw=True)
    stanzas = split_stanzas(pkgs)
    print("   当前 stanza 数:", len(stanzas))

    kept = [s for s in stanzas if ("Package: %s" % PKG_ID) not in s]
    print("   删除旧 %s 条目后剩余: %d" % (PKG_ID, len(kept)))
    kept.append(ce.rstrip("\n"))
    new_pkgs = "\n\n".join(kept) + "\n"

    rs = split_stanzas(new_pkgs)
    t = [s for s in rs if PKG_ID in s and ("Version: %s" % NEW_VERSION) in s]
    print("===== %s 条目 =====" % NEW_VERSION)
    print(t[0] if t else "!! 缺失")
    have = bool(t) and all(k in t[0] for k in ("Filename:", "Size:", "MD5sum:", "SHA1:", "SHA256:"))
    print(">>> 字段齐全:", have, "| %s 出现次数:" % NEW_VERSION, len(t))
    if not have or not t:
        print("!! 放弃")
        sys.exit(1)

    ref = json.loads(gh("repositories/%s/git/ref/heads/main" % _repo_id()))
    base_commit = ref["object"]["sha"]
    c = json.loads(gh("repositories/%s/git/commits/%s" % (_repo_id(), base_commit)))
    base_tree = c["tree"]["sha"]
    print("base:", base_commit)

    pkgs_utf8 = new_pkgs.encode("utf-8")
    gz = gzip.compress(pkgs_utf8, 9)
    bz = bz2.compress(pkgs_utf8, 9)
    # 每次发布都重写标准 Release 头（源名称/架构/版本），不再沿用旧头，
    # 解决 Sileo “Didn't find available architectures” 警告 + 源名称显示为 GitHub 用户名的问题。
    now = formatdate(usegmt=True)
    head = (
        "Origin: Ac`ljcr\n"
        "Label: Ac`ljcr\n"
        "Suite: stable\n"
        "Codename: stable\n"
        "Version: 1.0\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        "Description: Ac`ljcr 越狱插件源（定位模拟等）\n"
        "Date: %s\n" % now
    )
    bm5, bs1, bs256 = [], [], []
    for name, data in (("Packages", pkgs_utf8), ("Packages.gz", gz), ("Packages.bz2", bz)):
        bm5.append(" %s %d %s" % (hashlib.md5(data).hexdigest(), len(data), name))
        bs1.append(" %s %d %s" % (hashlib.sha1(data).hexdigest(), len(data), name))
        bs256.append(" %s %d %s" % (hashlib.sha256(data).hexdigest(), len(data), name))
    new_release = (head + "MD5Sum:\n" + "\n".join(bm5) + "\nSHA1:\n" + "\n".join(bs1) +
                  "\nSHA256:\n" + "\n".join(bs256) + "\n")

    # ------------------------------------------------------------------
    # 清掉 debs/ 里同包的旧版本 deb 文件。
    #
    # ⚠️ 这一步不能省。仓库里的 gen.yml 会在 debs/** 有变化时重跑
    #    gen_packages.py，它**扫描整个 debs/ 目录**重建 Packages。
    #    所以只删 Packages 里的旧条目是没用的 —— 旧 deb 文件还在，
    #    regen 一跑条目又全回来了（实测：0.1.0 条目删掉后又自己出现，
    #    而且 debs/ 里会越堆越多，myvoice 一度堆到 37 个版本）。
    # ------------------------------------------------------------------
    old_debs = []
    try:
        listing = json.loads(gh("repositories/%s/contents/debs?ref=main" % _repo_id()))
        for ent in listing:
            n = ent.get("name", "")
            if n.startswith(PKG_ID + "_") and n != deb_name:
                old_debs.append("debs/" + n)
    except Exception as e:
        print("   [warn] 列 debs/ 目录失败，跳过清理:", e)
    if old_debs:
        print("   将删除同包旧 deb: %d 个" % len(old_debs))
        for p in old_debs:
            print("      - " + p)

    files = {
        "Packages": pkgs_utf8,
        "Packages.gz": gz,
        "Packages.bz2": bz,
        "Release": new_release.encode("utf-8"),
        "debs/" + deb_name: deb_bytes,
    }
    blobs = {}
    for path, data in files.items():
        sha = json.loads(gh("repositories/%s/git/blobs" % _repo_id(),
                            payload={"content": base64.b64encode(data).decode(), "encoding": "base64"}))["sha"]
        blobs[path] = sha
    entries = [{"path": p, "mode": "100644", "type": "blob", "sha": s}
               for p, s in blobs.items()]
    # 删除旧 deb：tree entry 的 sha 传 null。
    # 只对**确实还存在**的路径这么做 —— 对已不存在的路径再删一次会 422 BadObjectState。
    for p in old_debs:
        entries.append({"path": p, "mode": "100644", "type": "blob", "sha": None})
    tree = json.loads(gh("repositories/%s/git/trees" % _repo_id(),
                         payload={"base_tree": base_tree,
                                  "tree": entries}))["sha"]
    commit_msg = MSG or ("%s v%s" % (PKG_ID, NEW_VERSION))
    commit = json.loads(gh("repositories/%s/git/commits" % _repo_id(),
                           payload={"message": commit_msg,
                                    "tree": tree, "parents": [base_commit]}))["sha"]
    gh("repositories/%s/git/refs/heads/main" % _repo_id(), payload={"sha": commit, "force": False})
    print("PUSHED OK ->", commit)


if __name__ == "__main__":
    main()
