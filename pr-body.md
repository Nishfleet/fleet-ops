**Root cause** — the `DetachedJobDied` alert description (config/fleet_rules.yml) told alert-repair workers to run `bin/fleet-who-stopped <unit>` and `bin/pi-detached-deadman --clear <unit>`: bare cwd-relative `bin/...` paths with **no stated base directory**. In the live 2026-09-10 alert-repair session the worker guessed `/home/nish/workspaces/tooling/fleet-ops` (a checkout that does not ship those scripts) and `sed bin/pi-detached-deadman` failed with ENOENT — a failed command the session swallowed (FAILED-COMMAND-SWALLOWED, signal `bin-pi-detached-deadman`, fleet-ops#4921).

**Fix** — the two commands are installed on PATH (symlinked from the canonical checkout `/home/nish/workspaces/tooling/fleet-ops-deploy-clone/`), so the description now names them directly and states that canonical source path. There is no cwd guess left for a repair worker to make; running the command works from any directory.

**Gate** — new `tests/fleet-alert-detached-deadman-command-path.test.sh`, nested into `tests/rule-enforcement.test.sh` so CI runs it without a workflow edit. It fails closed if:
- the DetachedJobDied description uses a bare cwd-relative `bin/...` path (the swallow source), or
- the on-PATH command names (`fleet-who-stopped`, `pi-detached-deadman`) are not advised, or
- the canonical source checkout path is dropped, or
- the named scripts are not shipped executables under `bin/`.

## Verification

Ran on this worker (real runs):

```
$ bash tests/fleet-alert-detached-deadman-command-path.test.sh
OK: repair commands ship as executable files under bin/: fleet-who-stopped pi-detached-deadman
OK: description advises on-PATH command `fleet-who-stopped` (no bare bin/ prefix)
OK: description advises on-PATH command `pi-detached-deadman` (no bare bin/ prefix)
OK: description names the canonical source checkout /home/nish/workspaces/tooling/fleet-ops-deploy-clone
fleet-alert-detached-deadman-command-path: all invariants pass (fleet-ops#4921)

$ bash tests/install-prometheus-rules-reload.test.sh  # PASS (scenarios A/B/C)
$ bash tests/fleet-rules-severity-page.test.sh        # PASS (fleet-ops#1534)
$ bash tests/pi-detached-deadman.test.sh              # PASS (12-case verdict matrix)
$ bash tests/alert-repair-detached-recursion-skip.test.sh  # PASS (fleet-ops#4266)
$ bash tests/pi-systemd-run.test.sh                   # PASS
$ bash bin/sgscan --base origin/main                  # No new security findings (exit 0)
```

run-proof: added `tests/fleet-alert-detached-deadman-command-path.test.sh` (offline, nested CI host `tests/rule-enforcement.test.sh`); no new units/timers/workflows. `prove-one-run-check` = SKIP (no new unit/timer/workflow).

research: no new bin/ file → `research-before-build-check` N/A. Existing tools reused (`pi-detached-deadman`, `fleet-who-stopped` already ship in MANIFEST). hand-building nothing.

help-first: no new bin/ file → N/A.

organ-heartbeat: diff touches `config/fleet_rules.yml` (an alert rule) + tests only, **not-an-organ**: no service/timer textfile probe emits a heartbeat series from my change.

Relates to #4921 (failed-command class, fleet-ops#1138 — reconciler observe-to-closes this issue, not the PR).

loose-ends: `loose-ends: straitly-ds4-pro-models-json-drift` — pre-existing host-only `tests/rule-enforcement.test.sh` scenario12 FAIL (deepseek/deepseek-v4-pro allowlisted in `config/seat-caps.json` but missing from `/home/nish/.pi/agent/models.json` providers.straitly.models). It reads live host state my diff does not touch; on hosted CI the live file is absent and scenario12 uses a clean scratch models.json, so CI stays green. Out of scope for #4921; filed as a separate concern, not fixed here.