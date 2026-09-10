# Pikmin Bloom audio packet run (2026-09-10)

Raw evidence for RESULTS-audio-collapse.md. `guards.jsonl.gz` retains each adb
query's epoch start/end, return code, stdout/stderr, parsed current target players
and foreground. `app.log` contains packet histograms and source window timestamps.
`capture.json` identifies the target UID and capture interval.

Guard queries run on a one-second monotonic schedule (0.8-second timeout).
A failed query is unknown (`valid=false`, `playing=null`), never zero playing.
Only the current PlaybackActivityMonitor players section is parsed, not history.

App `pkt/smp/supply` describe accepted ring writes. `rxpkt/rxbytes/pkt_bytes`
include raw payload sizes reaching that write boundary, including empty/dropped
packets. The histogram is not an arrival-time trace at the gRPC callback.
`window_seconds` is measured; analysis normalizes rates with it, leaving the
existing integer `supply` diagnostic unchanged. These are approximately one-second
windows, not exact wall-clock second bins.

Analysis (from repository root):

```sh
python3 app/scripts/lib/audio_packet_capture.py --selftest
python3 app/scripts/lib/audio_packet_analyze.py app/measurements/audio-pikmin-20260910
```

Each window must be bracketed by successful target-playing, target-foreground
queries with no other started source, stable target track/format and no guard gap
above 1.5 seconds. A window outside 0.8–1.2 seconds or with a source-log gap above
20 ms is excluded. Bracketing excludes both adjacent windows when a guard fails.
This is sampled evidence; it cannot rule out subsecond stops between queries.

A collapse candidate requires five consecutive valid, nonempty windows with both
accepted and raw supply below 50%, preceded by at least 30 healthy windows
(90–120%). The five confirmation windows are excluded as transition. Compare the
last 30 healthy windows before and first 30 low valid windows after confirmation.
These are 30 approximately-one-second windows; exact elapsed durations are reported.
When there is no candidate, `pre_role` explicitly identifies the first 30 healthy
windows as baseline, not precollapse; `comparison_available` is false.

`healthy_tail` is a normal tail baseline, not a post-collapse distribution.
The raw app log must also be checked for reconnect, audio-stream end and returned
format changes before treating a selected range as one uninterrupted segment.

Raw guards are losslessly gzip-compressed; the analyzer accepts either form.
