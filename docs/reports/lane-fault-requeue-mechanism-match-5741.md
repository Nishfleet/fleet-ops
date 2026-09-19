# Lane-fault requeue mechanism match for #5741

Issue #5741 asks to file or match a mechanism for a hand-performed requeue
after a transient-overload lane fault. Match it to the existing rail — the
systemd retry/release wiring, the LiteLLM router cooldown bench, and the
intake re-dispatch path — plus the claim-cap orchestrator gate that bounds
the worst case. No new machinery is built; `tests/lane-fault-requeue-rail.test.sh`
pins the match.

## The seam

An auditor hand-handled a `pi-issue@fleet-ops-2073.service` failure where
`pi-issue-run` reported
`503: {"message":"Upstream model provider is temporarily unavailable...","type":"overloaded_error"}`
on `commandcode/minimax/minimax-m3-free`. The hand steps were: diagnose the
lane fault, bench the seat, then add `fleet-ops-2073-requeue` to
`agent-state/READY-WORK.md` with an `after:` gate so the next worker did not
immediately re-hit the dead seat. READY-WORK.md was a paper ledger — if
nobody re-read it, the issue stayed unclaimed (mechanism issue
[#5743](https://github.com/Nishfleet/fleet-ops/issues/5743), evidence
AUDITOR-LOG.md, report `fleet-blind-audit/reports/20260912T020712Z`).

## Historical evidence

- [#5743](https://github.com/Nishfleet/fleet-ops/issues/5743) (CLOSED) is the
  mechanism request spawned by this issue, and [PR
  #5963](https://github.com/Nishfleet/fleet-ops/pull/5963) (merge commit
  `8529b0af1`, on `origin/main`'s ancestry) built it: on a no-deliverable reap
  of an OPEN issue, `bin/pi-issue-failed-reap` classified the death from the
  seat health ledger (`overload_bench` + `overload_503` + future
  `bench_until`) and appended `until: <bench_until>` to the reclaim-cooldown
  marker; `lib/pi-intake-tick.sh` honoured it with
  `skipped-reclaim-cooldown-bench`.
- `ca33faa96` (2026-09-18, "the unit IS the worker") then deleted both
  carriers — 9,449 lines of bin+lib wrappers — on Nish's minimal-machinery
  directive. `systemd/pi-issue-failed@.service` records the intent: the
  632-line reap was "re-claim accounting, cooldown ledgers and packet
  archiving around these two calls; none of that survives the rule that only
  issue->PR->deploy is load-bearing." The bench-aware `until:` mechanism was
  not lost to drift; it was deliberately replaced by the layers below.
- This issue's own claim record is the live load test: claim/release cycles
  from 2026-09-12 onward, the last StartLimitBurst release at
  2026-09-16T06:31:59Z ([comment
  5693086150](https://github.com/Nishfleet/fleet-ops/issues/5741#issuecomment-5693086150)),
  then the claim-cap gate firing at 2026-09-16T06:52:05Z ([comment
  5693290611](https://github.com/Nishfleet/fleet-ops/issues/5741#issuecomment-5693290611),
  fleet-ops#2772: 4 claims/7200s with no open PR → orchestrator decision
  sweep), and the decision at 2026-09-17T14:21:53Z ([comment
  5715955922](https://github.com/Nishfleet/fleet-ops/issues/5741#issuecomment-5715955922)):
  "resume the named investigation through existing intake; no new machinery
  or reserved action approved."
- The earlier closure attempt failed correctly: observe-to-close refused a
  mere merged-PR mention at 2026-09-13T04:02:49Z ([comment
  5651037172](https://github.com/Nishfleet/fleet-ops/issues/5741#issuecomment-5651037172)).
  This report supplies the acceptance evidence instead.

## Existing mechanism

The three hand steps map onto stock layers that all run today:

- **Diagnose + bench the seat → the LiteLLM router.** A deployment that
  fails is cooled by `router_settings` (`cooldown_time`, `allowed_fails`,
  `allowed_fails_policy` in `config/litellm-proxy.yaml`; the live
  `~/.config/fleet-ops/litellm-proxy.yaml` runs `cooldown_time: 900`,
  `allowed_fails: 2`, `RateLimitErrorAllowedFails: 1`) and is not offered
  again until the bench expires. The `worker-cheap`/`worker-capable`
  fallback pair means a benched group fails over to the other group rather
  than re-hitting the dead rung. This IS the `after:` gate — enforced at
  dispatch time on the seat, which is strictly better than a paper row: it
  cannot be forgotten, and it applies to every dispatch, not one issue.
- **Requeue the issue → systemd + intake.** `systemd/pi-issue@.service`
  retries in-unit (`Restart=on-failure`, `RestartSec=240`, `RestartSteps=3`,
  `RestartMaxDelaySec=30min`, hang-kill `TimeoutStartSec=45min`) under
  `StartLimitIntervalSec=1h`/`StartLimitBurst=3`; on exhaustion
  `OnFailure=pi-issue-failed@%i.service` drops `claim/issue-N` and flips
  `agent-in-progress` back to `agent-ready` — the release the hand row
  simulated. `pi-intake@.timer` (15 min), `bin/pi-intake-trigger`, the
  worker's own ExecStopPost refill, and `prompts/intake.md` then re-claim
  oldest-first and spawn a fresh worker, engine picked devin → cursor → pi
  by live capacity.
- **Bound the worst case → the claim-cap gate.** When every seat is cooled,
  a dispatch fails fast (~90 s observed), releases, and the next tick
  retries — bounded at 4 claims/7200s, after which fleet-ops#2772 parks the
  issue to the orchestrator decision sweep instead of spinning forever.
  That is the designed residual loss versus the retired `until:` gate: a
  few bounded claim cycles in the all-seats-down case only; in the common
  case (some seats healthy) the router bench is the exact equivalent of the
  `after:` gate. The 2026-09-17 decision accepted this route explicitly.

## Current execution evidence

- **The bench fired live today.** `journalctl --user -u
  pi-issue@0509-3622.service` on 2026-09-19 shows the router's own record:
  `429: {"message":"No deployments available for selected model, Try again
  in 900 seconds. Passed model=worker-capable. ... cooldown_list=
  ['synthetic-glm53flash-worker-cheap','pareto-glm53flash-worker-cheap',
  'zenmux-glm47flash-free-worker-cheap','xkiro-qwen3coderplus-free-worker-cheap',
  'xkiro-qwen38max-free-worker-capable','ollama-ds41flash-worker-cheap',
  'ollama-ds41flash-worker-capable']"}` at 09:44:58Z and 10:03:20Z — every
  dead rung benched by the router, no hand ledger. The unit's systemd
  restart counter climbed 2→3, the 45-min `TimeoutStartSec` hang-kill
  SIGTERM'd it at 10:48:54Z, and `Triggering OnFailure= dependencies`
  summoned `pi-issue-failed@0509-3622` for the release. The full
  retry→bench→release path exercised end-to-end on real bytes.
- **The re-dispatch delivered a live worker to this issue.** The 2026-09-19
  intake tick logged `#5741 claimed+spawned — gap-audit LANE FAULT report
  (oldest claimable, 2026-09-12)`, `Engine: devin-issue@fleet-ops-5741
  (Devin count 1 < 3 at selection time)` at 10:49:15Z; claim comment
  [5741189596](https://github.com/Nishfleet/fleet-ops/issues/5741#issuecomment-5741189596)
  at 10:48:47Z and `systemctl --user list-units` shows
  `devin-issue@fleet-ops-5741.service` activating. The issue that spun ~20
  dead claims is being worked — the claim-loop recovery completed through
  existing intake exactly as the decision prescribed (claim-cap → sweep →
  heartbeat stale-label re-queues 5723938221/5724948343/5725591041 on
  2026-09-18 → this dispatch).
- **The pin runs green.** `bash tests/lane-fault-requeue-rail.test.sh` at
  base `74f9a8e1f` exited 0: sections A–D pass — the #5963 carriers stay
  absent, no live surface reintroduces the retired marker grammar, and the
  systemd retry/release, router bench, and intake re-dispatch links are all
  present.

## Disposition

Record #5741 as matched to the existing rail above. The match is to current
live machinery, not to the deleted #5963 files: the hand bench is the router
cooldown, the hand requeue is systemd release + intake re-claim, and the
loop bound is the claim-cap orchestrator gate. `tests/lane-fault-requeue-rail.test.sh`
is the durable pin added with this report so neither the current rail nor
the "do not resurrect" half drifts silently. No new unit, timer, ledger, or
READY-WORK-style row is built — consistent with the 2026-09-17 decision and
the ca33faa96 collapse doctrine. Whether a future per-issue `until:` gate
belongs on the new rail is a rail-design call of the fleet-ops#6105 class,
not this seam's gap.
