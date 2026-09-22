# Observe-close for #7707 — eight stale open PRs dispositioned against current main

Issue #7707 (filed 2026-09-18) recorded that 9 of 11 open PRs had aged 6–8
days with zero commits and zero reviews, and asked for a per-PR decision:
rebase onto current main and land if the defect is still real, or close with
a citation of the newer PR/commit that already fixed it. By the time the
claim ran (2026-09-22), two of the eight named PRs were already closed with
evidence, and five more were made permanently unmergeable by the
2026-09-18/19 sweeps that deleted every file they touched. One — #5112 —
still fixed a real defect and was rebased and landed.

## Per-PR disposition

| PR | Disposition | Evidence |
|----|-------------|----------|
| #5112 CPUQuota bound | **Rebased and landed** | See below |
| #5418 seat-health bench | Closed | `tests/seat-health-classifier.test.sh` deleted in `7c2b2beac` "cut(extensions): delete 2,663 lines of pi extensions; stock forks + systemd carry the rest" — the classifier it benched no longer exists (only config/corpus references remain). |
| #5668 scout-futility bench | Closed | `bin/scout-futility-check` and `tests/scout-futility.test.sh` deleted in `fa2f27bf9` "chore(second-cut-A): delete the fleet self-watching organs" — the organ it benched was deliberately removed with the self-watching layer. |
| #5703 AGENTS.md vault-path fix | Closed | `lib/pi-agents-md/canonical.md` deleted in `f8b567588` "cut(rule-enforcement): delete the rule matrix, the rule renderers and the timer registry" — the source doc and renderer that emitted the stale path are gone. |
| #5762 issue-file rate-limit gate | Closed | `lib/issue-file.py` deleted in `6fee069b6` (PR #7907) "cut(no-glue 3): delete dead scripts, hooks, shims and their orphaned tests" — the tool it gated has no call site. |
| #5809 money-boundary `--check` | Closed | `bin/money-boundary-raise` deleted in `6fdd20ed1` "cut(escalation): one stock amtool line replaces the 1,181-line notify tower" — the tower it belonged to was replaced wholesale. |
| #5888 usage-guard STOP-REASON | Already closed 2026-09-20 | Closed with evidence citing `9f0cba02c`/`d4a42ced6` (escalation-tower sweep deleted `bin/unit-escalation-write`). |
| #5996 auditor closeout packet | Already closed 2026-09-20 | Closed with evidence citing the same sweep (`bin/stop-escalation-dispatch` deleted). |

Every close carries the deleting commit sha and subject in its close
comment, satisfying the issue's "specific merged-PR number or commit sha"
bar. All five sweeps are merged on main — `git merge-base --is-ancestor
<sha> origin/main` passes for each at `07b6779a2`.

## #5112 — the one real defect still standing

The PR bound worker CPU with `CPUQuota=25%` after SustainedLoadHigh fired
on 2026-09-10/11 (16 pi-issue@ workers on 8 vCPUs, ~2x oversubscription,
admission RAM-only). On current main the defect was still real:
`systemd/pi-issue@.service` and `systemd/devin-issue@.service` carried
`MemoryMax`/`MemorySwapMax` but no CPU bound, and nothing else had landed
one (`git grep CPUQuota` on main hits only the unrelated
`app-litellm*.slice` files).

The rebase dropped the two hunks whose targets were deleted
(`bin/pi-systemd-run` in `d4a42ced6`, `tests/worker-memory-dropin.test.sh`
in `ca33faa96`), kept the `pi-issue@.service` bound, and extended the same
two lines to `devin-issue@.service` — the devin template is the worker
class actually running today (5 `devin-issue@` units live at push time;
`cursor-issue@` has never instantiated). Rebase-verified per the issue's
force-push rule with the PR's own proof: a transient unit with
`CPUAccounting=yes CPUQuota=25%` reports `CPUQuotaPerSecUSec=250ms` and
`cpu.max=25000 100000`. Force-pushed `f077d761b`, CI green, armed into the
merge queue.

## Adjacent finding (filed separately, not in scope)

`systemd/devin-issue@.service`'s artifact-check ExecStopPost accepts only
"a claim branch exists" or "a PR from it" — but the step-4 blocked path
deletes the claim branch and opens no PR by design. Every devin worker
that correctly parks an issue fails its own dead-man and `Restart=on-failure`
burns three more claims on the already-parked issue. Observed live on
`devin-issue@fleet-ops-{7526,7572,7573}` (Result=exit-code, restart
counter 3). Filed as fleet-ops#8166.

## Verification

```
gh pr list -R Nishfleet/fleet-ops --state open --json number,createdAt \
  --jq '[.[] | select((now - (.createdAt | sub("[.]\\d+Z$"; "Z") | fromdate)) > 259200)] | length'
# -> 0 after #5112 merges; the issue's own termination loop (all 8 PRs
#    non-OPEN) passes the same way.
```
