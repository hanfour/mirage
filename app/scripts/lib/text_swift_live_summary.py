#!/usr/bin/env python3
"""Recompute Task 4 from actual field evidence, never from clipboard/RPC OK alone."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics

NAMES={'mixed','repeated','emoji','accent','zwj','ascii','insert','replace','burst-same','burst-distinct'}


def summarize(directory, positions_only=False, require_reselection=False):
    records=[]
    for path in directory.glob('*.json'):
        row=json.loads(path.read_text())
        if 'passed' in row:
            records.append(row)
    names={"insert","replace"} if positions_only else NAMES
    count=len(names)*6
    expected={(ms,round,name) for ms in [100,250] for round in [1,2,3] for name in names}
    actual={(r['settleMilliseconds'],r['round'],r['name']) for r in records}
    if actual!=expected or len(records)!=count or (directory/'run-failure.json').exists():
        raise ValueError(f'{directory.name}: incomplete or failed live run; {len(records)} cases')
    run=json.loads((directory/'run-summary.json').read_text())
    if run['completedCases']!=count or run['connectionCount']!=1:
        raise ValueError('run count or connection continuity failed')
    groups=defaultdict(list)
    for r in records:
        before,after=r['before'],r['after']
        assert before['fresh'] and after['fresh'] and before['focused'] and after['focused']
        assert before['package']==after['package'] and before['field']==after['field']
        assert after['className']=='android.widget.EditText' and after['capturedAt']>=r['start']
        assert r['passed'] and after['text'].encode()==r['expected'].encode()
        assert r['outcomes']==['submittedUnverified']*len(r['chunks'])
        assert all('error' not in rpc for rpc in r['rpc'])
        if r['name']=='insert':
            assert before['text']=='LEFTRIGHT' and after['text']=='LEFT中文🙂RIGHT'
        elif r['name']=='replace':
            assert before['text']=='LEFToldRIGHT' and r['selectionClipboardProof']=='old'
            assert after['text']=='LEFT中文🙂RIGHT'
            if require_reselection: assert r['selectionReappliedAfterCopy']
        else:
            assert before['text']=='' and r['expected']==''.join(r['chunks'])
        groups[r['settleMilliseconds']].append(r)
    result={}
    for ms,rows in sorted(groups.items()):
        gaps=[]
        holds=[]
        for r in rows:
            if not r['name'].startswith('burst-'):continue
            writes=[rpc['start'] for rpc in r['rpc'] if rpc['operation']=='setClipboard']
            ups=[rpc['end'] for rpc in r['rpc'] if rpc['operation']=='key:Control:false']
            assert len(writes)==len(ups)==20
            gaps.extend((b-a)*1000 for a,b in zip(writes,writes[1:]))
            holds.extend((write-up)*1000 for write,up in zip(writes[1:],ups[:-1]))
        # Actual delays are observations, not a universal guest-consumption guarantee.
        if holds: assert min(holds)>=ms-.5
        result[str(ms)]=dict(cases=len(rows),passed=len(rows),rounds=3,
                            insert_passes=sum(r['name']=='insert' for r in rows),
                            replace_passes=sum(r['name']=='replace' for r in rows),
                            burst_passes=sum(r['name'].startswith('burst-') for r in rows),
                            actual_start_gap_min_ms=min(gaps) if gaps else None,actual_start_gap_median_ms=statistics.median(gaps) if gaps else None,
                            actual_hold_min_ms=min(holds) if holds else None,actual_hold_median_ms=statistics.median(holds) if holds else None)
    final=json.loads((directory/'final-field.json').read_text())
    assert final['text']=='' and final['focused'] and final['fresh']
    return dict(scope="positions-only" if positions_only else "full",target=records[0]['after']['package'],policies=result,final_draft_empty=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('--positions-only',action='store_true')
    p.add_argument('--require-reselection',action='store_true')
    args=p.parse_args()
    result=summarize(args.directory,args.positions_only,args.require_reselection)
    (args.directory/'verified-summary.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
