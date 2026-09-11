#!/usr/bin/env python3
"""Offline verification of saved field results; clipboard equality is not PASS."""
import argparse
from collections import Counter
import json
from pathlib import Path
import statistics


def summarize(root):
    result={}
    for name,expected_count in [('edittext',24),('edittext-stress',12),('line',24),('line-stress',12)]:
        cases=[json.loads(x) for x in (root/name/'cases.jsonl').read_text().splitlines()]
        assert len(cases)==expected_count, name
        output=[]
        for c in cases:
            assert c['before']['focused']=='true' and c['before']['actual_text']==''
            if 'error' in c:
                verdict='blocked' if 'expected native Paste menu' in c['error'] else 'unknown'
                assert not c['pass']
            else:
                exact=c['actual']==c['expected'] and c['after']['focused']=='true'
                assert exact==c['pass']
                assert c['actual_codepoints']==[f'U+{ord(x):04X}' for x in c['actual']]
                assert c['expected_codepoints']==[f'U+{ord(x):04X}' for x in c['expected']]
                verdict='pass' if exact else 'mismatch'
            times=[o['start'] for o in c['operations'] if o['action']=='setClipboard']
            intervals=[(b-a)*1000 for a,b in zip(times,times[1:])]
            output.append(dict(route=c['route'],label=c['label'],verdict=verdict,
                               requested_gap_ms=c['delay']*1000,
                               commit_start_gap_min_ms=min(intervals) if intervals else None,
                               commit_start_gap_median_ms=statistics.median(intervals) if intervals else None,
                               commit_start_gap_max_ms=max(intervals) if intervals else None,
                               rpc_errors=[o for o in c['operations'] if 'status' in o and o['status'] not in ['OK','exit-0']],
                               clipboard_readbacks=sum(o['action']=='clipboard_readback' for o in c['operations'])))
        result[name]=dict(counts=dict(Counter(x['verdict'] for x in output)),cases=output)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    args=p.parse_args()
    result=summarize(args.directory)
    (args.directory/'summary.json').write_text(json.dumps(result,indent=2))
    for name,part in result.items():
        print(name,part['counts'])
        for c in part['cases']:
            if 'distinct' in c['label']:
                print(c['route'],c['label'],c['verdict'],'actual median gap ms',round(c['commit_start_gap_median_ms'],3))


if __name__=='__main__':
    main()
