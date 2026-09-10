"""Validate actual RPC boundaries before evaluating reopen-mode audio supply."""
import re


def rpc_schedule(log):
    rounds = {}
    errors = []
    active = None
    complete = None
    for line in log.splitlines():
        m = re.match(r'\[audio-rpc\] event=([\w-]+) round=(\d+) epoch=([\d.]+)', line)
        if m:
            name, number, epoch = m[1], int(m[2]), float(m[3])
            if name == 'complete':
                complete = epoch
                continue
            if name not in ['open', 'cancel', 'response-ended', 'closed']:
                errors.append(line)
                continue
            r = rounds.setdefault(number, dict(round=number, formats=[]))
            if name in r:
                errors.append(f'duplicate {number} {name}')
            r[name] = epoch
            if name == 'open':
                active = number
        elif '[audio] 收到的格式：' in line and active is not None:
            rounds[active]['formats'].append(line)
    previous = None
    for number, r in sorted(rounds.items()):
        reasons = []
        if not all(k in r for k in ['open','cancel','response-ended','closed']):
            reasons.append('rpc_incomplete')
        else:
            if not r['open'] <= r['cancel'] <= r['response-ended'] <= r['closed']:
                reasons.append('rpc_ended_early_or_invalid_order')
            if not 9.8 <= r['cancel']-r['open'] <= 10.2:
                reasons.append('rpc_duration')
            if previous and (previous.get('closed', float('inf')) >= r['open'] or
                             abs(r['open']-previous.get('open',0)-15) > .2):
                reasons.append('rpc_overlap_or_schedule_gap')
        if len(r['formats']) != 1 or not all('sr=48000 ch=stereo fmt=audFmtS16' in f for f in r['formats']):
            reasons.append('rpc_format_missing_or_changed')
        r['reasons'] = reasons
        r['valid'] = not reasons
        previous = r
    return dict(rounds=list(rounds.values()), errors=errors, complete_epoch=complete)


def window_round(start, end, schedule):
    for r in schedule['rounds']:
        if r.get('open', float('inf')) <= start and end <= r.get('cancel', -float('inf')):
            if not r['valid']:
                return r['round'], r['reasons']
            if start < r['open'] + 1:
                return r['round'], ['rpc_startup']
            return r['round'], []
    return None, ['rpc_off_or_boundary']


def selftest():
    log = ''
    for n in [1,2]:
        t = (n-1)*15
        log += f'[audio-rpc] event=open round={n} epoch={t}\n'
        log += '[audio] 收到的格式：sr=48000 ch=stereo fmt=audFmtS16\n'
        for event, offset in [('cancel',10),('response-ended',10.001),('closed',10.002)]:
            log += f'[audio-rpc] event={event} round={n} epoch={t+offset}\n'
    schedule = rpc_schedule(log)
    assert all(r['valid'] for r in schedule['rounds'])
    assert window_round(1,2,schedule) == (1,[])
    assert window_round(0,.9,schedule)[1] == ['rpc_startup']
    assert window_round(9.5,10.5,schedule)[1] == ['rpc_off_or_boundary']
    assert window_round(12,13,schedule)[1] == ['rpc_off_or_boundary']
    assert window_round(16,17,schedule) == (2,[])
    early = rpc_schedule(log.replace('event=response-ended round=1 epoch=10.001','event=response-ended round=1 epoch=3'))
    assert not early['rounds'][0]['valid']
    assert window_round(1,2,early)[1] == ['rpc_ended_early_or_invalid_order']
    incomplete = rpc_schedule(log.replace('[audio-rpc] event=closed round=1 epoch=10.002\n',''))
    assert not incomplete['rounds'][0]['valid'] and not incomplete['rounds'][1]['valid']
    print('PASS: on/startup/off/boundary classification, early end and incomplete cancellation rejected')


if __name__ == '__main__':
    selftest()
