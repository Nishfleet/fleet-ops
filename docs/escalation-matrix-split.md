# Escalation matrix → Jev split (fleet-ops#7414)

Phase 1 (SHADOW) rule-to-question mapping. Every decision the old escalation
matrix made is listed below with the live decision point that survives it, the
Jev question that runs in parallel, and which of the four actions it feeds:
**pi-issue-start**, **systemd restart**, **conference**, **notify**.

The matrix still acts everywhere; Jev answers are logged beside the real
decision and change nothing. All new rows land at
`~/.local/state/pi-packet/jev/escalation-shadow.jsonl` with
`site=escalation-shadow` and a `decision_class` field. The alert-side classes
were already split out to their own scored sites by #8121/#7396/#7392/#7394/
#7397/#7424 — the table records which file each class's rows actually live in.
fleet-ops#7754 scores every site against real outcomes.

## What the matrix was — and what the glue sweep already deleted

The issue's inventory (129 enforcement rules, 116 alert thresholds, a
1340-line drain) is pre-sweep. Two 2026-09-18 commits deleted most of it:

- `f8b567588` — `config/rule-enforcement.json` + `lib/rule-enforcement.py`
  (the 129-rule coverage matrix and its parser), the standing-rules
  renderers, and the timer-manifest registry. Pi reads rule files natively
  and the vault `global-standing-rules.md` remains the wording authority —
  the deleted half was the copier/matrix, not a rule.
- `9f0cba02c` — escalation-tower, 16,948 lines: the five global
  `OnFailure=unit-escalation@` drop-ins (13,226 trips/7d),
  `stop-escalation-*`, `fleet-escalation-drain` (the drain),
  `escalation-organ-watch`, `escalation-daily-sweep`, `pi-escalation-audit`,
  `bin/unit-escalation-write`, `prompts/escalation-auditor.md`,
  `docs/escalation-matrix.md`, 22 tests.
- `bin/blocked-reconcile` and `claim-reconcile` — deleted in the same sweep;
  their decisions moved into `prompts/intake.md` step 2 and the
  `am-executor-claim` EXIT trap respectively.

Deleted organs make no decisions, so no shadow rows can exist for them —
the sweep already ran Phase 2's deletion half on them. What follows is the
surviving deciding layer.

## Decision-class → Jev-question map

| # | Decision class | Live decision point | Jev question (type) | State fields | Action fed | Shadow site / file | Status |
|---|---|---|---|---|---|---|---|
| 1 | Alert threshold fire | `config/fleet_rules.yml` — 18 PromQL exprs, evaluated by Prometheus | none — arithmetic, not judgement (the `resolved` precedent): a threshold crossing is a fact, the decision is what to do about it | expr result, `for:` window | → dispatch | n/a | arithmetic; covered downstream by class 2/3 |
| 2 | Alert dispatch — spend a repair session? | `bin/am-executor-claim` Jev gate | `needs_repair_session` (boolean) | alertname, labels, annotations, alerts_summary, prior_dispatches | systemd restart (repair session spawn) | `alert-dispatch.jsonl` | live since #7396 + #8121 |
| 3 | Alert disposition — resolved-noop / repair-in-place / file-issue / nish-escalation | same POST, batched | `triage_class` (choice(4), candidates built in code) | same state + criteria per class | systemd restart / pi-issue-start (filed issue) / notify (nish) | `alert-triage.jsonl` | live since #8121 |
| 4 | Alert needs-Nish | same POST, batched | `needs_nish` (boolean) over canonical reserved-class list + money boundary | reserved_classes, money_boundary, alert fields | notify (out-of-band page) | `alert-triage.jsonl` | live since #8121; advisory forever |
| 5 | Dedupe — firing while a repair is live / claim held | `am-executor-claim` singleflight (`skipped-live-worker` code rows) | none — flock/live-unit probe is arithmetic | unit list, lock state | suppresses systemd restart | `alert-triage.jsonl` (`decision_source:code`) | live since #8121 |
| 6 | Repair-path dedupe/flap evidence | `prompts/alert-repair.md` tier (#7394) | dedupe/flap questions per that block | prior dispatches, marker matches | informs 3's real disposition | `alert-repair.jsonl` | live |
| 7 | Auto-rerun of a died-on-transient one-shot | `prompts/alert-repair.md` tier (#7392) | `jev-class` choice per that block | log tail, unit, repo | systemd restart (re-run) | `gha-stuck-run-watch.jsonl` | live |
| 8 | Auto-revert attribution | `prompts/alert-repair.md` tier (#7397) | `rule_disposition` per that block | alert, rule evidence | systemd restart (revert) | `auto-revert.jsonl` | live |
| 9 | Flaky-test quarantine | `prompts/alert-repair.md` tier (#7424) | per-test flakiness boolean | test, failure signature | pi-issue-start (quarantine issue) | `flaky-test-quarantine.jsonl` | live |
| 10 | Parked-issue gate eval — release vs stay parked (the issue-queue drain disposition; `blocked-reconcile`'s surviving organ) | `prompts/intake.md` step 2, per parked issue | `gate_resolved` (boolean) | gate form, gate text (untrusted), probe result, issue labels/age | pi-issue-start (release feeds claiming); conference (`needs-orchestrator` on loud-unparkable) | `escalation-shadow.jsonl` (`decision_class=parked-gate-eval`) | **this PR** |
| 11 | Claim release — dead worker's claim: release vs hold | `bin/fleet-claim-release` terminal decisions | `release_is_safe` (boolean) | open PRs on claim ref, issue state/labels, ahead_by, preserved wip ref, matrix_decision taken | systemd restart (requeue) / notify (trace comments) | `escalation-shadow.jsonl` (`decision_class=claim-release`) | **this PR** |
| 12 | Silent-PR-close flag | `bin/fleet-silent-pr-close-check` per candidate | `matches_silent_close` (boolean) | PR, head ref, close actor/ts, comment window, branch/issue state, verdict detail | notify (trace comment + SystemUnitFailed page) / conference (judge owns restore) | `escalation-shadow.jsonl` (`decision_class=silent-pr-close`) | **this PR** |
| 13 | Intake ordering / capacity / engine pick / enrolment | `prompts/intake.md` steps 3–5, `bin/pi-intake-trigger` | none — arithmetic: label sets, `createdAt` order, unit-count caps, repo membership | counts, caps, labels | pi-issue-start | n/a | arithmetic; no model to shadow |
| 14 | Seat smoke probe spend | `prompts/intake.md` Jev cascade (#7396) | `smoke_will_pass` (boolean) | seat's litellm_deployment_state rows | systemd restart (probe spend) | `intake-seat-smoke.jsonl` | live |
| 15 | Worker needs-Nish — `orchestrator` vs `nish-decision` park | `prompts/worker.md` step-4 second-opinion (#7429) | `needsNish` (boolean) + `reservedClass` (choice), two framings | blocker card, reserved-class list | notify (Nish) / conference (orchestrator) | `second-opinion-reserved.jsonl` | live |
| 16 | Conference verdicts | out-of-repo process — senior packets via the kimi judge unit; verdicts land as `decision-resolved:` comments | the summon decision is class 15's; verdicts themselves are the conference's output, not a matrix call | — | conference | n/a | no in-repo organ; Phase 2 puts the conference behind Jev's uncertain band only |
| 17 | Digest/notify disposition | `prompts/daily-digest.md` | per that prompt's blocks | triage inputs | notify | `hermes-digest.jsonl`, `merge-queue-batches.jsonl`, `fleet-weekly-review-triage.jsonl` | live |
| 18 | Claim-vs-evidence / reviewer-needs-review / merge-enqueue risk | `prompts/worker.md` steps 7–10 | per those blocks | PR metadata | conference (review) | `claim-check-*.jsonl`, `reviewer-needs-review.jsonl`, `merge-queue-enqueue.jsonl` | live |

## Alert rules → questions

All 18 rules in `config/fleet_rules.yml` funnel through the same dispatch
decision (classes 2–4); none carries its own judgement. Severity routes the
action, not the question: `severity=nish|page` → telegram (notify) and never
reaches a model; `critical|warning|none` → repair-dispatch → classes 2–4.

| alert | severity | for | question(s) |
|---|---|---|---|
| Watchdog | none | — | n/a — routes to repair-dispatch, dead-ends on resolved |
| RepairDispatchDown | page | 5m | notify path; dispatch unreachable by construction |
| FleetNishPageRailDown | critical | 5m | needs_repair_session + triage_class + needs_nish |
| LitellmKeyBudgetNearlyExhausted | nish | 10m | none — never-gated boundary class (code row) |
| FleetLitellmProxyAbsent | critical | 5m | needs_repair_session + triage_class + needs_nish |
| FleetLitellmDeploymentUnhealthy | critical | 10m | same |
| ResticRestoreProofStale | critical | 15m | same |
| SystemUnitFailed | critical | 5m | same |
| DiskAlmostFull | critical | 10m | same |
| MemoryPressureHigh | critical | 15m | same |
| CiMergeQueueHeadWaitHigh | critical | 10m | same |
| CiHostedQueueDepthHigh | warning | 15m | same |
| FleetMainRed | critical | 30m | same |
| FleetProbeStale | critical | 10m | same |
| Product0509TimelineDark | critical | 5m | same |
| Product0509SearchTierRegression | critical | 5m | same |
| Product0509SearchAliasGapDeadEnd | critical | 5m | same |
| ProductCanaryProbeDown | critical | 10m | same |

## The four actions, fed by class

- **pi-issue-start**: classes 3 (file-issue), 9, 10 (release→claim), 13.
- **systemd restart**: classes 2, 3 (repair-in-place), 5 (suppression), 7, 8, 11, 14.
- **conference**: classes 10 (loud-unparkable → `needs-orchestrator`), 12
  (judge owns restore-or-close), 15, 16.
- **notify**: classes 3 (nish-escalation), 4, 11–12 (trace comments),
  15 (Nish decision), 17.

## Fallback — kept, per the issue's rule

Shadow mode never acts, so the fallback IS the acting path. Every site fails
open on missing key, timeout (15–20 s), malformed answer or invalid
probability: the row is skipped (or logged with the matrix decision alone),
the real path runs, and `advisory unavailable (<reason>)` prints. A repeated
fallback stays loud through the existing canary (SystemUnitFailed →
repair-dispatch). The canonical reserved-classes list reaches Jev only as
criteria config in `state` — never inferred.

## Phase 2 (not this PR)

Off until the shadow log shows: ≥500 real events, 0 cases where Jev called a
truly reserved item auto-fixable, ≥95% agreement elsewhere with disagreements
spot-audited by the reviewer subagent. The flip is one config value per site
(the `JEV_*=act` switches); senior conference then runs only in Jev's
uncertain band. Counting note: `escalation-shadow.jsonl` rows carry
`matrix_decision` vs `jev answer+p` per event — agreement is a per-class
comparison over that file plus the per-class site files above.
