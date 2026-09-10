# Plan — fleet-ops#4773: FleetSloSeatAvailSlowBurn auto-file a repair-rung claim after 1h

## Goal
When `FleetSloSeatAvailSlowBurn` has been firing >1h, exactly ONE open
`critical-path` fleet-ops issue is linked to it (existing #4639-rung claim,
or one this change auto-files), and `am-executor` is notified. Zero open
items while the alert fires past 1h is the fault. Skip-list entry STAYS
(no repair worker spawned). Never page Nish.

## Design decision (link mechanism)
The issue's accept-1 says "write the issue number into the alert's
annotations.description". A runtime config edit of `config/fleet_rules.yml`
from the stateless alert-repair-dispatch receiver is rejected: it would
dirty the deploy clone (deploy-clone-readonly, fleet-ops#3758), be a
stateful side effect from a stateless receiver, and be untestable
hermetically. The fleet's canonical link pattern is the stable `signal:`
key embedded in the filed issue's body (detector-queue-reconciler,
fleet-ops#362). So:
- "Link" = the filed issue's body carries signal key
  `slo/seat-availability-slowburn` + names `FleetSloSeatAvailSlowBurn`; a
  second tick finds it via that key and takes the LINK path (heartbeat
  comment, no second file). Observable via LINK/FILED log lines in
  actions.log.
- The alert's `annotations.description` in `config/fleet_rules.yml` is
  updated ONCE in this PR to name the auto-file-or-link terminus + signal
  key (documenting the mechanism), not a dynamic runtime number.

## Mechanism (extend alert-repair-dispatch, no new organ)
In the `FleetSloSeatAvailSlowBurn` skip branch, BEFORE the generic
`return 0`:
1. Compute firing duration from `AMX_ALERT_1_START` (first alert's
   starts_at). If firing <= 1h: keep SKIP reason=skip-list, return 0 (rung
   hasn't had time to claim; no premature filing).
2. If firing > 1h: search open critical-path fleet-ops issues for the
   signal key `slo/seat-availability-slowburn` (gh issue list --search).
   - Found: log `LINK` line + heartbeat-comment the existing issue. No
     second file. (idempotence: a second tick lands here.)
   - Not found: file exactly ONE via `fleet-issue-file` with `critical-path`
     label + signal key in title/body, body referencing
     `FleetSloSeatAvailSlowBurn` + the #4639 rung + am-executor. Log
     `FILED` line.
3. Return 0 in both cases — skip-list stays, NO worker spawn (criterion 3).
"Notify am-executor": the dispatch path IS am-executor's receiver; the
file-or-link happening in-dispatch is the notification. Plus a LOUD log
line for fleet observability. No Nish page (criterion 4).

Reuse the exact organs detector-queue-reconciler uses: `fleet-issue-file`
(filing), `gh issue list` (search), `gh issue comment` (heartbeat). No new
timer/service/dispatcher/canary (deletion-first).

## Phases
- [ ] phase 1: extend `libexec/alert-repair-dispatch` — add
  `_slowburn_file_or_link()` + firing-duration helper + branch in the
  SlowBurn skip path. Hermetic via env overrides
  (FLEET_ISSUE_FILE, GH, ALERT_REPAIR_NO_SPAWN already exist; add
  FLEET_SLOWBURN_REPO, FLEET_SLOWBURN_SIGNAL, FLEET_SLOWBURN_THRESHOLD_S).
- [ ] phase 2: update `config/fleet_rules.yml` FleetSloSeatAvailSlowBurn
  `description` to name the auto-file-or-link terminus + signal key.
- [ ] phase 3: extend `tests/alert-repair-slo-slowburn-skip.test.sh` to
  prove BOTH directions + idempotence: (a) firing >1h + no existing claim
  → files exactly one, notifies, no spawn; (b) firing >1h + live claim →
  links (no file), idempotent across a second tick; (c) firing <=1h →
  plain SKIP, no file (no premature filing). Mock gh + fleet-issue-file.

## Out of scope
- Raising the alert-repair skip-list entry for SlowBurn (needs new judge
  call; tests/alert-repair-slo-slowburn-skip.test.sh +
  tests/alert-repair-claim-mutex.test.sh lock it).
- Any money/seat-cap/top-up decision (criterion 6).
- Runtime config edit of fleet_rules.yml (rejected above).

## Proportionality note
Heavy issue, but contained: 1 organ extended, 1 config doc edit, 1 test
file. Spawning nested pi workers (planner/worker/reviewer round-trips,
each consuming a seat + minutes) is disproportionate for a 3-phase
contained change where the manager holds full context. Implementing
directly with plan-first + self-review-against-acceptance discipline.
