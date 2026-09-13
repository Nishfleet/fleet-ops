## Summary

Implements the standing rule **"Nothing on the VPS fails silently, everything resumes, nothing is duct tape"** (Nish, 2026-09-11 — vault `global-standing-rules.md`, permanent fleet policy) as the resume-or-dispatch escalation chain (fleet-ops#5456, addenda G-J + the 2026-09-11 21:59 IST incident binding constraints).

A failed unit now always terminates in an ACTION, never a log:

- **A — chain terminates in an action:** `service.d/10-escalate.conf` OnFailure → `unit-escalation-write` STOP-REASON → `stop-escalation.path` → `bin/stop-escalation-dispatch` `resume_or_dispatch`: a pi-systemd-run packet with hop<2 is **relaunched** (same packet, `--hop+1`, next healthy seat via seat-lib `pick_seat`); hop>=2 or any non-packet unit is **dispatched** (agent-ready fleet-ops issue titled after the unit with the last 20 journal lines + findings-ledger `carried_over` row + LOUD `UNIT-DEATH-DISPATCH` triage line). A Nish message only when the dispatcher itself cannot act (issue create AND hermes both fail). A derived issue target that is closed/merged is recorded as a distinct `derived-target-closed` finding (disposition=by_design) instead of a false unit-death page — the 2026-09-11 `pi-issue@fleet-ops-37` false-page class.
- **B — deliverable contract:** `pi-systemd-run` arms an ExecStopPost dead-man that **fails the unit** when `--deliverable` is missing/empty at stop (`verdict=no-deliverable` in the ledger), so exit-0-without-deliverable fires OnFailure. Also arms a per-unit `90-no-resume.conf` (Restart=no) so the global policy never races the hop+1 relaunch.
- **C — fleet-ops#5444 folded in:** `pi-packet-failed@.service` now emits a structured STOP-REASON (`reason=packet-exhausted`) into the same dispatcher instead of a logger-only line; the logger breadcrumb stays.
- **D — coverage canary:** `bin/fleet-escalation-canary` fails on any loaded user service/path/timer/scope without the OnFailure hook and not on the explicit anti-recursion allowlist (`tests/escalation-canary` scenario coverage incl. `3b`); wired into the P14 CI list and fleet-heartbeat (block 1 every tick).
- **E/H — kill-three-ways drill:** `bin/chain-e2e-drill` hop 7 kills a throwaway dummy packet three ways (crash / RuntimeMaxSec deadline / success-without-deliverable) and asserts STOP-REASON → hop-1 relaunch → on resume exhaustion an agent-ready issue + ledger row + LOUD triage line. Runs from the EXISTING hourly `fleet-heartbeat-tier1` block 5b — no new timer. Its result is one line the judges read.
- **F — dead-man for the chain itself:** `~/.config/fleet-heartbeat/hc.env` is provisioned (HC_URL set) and all four keystone `HC_URL_*` in `~/.config/fleet-ops/keystone-hc.env` are populated (INTAKE/SCOUT/RECONCILE/RESTORE — verified this run; nothing left needing Nish's healthchecks login there). `bin/fleet-resilience-drill` now fails LOUD (`HEARTBEAT-HC-UNCONFIGURED`) when the heartbeat HC_URL is missing/empty — that rail is what pages through a stopped user manager.
- **G (amended) — resume policy is an ALLOWLIST, not a global Restart=:** `systemd/service.d/20-resume.conf` is the permanent policy declaration. It carries deliberately **no** `Restart=` key: the 2026-09-11 incident proved a global `Restart=on-failure` restart-loops timer-driven oneshot canaries into `start-limit-hit` (nine units dead six hours). Resume-in-place entries (pi-issue@, pi-packet@, litellm daemons) each ship their own per-unit Restart in `systemd/`; packet units resume via the dispatcher on the NEXT seat; oneshot/timer canaries keep Restart=no (next tick + dispatcher is the retry); escalation handlers never recurse. NO global StartLimit change ships — the busiest timer (siterep-uptime, 2-min cadence, Restart=no) would count timer-activated starts and re-create the outage; per-unit limits (3/1h, RestartSec=240) are sized so three restarts span ~12 min inside the 1h window, and their exhaustion is exactly the dispatcher's escalation trigger.
- **I — tamper canary:** canary block 1b hash-asserts BOTH global drop-ins (`10-escalate.conf`, `20-resume.conf`) repo-vs-live every tick; removed or hand-edited = `ESCALATION-CANARY-VIOLATION`.
- **Rule-enforcement:** the `sr-nothing-on-the-vps-fails-silently-everything-resumes-nothing` row in `config/rule-enforcement.json` flips from `queued(#5456)` (PR #5615) to `enforced`, citing this detector; `bash tests/rule-enforcement.test.sh` passes against the live vault.
- **Bridge retired:** `night-watch-20260911` (the duct-tape bridge this issue replaces) is already gone from the host (no unit files, no units — verified this run); nothing to delete at deploy time.

**Binding constraints honored:** nothing applied to the live host by this worker — all unit/drop-in changes ship under `systemd/` + `MANIFEST` and install via the existing deploy path after merge (the drill ran only against throwaway `live-dummy-resume-drill-*` units it created and removed itself, with hermetic dispatcher seams: fake gh/hermes, synthetic ledger/triage/findings); allowlist not global Restart=; no sudo; no system-level units touched.

net-positive-because: the chain previously TERMINATED in a log line at four separate hops (dispatcher absent, advisory deliverable, logger-only packet-failed, no relaunch consumer); each added block is one of those hops made mechanical, and the acceptance demands the live drill + canary prove all of them.

## Verification

Real runs on THIS branch (worktree `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-5456`, unit pi-issue-fleet-ops-5456, 2026-09-13). Pickup: the prior attempt's worktree held one 5456 commit (a9c887ac3, 2026-09-13T09:07Z, never pushed, no PR); salvaged it by cherry-picking onto current origin/main 60105ddc4 (which adds #6304 organ-watch + #6343) as f7b39a4f2 — three #5854-adjacency conflicts in `bin/fleet-resilience-drill`, `bin/unit-escalation-write`, `tests/fleet-resilience-drill.test.sh` resolved as unions (organ-watch entries + this issue's `*resume-drill-*` exclusion and HC_KEY sweep both kept). Then, on the merged tree:

```
$ for t in stop-escalation-dispatch pi-systemd-run pi-detached-deadman chain-e2e-drill fleet-resilience-drill; do bash tests/$t.test.sh; done  -> PASS rc=0 each
$ bash tests/escalation-coverage-canary.test.sh   -> rc=0 (allowlist + hash-tamper blocks; in the P14 CI list)
$ bash tests/rule-enforcement.test.sh             -> rc=0 (live-vault join; the sr-nothing-on-the-vps-fails-silently-… row enforced, detector = this chain)
$ sgscan                                          -> "No new security findings." rc=0
$ CHAIN_E2E_DRILL_DEADLINE_LIVE=1 bin/chain-e2e-drill -> ALL 16 hops pass, rc=0 (transcript below)
$ crgate                                          -> rc=3: CodeRabbit CLI signed out on this machine (auth status: signed out; the OAuth completion needs a browser, i.e. one Nish click — `coderabbit auth login`). No reviewer gate weakened: the CodeRabbit GitHub App reviews this PR in the cloud regardless, and sgscan + the suites above are green. Loose-end queued below.
```

Night-watch bridge (the duct tape this issue replaces) re-verified gone from the host this run: 0 `night-watch*` units, 0 unit files in `~/.config/systemd/user/`.

## run-proof:

run-proof: chain-e2e-drill LIVE kill-three-ways 2026-09-13T11:15:14Z→11:16:17Z (63s) all_pass=true, 16/16 hops (`/home/nish/workspaces/agent-state/chain-e2e/chain-e2e-drill-results.json` ran_at=2026-09-13T11:16:17Z, artifacts `resume-drill.20260913T111514Z`); leftover-dummy check: 0 `live-dummy-resume-drill-*` units remain; GitHub plane untouched (#3752 still CLOSED, updatedAt 2026-09-06 — this run's reconciler pass was a no-op against it); fleet-heartbeat-tier1 block 5b wires the drill hourly (no new timer); fleet-escalation-canary blocks 1+1b run every heartbeat tick via fleet-heartbeat-tier1; systemd units shipped for the deploy path: `systemd/service.d/20-resume.conf`, `systemd/pi-packet-failed@.service`, `systemd/chain-e2e-drill-fixture.service`, `systemd/chain-e2e-drill.slice` (MANIFEST lines 699-709); P14 CI job runs `tests/escalation-coverage-canary.test.sh`, `tests/stop-escalation-dispatch.test.sh`, `tests/pi-systemd-run.test.sh`, `tests/rule-enforcement.test.sh`.

## Live drill transcript (item E termination proof)

`CHAIN_E2E_DRILL_DEADLINE_LIVE=1 bin/chain-e2e-drill` — this run 2026-09-13T11:15:14Z → 11:16:17Z (63s, start-to-verdict; well inside the 5-minute budget):

```
fixture-isolated                    pass  stub unit not provisioned; wiring asserted (dry)
ticket-auto-filed                   pass  reconciler filed 1 ticket for signal: chain-e2e-drill/fixture (hop2)
escalate-senior-routed              pass  filed fixture ticket routed to escalate-senior (label) — panel intake, no real page
mechanism-gate                      pass  no-mechanism fixture REJECT; same fix + this drill PASS (#366)
observe-to-close-refused-while-red  pass  detector still red: ticket not closed (closed=0)
observe-to-close-flips-on-green     pass  fixture green observed on a real tick: ticket closed (closed=1)
slo-snapshot                        pass  fleet-gap-closure-slo folds chain-e2e-drill-results in; hops green
resume-wiring                       pass  dispatcher resume/dispatch + drill sink + writer exclusion + dead-man/no-resume arming
kill-crash-unit-failed              pass  exit-1 crash landed the transient unit in failed AND fired OnFailure
kill-crash-hop1-relaunch            pass  dispatcher relaunched the dead packet at hop=1 (same chain-id, ledger row written)
kill-nodeliv-deadman-fails-unit     pass  exit-0 stop with missing --deliverable FAILED the unit AND fired OnFailure (ExecStopPost)
kill-nodeliv-verdict-row            pass  dead-man recorded verdict=no-deliverable in the dispatch ledger
kill-deadline-runtime-cap           pass  deadline arms RuntimeMaxSec=<deadline>min — a hung packet self-terminates into failed
kill-deadline-live                  pass  RuntimeMaxSec killed the hung dummy at the cap; unit failed
second-death-dispatched             pass  resume exhausted -> agent-ready issue payload + findings-ledger row (carried_over) + LOUD triage line
drill-cleanup                       pass  all throwaway dummies stopped, reset, and drop-ins removed
kill-three-ways                     pass  live kills green
2026-09-13T11:16:17Z chain-e2e kill-three-ways: PASS (crash->hop1 relaunch, no-deliverable->failed unit, resume-exhausted->dispatch) artifacts=/home/nish/workspaces/agent-state/chain-e2e/resume-drill.20260913T111514Z
```

Ledger proof (hop 0 → hop 1 relaunch, then hop 2 dispatch) — rows written 2026-09-13T11:15:15Z, i.e. ~1s after the crash:

```
{"id":"6e1c5657-…","unit":"live-dummy-resume-drill-crash-20260913T111514Z","ts":"2026-09-13T11:15:15Z","status":"failed","verdict":"no-deliverable"}
{"id":"e72fe453-…","chain_id":"chain-20260913T111514Z","hop":1,"ts":"2026-09-13T11:15:15Z","unit":"live-dummy-resume-drill-crash-20260913T111514Z",…,"deadline_min":1,"deliverable":"…/never-written-live-dummy-resume-drill-crash-20260913T111514Z.md","status":"open","retries":1}
{"id":"f2a3312d-…","unit":"live-dummy-resume-drill-nodeliv-20260913T111514Z","ts":"2026-09-13T11:15:15Z","status":"failed","verdict":"no-deliverable"}
2026-09-13T11:16:17Z UNIT-DEATH-DISPATCH live-dummy-resume-drill-nodeliv-20260913T111514Z.service — drill-sink:…/resume-drill.20260913T111514Z/resume-drill/issues.jsonl (hop=2, resume exhausted) — take over + close
{"source_organ":"stop-escalation-dispatch","run_id":"live-dummy-resume-drill-nodeliv-20260913T111514Z-2026-09-13T11:16:17Z","severity":"error","title":"unit death dispatched: live-dummy-resume-drill-nodeliv-20260913T111514Z.service (hop=2)","evidence_ref":"drill-sink:…/resume-drill.20260913T111514Z/resume-drill/issues.jsonl","disposition":"carried_over","reason":"resume exhausted; agent-ready dispatch per fleet-ops#5456 A(ii)"}
```

The dispatched issue payload carries the last-20-journal-lines block (journal shows `Failed with result 'exit-code'` → `Triggering OnFailure= dependencies` → dead-man `verdict=no-deliverable — dead-man tripped`). The crash dummy's second dispatcher trip produced the hop-1 relaunch within ~1s of the STOP-REASON write. GitHub plane untouched: #3752's state after this run is CLOSED/2026-09-06 (verified) — the drill's gh plane stayed read-only.

## Remaining silent paths found but NOT fixed here (addendum J — each its own issue, none left in prose)

- #5918 — pi-detached-deadman who-stopped attribution is blind: ausearch lives at `/usr/sbin/ausearch`, outside the ExecStopPost PATH; #4733 fixed the canary (AUSEARCH_SBIN_PATHS) but not the deadman/who-stopped path. This run's drill journal shows the same blind who-stopped (2026-09-13T11:16:17Z: `who-stopped: no audit trail (auditd not installed?)`).
- #6359 — HC_URL_DETACHED (the fifth) still unprovisioned: the detached-job dead-man ping rail silently skips (`keystone-hc-ping skip (detached): HC_URL_DETACHED unset`, 2026-09-13T11:16:17Z, twice in this drill's journal). #5886 closed with the watching half done (the drill now fails LOUD, #5886's ground truth: four of five provisioned since Aug 27); the check creation needs healthchecks.io = the ONE Nish-login step.
- #6392 — HC_URL_ORGANWATCH (the sixth, added by #6304 today) has NO open owner until now: the escalation-organ watcher's success-ping dead-man silently skips today, exactly the #5886 class; filed this run (plain, no labels) so it is not left in prose.

organ-heartbeat: bin/stop-escalation-dispatch existing-organ unchanged-heartbeat-contract (dispatcher exports via unit-escalation-write STOP-REASON rows + findings-ledger, absent-rule already in config/fleet_rules.yml); bin/fleet-escalation-canary existing-organ unchanged-heartbeat-contract (its absent() rule covers the tick it runs in); bin/chain-e2e-drill existing-organ result-file heartbeat folded into fleet-gap-closure-slo (#180) as before.

loose-ends: HC_URL_DETACHED-creation (#6359), HC_URL_ORGANWATCH-creation (#6392), who-stopped-ausearch-path (#5918), coderabbit-cli-signin (local crgate rc=3; needs one browser OAuth by Nish — cloud CodeRabbit still reviews), first-post-merge tick must show canary block 1b hash-assert green after the deploy path installs 20-resume.conf (deploy-path install, not worker-applied).

Closes #5456
