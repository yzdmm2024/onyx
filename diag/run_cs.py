#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spawn OnyxApp + 注入 cs_valid.js，打印签名/信任/网络 entitlement 状态。"""
import frida, sys, time

DEV = '00008101-0012241C3A7A001E'
BUNDLE = 'com.yzdmm.onyx.app'
JS = open(sys.argv[1] if len(sys.argv) > 1 else 'diag/cs_valid.js', encoding='utf-8').read()

d = frida.get_device(DEV, timeout=8)

# 先杀旧进程确保干净 spawn
for a in d.enumerate_applications():
    if a.identifier == BUNDLE and a.pid > 0:
        try:
            d.kill(a.pid)
            print('killed old pid', a.pid)
            time.sleep(1)
        except Exception as e:
            print('kill ignore', e)

pid = d.spawn([BUNDLE])
print('spawned pid', pid)
resume_after = False
script = None

def on_message(m, dd):
    global resume_after
    if m.get('type') == 'message':
        p = m.get('payload')
        print(p if isinstance(p, str) else str(m))
    elif m.get('type') == 'input':
        resume_after = True
        try:
            d.resume(pid)
        except Exception as e:
            print('resume err', e)
    else:
        print('[msg]', m)

s = d.attach(pid)
script = s.create_script(JS)
script.on('message', on_message)
script.load()
# 脚本若没有 input -> resume，则这里手动 resume
d.resume(pid)
# 等待脚本输出完毕
time.sleep(4)
try:
    s.detach()
except Exception:
    pass
print('done')