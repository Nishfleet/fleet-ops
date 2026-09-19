# Seat reliability: inventory + causal classification of the #7483 window

Partial work for #7444. The evidence inventory below is unchanged. What changed
since: the 49 verified death records handed over from #7483 are now classified
by the evaluation service (see "Causal classification" below). Do not use these
counts or labels to bench a seat, change a cap, rank providers, or satisfy a
flip bar — the bar's machinery no longer exists either (see Acceptance).

## Observed records

On 2026-09-17, the offline reader ran against saved output from:

```sh
journalctl --user -t pi-issue-run --since '2026-08-18' -o json --no-pager
python3 scripts/bench/seat-reliability.py --journal JOURNAL.jsonl
python3 tests/seat-reliability.test.py
```

Snapshot SHA256: `5119a21fb3bf8d6c221e14658948f1801aa2eebc6bb773afde6c36dc986a088e`.
The saved snapshot is local runtime evidence, not committed session data.
Its retained timestamps span 2026-09-12T22:05:32.912880Z through
2026-09-17T22:01:26.784412Z. Requesting August 18 did not recover earlier logs.

| Wrapper observation | Count |
|---|---:|
| Exit records | 4,748 |
| Exactly one preceding start in the same boot and unit | 4,730 |
| Multiple preceding starts, left unpaired | 11 |
| Missing preceding start | 7 |
| Failure candidates by exit code or infra-death-requeue reason | 3,509 |
| Unknown reason, left unclassified | 138 |
| Other zero-exit records | 1,101 |

These include test traffic, no-seat starts, and wrapper failures. They are not
unique worker attempts, seat runs, or a death population. In-process resumed
attempts are not separate wrapper exits. A hard kill can leave no wrapper exit.
The reader retains successful exits but cannot supply a valid per-seat denominator.

The first inventory joined by logger PID and paired zero starts in the six-hour
sample from #7483. A real pair disproved that join: `fleet-ops-7414` started at
journal microseconds `1789655987413393` and exited at `1789658508590968`, but
`systemd-cat` had different PIDs. The regression test uses those real records.
The corrected duration is 2521.177575 seconds. Duration does not establish cause.

The final reader pairs by boot and unit, rejects ambiguous starts, removes duplicate
journal records, and leaves missing duration or unknown reason as null. Seven
focused tests passed initially; ten now pass after timezone and non-text-message
regressions were added to the existing `tests/jev-eval.test.sh` CI entry. This proves only the offline join, not classification accuracy.

## Causal classification: the #7483 six-hour window (49 records)

On 2026-09-19/20 the 49 verified `nonempty_hard_bound_aligned` records handed
over from #7483 (issuecomment-5721473896; window 2026-09-17T14:26:00Z to
20:26:00Z) were classified by the evaluation service — typesafe-ai/jev via the
LiteLLM pass-through `POST 127.0.0.1:4000/jev` (the shared `bin/jev-eval.mjs`
helper was deleted in the Jev pass-through cut). One call per death, the four
accepted questions per call: `cause` (choice among the eleven causes),
`attributable_to_seat`, `retry_would_help`, `same_cause_as_last_death`. Calls
ran chronologically; each seat's prior classified cause was fed into the next
call's state for the same-cause question.

Context per death, as far as surviving records allow: the session JSONL's model
alias, last usage, last-eight-record tail, and timeline features (max
inter-record gap, quiet spans, records in the final 300s, repeated identical
calls, errored tool results, whether the last record ends on a `toolCall`);
the unit's `.err` death block when this record was the unit's last attempt
(6 of 49 survived; the rest were overwritten by later attempts); the `.in`
packet head; and the seat ledger's current state. The user journal's retained
range now begins 2026-09-18, so the window's watchdog/exit lines are gone —
`.err` is the only surviving source for them. MemoryPeak is unavailable for
dead transient units. The upstream deployment behind the `litellm` alias is not
in surviving records; the seat is reported at alias granularity.

Every parsed session's tool-call count equals the handoff's verified column
(49/49) — the files classified are the same records #7483 verified against the
journal before rotation.

Distribution, all 49 on seat `litellm/worker-cheap`:

| cause | n | evidence shape |
|---|---:|---|
| unknown_needs_human | 38 | work-in-progress tails; no discriminating record survives |
| tool_or_repo_fault | 8 | blocking call outlived the bound (subagent wait ~2268 s, `systemctl start` on a long unit, `timeout N` bash) or repeated errored results |
| transport_death | 2 | `Request timed out` surfaced in `.err`; mid-request at kill |
| work_logic_error | 1 | real calls but looped/misguided |

The 78% `unknown_needs_human` share is the honest read under rotated evidence:
the journal death lines and request-level HTTP trail that would discriminate
"long productive task" from "quiet stall" are gone. Unknown is a label, not a
miss — preserving unknown joins is a rail of the accepted diagnostic target.
The actionable residue is tooling-side: worker-issued blocking calls that
outlive the 2520 s wall bound are guaranteed deaths regardless of seat health.

Spend: 49 calls, 171,297 input tokens, ≈ $0.0072 of the approved $1 cap.
Labelled rows: `docs/seat-reliability-2026-09-deaths.jsonl` — one JSON row per
death with ref (unit + session path + exit journal µs), `cause` + `cause_p`,
the three boolean probabilities, and `state_sha256` per call. Handed back to
#7483 in its comments; that issue's `blocked-on: #7444` dependency is met.

## Acceptance status after this classification

1. Advisory hook on every death — **mechanism-gone.** The death-record writer
   (`bin/pi-issue-run`'s watchdog/exit path, the regex cause table, and the
   `.last-death-class` marker it wrote) was removed by the rail refactor
   (the unit IS the worker — `pi --print` direct) and the no-glue sweeps.
   `pi-issue-failed@` releases claims only; nothing writes a death class. No
   live death record exists to attach advisory output to; a future advisory
   pipeline needs a new site decision, not this issue's hook.
2. Thirty-day backfill — **partially blocked.** Journal retention no longer
   reaches 2026-08-18→09-17; surviving evidence is session JSONLs plus
   latest-attempt `.err` files. The 49-record handoff window is classified
   above; the wider window needs a session-only rewalk, not the journal join
   originally specified.
3. Evaluation — **done for the handed-over window.** Per-seat distribution is
   on the only seat that died in the window (`litellm/worker-cheap`); a weekly
   per-seat trend is not computable from one six-hour window.
4. Actions — the top named cause is tooling-side (blocking calls outliving
   the wall bound): filed as fleet-ops#7921. No provider-side top cause was
   found, so no bench/cap proposal is justified by this window.
5. Flip — **moot.** The regex table and `.last-death-class` marker were deleted
   with the wrapper; there is nothing to flip and the 200-death/95% bar has no
   object.

Shared helper tracked spend was $0.222671484 before scope consultation and
$0.273476154 at the later read (the helper is now deleted; the pass-through
proxy owns spend). The classification calls above cost ≈ $0.0072.

## Continuation

Use this report and the labelled JSONL as the classification input for #7483.
The remaining open piece is the wider-window session-only rewalk (item 2) and
the site decision for any future advisory death record (item 1). No new
service, timer, manifest entry, automatic collection, or live deployment was
added.
