## Summary

#2734 is a stale duplicate of #2667 (closed by PR #2741 at 2026-09-02T00:31:15Z). The #2734 snapshot was filed 2026-09-01T23:30:22Z — 16 minutes before #2667 closed — so it predates the retirement that resolved both seats it names.

Both seats were already retired by #2667 / #2695 and are at `cap=0, intentional_cap_zero=corpse` in `config/seat-caps.json`:

- `commandcode/minimax/minimax-m3-free` — provider permanently retired the free MiniMax M3 line (HTTP 403 FORBIDDEN "The free MiniMax M3 and M2.7 models have been retired"). Not a credential fault: control probe `commandcode/poolside/laguna-s-2.1-free` returns PONG on the same provider.
- `opencode/hy3-free` — provider dropped the slug (HTTP 401 ModelError "Model hy3-free is not supported"). Not a credential fault: control probe `opencode/nemotron-3-ultra-free` returns PONG on the same provider.

This PR adds a dated `#2734` stale-duplicate re-verification citation to each seat's existing `_comment` row in `config/seat-caps.json`, recording the live re-probe outcome and confirming the metric is clear. No cap values change — comment-only.

## Verification

Live re-probes (2026-09-02T17:13Z):

- `pi --print --provider commandcode --model minimax/minimax-m3-free 'reply PONG'` → HTTP 403 FORBIDDEN "The free MiniMax M3 and M2.7 models have been retired" (PACKET-VERDICT tools=0 class=no-tools)
- `pi --print --provider opencode --model hy3-free 'reply PONG'` → HTTP 401 {"type":"ModelError","message":"Model hy3-free is not supported"} (PACKET-VERDICT tools=0 class=no-tools)
- Control `pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'` → PONG (commandcode credential LIVE)
- Control `pi --print --provider opencode --model nemotron-3-ultra-free 'reply PONG'` → PONG (opencode credential LIVE)

Corpse-ledger retirement confirmed (ledgers out of the live seats dir, so the alert metric is clear):

- minimax/minimax-m3-free ledger retired to `lanes/seats-corpse-retired-2026-09-02T12:12:15Z/` (by #2716 corpse-ledger retirement)
- hy3-free ledger quarantined to `lanes/seats-deadcred-quarantine-20260902T0124Z/` (by #2667 retirement path)
- `python3 libexec/fleet-metrics-export.py` → `fleet_pi_seat_dead_credential_total 0` (re-verified after removing the live ledger files my manual probes momentarily re-created)

Tests:

- `bash tests/fleet-free-roster-canary.test.sh` → ALL PASS (scenario19b pins the minimax/minimax-m3-free cap=0 corpse row)
- `python3 -c "import json; json.load(open('config/seat-caps.json'))"` → JSON OK
- `tests/alert-repair-claim-mutex.test.sh` FAIL is pre-existing on origin/main (open issues #2854 / #2856, FleetMainRed class-parked until 2026-09-03); unrelated to this comment-only diff.

run-proof: transcript `pi --print` probes above + `fleet_pi_seat_dead_credential_total 0` after `python3 libexec/fleet-metrics-export.py`.

loose-ends-canary: pr:nishfleet/fleet-ops#2734 stale-worker-pr (this PR closes the duplicate; no worktree left behind).

Closes #2734
