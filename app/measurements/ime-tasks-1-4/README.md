# IME implementation Tasks 1–4: evidence (2026-09-11)

See ../../RESULTS-ime-tasks-1-4.md for the findings and changes to the plan.
No NSTextInputClient/marked overlay/IME UI was implemented in this stage.

Task 1/2/3 red logs retain behavior failures, followed by complete swift test
summaries. Task 3's blocked-consumer checkpoint observes actual B/B insertion and
watcher overwrite, not just RPC return order. A late-consumption negative control
still fails under a shorter policy, deliberately demonstrating the absence of an ACK.

Task 4 runs:

- `live-edittext`: original full 60-case native EditText run; all passed.
- `live-line`: ORIGINAL FAILED RUN, 7 passes then 100-r1-replace failed. The
  expected field was LEFT中文🙂RIGHT; actual LEFTold中文🙂RIGHT. It was stopped
  immediately, not retried with a longer delay. This directory must not be replaced.
- `line-selection-diagnostic`: ASCII-only observation, with no Unicode paste.
  Before Copy, old is selected. Copy returned old, but the after-Copy image shows
  a collapsed caret. Reselecting restores the highlight. Test draft/clipboard restored.
- `live-edittext-reselected`: only the affected position cases rechecked with
  reselect-after-Copy, 12/12 passed (100/250 ms × 3 rounds × insert/replace).
- `live-line-reselected`: full corrected 60-case run, all passed. Product transport
  code and delays unchanged; only the test setup restores selection after Copy.

Each full run has six corpus cases, insert, replace, and 20-commit same/distinct
bursts, at both 100 and 250 ms for three rounds. All real Unicode delivery uses the
Swift InputQueue/executor/checked EmulatorClient transport. The Python driver only
clears, initializes known ASCII seed via native Paste, positions/selects/copies,
and reads fresh UIAutomator evidence. It never implements the Unicode paste under test.

Snapshots and screenshots contain only the test field. Private clipboard backups
remain in /private/tmp; their content and actual chat messages are not archived.
`environment-and-cleanup.json` records versions, empty final draft, restoration of
guest clipboard text, and a nonempty visible-chat fingerprint comparison against
the previous stage. It is not an audit of the full server-side chat history.

Recompute offline (no emulator or injection):

```sh
python3 -B app/scripts/lib/text_swift_live_summary.py app/measurements/ime-tasks-1-4/live-edittext
python3 -B app/scripts/lib/text_swift_live_summary.py app/measurements/ime-tasks-1-4/live-edittext-reselected --positions-only --require-reselection
python3 -B app/scripts/lib/text_swift_live_summary.py app/measurements/ime-tasks-1-4/live-line-reselected --require-reselection
python3 -B app/scripts/lib/verify_text_commit_selftest.py
```

Running the summary against `live-line` MUST fail; the failure output is preserved
in task4-failed-run-rejected.txt. original-line-failure-hashes.json protects the
original failing case and its surrounding data. Do not aggregate it away.

The official live wrapper refuses a nonempty evidence directory before starting
Swift; the Swift live test also refuses old cases. A regression test preserves
an old failure marker and proves the old wrapper starts Swift while the new one
refuses. This prevents accidental reuse of an evidence path.

`task4-source-hashes.json` captures the first live harness and product sources;
`task4-live-source-archives.json` points to archived original harness files.
`task4-source-hashes-v2.json` records the corrected selection harness. The actual
transport product files did not change between these runs. The final commit also
includes the small evidence-directory guard and its offline regression tests.

Final checks: task4-green.txt is the complete offline Swift test summary;
task4-ci.log contains the unmodified default CI run with three full Swift runs
and all existing checks. Live skip is not counted as field evidence.
