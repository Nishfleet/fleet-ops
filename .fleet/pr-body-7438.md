## Why

The intake packet asks for a class-level retention score for local log artefacts, an advisory report of what could be dropped and the gigabyte delta, and a rollback switch. The shared decision helper and its tests landed from the dependency PR. The existing census organ is the natural extension point. No new service, timer, or schedule. No deletion.

## Scope

`lib/pi-packet/asset-census.py` gains the `retention-report` subcommand. `retention_classes()` stats five bounded classes: `~/.local/state/pi-issues/*.{in,out,err}` and `~/.local/state/pi-packet/watch.log*`. It records file counts, logical and allocated bytes, modification and access age ranges, a `last_read` field that stays `None` with its stated reason, and per-class consumer references. Contents are never read; symlinks are never followed. `retention_verdict()` validates the helper's score (0–4, finite) and action (`keep`/`review-drop`). `cmd_retention()` sends each class's metadata and limitations to the shared `jev-eval` helper with the class budget cap, parses the answers, and writes a 600-mode report. Helper failure exits 2 and leaves any existing report untouched. `FLEET_RETENTION_ENABLED=0` skips both scanning and evaluation, the rollback switch. The output record also includes the model's per-call usage and response.

`tests/asset-retention.test.py` adds six offline tests, wired into `tests/fleet-asset-census.test.sh`. `docs/reports/retention-7438.md` holds the live-run report.

Out of scope: deletion of any file, retention config changes, R2 and filesystem-watcher classes, any automatic schedule. Deletion remains a separate decision that needs Nish's or the weekly review's one-time confirmation of a future list.

## Verification

Verification: observed 2026-09-17T17:56:16Z, `/tmp/retention-7438-live.json`.

Live run on the VPS: exit 0, all five classes scored, `proposed_drop_gb` 0.0, `deleted_bytes` 0.

| Class | Files | Decimal GB | Value, 0–4 | Keep probability | Proposed drop GB |
| --- | ---: | ---: | ---: | ---: | ---: |
| issue-inputs | 2269 | 0.046865562 | 3.22 | 0.93 | 0 |
| issue-outputs | 2253 | 0.004909897 | 3.01 | 0.90 | 0 |
| issue-errors | 2253 | 0.002907730 | 2.93 | 0.90 | 0 |
| watch-active | 1 | 0.005299565 | 3.69 | 0.98 | 0 |
| watch-rotated | 5 | 0.012575721 | 3.19 | 0.92 | 0 |

Full report: `docs/reports/retention-7438.md`. Real records include `/home/nish/.local/state/pi-issues/0509-1051.in` and `/home/nish/.local/state/pi-packet/watch.log.1`. The helper appended five real, non-synthetic rows to `/home/nish/.local/state/pi-packet/jev/artefact-retention.jsonl`, each with the class path/pattern, observation timestamp, state hash, answers, probabilities, usage and duration. Five SDK calls, 4,248 input tokens, about $0.000178416 at the helper's rate, each under the shared $1 budget.

Re-verified 2026-09-17T22:12:54Z: exit 0, five classes scored, `proposed_drop_gb` 0, `deleted_bytes` 0, keep probabilities 0.90–0.98, five non-synthetic helper rows in `~/.local/state/pi-packet/jev/artefact-retention.jsonl`.

run-proof: `python3 tests/asset-retention.test.py` (6 tests, pass, red before implementation); `bash tests/fleet-asset-census.test.sh` (pass, includes the new tests and existing organ/scalability checks); `bash tests/jev-eval.test.sh` (pass); `sgscan --base origin/main` (no new findings); `python3 -m py_compile lib/pi-packet/asset-census.py` (pass); real `retention-report` run on the VPS (exit 0, five scored classes, JSONL rows written); `FLEET_RETENTION_ENABLED=0 bin/fleet-asset-census retention-report` (rollback prints the disabled record with no helper call, proven in test).

Unknowns are preserved, not converted into a savings claim: last-read history and per-file consumer references stay `unknown` in the report and the shared state, since atime is not reliable under relatime/noatime and scanners also touch files. R2 and inotify pressure are unmeasured and named as such.

## Organ heartbeat

organ-heartbeat: lib/pi-packet/asset-census.py not-an-organ: advisory subcommand inside the existing organ; registry entry, files, absent() rule, and all existing commands unchanged.

## Tradeoffs

Scores cover whole classes, so recent activity can favor keeping a class that also contains cold files. Per-file cleanup decisions are outside this report.

## Blast radius

Only the new subcommand reads new paths. `census`, `diff`, `validate-map`, metrics, auto-filed issues, logrotate, and the timer are untouched; the full existing suite passes. The helper is invoked with an explicit cap and a 60-second timeout; a missing helper or a failed call exits 2 without writing a report. No scheduled caller invokes the command, so nothing new runs without a human.

## Review

Local review is blocked: `crgate --agent` failed with exit 3, "CodeRabbit is not signed in on this machine. Run: coderabbit auth login".

## Arm decision

The PR opens as a draft and is not armed for auto-merge: the local CodeRabbit gate cannot run until sign-in. Jev agreed (hold_for_review p=0.95, site issue-worker, ref Nishfleet/fleet-ops#7438, state_sha256 5231e1c42c577b746b116ce610fd0d158006a49238d9354346a3b7ba02fb7bc9). Arming waits until the review gate completes.

## Loose ends

net-positive-because: the packet requires a scored advisory report with per-class evidence, a rollback switch and regression tests; it contains no deletable prior machinery, and the only alternative was a new organ the issue forbids.

loose-ends: coderabbit-signin

Closes #7438
