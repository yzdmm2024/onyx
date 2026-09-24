#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""attach 到指定 pid 跑脚本。用法 run_pid.py <pid> <script.js>"""
import frida, sys, time
d = frida.get_device('00008101-0012241C3A7A001E', timeout=8)
pid = int(sys.argv[1])
JS = open(sys.argv[2], encoding='utf-8').read()
def on_message(m, dd):
    if m.get('type') == 'message':
        print(m.get('payload'))
    else:
        print('[msge]', m)
print('attach pid', pid)
s = d.attach(pid)
script = s.create_script(JS)
script.on('message', on_message)
script.load()
time.sleep(4)
try: s.detach()
except Exception: pass
print('done')