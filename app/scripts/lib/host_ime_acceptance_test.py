import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from host_ime_acceptance import evaluate, watch


def fixture():
    case = {"humanPhysicalKeys": True, "inputMethod": "Apple Pinyin", "physicalSequence": "zhongwen space return",
            "package": "jp.naver.line.android", "field": "draft", "settleMS": "250",
            "original": "original", "restored": "restored", "before": "before", "preedit": ["preedit"], "after": "after", "expected": "LEFT中文RIGHT",
            "commits": ["中文"], "noMessageSent": True, "originalDraftPreserved": True}
    def snap(text, at):
        return {"text": text, "capturedAt": at, "observationStartedAt": at - 0.1, "fresh": True, "focused": True,
                "package": case["package"], "field": case["field"], "className": "android.widget.EditText"}
    snapshots = {"original": snap("原稿", 8), "restored": snap("原稿", 25), "before": snap("LEFTRIGHT", 10), "preedit": snap("LEFTRIGHT", 12), "after": snap(case["expected"], 20)}
    import hashlib
    events = [
        {"event": "key-down", "time": 11, "route": "text", "eventID": "key1"},
        {"event": "interpret", "time": 11, "eventID": "key1"},
        {"event": "marked", "time": 11.1, "compositionID": "c1"},
        {"event": "commit-enqueued", "time": 14, "commitID": "id1", "settleMS": "250", "textSHA256": hashlib.sha256("中文".encode()).hexdigest()},
        {"event": "phase", "time": 14.1, "commitID": "id1", "phase": "dispatchingPaste"},
        {"event": "result", "time": 15, "commitID": "id1", "outcome": "submittedUnverified"},
    ]
    events.append({"event": "commit-request", "time": 13.9, "commitID": "id1", "origin": "input-client"})
    return case, snapshots, events


class AcceptanceTests(unittest.TestCase):
    def test_valid_fixture_is_only_sample_pass(self):
        self.assertEqual(evaluate(*fixture())["status"], "PASS")

    def test_false_positives_rejected(self):
        mutations = [
            lambda c, s, e: s["after"].update(text="LEFT中文中文RIGHT", clipboard=c["expected"]),
            lambda c, s, e: s["preedit"].update(text="LEFTzhongRIGHT"),
            lambda c, s, e: s["after"].update(focused=False),
            lambda c, s, e: s["after"].update(fresh=False),
            lambda c, s, e: s["after"].update(text=""),
            lambda c, s, e: s["restored"].update(text=""),
            lambda c, s, e: e.append(dict(e[3], time=14.2, commitID="id2")),
            lambda c, s, e: e.append({"event": "guest-key-dispatch", "time": 14, "key": "Enter"}),
            lambda c, s, e: e.clear(),
            lambda c, s, e: e.pop(1),
            lambda c, s, e: e.append(dict(e[1])),
            lambda c, s, e: c.update(humanPhysicalKeys=False),
            lambda c, s, e: c.update(noMessageSent=False),
            lambda c, s, e: c.update(originalDraftPreserved=False),
            lambda c, s, e: c.update(settleMS="100"),
            lambda c, s, e: c.update(commits=["中文", "中文"]),
            lambda c, s, e: s["after"].update(capturedAt=14),
            lambda c, s, e: c.update(preedit=[]),
            lambda c, s, e: s["preedit"].update(observationStartedAt=10.5),
            lambda c, s, e: s["after"].update(observationStartedAt=14.5),
            lambda c, s, e: e[-1].update(origin="appkit-paste"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                c, s, e = fixture(); mutate(c, s, e)
                self.assertNotEqual(evaluate(c, s, e)["status"], "PASS")

    def test_watcher_only_requests_read_only_observation(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / "fresh"
            args = SimpleNamespace(directory=str(target), seconds=1, interval=1, serial="emulator-5554",
                                   package="test", field="field", empty_label="")
            sample = {"fresh": True, "focused": True, "text": "untouched", "capturedAt": 1}
            response = SimpleNamespace(stdout=json.dumps(sample))
            with patch("host_ime_acceptance.time.monotonic", side_effect=[0, 0, 2, 3]), patch("host_ime_acceptance.subprocess.run", return_value=response) as run:
                watch(args)
            self.assertEqual(run.call_count, 1)
            request = json.loads(run.call_args.kwargs["input"])
            self.assertEqual(request["action"], "observe")
            self.assertNotIn("seed", request)
            self.assertEqual(json.loads((target / "0001.json").read_text())["text"], "untouched")

    def test_cli_fails_and_never_overwrites_old_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            c, snapshots, events = fixture()
            snapshots["after"]["text"] = "WRONG"
            (root / "case.json").write_text(json.dumps(c))
            samples = root / "samples"; samples.mkdir()
            for name, value in snapshots.items():
                (samples / (name + ".json")).write_text(json.dumps(value))
            events = [{"event": "diagnostics-start", "time": 0}] + sorted(events, key=lambda e: e["time"])
            for index, event in enumerate(events, 1):
                event["seq"] = index
            (root / "trace.jsonl").write_text("\n".join(map(json.dumps, events)))
            output = root / "result.json"
            command = [sys.executable, str(pathlib.Path(__file__).with_name("host_ime_acceptance.py")), "verify",
                       "--case", str(root / "case.json"), "--snapshots", str(samples),
                       "--trace", str(root / "trace.jsonl"), "--output", str(output)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
            original = output.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(output.read_bytes(), original)
            self.assertFalse(json.loads(original)["policyChangedToHideFailure"])
            (root / "trace.jsonl").unlink()
            command[-1] = str(root / "invalid.json")
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(json.loads((root / "invalid.json").read_text())["status"], "INVALID")

    def test_nfc_nfd_and_order_are_not_equivalent(self):
        c, s, e = fixture()
        c["expected"] = "é"; s["after"]["text"] = "e\u0301"
        self.assertNotEqual(evaluate(c, s, e)["status"], "PASS")
        c, s, e = fixture()
        c["commits"] = ["A01", "B02"]
        self.assertNotEqual(evaluate(c, s, e)["status"], "PASS")

if __name__ == "__main__":
    unittest.main()
