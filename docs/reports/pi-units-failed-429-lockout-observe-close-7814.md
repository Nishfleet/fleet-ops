# Observe-close for #7814 — 12 pi-* units permanently failed after the 2026-09-19 worker-lane 429 outage; remediation executed and verified

fleet-ops#7814 (filed 2026-09-19 ~06:55 UTC, from a worker live-state check
during the Nishfleet/0509#3579 run) recorded 12 user-scope `pi-*` units stuck
in `failed` after a LiteLLM worker-lane 429 wall: `pi-issue@fleet-ops-{3350,
5385, 5480, 5694, 5723, 5735, 5752, 5999}`, `pi-intake-repair@{0509,
fleet-ops}`, `pi-scout-repair@0509`, `pi-scout@0509`. Each had burned its
`StartLimitBurst=3` inside `StartLimitIntervalSec=1h` on
`429: No deployments available` and exited into `Start request repeated too
quickly` — a state no amount of lane recovery clears by itself. The issue's
remediation order was: wait for lane recovery -> `reset-failed 'pi-*'` -> let
the intake reconciler re-enable the intake/scout units -> confirm a clean
`list-units --state=failed`.

That order has been executed and re-verified live on 2026-09-22. This report
is the close record, matching the established observe-close pattern (#6665 /
PR #7972, #7483 / this directory).

## What the records show

1. **The failed set was drained by repeated `reset-failed` passes on
   2026-09-20/21**, applied by worker units running their step-3
   failed-list duty, not by a dedicated sweep. Journal evidence (IST):
   09-20 07:39:47, 08:07:09, 12:14:21, 13:00:04, 13:57:33, 14:49:33,
   16:11:01, 18:26:24, 18:51:42, 20:28:00, 21:16:59 — each pass ends "failed
   list is empty". `docs/reports/empty-run-burst-7483-observe-close.md`
   ("Live state measured this run", 2026-09-21 ~04:45 IST) records clearing
   the then-failed five units "with `systemctl --user reset-failed` (the
   #7814 remedy)".

2. **All 12 named units are now clean.** Verified 2026-09-22 ~09:31 IST
   (~04:01 UTC): `systemctl --user list-units --state=failed` (user scope,
   `XDG_RUNTIME_DIR=/run/user/1000`) returns empty, and
   `systemctl --user show` on each of the 12 reports `Result=success`,
   `ActiveState=inactive`. `pi-intake-repair@0509` completed green
   2026-09-21 15:02:09 IST (`INTAKE-REPAIR-VERDICT repo=0509
   result=success exit=0`). The `pi-issue@` oneshots' unit records have
   since been collected entirely (`-- No entries --` in the journal); their
   claims were released by the claim-release path (the `#6292` trace lines
   on this issue) and the issues re-entered the queue.

3. **The lanes recovered.** Live gauges at verify time: LiteLLM
   `/health/readiness` -> `{"status":"healthy","db":"connected"}`; every
   raw-model `litellm_deployment_state` row reads `0.0`
   (`pareto-glm53flash-worker-cheap`, `pareto-glm53flash-worker-capable`,
   `opencodego-ds41flash-worker-cheap`, `opencodego-ds41flash-worker-capable`,
   `pareto-glm53flash-senior`, `opencodego-ds41flash-judge`). The
   `worker-cheap`/`worker-capable`/`senior` alias rows at `2.0` are the
   documented 60-second cooldown flap, not an outage. Timers are armed and
   firing: `pi-intake@0509` ticked 09:30 IST, `pi-intake@fleet-ops` 09:11
   IST, `pi-scout@fleet-ops` 08:00 IST; `fleet-sync` is green on its ~90 s
   cadence.

4. **The lockout class's own fix already landed.** PR #8210 (merged,
   `9204bcd92`) made `pi-intake-repair@` retry transient 429s instead of
   locking out; PR #8213 (merged, `4dc13746d`) counts `activating` oneshot
   workers in the intake liveness guard so a cooldown burst is not misread
   as dead capacity.

## Acceptance status

1. Wait for lane recovery — **done** (raw-model rows all `0.0`,
   evidence above).
2. `systemctl --user reset-failed 'pi-*'` — **done** (journal trail plus
   the #7483 observe-close record; verified empty list today).
3. Reconciler re-enables the failed intake/scout units — **done**:
   `pi-intake-repair@` and `pi-scout@` are timer/path-fired units that
   re-enter on their own ticks once the rate-limit window and lanes clear;
   both are `Result=success` now, and the intake-repair prompt already
   carries the `reset-failed` + `start --no-block` wedge procedure
   (`prompts/intake-repair.md` step 3, `prompts/scout-repair.md` step 2).
4. Confirm a clean `list-units --state=failed` — **done** (empty at
   2026-09-22 ~04:01 UTC).

## Residual classes — each already owned by its own issue

- **No same-hour escalation for user-scope failed units** (the real
  detector gap this finding exposed: a worker noticed the pileup by hand
  three days after the fact because `node_systemd_unit_state` is
  system-scope only) — **fleet-ops#8161**, open.
- The provider-quota 429 wall itself — **fleet-ops#7820 / #7800**
  (intake-repair half fixed by #8210).
- `pi-issue-failed@` re-failing forever on already-deduped
  silent-PR-close findings — **fleet-ops#7917 / #7928 / #7929 / #7932**.
- The dead-man artifact check marking correctly-parked runs `failed` —
  **fleet-ops#7931 / #7851 / #8007**.
- Claim re-dispatch burn — **fleet-ops#7816 / #7817**.

## Termination

The remediation order is fully executed and live-verified; nothing in this
issue's scope remains unowned. The mechanical-fix obligation is met by this
observe-to-close, with the standing escalation detector deliberately left to
#8161 rather than duplicated here. Recommend close as
remediation-complete.
