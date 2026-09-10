## What & why

Issue #4921 is an alarm (`FAILED-COMMAND-SWALLOWED`, signal `loud/failed-command-swallowed/bin-pi-detached-deadman`) filed by the detector→queue reconciler when a live session swallowed a `sed: can't read bin/pi-detached-deadman` ENOENT and no open issue carried its signal key.

The root causes were already merged independently:
- **#4924** — the DetachedJobDied alert description no longer seeds a cwd-relative `bin/...` path (the actual source of the swallowed ENOENT), with a gate test.
- **#4934 (fleet-ops#4884)** — FAILED-COMMAND-SWALLOWED now keys on the session slug, not on a file token harvested from the snippet, with tests (9h/9h-close) proving the stale-file-token issue observe-to-closes.

This leaves the one durable gap scoped to #4921: no test names **this** signal. The issue itself is keyed on the legacy `bin-pi-detached-deadman` file token; under the re-keyed detector that signal is no longer produced, so #4921 must observe-to-close. Nothing locks that for this exact class.

## Change

Add scenarios **9i / 9i-close** to `tests/signal-reconcile.test.sh`:
- **9i** — a FAILED-COMMAND-SWALLOWED session whose snippet says `bin/pi-detached-deadman` keys on the session slug, and `grep -v` asserts the legacy `bin-pi-detached-deadman` token is never produced.
- **9i-close** — an open issue #4921 whose body carries `loud/failed-command-swallowed/bin-pi-detached-deadman` observe-to-closes on the same tick.

The test is already wired into the suite via `tests/ci-standards-audit.test.sh` (host line pinned by `p14-test-listing-gate.test.sh`).

## Verification

Real runs (below) of the touched test and the wiring gates:
```
bash tests/signal-reconcile.test.sh        # EXIT=0 — all scenarios pass
  OK: scenario 9i: bin/pi-detached-deadman swallowed failure keys on the session, not the legacy file token
  OK: scenario 9i-close: stale bin-pi-detached-deadman-keyed issue #4921 observe-to-closes after re-key
  [detector-queue-reconciler] closed #4921 (signal=loud/failed-command-swallowed/bin-pi-detached-deadman no longer in tick)
bash tests/p14-test-listing-gate.test.sh   # EXIT=0 — 45 OK, P14 list closed
```

`bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → `OK: no agent attribution detected`.

The failure in `tests/ci-standards-audit.test.sh` at scenario 4217 (minimax spawn-bench / console quota display) is **pre-existing** — it reproduces identically on clean `origin/main` in the deploy clone and is unrelated to this test-file-only change.

## run-proof

- Test unit: `validate-signal-reconcile` = `bash tests/signal-reconcile.test.sh` → **PASS** (exit 0).
- Gate unit: `validate-signal-p14-listing` = `bash tests/p14-test-listing-gate.test.sh` → **PASS**.
- No CI workflow or timer changed in this PR. No new `bin/` file added. No rebuild/masking/org diff.

## net-positive

net-positive-because: this PR is test-only: 41 net-added lines add two regression scenarios (9i/9i-close) that lock the observe-to-close path for #4921's exact legacy signal. There is no shrinkable code here to offset — new test coverage is the whole, intended payload and is wired into the suite auto-run by CI.

## Loose ends

- `loose-ends: none` — observe-to-close is a separate reconcile step that already runs on the live heartbeat tick; this PR is a gate/lock, not the closer. No half-done work left unshipped.

## References
Relates to #4921 — observe-to-close: this is a gate/lock PR, not the closer. GitHub must NOT auto-close #4921 on merge; the detector→queue reconciler closes it only when it reports green on a real heartbeat tick (per the issue body). On the next reconcile tick after this lands, the `loud/failed-command-swallowed/bin-pi-detached-deadman` signal is no longer produced (session-scoped keying itself drives the close), and #4921 observe-to-closes then.