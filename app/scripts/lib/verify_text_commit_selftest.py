#!/usr/bin/env python3
"""Wrapper refuses existing evidence before any Swift/live execution."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[3]

def run(source):
    with tempfile.TemporaryDirectory(prefix='mirage-evidence-guard-') as temp:
        root=Path(temp)
        scripts=root/'app/scripts'; scripts.mkdir(parents=True)
        wrapper=scripts/'verify_text_commit.sh'; wrapper.write_text(source)
        fakebin=root/'bin';fakebin.mkdir()
        fake=fakebin/'swift';fake.write_text('#!/bin/sh\nprintf invoked > "$MIRAGE_TEST_SWIFT_MARKER"\n');fake.chmod(0o755)
        evidence=root/'evidence';evidence.mkdir()
        old=evidence/'run-failure.json';old.write_text('original failure')
        marker=root/'swift-invoked'
        env={**os.environ,'PATH':str(fakebin)+':'+os.environ['PATH'],'MIRAGE_TEST_SWIFT_MARKER':str(marker)}
        p=subprocess.run(['bash',str(wrapper),'fake','1','fixture','fixture:id/edit',str(evidence)],env=env,capture_output=True,text=True)
        assert old.read_text()=='original failure'
        return p.returncode,marker.exists()

old=(ROOT/'app/measurements/ime-tasks-1-4/verify_text_commit.sh.live-source.txt').read_text()
assert run(old)==(0,True), 'negative control must show the old wrapper started Swift'
assert run((ROOT/'app/scripts/verify_text_commit.sh').read_text())==(2,False)
print('PASS: old wrapper permits reuse; new wrapper refuses before Swift, old failure remains intact')
