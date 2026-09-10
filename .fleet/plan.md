# Plan — fleet-ops#4957: cap-priority ordering, starved-signal detector, red-pr-repair terminus

## Context

- Branch: `claim/issue-4957` (worktree `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-4957`). Issue: Nishfleet/fleet-ops#4957.
- Touched files (2): `lib/detector-queue-reconciler.py` (signal ordering + cap line + starved-signal detector), `bin/fleet-heartbeat-red-pr-repair` (PR-keyed state, reap, terminus).
- New file (1): `tests/signal-cap-priority.test.sh`. Extended, never removed or skipped: `tests/fleet-heartbeat-red-pr-repair.test.sh`.
- Cap stays 5 (`FLEET_SIGNAL_RECONCILE_CAP`), never raised/removed/bypassed; no gate-owned path edited; no new organ — one priority map plus one starved-signal detector inside files that already exist.

Exact issue verify block:

```bash
# 1. ordering is no longer alphabetical
python3 - <<'PY'
import pathlib
src = pathlib.Path('lib/detector-queue-reconciler.py').read_text()
assert 'sorted(current_signals)' not in src, 'signals still iterated alphabetically'
assert 'priority' in src.lower(), 'no severity ordering present'
print('ordering ok')
PY
# 2. offline regression test
bash tests/signal-cap-priority.test.sh
# 3. live: after two heartbeat ticks the red-pr signal is no longer starved
journalctl --user -u fleet-heartbeat.service --since -3h -o cat \
  | grep 'SIGNAL-RECONCILE-CAP' | grep -c 'red-pr-repair'   # expect 0
```

## Plan

**Phase 1 — severity ordering + cap telemetry (same function, same edit)**

- [x] phase 1: `lib/detector-queue-reconciler.py` — in `reconcile()` replace `for sig in sorted(current_signals)` with a stable severity-ordered loop over ONE explicit small priority map matched on the signal's tag segment (`red-pr-repair`, then `timer-no-next`, `drift-install`, `exec-review-disarm`, `escalation-*`, `straitly-*`, `degraded-lanes`, all ahead of `failed-command-swallowed`), sort key `(priority_index, sig)` so unmapped tags keep today's alphabetical order as the tiebreak; the cap stays 5 and the `if filed_count >= cap` check, the dedupe/heartbeat path and the observe-to-close/reroute paths are untouched — nothing is raised, removed or bypassed and no gate is weakened.
- [x] phase 1: `lib/detector-queue-reconciler.py` — extend the `SIGNAL-RECONCILE-CAP` `loud()` line (~line 713) to also log `n_unfiled=<n> oldest_unfiled_age=<s>`, where `n_unfiled=len(capped_sigs)` and `oldest_unfiled_age` = now − the oldest `first_unfiled_at` recorded for those keys in the phase-2 starve state file (log `0` when no state file exists yet, so phase 1 does not depend on phase 2 shipping first) — starvation becomes a number, not an inference.

**Phase 2 — starved-signal detector (durable cross-tick state)**

- [x] phase 2: `lib/detector-queue-reconciler.py` — add the starved-signal detector: keep one durable cross-tick JSON state file under `~/.local/state/fleet-heartbeat/` (`$FLEET_SIGNAL_RECONCILE_STATE_DIR/signal-starve.json`, default `$HOME/.local/state/fleet-heartbeat/signal-starve.json`; that env var is the test seam), increment `consecutive_unfiled` and set `first_unfiled_at` for every capped key each tick, and reset/delete entries for keys that were filed or went green; when any key has been unfiled for >3 consecutive ticks, file exactly ONE deduped issue naming the starved keys (per-key tick counts + ages), with dedupe key = the SORTED KEY LIST carried as a stable backticked `loud/signal-starve/<slug-of-sorted-keys>` token in the body so the existing observe-to-close path can close it on the first green tick; at most one such issue per tick, so the cap of 5 is not bypassed — if judged impossible, write `mechanism-impossible: <reason>` in the PR body instead of dropping it.

**Phase 3 — red-pr-repair terminus + PR-keyed state + reap**

- [ ] phase 3: `bin/fleet-heartbeat-red-pr-repair` — give a budget-exhausted PR (red + dead worker + `attempts >= RED_PR_MAX_ATTEMPTS`) a terminus instead of an indefinite `holding`: store a fingerprint (`gh pr view --json headRefOid` head SHA + sorted failing-check names) in the state file and re-arm the budget (`attempts=0`, `escalated=false`, LOUD `RED-PR-REARM`) whenever the fingerprint changes; on exhaustion with an unchanged fingerprint hand the PR off ONCE per (pr, fingerprint) to a durable queue item naming `repo/pr/issue/failing checks` through the existing `fleet-issue-file` wrapper behind a new seam (`FLEET_REDPR_ISSUE_FILE`, default the real wrapper; missing wrapper = log WARN, never a hard failure), record `handed_off` in state so it never re-files, and keep the existing `RED-PR-ESCALATE` line plus exit 1 so `fleet-heartbeat-tier1` still propagates the page.
- [ ] phase 3: `bin/fleet-heartbeat-red-pr-repair` — include the PR number in `state_key()` as well as the issue (files become `<short>-<issue>-<pr>.json` / `.flag`) so an `escalated` marker cannot survive a PR swap (issue 1140: PR #1405 CLOSED, PR #1509 open → state starts fresh), and reap state at the end of each repo pass for PRs that are closed or merged (state files whose `short` matches that repo and whose `pr` is not in the just-listed open `claim/issue-*` set are deleted, json + flag), leaving the existing clear-on-green and clear-on-no-checks paths intact.

**Phase 4 — offline regression test**

- [ ] phase 4: `tests/signal-cap-priority.test.sh` — new offline test (stubbed `gh` + stubbed issue-file, `FLEET_SIGNAL_RECONCILE_STATE_DIR` pointed at a scratch dir, exits 0) with two scenarios: (a) a 10-signal tick with cap 5 containing 4 `failed-command-swallowed/sessio-*` keys, ≥5 further keys that sort alphabetically before `loud/red-pr-repair/`, and the key `loud/red-pr-repair/nishfleet-0509`, must file the red-pr-repair key (prove the harness starves it on pre-phase-1 code, passes after); (b) the same starved key replayed across 4 ticks with the cap always hit must file the starved-signal issue exactly once (one issue-file call, dedupe key = sorted key list) and the `SIGNAL-RECONCILE-CAP` line must carry `n_unfiled=` and `oldest_unfiled_age=`.

**Phase 5 — no test removed, verify green**

- [ ] phase 5: keep every existing test — remove or skip nothing; `bash tests/signal-reconcile.test.sh`, `bash tests/fleet-heartbeat-red-pr-repair.test.sh`, `bash tests/manifest-shape.test.sh` and `bash tests/intake-repos-shape.test.sh` must all exit 0; if a test must truly be removed or skipped the commit needs a `test-removal-justified: <reason>` trailer, and no gate-owned path may be edited (`.github/workflows/**`, `.github/scripts/**`, `CODEOWNERS`, gitleaks/semgrep config, design-system ratchet — editing one requires a `gate-integrity-attest: <40-hex head sha>` comment from a repository admin whose identity differs from the PR author); `tests/fleet-heartbeat-red-pr-repair.test.sh` is EXTENDED, not skipped (stub the new `FLEET_REDPR_ISSUE_FILE` seam, add the closed/merged reap scenario, keep scenarios A–G asserting unchanged exit codes and single-dispatch counts), and the same seam stub is added for the new terminus path.

Run the exact issue verify block and record all three results in the PR body. Command 3 is read-only evidence and can only read 0 after the change is deployed by the post-merge deploy path; if it is still non-zero because this PR is not deployed yet, say so explicitly in the PR body (command 2 is the pre-merge proof).

## Review log

### Phase 1 — reviewer, round 1 (revised after retry)

- **Act on (Critical):** the map as first written put `failed-command-swallowed` at index 7 and gave every unmapped class index 8, so the flood outranked `claim-reap-needed`, `decisions-ledger-fail`, `deploy-blocked`, `deploy-install` — classes filed today. FIXED: flood removed from the tuple and given its own bottom tier `TAIL+1`; unmapped classes now sort above it and keep alphabetical order among themselves.
- **Act on:** `red-pr-escalate` (tag `RED-PR-ESCALATE`) is the class the issue's own end state emits and was unmapped. FIXED: added to the map right after `red-pr-repair` as an explicit literal.
- **Act on:** `parts[1]` is the key, not the class, for the repo's non-`loud/` signals (`timer-manifest/<unit>`, `decisions-ledger/<slug>`, `cred-expiry/<provider>`, `exec-review-receipt/<slug>`, `chain-e2e-drill/fixture`). FIXED: class is `parts[1]` only under `loud/`, else the first segment.
- **Act on:** a naive (tz-less) `first_unfiled_at` made `now - first_dt` raise and the outer handler zeroed ALL ages. FIXED: naive entries are skipped per-entry, outer except kept as backstop.
- **Act on:** the state file was read on ticks with nothing capped. FIXED: read moved inside `if capped_sigs:`, summary keys still set unconditionally so the `--json` shape is stable.
- **Consider (accepted, carried to phase 4):** `tests/p14-test-listing-gate.test.sh` requires every `tests/*.test.sh` to be listed in `ci.yml` or invoked from an already-listed test, and `.github/workflows/**` is gate-owned. Phase 4 must therefore add `bash "$here/signal-cap-priority.test.sh"` to `tests/ci-standards-audit.test.sh` (the same host that already runs `signal-reconcile.test.sh`), not edit ci.yml.
- **Noted:** no consumer asserts an exact key set on the `--json` summary (`bin/chain-e2e-drill` reads `.filed`, `tests/signal-reconcile.test.sh` reads `.filed`/`.capped`/`.alarm_count`, `bin/fleet-heartbeat-tier1` never passes `--json`), so the two additive keys are safe.
- **Noted:** the cap guard is byte-identical, the default is still 5, and dedupe/heartbeat/observe-to-close/reroute are untouched.
- **Dismissed-with-reason:** "`drift-install`/`straitly-*`/`degraded-lanes` are dead map entries" — all three are live in the 48h journal (38 / 10 / 20 hits).
- **Dismissed-with-reason:** "the reorder makes an existing test flaky" — the sort key is total and deterministic; `tests/signal-reconcile.test.sh` exits 0.

Phase 1 commands (manager-run, raw): verify #1 `ordering ok` rc=0; `bash tests/signal-reconcile.test.sh` rc=0; `bash tests/timer-manifest-drift-canary.test.sh` rc=0.

### Phase 2 — reviewer, round 1 (revised after retry)

- **Act on (Critical):** `_starve_age_seconds()` left `now - first_dt` outside the `try`, so a naive `--now` against a Z-written state entry raised `TypeError: can't subtract offset-naive and offset-aware datetimes` out of `reconcile()` — the tick lost observe-to-close and the state write and exited 1 with no summary. FIXED: subtraction inside the `try`, and an up-front `"?"` when `now` itself is naive. Both directions proven.
- **Act on (Critical):** `already_reported = any(starve_entries[sig]["starve_reported"] ...)` muted a CHANGED starved set forever: the new token was not `already_open`, `any()` was still true, so no new issue was filed — while observe-to-close closed the old one because its token left `current_signals`. Net: starvation with no open issue, live-reachable via the churning `failed-command-swallowed/sessio-*` residue. FIXED: the per-key `starve_reported` field is gone; the state carries one top-level `reported_token` and suppression is an EXACT match on the current set's token. A changed set files; a superseded set's issue closes; `reported_token` clears when no keys are starved. One open starve issue at a time, documented in code.
- **Act on:** `_safe_slug(..., 80)` truncated the dedupe token, so two distinct key lists sharing an 80-char prefix collided — the reviewer produced the collision. FIXED: readable 48-char slug prefix plus a 12-hex sha1 of the exact newline-joined sorted key list.
- **Act on:** the skipped state write logged to stderr only, so a future real caller setting `FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON` would keep the tick green while starvation detection died silently. FIXED: `loud(triage, "SIGNAL-STARVE-STATE-SKIP", ...)` when not a dry run; the dry-run case stays `log()`-only.
- **Act on:** the fixed `.tmp` name lost writes under concurrency (measured 76/320 lost, counter 17 instead of 41, 7 duplicate issues). FIXED: unique tmp name per process. **Noted:** no `flock` added — the live tick is serial (`bin/fleet-heartbeat-tier1` runs the lib synchronously in one service); recorded here rather than papered over.
- **Act on:** a garbage or naive `first_unfiled_at` was carried forward verbatim forever, pinning the age at `?` and `oldest_unfiled_age` at 0. FIXED: self-heals to `now_str`.
- **Act on:** the issue body's "the cap is being spent on other classes" wording is misleading now that the bottom tier is the flood. FIXED: reworded to "the cap is saturated every tick and these are the keys that lost".
- **Consider (accepted, deferred):** phase 1's `oldest_unfiled_age()` and phase 2's `_load_starve_state()` are two readers of one file. They cannot disagree about a live field (same `_parse_iso`, both skip naive, both accept `{"signals":...}` and flat, both treat a non-dict payload as empty), so this is DRY only.
- **Noted:** the `current_signals.add(starve_signal)` happens after the `alarm_count` snapshot and corrupts no counter.
- **Dismissed-with-reason:** "the guard misclassifies a production caller, which then never detects starvation" — repo-wide only `bin/fleet-heartbeat-tier1` (live, no seam env, writes) and `bin/chain-e2e-drill` (sets `OPEN_ISSUES_JSON`, must not write) invoke the lib.
- **Dismissed-with-reason:** "the cap is bypassed" — `if filed_count >= cap` is not in the diff; the starve issue deliberately does not touch `filed_count`, and accept item 3 sanctions one meta-issue per tick.

Phase 2 commands (manager-run, raw): 6-tick replay with a set change at tick 5 files on tick 4 and tick 5 and not on tick 6; distinct sets with identical slug prefixes produce distinct tokens; issue verify #1 `ordering ok` rc=0; `bash tests/signal-reconcile.test.sh` rc=0; `bash tests/timer-manifest-drift-canary.test.sh` rc=0; `bash tests/chain-e2e-drill.test.sh` rc=0.

## Risks

- Long cap line + new state file must never crash the tick: wrap state read/write in try/except and keep the `loud()` call unconditional.
- The starved-signal issue must be one per sorted-key-list, not one per tick — a missing dedupe turns the anti-starvation fix into a new flood.
- Adding the handoff issue call can break the existing red-pr-repair test's whitelisting fake `gh`; that is why the seam defaults are stubbed inside the test in phase 3/5.
- Live tick order/jitter can interleave ticks; the tick counter is per reconciler run, keyed on `FLEET_SIGNAL_RECONCILE_NOW`, not wall-clock.
- Do not touch `lib/pi-intake-tick.sh`, `bin/fleet-heartbeat-tier1` wiring, or any gate-owned path.
- Rollback is a revert; `~/.local/state/fleet-heartbeat/**` is regenerated per tick, no migration involved.
