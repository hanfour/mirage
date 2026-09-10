#!/usr/bin/env python3
"""Join source-timestamped audio windows with bracketing one-second UID guards."""
import argparse
import gzip
from collections import Counter
import json
from pathlib import Path
import re


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    p.add_argument('--log', type=Path)
    args = p.parse_args()
    root = args.directory
    meta = json.loads((root / 'capture.json').read_text())
    guard_path = root / 'guards.jsonl'
    guard_text = guard_path.read_text() if guard_path.exists() else gzip.decompress((root / 'guards.jsonl.gz').read_bytes()).decode()
    guards = [json.loads(line) for line in guard_text.splitlines()]
    for g in guards:
        g['t'] = (g['audio']['start'] + g['audio']['end']) / 2
    rows = []
    events = []
    for line_number, line in enumerate((args.log or root / 'app.log').read_text().splitlines(), 1):
        if not line.startswith('[audio] pkt='):
            if '[audio]' in line or '[conn]' in line and any(s in line for s in ['attachStream', '連線', '斷線', 'connected', 'suspend']):
                events.append(dict(line=line_number, text=line))
            continue
        fields = dict(re.findall(r'(\w+)=([^ ]+)', line))
        required = ['pkt','smp','rxpkt','rxbytes','pkt_bytes','window_end','window_seconds','over']
        if any(k not in fields for k in required):
            raise ValueError(f'malformed audio row {line_number}')
        end, dt = float(fields['window_end']), float(fields['window_seconds'])
        start = end - dt
        bins = Counter()
        for pair in fields['pkt_bytes'].strip('{}').split(','):
            if pair:
                size, count = map(int, pair.split(':'))
                bins[size] += count
        rxpkt, rxbytes = int(fields['rxpkt']), int(fields['rxbytes'])
        if sum(bins.values()) != rxpkt or sum(s*c for s,c in bins.items()) != rxbytes:
            raise ValueError(f'histogram total mismatch {line_number}')
        before = [i for i,g in enumerate(guards) if g['t'] <= start]
        after = [i for i,g in enumerate(guards) if g['t'] >= end]
        reasons = []
        nearby = []
        if not before or not after:
            reasons.append('unbracketed')
        else:
            nearby = guards[before[-1]:after[0]+1]
            if start-nearby[0]['t'] > 1.5 or nearby[-1]['t']-end > 1.5 or any(b['t']-a['t'] > 1.5 for a,b in zip(nearby,nearby[1:])):
                reasons.append('guard_gap')
            if any(not g['valid'] for g in nearby):
                reasons.append('query_invalid')
            elif any(g['playing'] < 1 for g in nearby):
                reasons.append('target_stopped')
            if any(g.get('foreground') != meta['package'] for g in nearby):
                reasons.append('foreground_changed_or_unknown')
            if any(g.get('other_started') for g in nearby):
                reasons.append('other_source')
            signatures = {tuple((x['piid'], x['pid'], x['state'], re.search(r'FormatInfo\{.*?\}', x['raw'])[0] if 'FormatInfo{' in x['raw'] else 'unknown') for x in g.get('target_players', [])) for g in nearby}
            if len(signatures) > 1:
                reasons.append('target_track_transition')
        if not 0.8 <= dt <= 1.2:
            reasons.append('window_duration')
        if start < meta['start_epoch'] or end > meta['start_epoch'] + meta['seconds']:
            reasons.append('outside_capture')
        smp = int(fields['smp'])
        rows.append(dict(line=line_number, start=start, end=end, t=end-meta['start_epoch'], dt=dt,
                         valid=not reasons, reasons=reasons, guards=[g['second'] for g in nearby],
                         pkt=int(fields['pkt']), smp=smp, supply=smp/dt/96000*100,
                         rxpkt=rxpkt, rxbytes=rxbytes, rx_supply=rxbytes/dt/192000*100,
                         histogram=dict(sorted(bins.items())), over=int(fields['over'])))
    for i,r in enumerate(rows):
        if i and abs(r['start']-rows[i-1]['end']) > 0.02:
            r['reasons'].append('audio_window_gap')
            r['valid'] = False
    healthy = lambda r: r['valid'] and 90 <= r['supply'] <= 120 and 90 <= r['rx_supply'] <= 120
    low = lambda r: r['valid'] and r['rxpkt'] > 0 and r['supply'] < 50 and r['rx_supply'] < 50
    candidate = None
    for i in range(len(rows)-4):
        if all(low(r) for r in rows[i:i+5]) and len([r for r in rows[:i] if healthy(r)]) >= 30:
            candidate = i
            break
    def summarize(selected):
        hist = Counter()
        for r in selected:
            hist.update({int(k):v for k,v in r['histogram'].items()})
        seconds = sum(r['dt'] for r in selected)
        packets = sum(hist.values())
        byte_count = sum(k*v for k,v in hist.items())
        def quantile(q):
            count = 0
            for k,v in sorted(hist.items()):
                count += v
                if count >= packets*q:
                    return k
        return dict(windows=len(selected), seconds=seconds, start_t=selected[0]['start']-meta['start_epoch'] if selected else None,
                    end_t=selected[-1]['t'] if selected else None,
                    lines=[r['line'] for r in selected], packets=packets, bytes=byte_count,
                    mean_bytes=byte_count/packets if packets else None,
                    p10=quantile(.1), p50=quantile(.5), p90=quantile(.9),
                    packets_per_second=packets/seconds if seconds else None,
                    rx_supply=byte_count/seconds/192000*100 if seconds else None,
                    accepted_supply=sum(r['smp'] for r in selected)/seconds/96000*100 if seconds else None,
                    histogram=dict(sorted(hist.items())))
    if candidate is not None:
        pre = [r for r in rows[:candidate] if healthy(r)][-30:]
        # Exclude all five confirmation windows as the transition; take the next 30 low valid windows.
        post = [r for r in rows[candidate+5:] if low(r)][:30]
    else:
        pre = [r for r in rows if healthy(r)][:30]
        post = []
    summary = dict(audio_windows=len(rows), valid_windows=sum(r['valid'] for r in rows),
                   guard_queries=len(guards), invalid_guards=sum(not g['valid'] for g in guards),
                   target_stopped_guards=sum(g['valid'] and g['playing']==0 for g in guards),
                   invalid_reasons=dict(Counter(reason for r in rows for reason in r['reasons'])),
                   candidate_t=rows[candidate]['t'] if candidate is not None else None,
                   confirmed_t=rows[candidate+4]['t'] if candidate is not None else None,
                   pre=summarize(pre), post=summarize(post), events=events,
                   comparison_available=candidate is not None and len(pre)==30 and len(post)==30,
                   pre_role='precollapse' if candidate is not None else 'healthy_baseline_not_precollapse',
                   all_valid=summarize([r for r in rows if r['valid']]),
                   healthy_tail=summarize([r for r in rows if healthy(r)][-30:]))
    (root/'timeline.json').write_text(json.dumps(rows, indent=2))
    (root/'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k not in ['pre','post','events','all_valid','healthy_tail']}, indent=2))
    for label in ['pre','post']:
        print(label, json.dumps({k:v for k,v in summary[label].items() if k not in ['histogram','lines']}))


if __name__ == '__main__':
    main()
