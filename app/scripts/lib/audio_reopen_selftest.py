#!/usr/bin/env python3
"""Offline integration check: known packets, planned gaps, and guard failure."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    analyzer = Path(__file__).with_name('audio_packet_analyze.py')
    with tempfile.TemporaryDirectory(prefix='mirage-reopen-selftest-') as tmp:
        root = Path(tmp)
        (root/'capture.json').write_text(json.dumps(dict(start_epoch=1000, seconds=150, package='test.game')))
        guards = [dict(second=t, audio=dict(start=1000+t, end=1000+t), valid=True,
                       playing=1, foreground='test.game', other_started=[],
                       target_players=[dict(piid=1,pid=2,state='started',raw='FormatInfo{sampleRate=48000}')]) for t in range(151)]
        def save_guards():
            (root/'guards.jsonl').write_text('\n'.join(json.dumps(g) for g in guards)+'\n')
        save_guards()
        lines = []
        for number in range(1,11):
            opened = 1000+(number-1)*15
            lines.append(f'[audio-rpc] event=open round={number} epoch={opened}')
            lines.append('[audio] 收到的格式：sr=48000 ch=stereo fmt=audFmtS16')
            for offset in range(1,16):
                size = 1920 if number <= 5 else 136
                count = 100 if offset <= 10 else 0
                hist = f'{{{size}:100}}' if count else '{}'
                lines.append(f'[audio] pkt={count} smp={size*count//2} rxpkt={count} rxbytes={size*count} pkt_bytes={hist} window_end={opened+offset} window_seconds=1 over=0')
                if offset == 10:
                    for event, delay in [('cancel',0),('response-ended',.001),('closed',.002)]:
                        lines.append(f'[audio-rpc] event={event} round={number} epoch={opened+10+delay}')
        lines.append('[audio-rpc] event=complete round=10 epoch=1150')
        (root/'app.log').write_text('\n'.join(lines))
        def run():
            subprocess.run([sys.executable,'-B',str(analyzer),str(root)],check=True,capture_output=True)
            return json.loads((root/'summary.json').read_text())
        result = run()
        assert result['candidate_t'] == 77 and result['confirmed_t'] == 81
        assert result['pre']['histogram'] == {'1920':3000}
        assert result['post']['histogram'] == {'136':3000}
        assert result['comparison_available']
        assert result['invalid_reasons']['rpc_off_or_boundary'] == 50
        assert result['invalid_reasons']['rpc_startup'] == 10
        assert all(r['zero_windows']==0 for r in result['per_rpc'])
        guards[82]['valid']=False
        guards[82]['playing']=None
        save_guards()
        result=run()
        assert result['invalid_guards']==1 and result['target_stopped_guards']==0
        assert result['invalid_reasons']['query_invalid']==2
        assert result['candidate_t']==77
        # A run of low windows split by a planned gap must not form a five-window streak.
        for i,line in enumerate(lines):
            if '[audio] pkt=' in line:
                end=int(line.split('window_end=')[1].split()[0])
                phase=(end-1000-1)%15+1
                if phase in [5,6]:
                    lines[i]=line.replace('pkt=100 smp=6800 rxpkt=100 rxbytes=13600 pkt_bytes={136:100}',
                                          'pkt=100 smp=96000 rxpkt=100 rxbytes=192000 pkt_bytes={1920:100}')
        (root/'app.log').write_text('\n'.join(lines))
        assert run()['candidate_t'] is None
    print('PASS: exact pre/post buckets; planned off/startup excluded; invalid guard not stopped; no low streak across RPC gaps')


if __name__ == '__main__':
    main()
