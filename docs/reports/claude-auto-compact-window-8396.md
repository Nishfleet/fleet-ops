# Observe-close for #8396 — auto-compact window 250000

`CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000` is already set in
`~/.claude/settings.json` `env`. This run did not change that file.
The window stays 250000.

Claude Code 2.1.280 (the version on every session below) treats that
env as the compact window (`source: "env"` in `ok()`). The compact
fires at `window - min(output reserve, 20000) - 13000`. With a 20000
reserve that is `250000 - 20000 - 13000 = 217000`. The issue's "near
230k" is that same window minus only the 20000 reserve. The records
below fire at 217k–225k, which is the stock threshold for 250000.
`claude --help` names the same knob as `--autocompact <auto|tokens>`.

Context on a request is `input_tokens + cache_creation_input_tokens +
cache_read_input_tokens` on the assistant usage record.

## Session started after 2026-09-23 11:30 IST

Cutoff is 2026-09-23 06:00 UTC. Both sessions below are
`entrypoint: claude-desktop`, version `2.1.280`. Desktop did pass the
settings env into the process: these are not CLI probes.

### Primary: `26bae9cb-6b88-4a77-91ff-a95cf2c3b648`

Path: `~/.claude/projects/-home-nish/26bae9cb-6b88-4a77-91ff-a95cf2c3b648.jsonl`

First record: `2026-09-23T17:31:04.820Z` (23:01 IST).

Compact record, line 660, `2026-09-23T18:03:25.974Z`:

- `subtype: compact_boundary`
- `compactMetadata.trigger: auto`
- `preTokens: 217161`
- `postTokens: 13492`

Next request, line 682, `2026-09-23T18:03:27.900Z`: context **65891**
(`input_tokens` 2, `cache_creation_input_tokens` 34743,
`cache_read_input_tokens` 31146).

### Same bar: `2a1b2116-c84b-4955-9d99-d798916470ca`

Path: `~/.claude/projects/-home-nish/2a1b2116-c84b-4955-9d99-d798916470ca.jsonl`

First record: `2026-09-23T16:59:43.358Z` (22:29 IST).

Compact record, line 732, `2026-09-23T17:27:22.568Z`: `trigger: auto`,
`preTokens: 217442`, `postTokens: 12765`.

Next request, line 755, `2026-09-23T17:27:27.139Z`: context **64778**.

## Resumed session that crosses 217k

`26bae9cb` continued after the first compact. Line 664 is the
continuation summary ("This session is being continued from a previous
conversation that ran out of context"). The same file then crosses the
threshold again:

- line 1716, `2026-09-23T19:16:00.557Z`
- `trigger: auto`, `preTokens: 217484`, `postTokens: 12625`
- next request line 1738, `2026-09-23T19:16:05.514Z`, context **64299**

`2a1b2116` does the same: continuation summary at line 1725, second
`compact_boundary` at line 1721, `2026-09-23T18:02:23.993Z`,
`preTokens: 224890`, next request line 1749 context **69443**.

## Why `95293e12` and `1200aee0` did not compact

The env key is absent from
`settings.json.bak-hooks-20260919T050954Z`. It is present as `250000`
in `settings.json.bak-before-8395-20260923T062416Z`. The write is
session `d3920d3a` line 81, `2026-09-23T05:45:27.588Z` (11:15 IST).

| Session | Started (UTC) | Peak context | Peak time (UTC) | `compact_boundary` |
|---|---|---:|---|---|
| `95293e12-eb1d-47b6-8d67-a08ebd5e06b0` | 03:03:19 | 274859 | 05:23:23 | 0 |
| `1200aee0-d1ba-41b1-9eb4-aba681b65a84` | 02:54:58 | 205450 | 05:03:44 | 0 |

Both peaks are before the env write. `95293e12` ran past 217k only
because that process started before the setting existed.
`1200aee0` never reached 217000. Neither file was resumed after the
write. No config change: sessions that start after the write compact,
including desktop.

`e73a8b79` (2026-09-05, version 2.1.260, `preTokens` 968594) is the
pre-setting behavior. It is not in the 250000 sample.

Sidechain compacts on 2026-09-24, parent `17e426c0`, same threshold:
`a917a969d71f703ae` line 413 `preTokens` 217485;
`ae79e8a31f15ebe0e` line 332 `preTokens` 218048;
`a19ad211babace64b` line 196 `preTokens` 219277;
`aeecba59b94c1ee2c` line 323 `preTokens` 216846.
Each next request is 56k–59k.

## Quality after compaction

For each auto-compact under this window, the turns after the boundary
were compared with the turns before it. Counts:

| Session | Boundary line | (a) work redone | (b) decision contradicted | (c) fact re-asked |
|---|---:|---:|---:|---:|
| `26bae9cb` | 660 | 0 | 0 | 0 |
| `26bae9cb` | 1716 | 0 | 0 | 0 |
| `2a1b2116` | 732 | 0 | 0 | 0 |
| `2a1b2116` | 1721 | 0 | 0 | 0 |
| `a917a969d71f703ae` | 413 | 0 | 0 | 0 |
| `ae79e8a31f15ebe0e` | 332 | 0 | 0 | 0 |
| `a19ad211babace64b` | 196 | 0 | 0 | 0 |
| `aeecba59b94c1ee2c` | 323 | 0 | 0 | 0 |

What the lines show:

- `26bae9cb` line 625 opened PR #8438 before the compact. After line
  660 the session fixes that PR's red actionlint check (lines 703–715)
  and checks runner services (line 727). It does not open the PR again.
  Line 649 had unpacked six runner copies; line 732 removes copies 5
  and 6, inside the summary's "about 4–6" size, and does not unpack
  1–4 again. Line 683 creates the `shadow-actions` and `agent-failed`
  labels the summary still lists as pending.
- After line 1716 the session checks live queue health (line 1769)
  to answer the question already on line 1664. It does not ask for
  that question again.
- `2a1b2116` line 736 says the in-progress step is extracting blockers
  from the keep verdicts. Lines 756–774 do that extraction. They do
  not re-fetch the 186 issues the summary says were already on disk.
- After line 1721, line 1772 sends the other thread the advice the
  user asked for on line 1699. It does not ask what to send.
- `a917a969d71f703ae`: summary line 417 says `reliability.md` is not
  yet written. Line 432 writes that file. It does not ask the parent
  to repeat the research task.
- `ae79e8a31f15ebe0e`: summary line 336 says to assemble `fit.md`
  from parts already on disk. Line 353 reads `fit-part1.md`,
  `perf-a.md`, `perf-b.md`, and `mount-bench.md`. Line 361 writes
  `fit-s3to6.md`, the section 3-6 piece of that assembly. It does
  not ask the parent to restate the task.
- `a19ad211babace64b`: summary line 200 leaves the section-5 gaps
  and writing `perf-a.md` unfinished. Line 216 fetches the Wasabi
  consistency doc. Line 227 searches Storj conditional writes. It
  does not repeat the primary request.
- `aeecba59b94c1ee2c`: summary line 327 leaves the Hetzner Range
  measurement and `perf-b.md` unfinished. Line 342 runs that Range
  curl. It does not ask which URL to measure.

No compacted session showed (a), (b), or (c). The window stays
**250000**. It was not raised to 400000.

## Average context per request

Same definition as the 09-23 baseline (deduped by message id and
request id; context = input + cache create + cache read). The ~238k
figure is the 41 hours ending 2026-09-23 11:15 IST, not the calendar
day. Recomputed on the same local-time parse that produced it:
2221 requests, average 234912 (the original note was 2128 and ~238k;
transcripts appended after that morning account for the gap).

Calendar days, IST, UTC timestamps, same dedupe, scanned this run
(2026-09-24):

| Day (IST) | Requests | Average context |
|---|---:|---:|
| 2026-09-22 | 1370 | 287128 |
| 2026-09-23 | 1285 | 140500 |
| 2026-09-24 | 1331 | 113716 |

09-24 is 113716, against the ~238k baseline. 09-23 before the env
write (11:15 IST) averaged 158966 (758 requests); after it, 113941
(527 requests). The 09-24 maximum assistant-usage context in that
scan was 216939, on sidechain `ae79e8a31f15ebe0e` line 329
(`2026-09-24T04:45:13.060Z`). That figure is the maximum of assistant
usage records. No assistant usage record that day reached 217000.
Compact `preTokens` are a different field on the boundary record;
on 09-24 they peak at 219277 (`a19ad211babace64b` line 196).

No synthetic session was started.

encoded: 5 — the existing fix lives in the host file `~/.claude/settings.json` env `CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000` (present since the 2026-09-23 11:15 IST write). This run left it. No lower rung can hold it: the file is outside the repo, so there is no structure to delete, no CI gate, no rule, and no skill that applies it (docs/ARCHITECTURE.md, correction ladder). The diff against `settings.json.bak-20260924` is the unrelated key `crossSessionInbound` only.
