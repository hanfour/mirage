#!/usr/bin/env python3
"""One-second, UID-scoped current playback guards; retain errors as unknown.

Run --selftest without adb. Capture uses host epoch times matching window_end.
Raw stdout/stderr and current foreground are retained for re-analysis.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import time


def parse_audio(raw, uid):
    section = re.search(r'PlaybackActivityMonitor dump time:.*?\n\s*players:\s*\n(.*?)\n\s*ducked players piids:', raw, re.S)
    if not section:
        raise ValueError('missing current players section')
    players = []
    for line in section[1].splitlines():
        if not line.strip():
            continue
        match = re.search(r'AudioPlaybackConfiguration piid:(\d+).*?u/pid:(\d+)/(\d+) state:(\w+)', line)
        if not match:
            raise ValueError('unrecognized current player: ' + line)
        players.append(dict(piid=int(match[1]), uid=int(match[2]), pid=int(match[3]), state=match[4], raw=line))
    target = [p for p in players if p['uid'] == uid]
    return dict(playing=sum(p['state'] == 'started' for p in target),
                target_players=target,
                other_started=[p for p in players if p['uid'] != uid and p['state'] == 'started'])


def query(adb, serial, command):
    start = time.time()
    try:
        result = subprocess.run([adb, '-s', serial, 'shell', *command], capture_output=True, text=True, timeout=0.8)
        return dict(start=start, end=time.time(), rc=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except subprocess.TimeoutExpired as exc:
        def decode(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
        return dict(start=start, end=time.time(), rc=None, error='timeout', stdout=decode(exc.stdout), stderr=decode(exc.stderr))


def selftest():
    def fixture(lines):
        return 'PlaybackActivityMonitor dump time: now\n  players:\n' + lines + '\n  ducked players piids:\nEvents log: state:started uid/pid:10209/7'
    line = '  AudioPlaybackConfiguration piid:3 type:x u/pid:10209/7 state:started attr:x'
    assert parse_audio(fixture(line), 10209)['playing'] == 1
    assert parse_audio(fixture(line.replace('10209', '1000')), 10209)['playing'] == 0
    assert parse_audio(fixture(line.replace('started', 'paused')), 10209)['playing'] == 0
    assert parse_audio(fixture(''), 10209)['playing'] == 0
    for bad in ['', 'error: device offline', fixture('malformed player')]:
        try:
            parse_audio(bad, 10209)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid query was accepted')
    print('PASS: target UID, other UID, paused, empty players, missing/error/malformed output; history ignored')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--package', default='com.nianticlabs.pikmin')
    parser.add_argument('--seconds', type=int, default=600)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if not args.out or not 1 <= args.seconds <= 600:
        parser.error('--out required; seconds must be 1..600')
    adb = str(Path.home() / 'Library/Android/sdk/platform-tools/adb')
    package = query(adb, args.serial, ['pm', 'list', 'packages', '-U', args.package])
    match = re.search(r'^package:' + re.escape(args.package) + r' uid:(\d+)\s*$', package['stdout'], re.M)
    if package['rc'] != 0 or not match:
        raise RuntimeError('cannot establish target UID: ' + repr(package))
    uid = int(match[1])
    args.out.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    metadata = dict(start_epoch=time.time(), seconds=args.seconds, serial=args.serial, package=args.package, uid=uid, package_query=package)
    (args.out / 'capture.json').write_text(json.dumps(metadata, indent=2))
    with (args.out / 'guards.jsonl').open('x') as output, concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for second in range(args.seconds + 1):
            time.sleep(max(0, start + second - time.monotonic()))
            audio_future = pool.submit(query, adb, args.serial, ['dumpsys', 'audio'])
            activity_future = pool.submit(query, adb, args.serial, ['dumpsys', 'activity', 'activities'])
            audio, activity = audio_future.result(), activity_future.result()
            record = dict(second=second, audio=audio, activity=activity, valid=False, playing=None)
            try:
                if audio['rc'] != 0 or activity['rc'] != 0:
                    raise ValueError('query failed or timed out')
                record.update(parse_audio(audio['stdout'], uid))
                foreground = re.search(r'topResumedActivity=.*? ([\w.]+)/', activity['stdout'])
                if not foreground:
                    raise ValueError('missing foreground activity')
                record['foreground'] = foreground[1]
                record['valid'] = True
            except ValueError as exc:
                record['reason'] = str(exc)
                record['playing'] = None
            output.write(json.dumps(record) + '\n')
            output.flush()
            if second % 30 == 0:
                print(f"t={second}s valid={record['valid']} playing={record['playing']} foreground={record.get('foreground')} others={len(record.get('other_started', []))}", flush=True)
    print('capture complete', flush=True)


if __name__ == '__main__':
    main()
