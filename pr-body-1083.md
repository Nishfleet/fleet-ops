## Summary

`fix(failed-command):` and `fix(decisions-ledger):` issues use `Relates to #<N>` (not `Closes #<N>`) on their class-lock PR, so merging it does NOT close the issue. The release paths (tier1 §3, pi-issue-failed-reap, undersaturation label-hygiene) flip the issue back to `agent-ready` after the worker hits StartLimitBurst, so intake re-claims it every tick until the 24h observe-to-close window expires — wasted worker spawns on work that is already done (the live #958 loop: claimed/released repeatedly over ~3h after PR #1066 merged).

`bin/lifecycle-label-sweep` now runs a second pass per repo: for any class-lock title (`fix(failed-command):` / `fix(decisions-ledger):`) whose `claim/issue-<N>` branch has a **merged** PR, it drops the intake-visible lifecycle label (`agent-ready` / `agent-in-progress` / `agent-blocked`) and adds `observe-to-close`. Intake only lists `-l agent-ready`, so it stops spawning workers; the detector's own observe-to-close still closes the issue on session age-out.

- The merged-PR probe (`gh pr list --head claim/issue-<N> --state merged`) survives branch deletion because PRs keep their head ref — verified live: `claim/issue-958` is deleted on origin but returns the merged PR #1066, and `claim/issue-1255` returns the merged PR #1389.
- Fail-open: a gh blip leaves the label untouched and the next tick retries.
- Idempotent: an issue already under `observe-to-close` is left alone; non-class-lock titles are never probed.
- Also extends `classify()` to recognise `fix(decisions-ledger):` at filing time (same shape as the failed-command observe-to-close class, fleet-ops#1138) and updates `prompts/heartbeat.md` with both rules.

Proof against live data: a dry-run sweep against the real repo detected `Nishfleet/fleet-ops#1255` — OPEN with `agent-ready`, class-lock PR #1389 already merged, no open PR, exactly the loop this issue owns — and reclassified it to observe-to-close (`reclassified=1`).

## Verification

- `bash tests/lifecycle-label-sweep.test.sh` — 30 cases pass (6 new: decisions-ledger classify, merged-PR reclassify for agent-ready/agent-in-progress/decisions-ledger, no-merge leave-alone, non-class-lock no-probe, already-observe-to-close idempotency).
- `bash tests/fleet-decisions-ledger.test.sh` — PASS
- `bash tests/fleet-failed-command-flagged.test.sh` — PASS
- `bash tests/claim-reconcile.test.sh` — PASS
- `bash tests/manifest-shape.test.sh` + `bash tests/intake-repos-shape.test.sh` — PASS
- `bash -n bin/lifecycle-label-sweep` — syntax OK; `shellcheck -S warning` — clean.
- sgscan (live, `/home/nish/.local/bin/sgscan`) — `No new security findings.`
run-proof: live dry-run `LIFECYCLE_SWEEP_DRY_RUN=1 bin/lifecycle-label-sweep` against the real repo returned `sweep done: relabeled=0 skipped=336 failed=0 reclassified=1` — the 1 is `Nishfleet/fleet-ops#1255`, a live OPEN `fix(failed-command):` `agent-ready` issue whose class-lock PR #1389 merged (verified via `gh pr list --head claim/issue-1255 --state merged`).

No new systemd unit, timer, path unit, or workflow is added by this PR, so no `research:` / `help-first:` / `organ-heartbeat:` lines are required (the change extends the existing `bin/lifecycle-label-sweep`, which is already an installed organ covered by fleet_rules.yml).

Closes #1083
