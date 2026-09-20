# Audit seat-fanout mechanism match for #7074

Issue #7074 (filed 2026-09-15 by fleet-blind-audit, severity high) carries a
repair ask over the September 4 audit fan-out: 57 failed `pi-audit@*--straitly`
user units plus 2 dead seats never released (sources #3110, #3102, #3099; the
retained #7076/#7078 work folded in by the 2026-09-17 orchestrator decision).
The acceptance asks to locate the existing audit seat-selection repair and a
completed real audit, preserving the no-empty-verdict rule, with no new
checker.

Both acceptance elements are located with real receipts below. The remaining
decision items — capture the senior process failure through the existing
audit runner, rerun the existing regression suite — are
`mechanism-impossible`: the runner, the suite, and the lane that could
produce a senior verdict were all deliberately deleted in the 2026-09-18
glue sweep, one day after the decision scoped them. Recorded, not silently
dropped.

## What was found

1. **The seat-selection repair exists and is live.** PR #3387
   (`fix(audit): senior role replaces dead straitly seat; owner-authored
   bypass; tally rejects keyword-only reasons`, merge commit fd59f86,
   merged 2026-09-04T21:03:44Z, fleet-ops#3121) replaced the dead straitly
   role with the `senior` usable-seat ladder. On current origin/main
   (`c00704f3`) the repair content survives as `_comment_senior_order` in
   `config/seat-caps.json`: "the senior (judge/orchestrator/reviewer)
   role's seat ladder. Replaces the dead straitly role … senior replaces
   straitly everywhere." The straitly seat whose walled picks produced
   the 57 failed units was itself wiped 2026-09-10 (`_comment_straitly_wipe`:
   "402 credit exhausted, seat retired") — the fan-out's seat source is
   doubly gone.

2. **A completed real audit exists with receipts.** Per this issue's
   2026-09-17 partial-delivery comment: `pi-audit@0509--3587--devin.service`
   started 2026-09-17T19:49:21Z, wrote a substantive FAIL vote at
   19:50:02Z citing #3065 / PR #3588, and systemd recorded Finished — a
   real candidate verdict, not a failed unit; the free-role vote in the
   same panel carried a real reason. The #6357 record verified on
   2026-09-20 that the last `pi-audit@` execution on the host was a PASS
   vote for 0509/#2952 at 2026-09-18 07:53 UTC, hours before removal.
   What never existed: a non-empty SENIOR verdict — the same comment
   counted 26 senior-role exit-1 journal entries since 2026-09-16. That
   gap stayed open until the organ died; it is now unanswerable by
   construction (see 4).

3. **The organ that filed this issue is also deleted.** `f851c86cf`
   (`chore(glue-sweep): delete meta-metrics-scorers`, 42,794 lines across
   158 files, Jev-scored) removed `bin/fleet-blind-audit` (1,780 lines),
   `bin/fleet-blind-audit-panel`, `lib/blind-audit-cadence.sh`,
   `lib/blind-audit-panel.py`, `prompts/blind-audit.md`,
   `systemd/fleet-blind-audit.{service,timer}` and their tests. The cited
   report path
   `~/workspaces/agent-state/fleet-blind-audit/reports/20260915T220722Z/report.md`
   and the whole `fleet-blind-audit/` state dir are gone from the host
   (ENOENT today).

4. **Every object the 2026-09-17 decision named is retired.** The
   decision scoped: the existing audit runner (deleted — `d02760b53`
   removed `bin/pi-audit-run`, `bin/pi-audit-tally`,
   `systemd/pi-audit@.service` + `10-concurrency.conf` drop-in,
   `systemd/pi-audit.slice` and 9 test files, 2,981 lines), the existing
   regression suite (`tests/pi-audit-run.test.sh` et al. — same commit),
   and the senior verdict producer (same organs; registry/gate/CI
   leftovers finished by `3c3d74443` `chore(second-cut-B): finish the
   pi-audit panel removal`, Jev p(delete)=0.66). The escalation tower
   went in `9f0cba02c`. All four commits are `merge-base --is-ancestor`
   ancestors of origin/main `c00704f3`. The senior exit-1 journal
   entries the decision asked to capture have rotated out
   (`journalctl --user -u 'pi-audit@*'` → "No data available" on
   2026-09-21); their count and timing are preserved in the 2026-09-17
   comment record above.

5. **Live host is clean.** Probes on netcup-rs2000 2026-09-21 ~01:05 IST:
   `systemctl --user list-units 'pi-audit*' --all` → 0 loaded units;
   `list-timers` grep for audit → none; `~/.local/bin/pi-audit*` and
   `~/.config/systemd/user/pi-audit*` → absent; `ls -d
   ~/workspaces/agent-state/*audit*` → none; `systemctl --user
   list-units --state=failed` → EMPTY (the acceptance's "only the product
   live canary" state has fully cleared — zero failed user units);
   `git grep pi-audit|blind-audit origin/main` across bin/, libexec/,
   config/, systemd/, .github/, prompts/, tests/, MANIFEST, install.sh →
   zero hits outside docs/reports/bench fixtures. Deploy clone HEAD =
   origin/main = `c00704f3` — the live install source carries the
   deletions.

6. **Sibling surface.** #3110 (the auto-closed-against-#3647 source),
   #7076, #7078 (the retained repair/verification work), #7029 (comeback
   dependency the decision said not to wait on) and #7075 are all CLOSED.
   Same-class still-open rows that resolve identically on their own
   claims: #3485 (test issue for the deleted suite), #7107/#7117
   (pi-escalation-audit unit-deaths), #7728 (BLIND-AUDIT-CADENCE-OVERDUE
   — a stale alarm for the deleted cadence lib), the #6185–#6192
   LADDER-WALLED cluster. This run files nothing new; each already has an
   issue of record.

## Why deletion is the resolution

A failure mode is resolved by fixing its producer or retiring it. The
57-unit fan-out needed three organs: a dead seat still selectable for
audit (straitly — wiped 2026-09-10, replaced by the senior ladder via
PR #3387), an audit launcher/panel that could pick it (`pi-audit-run` +
`pi-audit@.service` — deleted `d02760b53`/`3c3d74443`), and the reporter
that turned the wreckage into this issue (`fleet-blind-audit` — deleted
`f851c86cf`). All three were removed under Jev-scored sweep review, not
lost. No seat can be selected for an audit that no longer exists; no
verdict — empty or otherwise — can be produced. The no-empty-verdict
rule is preserved trivially: there is no verdict writer left to violate
it, and this record adds no checker, per the acceptance constraint.

## Verification

- `gh pr view 3387 --json state,mergeCommit,mergedAt` → MERGED,
  fd59f86efa730d79843058a126584bfe9a1166f9, 2026-09-04T21:03:44Z.
- `git grep _comment_senior_order origin/main -- config/seat-caps.json`
  → the live senior ladder replacing straitly (fleet-ops#3121).
- `git merge-base --is-ancestor` → YES for d02760b53, 3c3d74443,
  f851c86cf, 9f0cba02c against origin/main `c00704f3`.
- `git show d02760b53 --stat` → 14 files / 2,981 deletions: runner,
  tally, service, slice, drop-in, 9 tests.
- `systemctl --user list-units 'pi-audit*' --all` → 0; `--state=failed`
  → 0 loaded units; `list-timers` audit grep → none.
- `ls ~/.local/bin/pi-audit*`, `ls ~/.config/systemd/user/pi-audit*`,
  `ls -d ~/workspaces/agent-state/*audit*` → all absent.
- `journalctl --user -u 'pi-audit@*'` → "No data available" (rotated;
  counts preserved in the 2026-09-17 issue comment and the #6357 record).
- `gh issue view` states: #3110, #7075, #7076, #7078, #7029 all CLOSED.

run-proof: probes ran live on netcup-rs2000 2026-09-21 ~01:05 IST
(19:35 UTC) against origin/main `c00704f3`; ancestry via
`git merge-base --is-ancestor`; unit/host state via `systemctl --user`
with `XDG_RUNTIME_DIR=/run/user/1000`; docs-only record — no unit, timer,
workflow or script path touched.

loose-ends: open same-class siblings #3485, #7107, #7117, #7728 and the
#6185–#6192 LADDER-WALLED cluster resolve identically on their own
claims (deleted-organ findings); nothing half-done.
