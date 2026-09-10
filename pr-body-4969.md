fix(signal-reconcile): stop queuing EXEC-REVIEW-DISARM alarm filings (fleet-ops#4969)

## What
`EXEC-REVIEW-DISARM` is the exec-review canary's disarm ACTION (fleet-ops#3731 hard gate): `bin/fleet-exec-review-canary` emits it when it disables auto-merge on an armed PR that carries no verify/receipt cue. The message is `auto-merge DISABLED on <repo>#NNN (no verify cue ...)`, so `derive_signals()` harvests only the repo token and forms the per-repo key `loud/exec-review-disarm/<repo>`. ANY later disarm in that repo re-emits the same key, so a filed alarm issue is never-green no matter which PR or how long the gap between disarms.

The actionable per-PR work is already tracked: a worker finding is filed by the canary itself under `signal: exec-review-receipt/<slug>`, and a human finding is disarmed-only (fleet-ops#4117: the disarm + LOUD line is the signal, not an issue). The disarm already stopped the unverified merge; the LOUD line is the measurement.

This is the same informational, never-green class as `PACKETS-ARCHIVED` (#4955), `FAILED-COMMAND-FAIL` (#4944) and `CLAIM-RELEASED` (#4940), all already in `SKIP_TAGS`. Add `EXEC-REVIEW-DISARM` to `SKIP_TAGS` so the reconciler stops filing a per-repo alarm it can never observe-to-close.

## Verification
`bash tests/signal-reconcile.test.sh` → `OK: all signal-reconcile scenarios passed` (includes new scenario 9l not-queued, 9l-key repo-scoped key, 9l-close observe-to-close terminus).

`bash tests/fleet-exec-review-canary.test.sh` → `OK: fleet-exec-review-canary: ... disarm hard gate, any-author hard gate` (canary's own disarm + hard-gate behavior unchanged; the skip is reconciler-side only).

run-proof: `tests/signal-reconcile.test.sh` scenario `9l`, `9l-key`, `9l-close`.

Test plan:
- [x] `EXEC-REVIEW-DISARM` LOUD line no longer queues an alarm (scenario 9l)
- [x] derived signal key is repo-scoped and constant across PRs in the same repo (9l-key)
- [x] an already-open `loud/exec-review-disarm/<repo>` issue observe-to-closes while disarm lines fire (9l-close)
- [x] canary disarm hard gate + any-author hard gate unchanged (fleet-exec-review-canary.test.sh)

Relates to #4969 (this issue is closed by the detector→queue reconciler observe-to-close once EXEC-REVIEW-DISARM stops queuing — not by PR merge)

Reviewer note: the ci-standards-audit scenario 4217 (console quota display for minimax/MiniMax-M3) fails on a clean origin/main checkout too — it depends on live minimax seat health on this host, untouched by this PR.