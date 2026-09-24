#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""attach 到运行中的 OnyxApp 跑脚本。用法 run_attach.py <script.js>"""
import frida, sys, time
d = frida.get_device('00008101-0012241C3A7A001E', timeout=8)
BUNDLE = 'com.yzdmm.onyx.app'
JS = open(sys.argv[1], encoding='utf-8').read()
pid = None
for a in d.enumerate_applications():
    if a.identifier == BUNDLE and a.pid > 0:
        pid = a.pid
        break
if not pid:
    print('OnyxApp 未在运行，先 spawn')
    pid = d.spawn([BUNDLE])
    d.resume(pid)
    time.sleep(2)
print('attach pid', pid)
def on_message(m, dd):
    if m.get('type') == 'message':
        print(m.get('payload'))
    elif m.get('type') == 'input':
        try: d.resume(pid)
        except Exception: pass
    else:
        print('[msge]', m)
s = d.attach(pid)
script = s.create_script(JS)
script.on('message', on_message)
script.load()
time.sleep(4)
try: s.detach()
except Exception: pass
print('done')