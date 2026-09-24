#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spawn OnyxApp 读版本+网络。rootless 下 bundle id com.yzdmm.onyx.app。"""
import frida, sys, time, os
js = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "spawncheck.js"), encoding="utf-8").read()
d = frida.get_usb_device(timeout=8)
print("device", d.id)
target = "com.yzdmm.onyx.app"
try:
    pid = d.spawn([target])
    print("spawned pid", pid)
except Exception as e:
    print("spawn ERR:", str(e)[:150])
    # 回退到 attach
    for p in d.enumerate_processes():
        if (p.name or "").lower() == "onyxapp":
            pid = p.pid; print("attach instead pid", pid); break
sess_fail = True
for k in range(5):
    try:
        sess = d.attach(pid); sess_fail = False; break
    except Exception as e:
        print("att retry", k, str(e)[:40]); time.sleep(2)
if sess_fail:
    print("attach fail"); sys.exit(1)
sc = sess.create_script(js)
sc.on("message", lambda m, data: print(m["type"], m.get("payload") or m.get("description") or m.get("stack")))
sc.load()
time.sleep(3)
try: sc.unload()
except: pass
try: d.resume(pid)
except: pass