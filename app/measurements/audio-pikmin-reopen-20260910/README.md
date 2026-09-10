# Pikmin Bloom: reopen-only audio RPC run (2026-09-10)

One cold boot of stable 37.1.11.0 / build 15917651, the same tutorial dialogue
scene as §12, same guest volume and location. Mirage remains alive on the same
gRPC channel with its display stream, AudioPlayer and ring. Only `streamAudio`
is reopened: 10 seconds on, 5 seconds off, 40 rounds, 600 seconds total.

Opt-in environment:

```text
MIRAGE_PORT=8554
MIRAGE_AUDIO_LOG=1
MIRAGE_CONN_LOG=1
MIRAGE_AUDIO_REOPEN=1
MIRAGE_AUDIO_REOPEN_START_EPOCH=<scheduled_start_epoch in setup.json>
```

`setup.json` records the host/guest time correspondence: app launch scheduled at
guest uptime 127 seconds and the first audio RPC at 131 seconds, approximately
matching §12. `capture.json` records the actual guard capture start. Startup
screenshots may show the dialogue's typewriter animation; the page is the same.

Raw evidence: `app.log`, `guards.jsonl.gz` (all original query stdout/stderr,
exit status and epoch intervals, lossless compression), setup/version/process
records, screenshots, and hashes. `timeline.json` and `summary.json` are derived.

Recompute from repository root without starting an emulator:

```sh
python3 -B app/scripts/lib/audio_packet_capture.py --selftest
python3 -B app/scripts/lib/audio_rpc_windows.py
python3 -B app/scripts/lib/audio_reopen_selftest.py
python3 -B app/scripts/lib/audio_packet_analyze.py app/measurements/audio-pikmin-reopen-20260910
```

The UID-specific current `players` guard is the same as §12. A failed query is
unknown, not stopped. Only complete audio windows bracketed by good guards and
contained within an actual open interval are eligible. Exclude the first second
after open, planned off time, and any window crossing an open/cancel boundary.
Validate each RPC's open <= cancel <= response-ended <= closed ordering, roughly
10-second on duration (9.8–10.2), 15-second start spacing (±0.2), one unchanged
48k/stereo/S16 response format, and closed-before-next-open. Incomplete RPCs are
excluded during live analysis until closure is recorded. Aborts invalidate the run.

Five consecutive valid nonempty windows with BOTH raw and accepted supply below
50% form a candidate only within the SAME RPC. Off time never joins a low streak.
The five confirmation windows are excluded from pre/post steady distributions.
Insufficient pre-event baseline means a candidate can be observed but the paired
30-window comparison remains unavailable. `per_rpc` lists low and zero windows;
zero delivery is a separate observation, not automatic proof of emulator failure.

Histograms measure raw S16 payload bytes at the ring-write boundary, exactly as
§12. Rates use actual `window_seconds`; 30 windows are not exactly 30 seconds.
Selected windows can span multiple RPCs; `rpc_rounds` and source line numbers are
retained. `healthy_tail` is a normal tail baseline, never a post-collapse label.

One exploratory round cannot establish causality. Planned off periods provide
about 400 seconds of requested audio over 600 seconds of guest playback; do not
compare event rates directly with the continuous run's roughly 600 seconds.
