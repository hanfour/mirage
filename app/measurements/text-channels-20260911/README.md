# Guest text channel experiment (2026-09-11)

Scope: design §7.1 only. No NSTextInputClient/UI implementation and no message
send actions. Ordinary native EditText first, then LINE draft field. System
Settings search is the ordinary EditText page; it is not a WebView or custom
fixture APK. Its class/resource ID/focus are recorded per case. The empty search
hint `Search settings` is recorded verbatim and normalized to empty only for the
known reset precondition. None of the corpus equals the hint.

Each corpus case independently taps the target, clears via Android Ctrl+A/DEL,
reads back the target identity, focus and empty state, then uses exactly one
channel. Clipboard readback validates only transport setup. PASS requires exact
field text and focus via UIAutomator; codepoints are retained (NFC/NFD/ZWJ are not
normalized). Screenshots are cropped to the target EditText, excluding chats.
Original private LINE hierarchy and guest clipboard are kept in /private/tmp,
not this evidence directory. LINE's original draft was empty.

Channels:
- `text`: one gRPC KeyboardEvent containing only text.
- `ctrl_v`: gRPC setClipboard/readback, then W3C Control-down, v-down, v-up,
  Control-up. Error cleanup only releases keys; it never repeats the paste.
- `android_paste`: same clipboard setup, then adb KEYCODE_PASTE.
- `ui_paste`: same clipboard setup, Android long-press menu and exact Paste item
  selected by replaying the native touch gesture. This is UI-menu paste, not a
  different paste API and not a claim that a human performed each gesture.

Corpus: mixed Chinese/ASCII/fullwidth punctuation, repeated Chinese string,
Chinese + emoji, NFC é plus NFD e+combining acute, emoji skin-tone/ZWJ plus family
ZWJ, and ASCII control. Each is a separate cleared-field case. Repeated commit
transactions are evaluated separately in the stress phase.

Run with phase0/harness/.venv-d45/bin/python -B app/scripts/lib/text_channel_probe.py;
serial/package/resource ID/output directory must identify the intended test field.
The script never sends Enter, taps Send, or retries a paste after timeout.
`cases.jsonl` includes operations, setup, actual field text and errors. A failed
clear/focus precondition aborts the matrix; it is not recorded as channel failure.

Stress mode uses 20 commits per independently cleared case, same vs distinct
chunks, with 0 / 100 / 250 ms requested gaps between completed transactions.
UIAutomator reads only before and after the burst, so it does not artificially
slow every commit. Transaction RPC/clipboard polling latency remains part of the
actual pacing and is recorded. Native long-press is excluded from append stress:
long-pressing nonempty text changes the selection and is not an append API.

Run completeness: 24 basic cases + 12 burst cases per target (72 total).
Native-menu cases are BLOCKED before a Paste click, not Unicode delivery failures.
The separate cursor/selection experiment was not executed: its command permission
request was rejected. No alternative command was used to bypass that rejection.

The ordinary EditText runs used the archived `edittext-probe-source.py`; its hash
is in `probe-revision.json`. After LINE startup returned a null UI root, the probe
was hardened to remove the old XML before each dump and require a fresh successful
dump. No LINE case was injected during the failed startup query. The current
probe was used for both LINE phases. Ordinary negative results retain the initial
reader limitation; independent LINE cases used the hardened reader.

Offline verification:

```sh
python3 -B app/scripts/lib/text_channel_summarize.py app/measurements/text-channels-20260911
```

`cleanup.json` confirms the original empty LINE draft is empty again, guest
clipboard restored, and a NONEMPTY baseline of two visible non-header chat text
nodes has the same fingerprint after testing. It does not claim a full chat-history
or server-side audit. Neither private original clipboard nor chat text is archived.
