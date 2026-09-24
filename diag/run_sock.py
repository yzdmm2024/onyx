#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Attach OnyxApp 运行 sock_probe.js，带重试。"""
import frida, sys, time, os
js = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sock_probe.js"), encoding="utf-8").read()
d = frida.get_usb_device(timeout=8)
pid = None
for p in d.enumerate_processes():
    if (p.name or "").lower() == "onyxapp":
        pid = p.pid; break
print("onyx pid", pid)
if pid is None: print("OnyxApp 未运行，请打开"); sys.exit(1)
sess = None
for i in range(6):
    try:
        sess = d.attach(pid); break
    except Exception as e:
        print("retry", i, str(e)[:50]); time.sleep(2)
if sess is None: print("attach FAIL"); sys.exit(1)
sc = sess.create_script(js)
sc.on("message", lambda m, data: print(m["type"], m.get("payload") or m.get("description") or m.get("stack")))
sc.load()
time.sleep(4)
try: sc.unload()
except Exception: pass