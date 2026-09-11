# Plan — fleet-ops#5142: DetachedJobDied repair relaunches packets whose deliverable already merged

Dispatcher `libexec/alert-repair-dispatch` (Python, 1182 lines) spawns a repair
worker for every `DetachedJobDied` alert. Add a bounded, fail-open pre-flight in
the existing per-alert filter loop (~L933-978) that drops alerts whose packet
already delivered.

## Phases (acceptance-driven)

- [ ] phase 1: write `tests/detached-deliverable-preflight.test.sh` on the `tests/alert-repair-detached-recursion-skip.test.sh` harness — scratch dir, mock `pi-detached-deadman` + `alert-repair-claim`, per-alert `AMX_ALERT_<i>_LABEL_*` envs — with a stubbed spawn binary and a stub `gh` covering: (a) deliverable file present/non-empty → 0 spawns, `RESOLVED-DELIVERED` in actions.log, dead-man `--clear` called; (b) deliverable absent and PR open → exactly 1 spawn; (c) `gh` times out → 1 spawn (accept #5)
- [ ] phase 1: prove case (a) FAILS against the unmodified dispatcher (commit/record the failing run before implementing) (accept #5)
- [ ] phase 2: implement the pre-flight for `DetachedJobDied` alerts that survive the existing recursion-guard skip — resolve the declared deliverable path from dead-man state (journal `died: unit=X ... deliverable=/abs/path` via new `JOURNALCTL_BIN` seam; fallback: alert label `dispatch` → last `${AGENT_STATE:-/home/nish/workspaces/agent-state}/dispatch-ledger.jsonl` entry with `id == dispatch` → `packet_path` → packet `## accept` naming `Nishfleet/<repo>#N` | `<repo>#N` | `PR #N` | branch) and treat as satisfied iff (a) deliverable file exists and is non-empty, or (b) named PR is `MERGED` or `OPEN`+autoMergeRequest+`MERGEABLE` as of check time (accept #1)
- [ ] phase 2: on satisfied, append `RESOLVED-DELIVERED unit=<unit> deliverable=<path|PR>` to `$PACKET_DIR/actions.log`, run `pi-detached-deadman --clear <unit>` (existing best-effort pattern), drop the alert so the run exits 0 without spawning (accept #2)
- [ ] phase 2: on not-satisfied OR any ambiguity/unreadable state/missing file/journal error, fall through to the unchanged relaunch path — fail-open, never strand a dead packet (accept #3)
- [ ] phase 2: bound the pre-flight — at most one `gh` call per dispatch run (first candidate spends the budget; later candidates fail-open), `subprocess` timeout=5, all exceptions swallowed; add `PI_SYSTEMD_RUN_BIN` and `JOURNALCTL_BIN` env seams per the file's `PI_DEADMAN_BIN`/`GH` convention (accept #4)
- [ ] phase 2: no changes to `RuntimeMaxSec`/`--deadline 60`, `bin/pi-detached-deadman` detection logic, or `config/fleet_rules.yml` alert thresholds (accept #6)
- [ ] phase 3: verify — issue's verify block plus `bash tests/detached-deliverable-preflight.test.sh`, `bash tests/alert-repair-detached-recursion-skip.test.sh`, `bash tests/alert-repair-seat-walled.test.sh`, `bash tests/pi-detached-deadman.test.sh`, `python3 -m py_compile libexec/alert-repair-dispatch`, `bash -n` on the new test (accept #5 proof of green)
