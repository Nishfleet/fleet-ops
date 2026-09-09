fix(stop-the-line): JS lookback floor of 30 so the 15m watch config cannot starve amnesia-close

Closes #4588
Relates to #4598 (YAML raise 15→30, workflows-scoped follow-up)
Relates to #4567 (orphaned freeze — already self-healed CLOSED, see Verification)

## Summary

The stop-the-line watch passes `lookback-minutes: 15`, but fleet-ops CI runs take 16-22m and the workflow_run tick fires on CI completion — so the just-completed run's `created_at` is always outside a 15m window. `fetchRecentMainRuns` samples 0 runs, classifyHalt sees nothing, and the fleet-ops#1489 amnesia-close (which needs a green run in the sampled set) never fires. An orphaned freeze issue then keeps auto-merge arming skipped for every fleet-ops PR (#4567 skipped arming on #4577).

The orchestrator DECISION on #4588 (2026-09-09) set the ship gate: a **JS floor** in the detector, because the nishfleet-worker App token cannot push `.github/workflows/**` (the prior unit's push was rejected: "refusing to allow a GitHub App to create or update workflow ... without 'workflows' permission"). A worker-side config bump is not landable; a script-side floor is.

- `.github/scripts/stop-the-line-detector.mjs`: `MIN_LOOKBACK_MINUTES = 30` + exported pure `clampLookbackMinutes(n)`, applied at BOTH resolution points in parseArgs — env `STOP_THE_LINE_LOOKBACK_MINUTES` and CLI `--lookback-minutes`. Values >= 30 (including the default 90) pass through untouched; one stderr notice names a clamped resolution. Classify/gate lines untouched — the stop-the-line gate is NOT weakened; the clamp only widens the sample window.
- `.github/workflows/stop-the-line-watch.yml` stays at 15 (net-unchanged vs origin/main — `git diff origin/main...HEAD -- .github/workflows/` is empty). The effective lookback is now 30 regardless; the YAML raise to match the floor is follow-up #4598 (needs a workflows-scoped push + Nish `gate-integrity-attest`).
- `tests/stop-the-line-detector.test.sh`: the YAML-grep floor guard is replaced by a behavioural JS-floor guard with stronger teeth — two live detector invocations (env=15 and CLI=15, fixture replay + `--output-json`, no network) assert the emitted report's `lookback_minutes` is 30 and the clamp notice fired, plus pure `clampLookbackMinutes` assertions and a 15m counterfactual. The starvation regression proves an 18m-old green run is UNSAMPLED at 15m (0 runs → noop) and CLOSES the orphaned freeze at the clamped 30m. Removing or neutralizing the clamp makes the suite fail.

## Verification

Real runs on this branch (claim/issue-4588):

```
$ bash tests/stop-the-line-detector.test.sh
all stop-the-line cases passed          # exit 0

$ bash tests/stop-the-line-detector.test.sh   # clamp neutralized (MIN=15, not committed)
FAIL: ... lookback floor ...            # exit 1 — teeth proven
standalone regression probe without clamp: effective=15m sampled=0 action=noop  # exit 1 (starvation reproduced)
standalone regression probe with clamp:    effective=30m sampled=1 action=close unfreeze_run=9001  # exit 0

$ bash tests/ci-standards-audit.test.sh
FAIL: 4217: console quota display failed    # exit 1 — PRE-EXISTING: fails identically standalone on origin/main (live minimax/MiniMax-M3 seat spawn_bench count 0); reads none of the changed files

$ git diff origin/main...HEAD -- .github/workflows/ | wc -l
0

$ gh issue view 4567 -R Nishfleet/fleet-ops --json state --jq '.state'
CLOSED    # the orphaned freeze self-healed on the next green run; no manual close

$ sgscan --base origin/main
No new security findings.   # exit 0
```

run-proof: tests/stop-the-line-detector.test.sh is CI-wired (.github/workflows/ci.yml → tests/ci-standards-audit.test.sh) — the JS-floor guard hard-fails PR CI on any clamp removal or re-tighten; teeth runs above: exit 1 without the clamp, exit 0 with it.

net-positive-because: the regression + JS-floor guard are additive tests (~+104 lines) that must exist to prove the clamp has teeth (the acceptance requires a test that fails on the old 15m config and passes on the new one); the .mjs change is +30/-3.

## Review

Manager-phase reviews (stock reviewer subagent on the phase diffs): phase 1-2 (original YAML-targeted fix): 0 Act-on, 0 blocking. Phase 1b-2 (amended JS fix, `git diff 50e445b9..HEAD`): **0 Act-on, 0 blocking** — reviewer ran the detector test live (exit 0) and a MIN=15 teeth probe (suite exit 1). CONSIDER (recorded in .fleet/plan.md, not re-delegated): `--lookback-minutes 0` falls to the default 90 rather than the floor 30 (pre-existing default-fallback semantics; tidy-up candidate for #4598); the regression re-implements the fetchRecentMainRuns ms-filter inline (semantic-equivalent today); the static 30m floor does not track CI-duration drift (documented). NOTED: the `--from-json` replay path reports the clamped lookback (harmless — the clamp only widens the window). Full adjudication in .fleet/plan.md (in-tree).

research: prior art read before building — .github/scripts/stop-the-line-detector.mjs (parseArgs resolution points, fetchRecentMainRuns filter, fleet-ops#1489 amnesia-close in buildDecision), .github/workflows/stop-the-line-detector.yml (env plumbing: `STOP_THE_LINE_LOOKBACK_MINUTES: ${{ inputs.lookback-minutes || 90 }}`), stop-the-line-watch.yml (the 15m input), tests/stop-the-line-detector.test.sh (existing #1489 + #2911 cases), plus the prior unit's reviewed commits 735de644/291cc5c6 (superseded, not discarded). The JS floor was chosen by orchestrator decision after the workflows-permission boundary was hit; no existing clamp/constant existed to extend, and no shared window-filter helper exists to reuse (recorded as CONSIDER, not built).

help-first: the detector's `--help` now documents the 30-minute floor and why (CI runtime 16-22m observed + margin) before the flag list.

organ-heartbeat: .github/scripts/stop-the-line-detector.mjs not-an-organ: it is a standalone detector script with no heartbeat dependency; no registered organ is touched by this diff.

loose-ends: yaml-raise-15-to-30-followup-4598 (single remaining phase of the original acceptance, filed as #4598 with the gate-integrity-attest requirement)

Test plan: bash tests/stop-the-line-detector.test.sh (green); removing the clamp makes it fail (proven); ci-standards-audit pre-existing failure on main is unrelated (console-tile-verify).
