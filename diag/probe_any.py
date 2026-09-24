#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Attach 一个进程，运行指定 js，比对 DNS 解析."""
import frida, sys, time, os
procname = sys.argv[1] if len(sys.argv)>1 else "SpringBoard"
js = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "dns_probe.js"), encoding="utf-8").read()
d = frida.get_usb_device(timeout=8)
pid = None
for p in d.enumerate_processes():
    if (p.name or "").lower() == procname.lower():
        pid = p.pid; break
if pid is None:
    print("not running:", procname); sys.exit(1)
s = d.attach(pid)
print("attached", procname, "pid", pid)
sc = s.create_script(js)
sc.on("message", lambda m,d: print(m["type"], m.get("payload") or m.get("description") or m.get("stack")))
sc.load()
time.sleep(2)
sc.unload()