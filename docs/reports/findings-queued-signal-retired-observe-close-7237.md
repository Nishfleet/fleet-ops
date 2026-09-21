# Observe-close for #7237 — sibling filing of the findings-queued/583c41ee flood already retired on main (see the #7234 record, PR #7976)

fleet-ops#7237 (filed 2026-09-16 by fleet-blind-audit) is a gap-audit
recurrence finding: failure class "finding named in chat, never filed"
(signal `findings-queued/583c41ee-f88b-4b2a-84c5-4f691f9de076`) fired
again after its closed fix #4594. It is one of the nine gap-audit
filings for that signal — filed by the *same audit run* as the sibling
record #7234 (both bodies carry `*Filed by fleet-blind-audit at
2026-09-16T22:03:27Z*`; the duplicate-detector comment on this thread
scores the sibling pair #7234/#7237 at 1.00). The umbrella observe-close
record for the flood lives at
`docs/reports/findings-queued-signal-retired-observe-close-7234.md`
(PR #7976, merged 2026-09-20) and stated "siblings #7235–#7239 resolve
identically on their own claims"; this is #7237's own claim, with the
probes re-run fresh at the current tip rather than copied. Siblings
already resolved this way: #7235 (PR #7993, merged 2026-09-20) and
#7236 (PR #7994).

## What was found on this claim's probes

1. **Nothing to fix on main.** The producer chain is deleted:
   `git cat-file -e origin/main:<path>` fails for
   `bin/fleet-findings-queued`, `bin/fleet-blind-audit`,
   `lib/findings-queued.py`, `lib/findings_ledger.py`,
   `systemd/fleet-blind-audit.service`,
   `systemd/fleet-blind-audit.timer`; the glue-sweep commit `f851c86cf`
   that deleted the detector, blind-audit organs and their timers is an
   ancestor of origin/main (`git merge-base --is-ancestor` → yes,
   origin/main `c0d6dbeac`). Repo-wide `git grep` on origin/main for
   `findings-queued`, `findings_queued`, `fleet-blind-audit` matches
   only docs/records prose, `.fleet/bench7371` bench fixtures and
   pasted `.pr-body-*` scratch records — `.github` and `tests` have
   zero hits, so no script, workflow, manifest or unit file can
   resurrect the class.
2. **The retirement is installed and live on the box.** The deploy
   clone (live install source) HEAD is `c0d6dbeac`, equal to
   origin/main. Live probes 2026-09-21: `systemctl --user list-units
   --state=failed` → 0 loaded units; `list-units`/`list-timers` greps
   for blind-audit/findings/heartbeat-tier1 → no match;
   `~/.config/systemd/user/`, `~/.local/bin/`, `crontab -l` greps →
   zero hits. Nothing armed can run the detector or the audit again.
3. **The audit's "live open-issue" evidence was stale at filing
   time.** #7237's body cites `live open-issue: #4674`; #4674 actually
   closed 2026-09-09T06:53:53Z — a week before the audit filed at
   2026-09-16T22:03:27Z. The replay layer re-panelled closed rows as
   live recurrence (defect of an organ that no longer exists). The
   body's cited closed fix #4594 checks out (closedAt
   2026-09-09T00:54:40Z).
4. **The immutable evidence still sits on disk.**
   `~/.cursor/projects/home-nish-workspaces-tooling-fleet-ops-deploy/agent-transcripts/583c41ee-f88b-4b2a-84c5-4f691f9de076/583c41ee-f88b-4b2a-84c5-4f691f9de076.jsonl`
   — 103,453 bytes, mtime 2026-09-08 22:04:12 IST, unchanged. The
   open-issue-only dedupe defect in the deleted detector kept re-filing
   against this transcript on every hourly tick (19
   `fix(findings-queued)` filings 2026-09-08/09, then 9 gap-audit
   filings #7234–#7239); with the organ deleted there is no scanner
   left to re-file against it. The audit report directory the body
   cites (`fleet-blind-audit/reports/20260916T220327Z`) is gone from
   disk — the whole `fleet-blind-audit/reports/` parent no longer
   exists.
5. **Status of the signal's issue cluster.** Title-restricted search
   for `583c41ee` returns 28 issues — 19 `fix(findings-queued)`
   filings from the 2026-09-08/09 flood plus the 9 gap-audit filings
   `[4680, 4788, 5478, 7234, 7235, 7236, 7237, 7238, 7239]`. Closed:
   the three flood-week filings, #7234 via PR #7976, #7235 via PR
   #7993, #7236 via PR #7994. Still open: #7237 (this), #7238, #7239
   — each resolves identically on its own claim; this PR closes only
   #7237.

## Why a record and not a code change

A recurred failure class is resolved by fixing or retiring its
producer. The whole producer chain of the 583c41ee flood — the
session-lint detector, its hourly heartbeat-tier1 runner, and the
blind-audit that filed recurrence issues from stale rows — was
deliberately removed on main under the glue-sweep review
(fleet-ops#7828) before this issue's first claim, and retired on the
box. The deferred durable fix named in the #7234 record (dedupe on the
signal key across all states, or a resolved-signal suppression ledger)
is recorded there for the postmortem; there is no organ left to patch
on #7237, and re-adding one would reinstate a retired failure surface.
This report is the observe-to-close resolution, matching the
established pattern for retired-organ findings (the #6665 record, PR
#7972; the #6799 record, PR #7964; the #6499 record, PR #7965; the
umbrella #7234 record, PR #7976; siblings #7235/#7236 via #7993/#7994).

## Verification

- `git merge-base --is-ancestor f851c86cf origin/main` → yes (origin/main
  `c0d6dbeac`).
- `git cat-file -e origin/main:bin/fleet-findings-queued`,
  `:bin/fleet-blind-audit`, `:lib/findings-queued.py`,
  `:lib/findings_ledger.py`, `:systemd/fleet-blind-audit.service`,
  `:systemd/fleet-blind-audit.timer` → all absent on main.
- `git grep -il -e findings_queued -e fleet-findings-queued -e
  fleet-blind-audit origin/main -- .github tests` → no match.
- `git grep -il -e findings-queued -e findings_queued -e blind-audit
  origin/main -- .` → only docs/records prose, `.fleet/bench7371`
  fixtures, pasted `.pr-body-*` scratch records; no runtime path.
- `systemctl --user list-units --state=failed` → 0 loaded units (with
  `XDG_RUNTIME_DIR` set); blind-audit/findings/heartbeat-tier1 greps on
  `list-units` and `list-timers` → no match; `ls
  ~/.config/systemd/user/`, `ls ~/.local/bin/`, `crontab -l` greps →
  zero hits.
- `gh issue view 4594 --json closedAt` → 2026-09-09T00:54:40Z (the
  closed fix this issue cites); `gh issue view 4674 --json closedAt` →
  2026-09-09T06:53:53Z (closed before the audit filed #7237 at
  2026-09-16T22:03:27Z — evidence stale at filing).
- `gh issue list -R Nishfleet/fleet-ops --state all --search "583c41ee
  in:title"` → 28 issues (19 fix-findings + 9 gap-audit — confirmed by
  separate `"583c41ee in:title gap-audit in:title"` search → 9, ids and
  states listed above); still OPEN: #7237, #7238, #7239.
- `stat` on the cited transcript → present, 103,453 bytes, mtime
  2026-09-08 22:04:12 IST.
- `ls /home/nish/workspaces/agent-state/fleet-blind-audit/reports/` →
  ENOENT — the audited report directory is gone from disk entirely.

run-proof: probes above ran live on netcup-rs2000 2026-09-21 ~01:20 UTC
(this claim) against origin/main `c0d6dbeac`; commit ancestry via
`git merge-base --is-ancestor`; issue state via `gh issue list/view`;
unit presence via `systemctl --user list-units/list-timers` with
`XDG_RUNTIME_DIR=/run/user/1000`; docs-only record — no unit, timer,
workflow or script path touched.

loose-ends: siblings #7238/#7239 are the same signal's open gap-audit
filings and resolve identically on their own claims; nothing half-done
here.
