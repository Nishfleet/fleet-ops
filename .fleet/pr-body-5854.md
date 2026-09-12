## Summary

Closes the silent-death gap from #5456: the escalation organs are deliberately excluded from the chain they run (anti-recursion), so a dead `stop-escalation.path`, a crash-loop-parked `stop-escalation-dispatch`, a dodged `escalation-daily-sweep`, or a broken `unit-escalation@` template produced NO STOP-REASON — detection waited for the hourly tier1 failed-units sweep (~60 min), not the 5-minute contract.

Fix: a dedicated, deliberately *non-organ* watcher — `escalation-organ-watch` — on its own 5-minute timer. It checks one thing per silent-death class: `stop-escalation.path` active, `unit-escalation@.service` template loads, `stop-escalation-dispatch` not parked, and a freshness-stamped `escalation-daily-sweep` liveness marker. On any red it exits 1 (systemd failed state — the tier1 sweep's existing observable); its red never routes through the chain it watches.

- `systemd/escalation-organ-watch.service.d/no-self-escalate.conf` resets `OnFailure=` (the acceptance's no-recursion rule); `bin/unit-escalation-write` now also refuses `escalation-organ-watch*` by name (defense in depth), and `bin/fleet-escalation-canary`'s exclusion list matches — the test locks write+canary in lockstep.
- The out-of-band page is the healthchecks.io dead-man: the service pings `HC_URL_ORGANWATCH` via `bin/keystone-hc-ping` on SUCCESS only (ExecStopPost, same pattern as the keystone intake dead-man), so a missed 5-min cadence pages. Provisioning is the same one-time machine step as the other `HC_URL_*` checks (create check, add to `~/.config/fleet-ops/keystone-hc.env`).
- `bin/escalation-daily-sweep` stamps `ESCALATION-DAILY-SWEEP-LIVENESS` each run (issue option 3) — a dead sweep leaves a stale marker (25h grace = 24h dead-man floor + Persistent catch-up).
- `bin/fleet-resilience-drill`'s keystone-HC plane adds `HC_URL_ORGANWATCH` to the distinctness sweep so a shared URL cannot mask it.
- `lib/role-quality-gates.py`: `escalation-organ-watch` joins the deterministic-plumbing exclusion list (5-min timer, no model, no prompt, no work items — same class as `escalation-drail`-… `escalation-drain`).
- Tests: `tests/fleet-ops-5854-organ-watch.test.sh` (222 lines: wiring, 5-min cadence, name-guard lockstep, marker, GREEN baseline + one RED-transition per silent-death class, success-only dead-man, systemd-analyze verify).
- Test-ride fixes in `tests/fleet-resilience-drill.test.sh`: (a) the remapped-`HOME` salvage plane never had `worker-token`, so the `env -u GH_TOKEN` mint ENOENTed on the VPS (CI masked it via `GITHUB_ACTIONS=true`) — a stub is now shipped; (b) the shared-URL and heartbeat-reuse fixtures gained `HC_URL_ORGANWATCH` so they exercise KEYSTONE-HC-SHARED instead of skipping.

Closes #5854

net-positive-because: the watcher is one 112-line script + 3 small unit files + ~40 lines of wiring; it adds no new escalation mechanism — it reuses the failed-state observable, the tier1 sweep, and the dead-man pattern that already exist.

## Verification

- `bash tests/fleet-ops-5854-organ-watch.test.sh` → `ALL PASS: fleet-ops#5854 escalation-organ-watch tests` (exit 0), including RED transitions for path/template/parked-dispatch/stale+missing-marker and success-only dead-man wiring.
- `bash tests/fleet-resilience-drill.test.sh` → exit 0, `OK: fleet-ops#455 resilience drill acceptance pass` (first runs exited 1: SALVAGE-ORPHAN-FAIL `worker-token: No such file or directory`, then two KEYSTONE-HC-UNCONFIGURED skips — each root-caused and fixed above, re-run green).
- `bash tests/escalation-coverage-canary.test.sh` → exit 0 (first run exited 1 on the same heartbeat-reuse fixture; re-run green).
- `bash tests/unit-escalation-write-retry-absorb.test.sh`, `tests/unit-escalation-write-scout-futility-dedupe.test.sh`, `tests/escalation-units-shape.test.sh` → all exit 0.
- `./bin/escalation-organ-watch --help` → prints usage, exit 0. Live host run → RED `escalation-daily-sweep liveness marker missing` (correct: the sweep's marker line is not deployed yet) — the RED path is proven live, the GREEN path in the drill.
- `sgscan` → No new security findings. `systemd-analyze verify` inside the test → clean.
- Pickup re-verification (this session, branch rebased onto current main, same commands re-run on the exact merge tree): `bash tests/fleet-ops-5854-organ-watch.test.sh` → ALL PASS (exit 0); `bash tests/fleet-resilience-drill.test.sh` → exit 0; `bash tests/role-quality-gates.test.sh` → exit 0; `tests/unit-escalation-write-retry-absorb`, `tests/unit-escalation-write-scout-futility-dedupe`, `tests/escalation-units-shape` → all exit 0; `bash tests/escalation-coverage-canary.test.sh` (full umbrella) → exit 0, ends `fleet-ops#1135 bare-metal rebuild test pass`.

## run-proof

units: pi-issue@fleet-ops-5854.service (this run — cgroup-verified `app-pi\x2dissue.slice/pi-issue@fleet-ops-5854.service`; resumed its own prior session's committed work on `claim/issue-5854`); timers: `escalation-organ-watch.timer` `OnCalendar=*:0/5` proven by test (cadence) + `systemd-analyze verify` (syntax); drills: the watcher's RED/GREEN mechanics proven by `tests/fleet-ops-5854-organ-watch.test.sh` on this host (one RED-transition per silent-death class, incl. a live-host RED run of the marker check); the timer+dead-man go live via the MANIFEST deploy on merge.

## Test plan

- `bash tests/fleet-ops-5854-organ-watch.test.sh`
- `bash tests/fleet-resilience-drill.test.sh`

research: `bin/escalation-organ-watch` — the issue offers three designs, COMPARED: (a) per-organ healthchecks pings on every organ, (b) tightening the hourly drill to a 5-min lighter probe, (c) the daily-sweep liveness marker. ADOPTED: (c) for the sweep's own death plus a passive 4-class watcher (path active / template loads / dispatcher not parked / marker fresh) — because (a) needs new plumbing inside each anti-recursion-excluded organ (self-trigger risk, the very recursion the exclusion avoids) and (b) still reports through the hourly-drill path it is meant to shorten. NOT a new dispatch mechanism: it reuses the existing failed-state → tier1 observable and the existing keystone dead-man pattern; no neworgan, no STOP-REASON writes. Official docs (healthchecks.io/docs, fetched live 2026-09-12): a check goes down when the success signal is absent past the configured Grace Time (e.g. Period 5 min, Grace 5 min for a 5-min cadence) — grounding the success-only ExecStopPost ping and the 5-min deviation page for a missed tick.

help-first: `./bin/escalation-organ-watch --help` prints its header rationale + the 4 checks + the red-OUT contract, exit 0 (fleet-ops#534). The existing tools do not already do this: `unit-escalation-write` only REFUSES the excluded units (writes nothing about their liveness), `fleet-escalation-canary` only gates their identity class, and `fleet-resilience-drill`'s chain drill runs hourly — none watches the organs' own liveness, which is the gap; the new watcher's --help is a header-excerpt, not a rebuilt flag duplicated from an existing binary.

organ-heartbeat: systemd/escalation-organ-watch.service not-an-organ: deterministic plumbing (no model, no prompt, no work items) — classified alongside escalation-drain in lib/role-quality-gates.py; its liveness IS the heartbeat (5-min dead-man).

loose-ends: organwatch-provision — after merge+deploy: create the HC_URL_ORGANWATCH check (5-min grace) in `~/.config/fleet-ops/keystone-hc.env`, confirm `escalation-organ-watch.timer` is active and the watcher goes GREEN, then one live kill drill (stop `stop-escalation.path`, expect failed watcher + missed-ping page inside 5 min, restore). Fleet-wipe-lessons: worktree `issue-fleet-ops-5854` removed at close.
