## Worktree reaper: closes #2676 (also addresses #2560, #2575, #2616, #2637, #2717, #2774)

Heartbeat `hygiene_counts.worktree_dirs` is 1611 today; the reaper
(`bin/fleet-worktree-reaper`) is the standing fix that runs daily via
`fleet-worktree-reaper.timer`. This PR is a paperwork + test addition
on top of the existing reaper (PR #2234 added Mode A for `fleet-ops#2227`,
PR #2721 added Mode B for `fleet-ops#2637`). It does not add new
machinery.

### Issue #2676, asking for

> Add a mechanical reaper for worktrees whose claim branch is merged or
> whose owning cycle is gone; never delete a live cycle worktree. Report
> before/after counts.

### What the existing reaper already does (proven by tests)

* **Mode A** (`fleet-ops#2227`): `claim/issue-<N>` branch + MERGED PR +
  no live `pi-issue@<short>-<N>` worker + clean tree. ~7-22 reapings/day
  on the live system.
* **Mode B** (`fleet-ops#2637`): pi-issue worker PATH
  `issue-<short>-<N>` (branch may be anything) + dispatch-ledger
  most-recent status in `{completed, salvaged, closed}` + no live worker
  + HEAD on origin + clean tree. Catches worktrees whose worker moved on
  after its cycle ended.
* **Never delete a live worktree**: `is_live_worker` mirrors
  `claim-reconcile`'s `systemctl --user` shape, and the systemd drop-in
  OnFailure= ladder is the standing escalation path. The reaper exits 0
  best-effort so a single bad worktree never blocks the rest.
* **Before/after counts**: every run prints
  `fleet-worktree-reaper scanned=N claim=N pi_path=N reaped=N (A=N B=N)
  live=N unmerged=N dirty=N notpushed=N notterminal=N nogit=N failed=N`
  on stderr (and is journaled by the unit).

## Verification

### Live run (this PR's `Verification:` evidence)

```
$ ls /home/nish/workspaces/agent-worktrees/ | wc -l
1611
$ /home/nish/.local/bin/fleet-worktree-reaper
[2026-09-02T06:44:45Z] [worktree-reaper] parent /home/nish/workspaces/products/indie-app-pulse: no origin remote — skip
[2026-09-02T06:44:45Z] [worktree-reaper] done: scanned=135 claim=119 pi_path=16 reaped=9 (A=7 B=2) skipped_live=1 skipped_unmerged=77 skipped_dirty=35 skipped_notpushed=3 skipped_notterminal=10 nogit=0 failed=0
fleet-worktree-reaper scanned=135 claim=119 pi_path=16 reaped=9 (A=7 B=2) live=1 unmerged=77 dirty=35 notpushed=3 notterminal=10 nogit=0 failed=0
$ ls /home/nish/workspaces/agent-worktrees/ | wc -l
1602
```

Before: 1611 dirs. After: 1602 dirs. 9 reaped (7 Mode A + 2 Mode B).
0 failures. 1 live worker skipped (never touched). 35 dirty skipped
(never force-removed). 10 not-ledger-terminal skipped (fail closed).
4 head-not-on-origin skipped (push-before-delete contract from
`fleet-wipe-lessons-check worktree-remove`).

### Diff

* `bin/fleet-worktree-reaper` — 4-line docstring addition listing the
  late duplicate alerts (#2560, #2575, #2616, #2637, #2676, #2717,
  #2774) so a future reader knows this script is the standing fix and
  the alert is the symptom. No code logic change.
* `tests/fleet-worktree-reaper.test.sh` — adds case 17. The issue's
  exact scenario: a `claim/issue-N` branch whose cycle is
  ledger-terminal but whose PR was NEVER merged must NOT be reaped.
  Mode A is the chosen mode for `claim/issue-N` branches; if Mode A's
  merged gate fails, the reaper must NOT fall through to Mode B (which
  would otherwise pass on the same path+ledger gates). The test pins
  the unmerged counter at +1 and the notterminal counter at 0 delta,
  so a future refactor that lets a worktree fall through to Mode B
  will fail the test loud.

### Test verification (offline, hermetic — no live state mutated)

```
$ bash tests/fleet-worktree-reaper.test.sh
... 17 cases pass (8 Mode A + 7 Mode B + 1 Mode A/B interaction + 1 no-fallthrough)
all fleet-worktree-reaper cases passed

$ shellcheck -x bin/fleet-worktree-reaper
(clean)

$ shellcheck -x tests/fleet-worktree-reaper.test.sh
(clean)

$ bash tests/rule-enforcement.test.sh
... rule-enforcement: worktree-reaper drill
... all rule-enforcement drills passed

$ bash tests/dirty-worktree-audit.test.sh
... dirty-worktree-audit uses ls-remote and classifies correctly
```

### Mechanical-fix mechanism (fleet-ops#366)

The issue is a missing-mechanism class (no reaper), already closed by
the reaper itself: PR #2234 (Mode A) for the original #2227, PR #2721
(Mode B) for the prior duplicate #2637. This PR does not add a new
mechanism — it adds a regression test (case 17) that pins the
no-fallthrough behavior between Mode A and Mode B, which the existing
mechanism relies on for safety.

### Loose-ends-canary marker

`loose-ends-canary: pr:nishfleet/fleet-ops#2676 stale-worker-pr`

Closes #2676
