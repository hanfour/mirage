#!/usr/bin/env python3
"""Explicit, draft-only channel experiment. Never sends Enter or a send action.
Run with phase0/harness/.venv-d45/bin/python. Only target field evidence is saved.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'phase0/harness/gen'))
sys.path.insert(0, str(ROOT/'tools/probe'))
import grpc
from google.protobuf.empty_pb2 import Empty
import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg
from lib.framebuffer import parse_screencap_raw
from lib.png import encode_rgba

CORPUS = [
    ('mixed', 'Mirage IME 中文測試 42！'),
    ('repeated', '你好你好'),
    ('emoji', '你好🙂'),
    ('accent', 'é e\u0301'),
    ('zwj', '👩🏽\u200d💻👨\u200d👩\u200d👧\u200d👦'),
    ('ascii', 'Mirage ASCII 42'),
]
ROUTES = ['text', 'ctrl_v', 'android_paste', 'ui_paste']


def bounds(node):
    return tuple(map(int, re.findall(r'\d+', node['bounds'])))


class Probe:
    def __init__(self, args):
        self.args = args
        self.adb = str(Path.home()/'Library/Android/sdk/platform-tools/adb')
        self.channel = grpc.insecure_channel('localhost:8554')
        self.stub = pbg.EmulatorControllerStub(self.channel)
        self.log = []

    def adb_run(self, *args, binary=False):
        result = subprocess.run([self.adb,'-s',self.args.serial,*args], capture_output=True,
                                text=not binary, timeout=20)
        if result.returncode:
            raise RuntimeError(f'adb {args}: {result.stderr!r}')
        return result.stdout

    def tree(self):
        self.adb_run('shell','rm','-f','/sdcard/mirage-text-probe.xml')
        status=self.adb_run('shell','uiautomator','dump','/sdcard/mirage-text-probe.xml')
        if 'dumped to:' not in status:
            raise RuntimeError('fresh UI hierarchy unavailable: '+status)
        raw = self.adb_run('exec-out','cat','/sdcard/mirage-text-probe.xml')
        return ET.fromstring(raw[raw.index('<hierarchy'):])

    def field(self, tree=None):
        tree = self.tree() if tree is None else tree
        found = [n.attrib.copy() for n in tree.iter('node') if n.get('resource-id')==self.args.field]
        if len(found)!=1:
            raise RuntimeError(f'expected one target field, got {len(found)}')
        node = found[0]
        if node['package']!=self.args.package or node['class']!='android.widget.EditText':
            raise RuntimeError('target field identity changed')
        node['actual_text'] = '' if node.get('text')==self.args.empty_label else node.get('text','')
        return node

    def tap(self, node):
        x1,y1,x2,y2 = bounds(node)
        self.adb_run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))

    def clear(self):
        node = self.field()
        self.tap(node)
        self.adb_run('shell','input','keycombination','113','29')  # Android Ctrl+A, setup only
        self.adb_run('shell','input','keyevent','67')              # Android DEL, never Enter
        time.sleep(.2)
        node = self.field()
        if node['focused']!='true' or node['actual_text']!='':
            raise RuntimeError('precondition failed: field not focused and empty: '+repr(node))
        return node

    def rpc(self, name, request):
        started = time.time()
        try:
            reply = getattr(self.stub,name)(request,timeout=5)
            self.log.append(dict(action=name,start=started,end=time.time(),status='OK'))
            return reply
        except grpc.RpcError as exc:
            self.log.append(dict(action=name,start=started,end=time.time(),status=str(exc.code())))
            raise  # No resend after timeout/ambiguous delivery.

    def clipboard(self, text):
        self.rpc('setClipboard',pb.ClipData(text=text))
        deadline=time.monotonic()+2
        while True:
            reply=self.rpc('getClipboard',Empty())
            if reply.text==text:
                self.log.append(dict(action='clipboard_readback',equal=True,characters=len(text)))
                return
            if time.monotonic()>deadline:
                raise RuntimeError('clipboard readback mismatch; Paste not sent')
            time.sleep(.05)  # Read-only observation; never repeats set/Paste.

    def key(self, key, down):
        self.rpc('sendKey',pb.KeyboardEvent(key=key,eventType=pb.KeyboardEvent.keydown if down else pb.KeyboardEvent.keyup))

    def send(self, route, text):
        if route=='text':
            self.rpc('sendKey',pb.KeyboardEvent(text=text))
            return
        self.clipboard(text)
        if route=='ctrl_v':
            try:
                self.key('Control',True)
                self.key('v',True)
            finally:
                # Cleanup key releases only, never repeat the paste action.
                try:
                    self.key('v',False)
                finally:
                    self.key('Control',False)
        elif route=='android_paste':
            self.adb_run('shell','input','keyevent','KEYCODE_PASTE')
            self.log.append(dict(action='adb_KEYCODE_PASTE',status='exit-0',epoch=time.time()))
        elif route=='ui_paste':
            node=self.field()
            if node['focused']!='true' or node['actual_text']!='':
                raise RuntimeError('UI long-press cases require independently cleared empty field')
            x1,y1,x2,y2=bounds(node)
            x,y=(x1+x2)//2,(y1+y2)//2
            self.adb_run('shell','input','swipe',str(x),str(y),str(x),str(y),'900')
            tree=self.tree()
            candidates=[n.attrib for n in tree.iter('node') if n.get('text') in ['Paste','貼上','粘贴','貼り付け']
                        and n.get('package') in ['android',self.args.package]]
            if len(candidates)!=1:
                raise RuntimeError(f'expected native Paste menu, found {len(candidates)}')
            self.log.append(dict(action='native_menu_Paste',node=candidates[0],epoch=time.time()))
            self.tap(candidates[0])
        else:
            raise ValueError(route)

    def screenshot_field(self, node, path):
        w,h,rgba=parse_screencap_raw(self.adb_run('exec-out','screencap',binary=True))
        x1,y1,x2,y2=bounds(node)
        assert 0<=x1<x2<=w and 0<=y1<y2<=h
        crop=b''.join(rgba[(y*w+x1)*4:(y*w+x2)*4] for y in range(y1,y2))
        path.write_bytes(encode_rgba(x2-x1,y2-y1,crop))

    def case(self, route, label, chunks, delay=.25):
        record=dict(route=route,label=label,chunks=chunks,expected=''.join(chunks),delay=delay,start=time.time())
        self.log=[]
        try:
            record['before']=self.clear()
            for index,text in enumerate(chunks):
                self.send(route,text)
                if index+1<len(chunks):
                    time.sleep(delay)
            time.sleep(.5)
            after=self.field()
            record['after']=after
            record['actual']=after['actual_text']
            record['pass']=after['focused']=='true' and record['actual']==record['expected']
            record['expected_codepoints']=[f'U+{ord(c):04X}' for c in record['expected']]
            record['actual_codepoints']=[f'U+{ord(c):04X}' for c in record['actual']]
            self.screenshot_field(after,self.args.out/f'{route}-{label}.png')
        except Exception as exc:
            record['pass']=False
            record['error']=repr(exc)
            # This is NOT a retry: observe the field once after failure if possible.
            try:
                record['after_error']=self.field()
            except Exception as observation_error:
                record['observation_error']=repr(observation_error)
        record['operations']=self.log
        record['end']=time.time()
        with (self.args.out/'cases.jsonl').open('a') as f:
            f.write(json.dumps(record,ensure_ascii=False)+'\n')
        print(json.dumps({k:record.get(k) for k in ['route','label','pass','actual','error']},ensure_ascii=False),flush=True)
        if 'before' not in record:
            raise RuntimeError('aborting matrix: independent clear/focus precondition failed')
        return record


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial',default='emulator-5554')
    p.add_argument('--package',required=True)
    p.add_argument('--field',required=True)
    p.add_argument('--empty-label',default='')
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--routes',nargs='+',choices=ROUTES,default=ROUTES)
    p.add_argument('--stress',action='store_true')
    args=p.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    probe=Probe(args)
    if args.stress:
        for route in args.routes:
            if route=='ui_paste':
                raise ValueError('UI long-press selection is not an append automation route')
            for delay in [0,.1,.25]:
                for name,chunks in [('same',['你好']*20),('distinct',[f'測{i:02d}🙂 ' for i in range(20)])]:
                    probe.case(route,f'stress-{name}-{delay}',chunks,delay)
    else:
        for route in args.routes:
            for name,text in CORPUS:
                probe.case(route,name,[text])
    probe.clear()  # Leave no test draft behind.
    probe.channel.close()


if __name__=='__main__':
    main()
