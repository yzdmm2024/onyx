#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Attach OnyxApp, run netdiag.js, keep listening N sec to capture live tile requests."""
import frida, sys, time, os

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "netdiag.js")
js = open(SCRIPT, encoding="utf-8").read()
WAIT = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0

d = frida.get_usb_device(timeout=8)
print("device:", d.id, d.name)

# 优先按 pid attach；否则按名
target = None
try:
    for p in d.enumerate_processes():
        if (p.name or "").lower() in ("onyxapp", "onyx"):
            target = p.pid
            break
except Exception:
    target = None
if target is None:
    try:
        target = d.get_process("OnyxApp").pid
    except Exception:
        target = None
if target is None:
    print("无法定位 OnyxApp 进程，请先打开 App")
    sys.exit(1)
print("[attach] OnyxApp pid=", target)
proc = d.attach(target)

script = proc.create_script(js)
def on_message(message, data):
    if message["type"] == "send":
        print("[send]", message["payload"])
    elif message["type"] == "error":
        print("[error]", message.get("stack") or message.get("description"))
    else:
        print("[msg]", message)

script.on("message", on_message)
script.load()
print("[listening] %s sec... (在手机上点一下地图/刷新会触发瓦片请求)" % WAIT)
time.sleep(WAIT)
print("=== done ===")
try:
    script.unload()
except Exception:
    pass