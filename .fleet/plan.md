# Plan — fleet-ops#4773 (manager: finish the shipped-but-dead SlowBurn terminus)

## Context (manager-verified, do not re-derive)

- The mechanism is ALREADY MERGED: #4998 added `_slowburn_file_or_link` to
  `libexec/alert-repair-dispatch`; #5012 added AMX epoch parsing. Both used
  "Relates to #4773", never "Closes", so #4773 stays open and keeps being
  re-claimed (4 claims, 2 merged PRs, issue still open).
- The issue's `metric:` is still FALSE and the manager proved why, live:
  1. `_slowburn_find_existing("Nishfleet/fleet-ops", "slo/seat-availability-slowburn", "gh")`
     returns `'4773'` — this meta-issue — because `gh issue list --search`
     tokenizes the hyphenated signal and #4773's text matches. The helper never
     checks the `critical-path` label, so the link path treats the META-ISSUE as
     the repair terminus.
  2. Even with the finder fixed, `_slowburn_file` -> `fleet-issue-file` collapses
     onto #4773: real dry-run scored the alarm at **1.00** and printed
     `dry-run comment Nishfleet/fleet-ops#4773`. `_slowburn_file` then parses
     `/issues/4773` out of the comment URL and LOGS `FILED ... issue=#4773`
     while nothing was filed. Wording cannot dodge this: an honest alarm body
     still scored exactly 0.65 (DUP_THRESHOLD) because the shared secondary
     signal `alert/fleetsloseatavailslowburn` adds 0.15 on top of body overlap.
- Live alert: `FleetSloSeatAvailSlowBurn` active since `2026-09-08T09:51:03.742Z`
  (2+ days), zero open `critical-path` items carrying the signal. That is the
  metric's fault state.
- Existing rail to reuse (do NOT invent): `lib/detector-queue-reconciler.py`
  already solves this exact class — `find_existing_signal()` matches the signal
  key as a body trailer, and `verify_filed_signal()` (fleet-ops#4622/#4841)
  checks the RETURNED issue's title carries the signal key and refuses to count
  a wrong pointer as a filing.

## Acceptance mapping

- accept-1 -> phase 1 (find only a real `critical-path` claim; never the meta-issue)
- accept-2 -> phase 1 + phase 3 (one queue item, existing organs only, no new organ)
- accept-3 -> phase 3 (skip-list entry unchanged)
- accept-4 -> phase 3 (am-executor notified; never pages Nish)
- accept-5 -> phase 2 (both directions + idempotence + the live #4773 decoy)
- accept-6 -> phase 3 (no money, no seat top-up/buy/re-scale)

## Phases

- [ ] phase 1: accept-1 + accept-2 — in `libexec/alert-repair-dispatch`, make the
      link path unable to accept a non-claim and make the file path unable to
      report a false terminus. (i) `_slowburn_find_existing`: narrow server-side
      with `--label critical-path`, request `--json number,title,labels`, and
      accept an item ONLY when its labels include `critical-path` AND its title
      carries the `[{signal}]` key (the shape `_slowburn_file` already writes);
      return "" otherwise; keep the fail-open "" on search failure. (ii)
      `_slowburn_file`: after the `fleet-issue-file` call, verify the RETURNED
      issue's title carries `[{signal}]` (reuse the reconciler's
      `verify_filed_signal` shape); on mismatch log a LOUD
      `FILED-LINK-MISMATCH` and return "" — a dedupe collapse onto #4773 must
      never be reported as `FILED`. (iii) `_slowburn_file_or_link`: a failed
      verify becomes `skip-error`, never `filed`. No new organ, no config change.
- [ ] phase 2: accept-5 — extend `tests/alert-repair-slo-slowburn-skip.test.sh`
      so the mock `gh` is label-aware, and add/lock: case (a) >1h + no claim
      FILES exactly one and the create carries `--label critical-path`; case (b)
      >1h + a live `critical-path` claim carrying the signal LINKS + heartbeats
      and files nothing; case (b2) a second tick is idempotent (LINK again,
      still zero files); case (g) the LIVE DECOY — an open non-`critical-path`
      issue whose text fuzzy-matches the signal (the real #4773 shape) must NOT
      be linked and must NOT suppress the file path; case (h) the dedupe
      collapse — the create returns the decoy's `/issues/4773` URL, so the
      dispatcher must log `FILED-LINK-MISMATCH` and must NOT log `FILED`. Keep
      the existing SKIP_SET-lock assertions and all existing cases green.
- [ ] phase 3: accept-2 + accept-3 + accept-4 + accept-6 — prove the blast
      radius is one organ plus its test: diff touches only
      `libexec/alert-repair-dispatch` and `tests/alert-repair-slo-slowburn-skip.test.sh`
      (no new timer/service/dispatcher/canary, no `config/` change), SKIP_SET
      entry for `FleetSloSeatAvailSlowBurn` unchanged (still no worker, no
      DISPATCH line), no Nish page, no money/seat-cap change. Then run the live
      proof: the real finder against the real open queue must now return "" (was
      `'4773'`); a real dispatcher tick must not log a false `FILED`; and the
      real `fleet-issue-file --dry-run` over the real open queue with #4773
      removed (the issue this PR closes) must report a clean file, showing the
      first auto-file lands on the first tick after merge. Paste all raw output.

## Termination command

```
bash tests/alert-repair-slo-slowburn-skip.test.sh \
  && bash tests/alert-repair-claim-mutex.test.sh \
  && python3 -m py_compile libexec/alert-repair-dispatch
```

## Deliverable

A PR on `claim/issue-4773` touching only `libexec/alert-repair-dispatch` and
`tests/alert-repair-slo-slowburn-skip.test.sh`, body carrying `Closes #4773`,
Verification with raw output, and `run-proof:`.
