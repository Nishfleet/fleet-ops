# Agent-worktree inventory and reaper-gate candidate report — fleet-ops#6889

Run: 2026-09-20, unit `pi-issue@fleet-ops-6889`, worktree `issue-fleet-ops-6889` @ `072b81a`.
Deliverable per DECIDE (2026-09-17, issue thread): **preservation-first candidate report** — not a reaper code change. Zero deletions, zero pushes, zero gate relaxations were performed. Data file: `reports/issue-6889-candidates.tsv` (same snapshot).

## 1. Scope and snapshots

- Root: `/home/nish/workspaces/agent-worktrees` — 26 directory entries (24 with a `.git` gitfile + 2 machinery dirs), 2893 stray root-level files (legacy `.packet-*.md` / `REPORT-*.md` artifacts, a few hundred small data files), total **2.07 GB**.
- Snapshot A (full inventory): 2026-09-20 ~13:41Z.
- Snapshot B (re-verification, immediately before this commit): 2026-09-20 ~14:07Z — every TSV row re-probed for existence and `git status --porcelain` emptiness; every candidate tip re-read. All 8 candidates pass both snapshots.
- Live-state corrections during the run (the corpus moved under us, which is itself evidence):
  - `issue-0509-3788` vanished mid-run: `devin-issue@0509-3788.service` hit a timeout at ~13:56Z; `pi-issue-failed@0509-3788` released the claim; the unit's `ExecStopPost` removed the worktree (`rm -rf`, by design); the unit sits in `auto-restart` (`Restart=on-failure`), so the tree may reappear any minute. Its 14-file WIP session (better-auth genericOAuth state/PKCE work on 0509, per the journal narrative) was destroyed at the stop.
  - `issue-0509-2771` belongs to `devin-issue@0509-2771.service` (active during the whole run; PR #3823 opened 13:42Z from it) and `issue-0509-2764` to a devin unit that started at ~14:02Z. These are live-cycle trees, excluded by design.

## 2. Where things stand after the earlier cuts (the world this report proposes against)

- `bin/fleet-worktree-reaper` (1,357-line reaper, deleted in second-cut-B `2ff2b0cac`) was the root-state tooling. When it died, three of its safety gates also lost their only enforcement point: merged/closed-PR age gating, dirty-tree protection, salvage banking (`pi-salvage-worktree`, the `wip/wfr-*` banking organ).
- Unit-managed cleanup now handles the registered claim-worktree path on BOTH lanes: `pi-issue@.service` (live on this host) and by explicit contract the devin/cursor templates — same three `ExecStopPost` hooks (worktree removal, intake refill, artifact check). The stop-cleanup deliberately destroys uncommitted work: "work that was never committed and pushed did not happen."
- The leak observed in this inventory is the **fleet-ops#8814 class** — units completing (PR merged) without their stop-cleanup removing the tree. Live corroboration: `issue-0509-6475` (PR merged 02:38Z), `issue-0509-6829` (07:21Z), `issue-7862` (merged 12:57Z 09-19), `issue-7869` (11:37Z 09-19) — all four trees still present, clean, at exact merged-tip SHAs, hours after their PRs merged.
- The dispatch ledger (`dispatch-ledger.jsonl`) is dead: **zero unit entries** are on file for any tree in this inventory. Every Mode B gate therefore fails on the ledger-read alone.

## 3. Candidate reconciliation (gates from the deleted reaper's own source)

Gate constants restored from the deleted reaper source (`/tmp/reaper-history`, file form): `MIN_AGE_HOURS=24` (line 294); Mode A: `PR merged` → reap immediately (dirty gate still applies); `PR closed-unmerged` → needs age ≥ 24 h; open/none → `skipped_unmerged`; Mode B: ledger-terminal + pushed + age; Mode C: `HEAD sha == sha of ANY origin ref` (fail-closed) + age ≥ 24 h; Mode E: registered/scratch reaping at 14-day salvage age; dirty from `"^[AM?]{1,2} .+"` porcelain parsing → SKIP (always).

Every candidate passes ALL of: (1) tree clean (`git status --porcelain` empty, verified twice); (2) tip SHA verified on a write-served origin ref (ls-remote proof, exact SHA match) or contained in `origin/main` on a bare clone (hence nothing local-only exists in the tree); (3) no live worker owns it — checked across ALL lanes this time, not just `pi-issue@` (the deleted reaper's `is_live_worker` keyed on `pi-issue@`; this run added `devin-issue@`/`cursor-issue@` actives); (4) age window satisfied for the relevant mode.

| tree | repo | branch | tip | mode | age | gated by |
|---|---|---|---|---|---|---|
| 0509-3617-followup | 0509 | claim/issue-3617-followup | f9d7306f… | C | 29.3 h | `refs/heads/claim/issue-3617-followup @ f9d7306` (ls-remote, exact SHA match) |
| 5918-repro | fleet-ops | (detached) | f48cb502 | C | 32.4 h | `refs/pull/7823/head @ f48cb502` — tip preserved on origin pull-ref (#7823 closed-unmerged 2026-09-19) |
| fleet-ops-5175 | fleet-ops | (detached) | 74145328 | C | 46.6 h | `refs/heads/claim/issue-5326 @ 7414532` — tip == the live origin claim tip exactly; zero local-only content |
| fleet-ops-7820-cap8 | fleet-ops | fix/intake-cap-8-pareto-xkiro | 776fa6b9 | C | 32.8 h | `refs/pull/7827/head @ 776fa6b9` — branch deleted on origin post-merge (#7827 merged 2026-09-19T04:54Z), pull ref keeps the head |
| issue-7862 | fleet-ops | claim/issue-7862 | b40c9e52 | A | 25.9 h | `refs/pull/7894/head @ b40c9e52` — PR #7894 merged 2026-09-19T12:57Z |
| issue-7869 | fleet-ops | claim/issue-7869 | c09fa94b | A | 26.2 h | `refs/pull/7881/head @ c09fa94b` — PR #7881 merged 2026-09-19T11:37Z |
| issue-0509-6475 | 0509 | claim/issue-6475 | f5b84ab2 | A | 11.4 h | `refs/pull/3735/head @ f5b84ab2` — PR #3735 merged 2026-09-20T02:38Z |
| issue-0509-6829 | 0509 | claim/issue-6829 | abaa9121 | A | 7.0 h | `refs/pull/3799/head @ abaa9121` — PR #3799 merged 2026-09-20T07:21Z |

Notes the next reaper (if any) would need to replicate:
1. **Only the four Mode A trees (merged PRs) pass every reaper gate.** The reaper's own mode-A wording documents merged-claims as reaped immediately; age for those is informational. This report still cites each PR's mergedAt.
2. **`fleet-ops-7820-cap8` and `0509-3617-followup`/`5918-repro`/`fleet-ops-5175`'s branches are claim-shaped but fail the reaper's own branch-name parse** (`^issue-…` and fully-numeric only), so the reaper never evaluated them as Mode A/B — they pass on Mode C instead (tip == remote-tip exact).
3. **Mode E (14-day salvage-age)** trees — `.hidden-x` (8.4 d), `fleet-ops-5144` (1.9 d), `jev-ultrafast-ref` (42.9 h), `ref-jev-ultrafast` (44.2 h) — are all under the 14-day window. Retained by the deleted reaper's own gate, not a candidate.
4. `.lane` and `.pi` (machinery dirs, no `.git`) are excluded by nature; the 2893 root-level stray files are legacy dispatch packet artifacts — outside the worktree taxonomy, noted only.

## 4. Retained (unsafe) trees and the preservation evidence for each

Preservation = tree persists; local-only content = content NOT reachable from origin by any ref this run enumerated (PR pull refs, branch refs, containment check in a fresh deploy clone at `fleet-ops-deploy-clone`, and the 0509 mirror). Every such file's working-tree blob SHA (from `git hash-object`) is recorded in the TSV column — the evidence of what was at stake at snapshot time.

| tree | why retained |
|---|---|
| `issue-fleet-ops-7776` | Dirty — 3 staged adds + 1 modified; each verified ABSENT-from or DIFFERENT-from origin/main (`lib/seat-probe.sh` blob 828137ec, `systemd/pi-intake@.service` tree 03b75424 vs main bc6025b0, `tests/seat-probe.test.sh` blob 9330af2e, `tests/test_pi_packet_verdict.py` blob 54a40ef1 — all local-only). Local tip `be38630df` sits 10 commits ahead of the remote branch (5555025), but all 10 commits are PROVEN contained in origin/main (deploy clone `merge-base --is-ancestor` OK; branch-containing: `origin/claim/issue-{3345,3350,3622,5373}`). PR #7784 OPEN + auto-merge **armed** since 2026-09-18T18:23Z by nishfleet-worker with `mergeStateStatus: UNKNOWN` + zero reviews (checked this run). Pushing would advance someone else's armed PR — refused: preservation-by-proof instead (committed content already on origin; dirty content noted for follow-up). |
| `issue-fleet-ops-3622` | PR #7808 OPEN + auto-merge **armed** since 2026-09-19T05:44Z; branch tip == the tree tip exactly; clean. Mode A `skipped_unmerged`. |
| `issue-fleet-ops-7799` | Dirty — 2 files, both ABSENT on origin/main (`measure.sh` blob 08d3c66d, `tests/findings-measure-line.test.sh` blob c3c9b41d). Mode B ledger gate fails (no unit entry on file). Branch tip also preserved on a SECOND origin ref (`claim/issue-5959 @ b6eb510`) — content-redundant, but tree ≠ ref and the reaper requires repos-side only. |
| `issue-fleet-ops-7792` | Dirty — `systemd/pi-scout-repair@.service` DIFFERS from origin/main (tree 784d012e vs main 160e00c1). Mode B ledger gate fails. |
| `fleet-ops-5124` | Dirty — `lib/fleet-product-slo.py` ABSENT on origin/main (blob 2a916059). |
| `issue-0509-3536-0509` | Untracked `migrations/0105_add_jev_mention_columns.sql` (blob afea424b) — verified against a freshly fetched 0509 mirror: ABSENT on 0509 origin/main, path absent on any 0509 branch under that filename; genuine local-only migration work (harness-closed on 0509#3536). |
| `issue-0509-3750` | Untracked `scripts/search-tier-canary.mjs` (blob ccef0011) — ABSENT on 0509 origin/main; the canary work this does refer to landed via `.github/workflows/prod-public-canary.yml` (blob identity differs) — this copy is genuine local-only evolution; porcelain non-empty beats merged-immediate. PR #3752 tree-tip match: `refs/pull/3752/head @ 77dd7d7` == this tree. |
| `jev-ultrafast-ref`, `ref-jev-ultrafast` | Genuine `browser-use/jev-ultrafast` clones at the upstream main tip `1231850` — both clean; mode E age-window young. Unchanged vs upstream main. |
| `.hidden-x` | Deploy-clone fork (local-path origin); main `97fe66d` verified contained in the deploy clone's `origin/main` (ancestor check OK); clean; mode E young. Note: the deleted reaper's mode E explicitly treated archived local-origin clones as `SALVAGE-BANKED-LOCAL` — not mine to redefine per DECIDE. |
| `fleet-ops-5144` | Standalone clone on main `5b298fb` = the live `refs/heads/claim/issue-5124` tip exactly; contained in origin; clean; mode E young. |
| `issue-0509-2771` | LIVE-CYCLE — devin unit active during the run; PR #3823 open (2026-09-20T13:42Z). |
| `issue-0509-3788` | LIVE-CYCLE TRANSIENT — timed out at 13:56Z; claim released; auto-restart pending; tree removed at stop (was dirty 14+1 at snapshot A, destroyed by design). |
| `issue-0509-2764` | LIVE-CYCLE — devin unit started 14:02Z; tree not yet on disk at snapshot B. |
| `issue-fleet-ops-6889` | This run's own worktree/unit. |

**Summary of preservation: zero deletions, zero pushes, zero tree writes.** Every tip across all candidate + retained trees is verified present on origin (exact-SHA or ancestor-containment proof). What is NOT on origin anywhere: 9 dirty/untracked file copies enumerated above (blob SHAs recorded). Any future action that removes their trees destroys that content — the only content preservation achieved this run IS the trees' continued existence.

## 5. Observations supporting the removal-policy decision (report-only; no code change this run)

- **`fleet-ops#8814` class is corroborated live, twice, today.** Post-cut units (both `pi-issue@…` and `devin-issue@…` templates) leave their registered worktrees behind when their stop-cleanup doesn't run post-merge — the four merged-tree cases above are 7–26 hours post-merge and still present, full and clean. This is the precise gap the deleted reaper's mode A covered automatically (merged-PR → immediate reap).
- **Uncommitted WIP is destroyed by unit-stop by design (both lanes).** The live `pi-issue@.service` and devin/cursor templates carry the same three `ExecStopPost` hooks with literal `rm -rf` of the worktree — the design comment states "work that was never committed and pushed did not happen." LIVED PROOF this very run: `devin-issue@0509-3788`'s session (a whole better-auth genericOAuth state/PKCE sweep on 0509#3788, 14 files mid-WIP, `npm ci` done, 9-test green run in-journal) was wiped at the stop's `ExecStopPost`. The former `pi-salvage-worktree` banking organ (which previously turned dirty stale trees into `wip/wfr-*` refs) is also deleted — nothing banks, nothing safeguards against that specific path anymore. This is a previously-accepted design tradeoff; the DECIDE for #6889 orders preservation, and this report's gap: 9 such local-only file copies exist ONLY because their trees still exist.
- **`fleet-ops#8814`'s fix, when it lands, needs to read ALL lanes**, not only `pi-issue@` — the deleted reaper's `is_live_worker` substring-matched `0509-3788` etc. against `pi-issue` running-units only; devin/cursor claims would be invisible to that check. This run checked all lanes and only ever found devin + one pi-issue active (this worker itself).
- No reaper timer re-created itself after second-cut-B (`systemctl --user list-timers` contains no reaper); there is no other existing automation that reaps; removal-policy status quo = the unit-stop cleanup and leak.

## 6. Recommendation (decision owned by Nish/orchestrator per DECIDE)

1. Adopt the merged-PR immediate-reap gate (Mode A semantics: merged + clean + tip already on the pull-ref) with ALL-lane live-worker checking first, then the 24-hour Mode C gate — smallest change restoring prior behavior without touching Mode B (dead ledger) or the 14-day Mode E window.
2. Keep the dirty gate absolute (this merger could protect trees with real failed-work content, as enumerated in §4 — do not weaken it).
3. For the 9 local-only file copies listed above: separate follow-up proposal needed per-file (bank, reopen, or declare abandoned-by-design) — NOT this PR's scope.

Nothing in this report, and nothing committed to this branch, deletes or rewires any tree — the removal policy question itself is answered by Nish/orchestrator in the DECIDE framework.
