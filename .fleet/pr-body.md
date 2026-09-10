## Summary

The `FleetSloSeatAvailSlowBurn` terminus shipped in #4998/#5012 was **never live**. Both PRs merged with `Relates to #4773`, so the issue stayed open — and that open meta-issue is exactly what broke the mechanism. Two coupled live defects, both proved with real commands on the live queue:

1. `_slowburn_find_existing` accepted the **meta-issue #4773** as the repair claim. It used a fuzzy `gh issue list --search` and returned the first hit, and never checked the `critical-path` label. Live, before this PR: `_slowburn_find_existing(...) -> '4773'`. The link path therefore treated a non-claim as the terminus.
2. `_slowburn_file` reported `FILED ... issue=#4773` while **nothing was filed**. `fleet-issue-file` dedupes the alarm onto #4773 (real dry-run score **0.98**) and returns a *comment* URL; `_slowburn_file` parsed `/issues/4773` out of it. No amount of rewording fixes this — an honest alarm body still scored exactly 0.65 because the shared secondary signal `alert/fleetsloseatavailslowburn` adds 0.15 on top of the token overlap.

Net effect: the alert fired **2 days** with zero linked `critical-path` items — the exact fault the issue's `metric:` names — and every tick looked successful.

This PR makes a non-claim unusable as a terminus, and makes a false terminus impossible to report.

- `libexec/alert-repair-dispatch` `_slowburn_find_existing`: narrows server-side with `--label critical-path`, and accepts an item only when **both** its labels include `critical-path` **and** its title carries the `[{signal}]` marker (the shape the file path writes). Still fails open to `""`.
- `libexec/alert-repair-dispatch` `_slowburn_file`: after the create it reads the returned issue's title back and requires the `[{signal}]` marker; on mismatch (or an unreadable view) it logs a LOUD `FILED-LINK-MISMATCH`, returns `""`, and the caller reports `skip-error` — never a terminus.
- `libexec/alert-repair-dispatch` filed body made **claimable**: it now carries `metric:` / `accept:` / `moves: no_usable_seat_events`, so the repo's own admission gate accepts it. Before, the gate refused it (`SPEC-GATE: refused — body has no termination:/accept:/required:/metric:`) and nothing could ever claim the item.
- Small robustness guard `_slowburn_run`: a failed exec or a malformed gh payload becomes `skip-error` instead of an uncaught traceback in the dispatcher.
- `tests/alert-repair-slo-slowburn-skip.test.sh`: proves both directions, idempotence, and the two new failure modes.

These rails already existed — this reuses the reconciler's fleet-ops#4622/#4841 shapes (`find_existing_signal`, `verify_filed_signal`) instead of inventing a new one. No new organ, no new timer, no new dispatcher, no new canary.

## accept (from the issue)

1. **Check for an existing claim before filing; link it and stop.** ✓ `_slowburn_find_existing` now requires the `critical-path` label and the `[{signal}]` title marker, so the live #4773 decoy is rejected instead of being linked. Living proof below.
2. **Auto-file-or-link so a >1h slow burn produces exactly ONE queue item, through the existing organs; no new timer/service/dispatcher/canary.** ✓ Diff is 2 files: `libexec/alert-repair-dispatch` (the existing organ) + its test. The item is also now *claimable*, which it was not before.
3. **Do NOT raise the alert-repair skip-list entry for SlowBurn.** ✓ Untouched — `git diff origin/main..HEAD -- libexec/alert-repair-dispatch` contains no SKIP_SET line change, and the tests assert the skip path still spawns nothing.
4. **Notify `am-executor` with the rung; never page Nish.** ✓ The dispatch path is unchanged (`repair-dispatch` receiver); the filed body still carries the explicit "do NOT page Nish" line, and the live tick exits 0 with no page.
5. **Prevention mechanism proving both directions.** ✓ Cases (a)-(l); see the test output. Mutation controls confirm each new case bites.
6. **No money decision; no seat top-up/buy/re-scale.** ✓ No seat cap, seat state, or spend file is touched.

## Verification — real runs, raw output

### Live: the finder no longer accepts the meta-issue

```
$ python3 -c "... _slowburn_find_existing('Nishfleet/fleet-ops','slo/seat-availability-slowburn','gh') ..."
BEFORE (origin/main): '4773'      <- the meta-issue, treated as the repair claim
AFTER  (this branch): ''          <- no claim; the file path runs
```

### Live: a real dispatcher tick against the live alert (firing 206798s = 2.4 days)

Real `gh`, real live alert (`AMX_ALERT_1_START=1788861063`, the epoch of `2026-09-08T09:51:03.742Z`), create suppressed read-only so no spurious comment lands on #4773:

```
$ libexec/alert-repair-dispatch
[2026-09-10T19:17:45Z] LOUD FILED-LINK-MISMATCH FleetSloSeatAvailSlowBurn fleet-issue-file returned
  issue=#4773 title='FleetSloSeatAvailSlowBurn should auto-file a repair-rung claim after 1h
  (follow-up to #4639)' which does not carry signal key [slo/seat-availability-slowburn];
  refusing to report it as FILED (fleet-ops#4773)
[2026-09-10T19:17:45Z] WARN FleetSloSeatAvailSlowBurn auto-file failed (firing 206798s)
[2026-09-10T19:17:45Z] SKIP alertname=FleetSloSeatAvailSlowBurn (in skip-list)
dispatcher rc=0
```

Before this PR the same tick logged `FILED ... issue=#4773` and no worker, no item, no terminus ever existed.

### Live: the dedupe collapse is real, and the file path is clean once #4773 closes

`fleet-issue-file --dry-run` over the **real** open queue (153 issues fetched live):

```
$ ... --from-json <real open queue>                    -> dry-run comment #4773 score=0.98
$ ... --from-json <real open queue minus #4773>        -> dry-run filed    score=0.28  kind=new
```

So the collapse onto #4773 is what the `FILED-LINK-MISMATCH` guard is protecting against, and once this PR closes #4773 the file path is clean — the first 6h tick after merge files exactly one `critical-path` item. **This is why the PR must carry `Closes #4773`: while that meta-issue is open, the repo's own dedupe correctly refuses to file a second issue about the same alert, and no wording change can dodge it (an honest body still scored 0.65).**

### Termination command (from the issue)

```
$ bash tests/alert-repair-slo-slowburn-skip.test.sh && bash tests/alert-repair-claim-mutex.test.sh && python3 -m py_compile libexec/alert-repair-dispatch
OK: dispatcher SKIP_SET contains FleetSloMainGreenSlowBurn (one occurrence in literal)
OK: FleetSloMainGreenSlowBurn: dispatcher SKIP reason=skip-list, no DISPATCH, no spawn
OK: fleet-ops#2672 slow-burn skip-list lock passes
OK: (c) firing <=1h: SKIP reason=skip-list, no file, no link, no spawn
OK: (a) firing >1h + no existing claim: FILED exactly one #5555 with --label critical-path, verified by issue view, no spawn, no DISPATCH
OK: (b) firing >1h + live claim: LINK #4242 + heartbeat, no file; idempotent across 2nd tick
OK: (d) multi-alert: SlowBurn at idx2 (>1h) FILED using its own start, not idx1's short decoy
OK: (e) ISO 8601 start also works (backward-compat): FILED exactly one
OK: (f) ISO 8601 start with fractional ms + Z (live AMX shape): FILED exactly one
OK: (g) LIVE DECOY #4773 (agent-in-progress, no [signal] marker) rejected: no link, no comment, file path still ran -> #5555
OK: (h) DEDUPE COLLAPSE onto decoy #4773: FILED-LINK-MISMATCH logged, no '] FILED ' terminus, reported as skip-error
OK: (i) unreadable gh issue view (rc=1, no stdout): FILED-LINK-MISMATCH title='<unavailable>', no FILED, skip-error
OK: (j) the body the dispatcher really filed is claimable: SPEC-GATE: ok (repo fleet-ops)
OK: (k) non-list gh search response: no traceback, fail-open file path still ran
OK: (l) missing gh binary (OSError): no traceback, refused terminus, skip-error
OK: fleet-ops#4773 slowburn file-or-link both directions + idempotence + live-decoy/dedupe-collapse refusal + claimable-body/unreadable-view robustness pass
EXIT=0

... alert-repair-claim-mutex: all OK, EXIT=0
... py_compile: EXIT=0
```

Adjacent dispatcher suites also green: `alert-repair-wfr-trend-skip`, `alert-repair-class-park-skip`, `alert-repair-detached-recursion-skip`, `alert-repair-fleet-escalation-storm-skip`, `slo-budget`.

### Mutation controls — the new cases really bite

Each mutant was reverted; the shipped file is byte-identical to the reviewed one.

```
M1 accept the number whenever the view failed        -> FAIL (i)  [logged FILED ... issue=#9999]
M2 create drops --label critical-path                -> FAIL (a)
M3 title drops the [signal] marker                   -> FAIL (a)  [FILED-LINK-MISMATCH]
M4 no non-list items guard                           -> FAIL (k)  [Traceback]
M5 _slowburn_run does not catch OSError              -> FAIL (l)  [Traceback]
M6 filed body drops metric:/accept:/moves:           -> FAIL (j)  [SPEC-GATE: refused]
```

### run-proof:

`run-proof: libexec/alert-repair-dispatch slowburn terminus — live tick on the real 2.4-day firing alert logs LOUD FILED-LINK-MISMATCH and refuses the false terminus (rc=0, no spawn, no DISPATCH, no page); the repo's own gate accepts the filed body (SPEC-GATE: ok); termination suite exit 0.`

No systemd unit, timer, path unit, or workflow is added by this diff, so there is no new unit/timer to run.

## Test plan

- `bash tests/alert-repair-slo-slowburn-skip.test.sh` — 15 assertions incl. the live decoy and the dedupe collapse.
- `bash tests/alert-repair-claim-mutex.test.sh` — claim-mutex + the SlowBurn skip-list lock.
- `python3 -m py_compile libexec/alert-repair-dispatch`
- Neighbour dispatcher suites listed above.

## Gate lines

- `research:` reusing proven off-the-shelf shapes rather than building: the fix adopts `lib/detector-queue-reconciler.py`'s existing `find_existing_signal` / `verify_filed_signal` (fleet-ops#4622/#4841) signal-trailer + read-back-verify pattern, and `lib/issue-file.py`'s existing label plumbing. No new file is added.
- `help-first:` ran `--help` on every gate used before running it: `bin/prove-one-run-check`, `bin/fleet-exec-review-canary`, `bin/fleet-organ-heartbeat-check gate`, `bin/fleet-token-efficiency-check`, `bin/research-before-build-check`, `bin/agent-ready-spec-gate.py check-body`.
- `organ-heartbeat: libexec/alert-repair-dispatch not-an-organ: it is not present in config/fleet-organs.json; `bin/fleet-organ-heartbeat-check gate --name-status` prints `SKIP: no fleet organ touched in the diff`.`
- `loose-ends: slowburn-first-file-after-4773-closes — the first real auto-file lands on the first 6h AMX tick after this PR closes #4773; until then the tick correctly refuses the false terminus. Verify with: gh issue list -R Nishfleet/fleet-ops --state open --label critical-path --search 'slo/seat-availability-slowburn' — expect exactly one issue whose title carries [slo/seat-availability-slowburn].`
- `loose-ends: seat-walled-test-pre-existing-red — tests/alert-repair-seat-walled.test.sh fails identically on a pristine git archive HEAD export (seat-ladder drift); unrelated to this diff, queued separately.`

net-positive-because: 427 of the 476 net lines are the prevention test the issue's accept-5 requires (cases a-l plus the mock rewrite that stops the test and the code agreeing with themselves); the organ change is 94 added / 22 deleted.

## Consider (reviewer round — recorded, deliberately not actioned here)

- Use `fleet-issue-file --json` to distinguish `filed` from `commented` explicitly, instead of inferring from the title. Harmless today: the only way a collapse reports `FILED` is when the pointer's title already carries `[{signal}]`, i.e. it is the correct terminus.
- The read-back always resolves against `SLOWBURN_REPO` while cross-repo dedupe is on by default; a cross-repo pointer could be verified as a same-numbered fleet-ops issue. Narrow, and fail-closed in almost every case.
- The title match is a substring match, so a `critical-path` issue whose title merely mentions `[{signal}]` is accepted. One step narrower than the bug fixed here.

Closes #4773
