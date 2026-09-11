#!/usr/bin/env python3
"""Read-only observation and exact, per-case host IME acceptance. No input injection."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def evaluate(case, snapshots, events):
    reasons = []
    def require(condition, reason):
        if not condition:
            reasons.append(reason)
    try:
        require(case.get("humanPhysicalKeys") is True, "physical-key attestation missing; synthetic callbacks are not acceptance")
        require(bool(case.get("inputMethod")) and bool(case.get("physicalSequence")), "input method / actual keys missing")
        require(case.get("noMessageSent") is True, "no-send check missing/failed")
        require(case.get("originalDraftPreserved") is True, "original draft preservation check missing/failed")
        before = snapshots[case["before"]]
        after = snapshots[case["after"]]
        preedit = [snapshots[name] for name in case["preedit"]]
        original = snapshots[case["original"]]
        restored = snapshots[case["restored"]]
        kind = case.get("kind", "ime")
        require(kind in ("ime", "unicode-control"), "unknown case kind")
        if kind == "ime":
            require(bool(preedit), "no independently observed preedit field")
        for sample in [original, before, *preedit, after, restored]:
            require(sample.get("fresh") is True and sample.get("focused") is True, "invalid/stale/unfocused field")
            require(sample.get("package") == case["package"] and sample.get("field") == case["field"]
                    and sample.get("className") == "android.widget.EditText", "wrong field identity")
            require(isinstance(sample.get("text"), str), "missing field text")
        start, end = before["capturedAt"], after["capturedAt"]
        require(original["capturedAt"] <= start < end < restored["observationStartedAt"], "invalid observation/restore order")
        require(original["text"].encode() == restored["text"].encode(), "original draft was not exactly restored")
        for sample in preedit:
            require(start < sample["capturedAt"] < end, "preedit snapshot outside case")
            require(sample["text"].encode() == before["text"].encode(), "preedit leaked into guest / original text changed")
        require(after["text"].encode() == case["expected"].encode(), "exact field mismatch (clipboard/RPC cannot override)")
        trace = [e for e in events if start < e["time"] < end]
        downs = [e for e in trace if e["event"] == "key-down"]
        marked = [e for e in trace if e["event"] == "marked"]
        if kind == "ime":
            require(any(e.get("route") == "text" for e in downs), "missing real-path key diagnostic evidence")
            require(bool(marked), "missing marked diagnostic evidence")
        for event in downs:
            if event.get("route") == "appkit-shortcut":
                continue
            require(event.get("route") == "text", "key bypassed text mode")
            require(sum(e["event"] == "interpret" and e.get("eventID") == event.get("eventID") for e in trace) == 1,
                    "key was not interpreted exactly once")
        require(not any(e["event"] == "guest-key-dispatch" for e in trace), "guest raw key leaked (includes candidate Enter)")
        commits = [e for e in trace if e["event"] == "commit-enqueued"]
        require([e.get("textSHA256") for e in commits] == [digest(s) for s in case["commits"]], "commit count/content/order mismatch")
        require(len({e.get("commitID") for e in commits}) == len(commits), "duplicate commit ID")
        for commit in commits:
            requests = [e for e in trace if e["event"] == "commit-request" and e.get("commitID") == commit.get("commitID")]
            require(len(requests) == 1 and requests[0].get("origin") == "input-client", "missing input-client origin / paste shortcut cannot replace IME")
            require(commit.get("settleMS") == str(case["settleMS"]), "policy differs from declared configuration")
            phases = [e for e in trace if e["event"] == "phase" and e.get("commitID") == commit.get("commitID") and e.get("phase") == "dispatchingPaste"]
            results = [e for e in trace if e["event"] == "result" and e.get("commitID") == commit.get("commitID")]
            require(len(phases) == 1, "paste dispatch count is not one")
            require(len(results) == 1 and results[0].get("outcome") == "submittedUnverified", "missing/unsettled/failed result")
            if results and phases:
                require(commit["time"] <= phases[0]["time"] <= results[0]["time"] < after["observationStartedAt"] <= end, "field snapshot precedes completed scheduling")
        if preedit and commits:
            require(max(s["capturedAt"] for s in preedit) < commits[0]["time"], "preedit observed after dispatch")
        if preedit and marked:
            require(marked[0]["time"] < min(s["observationStartedAt"] for s in preedit), "snapshot does not observe marked interval")
        require(not any(e["event"] == "result" and e.get("outcome") != "submittedUnverified" for e in trace), "known runtime failure in case")
    except (KeyError, TypeError, ValueError, UnicodeError) as error:
        reasons.append("invalid/missing evidence: " + str(error))
    result = {"status": "FAIL" if reasons else "PASS", "scope": "this case and configuration only; physical keys are human-attested", "reasons": reasons}
    if isinstance(case.get("expected"), str):
        result["expectedScalars"] = [f"U+{ord(c):04X}" for c in case["expected"]]
    observed = snapshots.get(case.get("after"), {}).get("text")
    if isinstance(observed, str):
        result["observedScalars"] = [f"U+{ord(c):04X}" for c in observed]
    return result


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def watch(args):
    root = pathlib.Path(args.directory)
    root.mkdir(parents=True, exist_ok=False)
    driver = pathlib.Path(__file__).with_name("text_field_driver.py")
    deadline = time.monotonic() + args.seconds
    index = 0
    while time.monotonic() < deadline:
        index += 1
        name = f"{index:04}"
        request = {"serial": args.serial, "package": args.package, "field": args.field,
                   "emptyLabel": args.empty_label, "action": "observe", "image": str(root / (name + ".png"))}
        began = time.time()
        try:
            result = subprocess.run([sys.executable, str(driver)], input=json.dumps(request),
                                    capture_output=True, text=True, timeout=20, check=True)
            sample = json.loads(result.stdout)
            # Keep independent driver timestamp and observation start; no clipboard reads here.
            sample["observationStartedAt"] = began
        except (subprocess.SubprocessError, ValueError) as error:
            sample = {"fresh": False, "capturedAt": time.time(), "error": str(error)}
        (root / (name + ".json")).write_text(json.dumps(sample, ensure_ascii=False, indent=2))
        print(name, "valid" if sample.get("fresh") and sample.get("focused") else "INVALID", flush=True)
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(args.interval, remaining))


def verify(args):
    try:
        events = [json.loads(line) for line in pathlib.Path(args.trace).read_text().splitlines()]
        if not events or events[0].get("event") != "diagnostics-start" or [e.get("seq") for e in events] != list(range(1, len(events) + 1)):
            raise ValueError("missing/truncated diagnostic header or sequence gap")
        root = pathlib.Path(args.snapshots)
        snapshots = {p.stem: load(p) for p in root.glob("*.json")}
        case = load(args.case)
        report = evaluate(case, snapshots, events)
        report["snapshotSHA256"] = {name: digest((root / (name + ".json")).read_text()) for name in
                                    [case["original"], case["before"], *case["preedit"], case["after"], case["restored"]]}
        report["caseSHA256"] = digest(pathlib.Path(args.case).read_text())
        report["traceSHA256"] = digest(pathlib.Path(args.trace).read_text())
        before = snapshots[case["before"]]["capturedAt"]
        after = snapshots[case["after"]]["capturedAt"]
        starts = [e["time"] for e in events if e["event"] == "phase" and e.get("phase") == "dispatchingPaste" and before < e["time"] < after]
        report["dispatchStartIntervalsMS"] = [(b-a)*1000 for a, b in zip(starts, starts[1:])]
        report["settleMS"] = case["settleMS"]
    except (OSError, ValueError, TypeError, KeyError) as error:
        report = {"status": "INVALID", "reasons": [str(error)]}
    report["policyChangedToHideFailure"] = False  # This tool never modifies policy.
    with open(args.output, "x") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return {"PASS": 0, "FAIL": 1, "INVALID": 2}[report["status"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    observe = sub.add_parser("watch", help="read-only fresh field snapshots; never focus, clear, paste or send")
    observe.add_argument("directory")
    observe.add_argument("--serial", default="emulator-5554")
    observe.add_argument("--package", required=True)
    observe.add_argument("--field", required=True)
    observe.add_argument("--empty-label", default="")
    observe.add_argument("--seconds", type=int, default=180)
    observe.add_argument("--interval", type=float, default=1)
    check = sub.add_parser("verify")
    for name in ["case", "snapshots", "trace", "output"]:
        check.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        if args.command == "watch":
            if not 1 <= args.seconds <= 600 or not 0.1 <= args.interval <= 60:
                raise ValueError("invalid observation duration/interval")
            watch(args)
            return 0
        return verify(args)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print("INVALID: " + str(error), file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main())
