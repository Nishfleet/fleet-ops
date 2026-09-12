## What
`libexec/alert-repair-dispatch` relaunches every `DetachedJobDied` repair without ever consulting the packet's declared deliverable — four seat-minutes were burned in one hour on packets whose PR had already merged (gate-c-billing-failed / ds41-amend-183353, live ledger 2026-09-10T20:52Z).

## Fix
Bounded, fail-open pre-flight before any `DetachedJobDied` relaunch:
- Resolve the unit's declared deliverable from the dead-man journal `died: unit=... deliverable=...` line (new `JOURNALCTL_BIN` seam); fallback via the dispatch-ledger → packet.
- Satisfied iff the deliverable file exists non-empty, OR a named PR (`branch <x>`, `Nishfleet/<repo>#N`, `PR #N`) is `MERGED` or armed (`autoMergeRequest != null`) + `MERGEABLE`.
- On satisfied: append `RESOLVED-DELIVERED unit=<u> deliverable=<p|PR>` to `actions.log`, run `pi-detached-deadman --clear <unit>`, exit 0 with zero spawns.
- Bounded: at most one `gh` call per dispatch run (budget shared, first candidate spends it), 5s `gh` timeout, 10s journal timeout, every error fails open to today's relaunch behaviour. New `PI_SYSTEMD_RUN_BIN` seam per the existing `GH`/`PI_DEADMAN_BIN` convention.
- No changes to `RuntimeMaxSec`/`--deadline 60`, dead-man detection, or alert thresholds.

## Verification
- `bash tests/detached-deliverable-preflight.test.sh` — all 3 cases green: (a) deliverable file present → 0 spawns + RESOLVED-DELIVERED + dead-man cleared; (b) deliverable absent, PR open/unarmed → exactly 1 spawn; (c) `gh` timeout → fail-open, 1 spawn. Case (a) was proven FAILING against the unmodified dispatcher first (`.fleet/phase1-failproof.txt`).
- `bash tests/alert-repair-seat-walled.test.sh` — green.
- `bash tests/alert-repair-detached-recursion-skip.test.sh` — green (harness kept hermetic under the new seams).
- `bash tests/pi-detached-deadman.test.sh` — 12-case verdict matrix green.
- `bash tests/ci-standards-audit.test.sh` — green (new test hosted here; workers cannot push `.github/workflows/**`).
- `python3 -m py_compile libexec/alert-repair-dispatch` — green. Note: the issue verify block's `bash -n libexec/alert-repair-dispatch` cannot pass — the file is Python; `bash -n` on it fails with `syntax error near unexpected token '('` (exit 2). `py_compile` is the equivalent syntax gate and passes.

run-proof: unit pi-issue-fleet-ops-5142 — tests listed above executed on claim/issue-5142 in the issue worktree; reviewer round on the diff origin/main...HEAD (stock reviewer seat), one Act-on finding (CI registration) fixed and re-verified.

research: n/a — no new bin/ files; uses existing `pi-detached-deadman --clear`, existing seams pattern.
help-first: n/a.
organ-heartbeat: libexec/alert-repair-dispatch not-an-organ: repair dispatcher, no heartbeat contract.
loose-ends: detached-deliverable-preflight-journal-leg — journal leg relies on the `died:` line format; if journald retention lapses, fallback is dispatch-ledger packet_path, fail-open if both miss.
Relates to #5142
