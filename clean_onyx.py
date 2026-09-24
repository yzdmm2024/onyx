#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从线上 Packages 中剔除指定的 Onyx 旧版本 stanza（保留其余包），并写回仓库。"""
import json, base64, re, subprocess, sys

REPO = "yzdmm2024/repo"

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
        raise RuntimeError("API失败:%s\n%s" % (r.stdout[:600], r.stderr[:600]))
    return r.stdout

def split_stanzas(text):
    return [s for s in re.split(r"\n\n+", text) if s.strip()]

def stanza_pkg(s): 
    m = re.search(r"(?m)^Package:\s*(.+)$", s); return m.group(1).strip() if m else ""
def stanza_version(s):
    m = re.search(r"(?m)^Version:\s*(.+)$", s); return m.group(1).strip() if m else ""
def stanza_arch(s):
    m = re.search(r"(?m)^Architecture:\s*(.+)$", s); return m.group(1).strip() if m else ""

def main():
    raw = gh("repos/%s/contents/Packages?ref=main" % REPO, raw=True)
    stanzas = split_stanzas(raw)
    # 对 Onyx 去重：每个 (pkg, arch) 只保留 Version 最高的一个
    onyx_by_arch = {}
    for s in stanzas:
        if stanza_pkg(s) == "com.yzdmm.onyx":
            ar = stanza_arch(s)
            v = stanza_version(s)
            cur = onyx_by_arch.get(ar)
            # 简单版本比较（数字点分）
            def vnum(x):
                try: return tuple(int(p) for p in x.split("."))
                except: return (0,)
            if not cur or vnum(v) > vnum(cur[0]):
                onyx_by_arch[ar] = (v, s)
    removed = []
    # 对每个 (pkg, arch) 记录应保留的那一份 stanza（按 Version 最高）
    kept_onyx = {(ar, v): s for ar, (v, s) in onyx_by_arch.items()}
    kept = []
    from collections import Counter
    usage = Counter()
    for s in stanzas:
        p = stanza_pkg(s)
        if p == "com.yzdmm.onyx":
            v = stanza_version(s); ar = stanza_arch(s)
            want = kept_onyx.get((ar, v))
            if want is not None and s == want and usage[(ar, v)] == 0:
                usage[(ar, v)] += 1
                kept.append(s)
            else:
                removed.append((v, ar))
            continue
        kept.append(s)
    new = "\n\n".join(kept) + "\n"

    print("onyx per arch kept:", {ar: v for ar,(v,s) in onyx_by_arch.items()})
    print("removed onyx duplicates:", removed)

    ref = json.loads(gh("repos/%s/git/ref/heads/main" % REPO))
    base = ref["object"]["sha"]
    c = json.loads(gh("repos/%s/git/commits/%s" % (REPO, base)))
    blob = json.loads(gh("repos/%s/git/blobs" % REPO,
                         payload={"content": base64.b64encode(new.encode()).decode(), "encoding": "base64"}))["sha"]
    tree = json.loads(gh("repos/%s/git/trees" % REPO,
                         payload={"base_tree": c["tree"]["sha"],
                                  "tree": [{"path":"Packages","mode":"100644","type":"blob","sha":blob}]}))["sha"]
    commit = json.loads(gh("repos/%s/git/commits" % REPO,
                           payload={"message":"dedupe Onyx stanzas", "tree":tree, "parents":[base]}))["sha"]
    gh("repos/%s/git/refs/heads/main" % REPO, payload={"sha": commit, "force": False})
    print("OK ->", commit)

if __name__ == "__main__":
    main()