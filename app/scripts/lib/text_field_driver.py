#!/usr/bin/env python3
"""Task 4 observer/setup only. Unicode under test is sent by Swift, never here."""
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/probe'))
from lib.framebuffer import parse_screencap_raw
from lib.png import encode_rgba


def main():
    signal.alarm(60)
    req=json.load(sys.stdin)
    adb=str(Path.home()/'Library/Android/sdk/platform-tools/adb')
    def run(*args,binary=False):
        p=subprocess.run([adb,'-s',req['serial'],*args],capture_output=True,text=not binary,timeout=20)
        if p.returncode:
            raise RuntimeError(f'adb failed: {args}: {p.stderr!r}')
        return p.stdout
    def field():
        run('shell','rm','-f','/sdcard/mirage-text-task4.xml')
        status=run('shell','uiautomator','dump','/sdcard/mirage-text-task4.xml')
        if 'dumped to:' not in status:
            raise RuntimeError('fresh UI dump unavailable')
        raw=run('exec-out','cat','/sdcard/mirage-text-task4.xml')
        tree=ET.fromstring(raw[raw.index('<hierarchy'):])
        nodes=[n for n in tree.iter('node') if n.get('resource-id')==req['field']]
        if len(nodes)!=1:
            raise RuntimeError('target field missing or ambiguous')
        n=nodes[0]
        if n.get('package')!=req['package'] or n.get('class')!='android.widget.EditText':
            raise RuntimeError('target identity changed')
        raw_text=n.get('text','')
        return dict(package=n.get('package'),field=n.get('resource-id'),className=n.get('class'),
                    focused=n.get('focused')=='true',text='' if raw_text==req.get('emptyLabel','') else raw_text,
                    rawText=raw_text,bounds=list(map(int,re.findall(r'\d+',n.get('bounds','')))),
                    capturedAt=time.time(),fresh=True)
    def tap(n):
        x1,y1,x2,y2=n['bounds']
        run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
    n=field()
    action=req['action']
    if 'expectedCurrent' in req and n['text']!=req['expectedCurrent']:
        raise RuntimeError('field changed unexpectedly; refusing to clear or edit it')
    if action=='clear':
        tap(n)
        run('shell','input','keycombination','KEYCODE_CTRL_LEFT','KEYCODE_A')
        run('shell','input','keyevent','KEYCODE_DEL')
        n=field()
        if n['text']!='' or not n['focused']:
            raise RuntimeError('clear/focus precondition failed')
    elif action=='paste-seed':
        # The ASCII seed was set through the Swift queue, not this helper.
        if req.get('seed') not in ['LEFTRIGHT','LEFToldRIGHT'] or n['text']!='' or not n['focused']:
            raise RuntimeError('invalid seed setup')
        run('shell','input','keyevent','KEYCODE_PASTE')
        n=field()
        if n['text']!=req['seed']:
            raise RuntimeError('seed was not inserted exactly')
    elif action in ['place-insert','place-replace']:
        if not n['focused']:
            raise RuntimeError('position requires focus')
        run('shell','input','keyevent','KEYCODE_MOVE_HOME')
        for _ in range(4):
            run('shell','input','keyevent','KEYCODE_DPAD_RIGHT')
        if action=='place-replace':
            for _ in range(3):
                run('shell','input','keycombination','KEYCODE_SHIFT_LEFT','KEYCODE_DPAD_RIGHT')
        n=field()
    elif action=='copy-selection':
        # Sentinel is set/read by Swift beforehand. This must copy actual selected text.
        run('shell','input','keycombination','KEYCODE_CTRL_LEFT','KEYCODE_C')
        n=field()
    elif action!='observe':
        raise RuntimeError('unsupported action (no send/Enter actions exist)')
    if req.get('image'):
        w,h,rgba=parse_screencap_raw(run('exec-out','screencap',binary=True))
        x1,y1,x2,y2=n['bounds']
        if not (0<=x1<x2<=w and 0<=y1<y2<=h):
            raise RuntimeError('bad crop bounds')
        crop=b''.join(rgba[(y*w+x1)*4:(y*w+x2)*4] for y in range(y1,y2))
        Path(req['image']).write_bytes(encode_rgba(x2-x1,y2-y1,crop))
    print(json.dumps(n,ensure_ascii=False))


if __name__=='__main__':
    try:
        main()
    except Exception as exc:
        print(str(exc),file=sys.stderr)
        sys.exit(2)
