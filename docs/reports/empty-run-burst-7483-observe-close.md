# Observe-close for #7483 — worker-cheap "empty run" burst: population join falsified the benchable-offender premise

fleet-ops#7483 (filed 2026-09-17) asked for a population diagnosis of the
2026-09-17 21:10–22:10 IST burst in which 27 of ~150 `pi-issue-run` exits were
`infra-death-requeue`-class "empty runs" on `litellm/worker-cheap`, then a bench
of the offending deployment in the router config, a two-tick verification, and
a labelled handoff of the deaths to #7444.

The diagnosis ran to ground across three claimed runs and two orchestrator
amendments. The answer the evidence supports: **there were no empty runs and
there is no benchable offender.** Every infra-death in the window was a
nonempty session killed at the ~2520 s wall bound; the deployment behind every
death also served the large majority of successful runs, and the #7444 causal
classification found no row attributable to a seat fault. This report is the
resolution record, matching the established observe-close pattern (#6665, PR
#7972; #6799, PR #7968).

## What the records show

1. **Population join (accept-1), comments 5720906516/5720911826 on #7483** —
   window 2026-09-17T14:26Z–20:26Z, journal identifier `pi-issue-run`, 402
   enrolled-name exits, 376 session-matched, 26 unknown. **All 49
   `infra-death-requeue` exits carry 16–98 recorded tool calls** and a direct
   `responseId` → `LiteLLM_SpendLogs.request_id` join. Zero matched runs have
   both zero tool calls and zero assistant text — the "empty run" class named
   in the issue body does not exist in the measured population.

2. **Deployment split is shared, not discriminating.** All 49 deaths joined
   `union-alpha-openrouter-worker-cheap` — and 158 of 186 joined
   wrapper-success runs used the same deployment. Presence in both populations
   is correlation, not cause; the orchestrator decision of 2026-09-17
   (issuecomment-5721361002) explicitly forbade benching on it: "Do not bench
   from shared deployment correlation: the same deployment served successes
   and no zero-tool death was proved."

3. **Causal classification (accept-4) landed on main via PR #7922.** The 49
   verified records were handed to #7444 (issuecomment-5721473896) and
   classified per-death through the Jev pass-through: `unknown_needs_human`
   38, `tool_or_repo_fault` 8, `transport_death` 2, `work_logic_error` 1.
   `attributable_to_seat` never exceeded p≈0.51 on any row; the handback
   states "a bench/cap proposal for worker-cheap is NOT justified by this
   window's evidence." Deliverables verified on `origin/main` `abee1abfe` via
   `git cat-file -e`: `docs/seat-reliability-2026-09.md`,
   `docs/seat-reliability-2026-09-deaths.jsonl`.

4. **Elapsed-time structure**: all 49 deaths exited 2520.804–2521.504 s after
   start — the worker wall bound, mid-session. 24 of 49 have a session message
   within 30 s of exit. This is a hard-bound timeout population, not an
   upstream-first-chunk population; the named repair class is #7921 (tool
   calls that cannot return inside the 2520 s bound).

## Acceptance status

1. Population diagnosis naming the offender(s) — **done; the offender count is
   zero.** No deployment is attributable for any of the 49 deaths.
2. Bench the offending deployment + restart the proxy — **not executable on
   evidence.** No offender exists; benching the shared majority deployment is
   forbidden by the orchestrator amendment and by the classifier's attribution
   verdict. No router config was changed and no restart was performed in any
   of the runs.
3. Two-tick verify + burst canary quiet — **moot as written.** The exit-reason
   taxonomy (`bin/pi-issue-run` `journal_mark` `phase=exit` records) was
   deleted in the 2026-09-18 rail collapse `ca33faa96` ("the unit IS the
   worker"), and the empty-run-burst canary went with canary-fleet in
   `ada87b543`. Live check 2026-09-21 ~04:45 IST: `journalctl -t pi-issue-run`
   returns `-- No entries --` for the entire retained journal. As the closest
   surviving proxy signal, `fleet-litellm-proxy.service` logged **0**
   `client disconnected before first chunk` lines in the last 60 min and **3**
   in the last 6 h — versus 84 in the six-hour window that filed this issue.
4. Classified-death handoff to #7444 — **done** (item 3 above; PR #7922 merged
   2026-09-19T23:49:51Z).
5. Devin fallback + seat-lib ledgers — **untouched**; no writes were made.

## Live state measured this run (2026-09-21 ~04:40–05:05 IST)

- Current unit failures are a **different class**: 334 LiteLLM `429
  RateLimitError` lines in the last 60 min (`synthetic.new` subscription rate
  limit; the `worker-cheap → worker-capable` fallback chain in simultaneous
  cooldown — "No deployments available for selected model"). Spend table, same
  6 h, `model_group=worker-cheap`: `pareto-glm53flash-worker-cheap` 45
  success / 1 failure; `synthetic-glm53flash-worker-cheap` 18 success. This is
  the provider-quota wall tracked by #7820/#7800/#7814 — not the
  disconnect-before-first-chunk class that filed this issue.
- Two of the five units then in `list-units --state=failed`
  (`devin-issue@fleet-ops-5650`, `pi-issue@fleet-ops-5722`) were
  correctly-parked blocked-path runs marked failed by the ExecStopPost
  artifact check — the defect tracked by #7931/#7851. All five failed units
  were cleared with `systemctl --user reset-failed` (the #7814 remedy); the
  failed list is empty.

## Termination

`empty-run exits in a 60-min window ≤ 3 with the offender benched and named`
cannot be satisfied as written: there is no offender to bench or name, and the
exit class that defined the metric no longer exists. The diagnostic question —
which deployment served the empty runs vs the successes — is answered with
population-wide real-record evidence: the premise was false. Residual failure
classes live in #7921 (bound-outliving tool calls), #7444 (seat-reliability
classifier, still open), and the 429-wall cluster #7820/#7800/#7814. Recommend
close as diagnosis-complete.
