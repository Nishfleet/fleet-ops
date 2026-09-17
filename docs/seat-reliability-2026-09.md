# Seat reliability: incomplete evidence inventory

This is partial work for #7444, not the requested reliability report.
No death has been classified by the evaluation service in this run. Do not use
these counts to bench a seat, change a cap, rank providers, or satisfy a flip bar.
The existing `infra/work` marker and reclaim behavior are unchanged.

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

## Acceptance still open

1. Add advisory cause and probability beside the regex result on every failed
   attempt, including resumed and wrapper deaths. No live hook is included here.
2. Join the full August 18 onward window with session timestamps, packet archives,
   historical seat ledgers and host failure records. Exclude test traffic and
   reconcile unmatched starts and exits. Do not substitute current memory peak or
   ledger state for missing historical values.
3. Evaluate every real death with the exact shared questions and full context,
   within the approved $1 cap. No raw credential-bearing session text may be sent
   or committed. Produce per-seat causes, rates, medians, weekly trends and evidence.
4. File supported bench/cap proposals or tooling repair issues. No such conclusion
   follows from this inventory, so no seat action issue is justified yet.
5. Keep detailed causes advisory. The later mapping review and flip still require
   200 real deaths and at least 95% independent audited agreement. Neither is met.

Shared helper tracked spend was $0.222671484 before scope consultation and
$0.273476154 at the later read. Other callers share that ledger, so the difference
is not this issue's cost. Gateway credits were not read. There is no classified
backfill or credits-delta claim. Scope decisions are not death classifications.

## Continuation

Use this reader as an inventory input, not as the full backfill. Keep #7444 open
until all missing acceptance above is proven. No new service, timer, manifest
entry, automatic collection, or live deployment was added.
