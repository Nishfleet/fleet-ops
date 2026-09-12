fix(escalation-drain): archive stuck-packet bursts same-run with DISPOSITION lines; stale no-terminal packets move to `archived/stuck/` with a decision line in `actions.log` so the hourly LOUD STUCK-PACKET line cannot repeat forever for a settled burst (fleet-ops#5647)

## What

The drain already deletes consumed packets (terminal proof via `chains.terminated.jsonl`) and LOUD-flags packets older than `FLEET_ESCALATION_DRAIN_STUCK_AGE_S` (6h) with no terminated chain. Per antiquity-prevention fleet-ops#366 and #528, that LOUD line repeated forever for a settled burst: the 244-packet bursts (~10/h) landed hourly because the packets stayed live. Now, in the run that LOUDs:

- each stuck packet is MOVED to `$PACKET_DIR/archived/stuck/` (never silently deleted — the file persists and its name is preserved),
- a `DISPOSITION stuck-packet packet=<name> terminal=escalated-filed issue=absent-pipeline-filer` decision line is appended to the bounded `actions.log`,
- the LOUD line still fires, so the absent()/filing pipeline files a FRESH `[stuck-packet]` issue for a NEW burst (fresh filing per burst),
- fresh re-fires (< STUCK_AGE_S) stay live and undispositioned; a failed `mv` logs `WARN` and leaves the packet live for the next run's loud line.

The 244-packet burst of Nishfleet/fleet-ops#5647 itself was already disposed (verified: 244/244 `terminal=escalated-filed issue=5647` DISPOSITION lines, exact-set match against `archived/stuck/`, see Verification); this PR closes the prevention mechanism so the drain does it itself in the same run going forward.

Research / prior art: `bin/fleet-escalation-drain` header doc (3 drain ops + LOUD at 6h, #2677/#2773/#2677 follow-ups #3996/#4418), plus the same DISPOSITION shape already used by the escalation pipeline in `agent-state/alert-repair/actions.log` (244 lines, 2026-09-11T23:10:5xZ, issue=5647). The mechanism was hand-run once and lived outside the repo; this lands it in the drain that owns the loop. help-first: checked `bin/fleet-escalation-drain --dry-run` + `--numstat` gate help before writing anything new.

## Verification

- `bash tests/fleet-escalation-drain.test.sh` — exit 0, all 17 OK lines: `fleet-escalation-drain: all scenarios passed (fleet-ops#2677 + #2773 + #3996 + #4418)`
  - scenario 3 asserted the new behavior: stale no-terminal packets archived under `archived/stuck/`, DISPOSITION line present in actions.log, summary `packet_archived=3`, and full idempotency (`packet_deleted=0`, `packet_archived=0` on re-run)
  - scenario 5 asserted the LOUD-then-archive ordering for the STUCK_AGE_S threshold and override path
- `sgscan bin/fleet-escalation-drain tests/fleet-escalation-drain.test.sh` — `No new security findings.` (exit 0)
- Burst-state verification of the issue itself (litmus for the accept bullets):
  - `ls archived/stuck | wc -l` = 244; `grep -c "DISPOSITION stuck-packet" actions.log` = 244; set-diff of names vs DISPOSITION lines: empty (`diff` exit 0)
  - every DISPOSITION line carries `terminal=escalated-filed issue=5647`
  - alert-repair continues via the normal dispatch path: `[FIXED] alertname=SustainedLoadHigh ... root-cause=transient worker-burst ... RESOLVED in 127.0.0.1:9090/api/v1/alerts` (2026-09-11T23:31:46Z)

run-proof: issue-5647-drain-sandbox on the live-copy fixture ran end-to-end 2x — first run alleged `packet_archived=8` with 8 DISPOSITION lines appended and the live `packet-*` count dropping 18 → 10; second run `packet_archived=0` (idempotent), archived/stuck count 252 (244 burst + 8 sandbox); both runs logged rc=0 summary lines

review: skipped, no capable seat

loose-ends: chain-terminal ledger — `chains.terminated.jsonl` has not been appended since the completion-canary mirror retired (mtime 2026-09-07); new dispatches therefore produce no terminal records and new stuck packets will keep firing. That producer repair is owned by the repair work (Nishfleet/fleet-ops#5622), NOT this PR: this issue is the escalation surface, not the repair worker.

net-positive-because: prevention mechanism fleet-ops#366 / acceptance bullet 3 of Nishfleet/fleet-ops#5647 — the drain must archive and decision-log the burst in the same run that detects it; the state was already exercised by hand (see Verification), and this PR puts the exact same behavior into the script that owns the loop, with two new guard assertions in the drain test suite. Uses only existing bin/ machinery (`fleet-escalation-drain`).

Closes Nishfleet/fleet-ops#5647
Relates to Nishfleet/fleet-ops#5622
Relates to Nishfleet/fleet-ops#366

Test plan: `bash tests/fleet-escalation-drain.test.sh` on the PR branch — all 17 scenarios OK including the new fleet-ops#5647 assertions (scenario 3 archive + DISPOSITION, scenario 5 threshold/override archive, idempotent re-runs both).
