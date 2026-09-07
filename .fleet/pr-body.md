## What

Adds the missing prevention mechanism for the continuous research sweep (P11-A, fleet-ops#3130): a `fleet-research-sweep-canary` that asserts the researcher role actually ran AND produced >= 1 mechanism proposal in the trailing 7 days, and auto-files a `fix(research-sweep):` issue when the sweep misses its weekly bar.

The rest of the issue was already shipped by prior work:
- Weekly Sunday timer that dispatches a researcher worker — `quality-research-weekly.timer` (Sun 03:00 IST, fleet-ops#541).
- Researcher worker producing specced mechanism proposals — `fleet-researcher-run` / `fleet-researcher-dispatch` (fleet-ops#458).
- Cheap/free lanes only + event-driven triggers — both in the researcher role.
- Weekly Fleet Review — `fleet-weekly-fleet-review.timer` (Sun 04:30 IST, fleet-ops#1146).

The one acceptance bullet that was missing is the **prevention mechanism**: a canary that asserts the researcher ran and produced >= 1 mechanism proposal in the last 7 days, auto-filing a "research sweep missed" issue on violation. That is this PR.

## How it works

`bin/fleet-research-sweep-canary` reads the researcher's own state sink (`agent-state/fleet-researcher/state.json`, written by `fleet-researcher-run`) and asserts two invariants:
1. **ran** — `last_run_at` is within the trailing 7 days.
2. **produced** — at least one delta with `status == "filed"` and `filed_at` within the trailing 7 days (a filed research-delta issue = a specced mechanism proposal).

On violation it observe-to-opens a `fix(research-sweep):` mechanism issue naming which invariant broke and the live state. When both invariants hold it observe-to-closes any open canary-filed ticket. Runs from heartbeat-tier1 block 46 — no new scheduler.

A run that files nothing (all deltas rejected/deduped) is a missed sweep: the ratchet starves even though the timer fired. The live state today is exactly that case — `last_run_at=2026-09-07T14:53:32Z` (ran) but `produced=0` in the last 7 days — so the canary correctly flags it.

## Verification

- `bash tests/fleet-research-sweep-canary.test.sh` — 10 scenarios ALL PASS (missing/unparseable/no-last-run state -> exit 1 + LOUD; healthy sweep -> exit 0 + observe-to-close; ran-but-produced-0 -> files ticket; did-not-run -> files ticket; dedup; file=0; tier1+MANIFEST+host-audit wiring; --help).
- `bash tests/ci-standards-audit.test.sh` — exit 0, 0 FAIL, 15 ALL PASS/ALL OK (hosts the new test).
- `bash tests/ci-checklist-gate.test.sh` — OK.
- `sgscan` — "No new security findings."
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` — OK, no agent attribution.
- `bin/fleet-token-efficiency-check --name-status` — OK.
- `bin/fleet-organ-heartbeat-check gate` — OK (touched organs: none; new candidates: none).

run-proof: canary tick against live state at 2026-09-07T15:17:26Z — `last_run_at=2026-09-07T14:53:32Z ran=1 produced=0 window=7d` -> correctly flags "researcher ran but produced 0 mechanism proposals in the last 7d". Healthy fixture (`ran=1 produced=1`) -> "research sweep healthy" exit 0. Missing-state fixture -> exit 1 + LOUD RESEARCH-SWEEP-WATCHER-BROKEN.

## research

research: live search + official docs — compared against the existing researcher role (fleet-ops#458), the weekly quality-research-weekly timer (fleet-ops#541), the Weekly Fleet Review (fleet-ops#1146), and the scout-leak canary (fleet-ops#3123) as the reaction-detector pattern; adopted the existing state sink + heartbeat canary wiring rather than building a new scheduler or organ.

help-first: read `fleet-researcher-run`/`fleet-researcher-dispatch` `--help` and the scout-leak canary `--help` before building; the existing tools do not assert the researcher produced a mechanism in the last 7 days, so a new detector was warranted.

organ-heartbeat: bin/fleet-research-sweep-canary not-an-organ: reaction detector over the researcher role's own state.json — exports no heartbeat metric, same class as fleet-scout-leak-canary (fleet-ops#3123).

Closes #3130
