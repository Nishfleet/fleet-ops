# Plan — fleet-ops#5142: DetachedJobDied repair relaunches packets whose deliverable already merged

Dispatcher `libexec/alert-repair-dispatch` (Python, 1254 lines) spawns a repair
worker for every `DetachedJobDied` alert. Add a bounded, fail-open pre-flight in
the existing per-alert filter loop (L1013-1050) that drops alerts whose packet
already delivered.

Manager re-verified 2026-09-11T04:2xZ (this run, after rebase onto e47faec5b):
- The recursion-guard loop sits at L1013-1050; the spawn argv is bare
  `pi-systemd-run` at L1217-1232 (PATH-resolved — a `PI_SYSTEMD_RUN_BIN` env
  seam is required for a stubbed spawn in tests).
- `GH` env seam already exists (`GH_BIN` L176); `PI_DEADMAN_BIN` exists (L1014).
- The dispatch ledger (`${FLEET_DISPATCH_LEDGER:-$AGENT_STATE/dispatch-ledger.jsonl}`)
  carries `id` (= the alert's `dispatch` label uuid), `unit`, `packet_path` —
  it does NOT carry the deliverable path. The deliverable path lives only in
  the dead unit's journal: `pi-detached-deadman` logs
  `died: unit=X result=Y deliverable=/abs/path|unset — dead-man tripped`
  (confirmed live in `journalctl --user`). So: journal first via a new
  `JOURNALCTL_BIN` seam; ledger+packet only as the PR-evidence fallback.
- Real packets name their deliverable as a branch (`branch fable/gate-c-billing-failed`,
  `claim/issue-<N>`) or `Nishfleet/<repo>#N` / `PR #N`. PR-evidence order:
  branch ref -> `gh pr list -R <repo> --head <branch> --state all --json
  number,state,autoMergeRequest,mergeable`; else `Nishfleet/<repo>#N` or
  `PR #N` (+repo) -> `gh pr view <N> -R <repo> --json
  state,autoMergeRequest,mergeable`. Satisfied iff any named PR is MERGED, or
  OPEN with autoMergeRequest != null and mergeable == MERGEABLE. Exactly one
  `gh` call per dispatch run — the first candidate spends the budget; a spent
  budget or a non-proving result means fail-open.

## Phases (acceptance-driven)

- [x] phase 1: write `tests/detached-deliverable-preflight.test.sh` on the `tests/alert-repair-detached-recursion-skip.test.sh` harness — scratch dir, mock `pi-detached-deadman` + `alert-repair-claim`, per-alert `AMX_ALERT_<i>_LABEL_*` envs — with a stubbed spawn binary and a stub `gh` covering: (a) deliverable file present/non-empty → 0 spawns, `RESOLVED-DELIVERED` in actions.log, dead-man `--clear` called; (b) deliverable absent and PR open → exactly 1 spawn; (c) `gh` times out → 1 spawn (accept #5)
- [x] phase 1: prove case (a) FAILS against the unmodified dispatcher (commit/record the failing run before implementing) (accept #5)
- [x] phase 2: implement the pre-flight for `DetachedJobDied` alerts that survive the existing recursion-guard skip — resolve the declared deliverable path from dead-man state (journal `died: unit=X ... deliverable=/abs/path` via new `JOURNALCTL_BIN` seam; fallback: alert label `dispatch` → last `${AGENT_STATE:-/home/nish/workspaces/agent-state}/dispatch-ledger.jsonl` entry with `id == dispatch` → `packet_path` → packet `## accept` naming `Nishfleet/<repo>#N` | `<repo>#N` | `PR #N` | branch) and treat as satisfied iff (a) deliverable file exists and is non-empty, or (b) named PR is `MERGED` or `OPEN`+autoMergeRequest+`MERGEABLE` as of check time (accept #1)
- [x] phase 2: on satisfied, append `RESOLVED-DELIVERED unit=<unit> deliverable=<path|PR>` to `$PACKET_DIR/actions.log`, run `pi-detached-deadman --clear <unit>` (existing best-effort pattern), drop the alert so the run exits 0 without spawning (accept #2)
- [x] phase 2: on not-satisfied OR any ambiguity/unreadable state/missing file/journal error, fall through to the unchanged relaunch path — fail-open, never strand a dead packet (accept #3)
- [x] phase 2: bound the pre-flight — at most one `gh` call per dispatch run (first candidate spends the budget; later candidates fail-open), `subprocess` timeout=5, all exceptions swallowed; add `PI_SYSTEMD_RUN_BIN` and `JOURNALCTL_BIN` env seams per the file's `PI_DEADMAN_BIN`/`GH` convention (accept #4)
- [x] phase 2: no changes to `RuntimeMaxSec`/`--deadline 60`, `bin/pi-detached-deadman` detection logic, or `config/fleet_rules.yml` alert thresholds (accept #6)
- [ ] phase 3: verify — issue's verify block plus `bash tests/detached-deliverable-preflight.test.sh`, `bash tests/alert-repair-detached-recursion-skip.test.sh`, `bash tests/alert-repair-seat-walled.test.sh`, `bash tests/pi-detached-deadman.test.sh`, `python3 -m py_compile libexec/alert-repair-dispatch`, `bash -n` on the new test (accept #5 proof of green)
