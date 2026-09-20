# Observe-close for #6779 — deploy-fault-gate orphaned `mergeCommit.oid`

Issue #6779 (filed 2026-09-14) reported that the deploy-fault gate
(`lib/deploy-fault-gate.sh`, fleet-ops#5785) resolved an issue's delivery
merge via `gh pr view --json mergeCommit` and then demanded that the
recorded sha be contained by a green `Deploy production` run. When main's
history is later rewritten (rewind + re-merge), the recorded
`mergeCommit.oid` diverges from main forever, no run can ever contain it,
`deploy_fault_has_proof` can never return 0, and the delivered issue is
un-closable no matter how green production is. Live case: Nishfleet/0509#2944,
reopened twice with green production; the recorded sha `9cc3f3bab` was
orphaned while the real on-main delivery `c26c55ce9` was dead ahead of
nothing that the gate ever re-read.

The issue proposed three fix directions — match on-main
`Merge pull request #<N>` commit messages, check the delivery PR's
head-sha ancestry, or accept an explicit `deploy-fault-delivery: <sha>`
comment. All three presuppose `deploy_fault_fix_shas`, the function the
gate used to collect candidate shas.

By the time this claim ran (2026-09-20), the entire surface the issue
targets was already deleted from main. No new code is needed; this
report is the resolution record.

## What was found

1. **The gate and its config are deleted.** `d7d69d813`
   ("chore(glue-sweep): cut the market-signal cron and four zero-caller
   orphans", 2026-09-18) removed `lib/deploy-fault-gate.sh` (291 lines),
   `config/deploy-fault-stranded-merges.json` (41 lines) and
   `tests/fleet-deploy-fault-gate.test.sh` (650 lines) together with the
   `MANIFEST` rows; the commit's stated deletions name this exact pair.
   `git merge-base --is-ancestor d7d69d813 origin/main` passes at
   origin/main `d73863867`.
2. **Its sourcing callers were deleted the same day.** `0dc5dd4ac`
   ("refactor(prs): GitHub closes the issue — drop the observe-to-close
   sweep") removed `bin/fleet-merged-pr-close` and
   `bin/fleet-dead-pr-detector`, the two binaries that sourced the gate
   and did the reopen branch of
   `if deploy_fault_has_proof ... else reopen`, plus the webhook route
   that fired them; `git merge-base --is-ancestor 0dc5dd4ac origin/main`
   passes. The close path is now GitHub's own `Closes #<N>` trailer close
   (commit 0dc5dd4ac decision), which never re-examines a delivery sha.
   The stranded-merge map fix that PR #6768 began for the same 2026-09-11
   0509 rewrite (fleet-ops#6770) landed as `01e5aabec` and then went away
   with the deletion of the map file it added — the gate that consumed the
   map no longer exists (also verified as an ancestor of origin/main).
3. **No replica exists anywhere checked.** Repo-wide greps for
   `deploy-fault-gate`, `deploy_fault_has_proof`, `deploy_fault_fix_shas`,
   `DF_FIX_SHAS`, `mergeCommit` and `FleetProductionStale` return zero
   hits outside `.fleet/bench7371/` (static review-bench fixture copies of
   old PR bodies) and the historical reports/ prose; `ci.yml`, `MANIFEST`
   (file no longer exists at all) and `config/fleet_rules.yml` carry no
   deploy-fault row, and `.github/workflows/deploy-production.yml` (24
   lines) contains no fault/proof logic. On the host
   (`netcup-rs2000`), recursive greps over `~/.local/bin`,
   `~/.local/libexec`, `~/.config/systemd`, `/etc/systemd`,
   `~/.local/share/systemd` find no `deploy-fault`/`deploy_fault`
   reference — the only `~/.pi/agent` hits are historical session
   transcripts. The `alert-repair-FleetDeployFaultClosedWithoutGreen-*`
   unit family (#6782) has nothing left to fire its rule: no
   `FleetDeployFault*`/production-stale alert remains in
   `config/fleet_rules.yml`.
4. **The live case is no longer held open by the gate.** The last gate
   comment on Nishfleet/0509#2944 was the 2026-09-14T08:52:14Z reopen
   ("...no green `Deploy production` run whose SHA contains the fix
   exists. Reopened."). Every event after that (timeline verified
   2026-09-20) is a nish3451 label change (latest 2026-09-20T08:32:15Z);
   no gate actor has acted since the surface died. The issue's own
   production proof stands (green `Deploy production` run 34798996355 on
   head `16bd92843` containing the real delivery `c26c55ce9`, cited in the
   same thread). Nothing autonomous re-blocks or re-opens it: the only
   remaining party is the owner-side close itself.

## Why none of the three proposed directions apply

Each direction patches `deploy_fault_fix_shas`, which along with
`deploy_fault_has_proof` and the reopen branch has been deleted rather
than fixed. Re-adding 291 lines of zero-caller machinery — machinery cut
twice, not once: the callers went with 0dc5dd4ac's close-path decision
and the file went with the glue-sweep's zero-caller pass — in order to
then harden it would reinstate the observe-to-close sweep that the
0dc5dd4ac decision deliberately retired. The unclosability failure shape
cannot be produced by anything on main since 2026-09-18.

## Acceptance verification (2026-09-20, netcup-rs2000)

| Check | Result |
|---|---|
| `d7d69d813` (gate/config/test deletions) on origin/main | `git merge-base --is-ancestor` → yes |
| `0dc5dd4ac` (fleet-merged-pr-close/dead-pr-detector deletions) on origin/main | `git merge-base --is-ancestor` → yes |
| No live repo references | grep zero hits for gate symbols, `DF_FIX_SHAS`, `mergeCommit`, `FleetProductionStale` outside `.fleet/` fixtures; `ci.yml` zero refs; `fleet_rules.yml` zero refs; `deploy-production.yml` zero refs |
| No host machinery | greps over systemd dirs + `~/.local/{bin,libexec}` zero hits; only session transcripts mention the gate |
| Live case not gate-reopenable | last gate action 2026-09-14T08:52:14Z; post-deletion 0509#2944 events are label-only (nish3451); no autonomous actor re-examines delivery shas |
| Fleet alive while on this check | `systemctl --user list-units --state=failed` → 0 loaded units; litellm `/health/readiness` → healthy/db connected, all `litellm_deployment_state` gauges 0.0 |

## Residual note

Nishfleet/0509#2944 still sits OPEN with `stateReason=REOPENED` — not
because any gate holds it (none exists) but because its correct close
under the new trailer regime has not yet been executed the normal way by
the repo's own close path. Repeating the 08:36Z-style production-proof
close (or a plain `Closes`-trailer delivery PR) is ordinary 0509 close
work and is tracked by the stranded-SHAs roll-up fleet-ops#6770; filed
evidence here so this record and that thread say the same thing. The
co-stale followups #7572 (remap helper) and #7640 (park) also name only
the deleted surface; noting, not re-classing, them here.
