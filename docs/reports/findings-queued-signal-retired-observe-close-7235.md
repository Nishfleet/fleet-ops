# Observe-close for #7235 — findings-queued/583c41ee recurred-finding: detector, tier1 runner and blind-audit are all retired on main

fleet-ops#7235 (filed 2026-09-16 by fleet-blind-audit) is a gap-audit
recurrence finding: failure class "finding named in chat, never filed"
(signal `findings-queued/583c41ee-f88b-4b2a-84c5-4f691f9de076`) fired
again after its closed fix #4612. It is the same signal as closed
sibling #7234 (resolved by PR #7976) — the same transcript produced 19
`fix(findings-queued)` issues on 2026-09-08/09 and 9 gap-audit filings,
one per closed fix issue; open siblings #7236–#7239 are the same signal.

By the time this claim ran, the failure class was dead twice over on
main — the detector that produced the signal and the blind-audit that
filed this issue were deleted in the same glue-sweep commit, and the
heartbeat tier1 that ran the detector is gone from the live unit set.
No code change remains; this report is the resolution record, matching
the established observe-close pattern (the #7234 record, PR #7976; the
#6665 record, PR #7972; the #6799 record, PR #7964; the #6499 record,
PR #7965; the #5272 record, PR #7992).

## What was found

1. **The dedup defect, verbatim.** `bin/fleet-findings-queued` ran on
   fleet-heartbeat tier1, scanned session JSONL inside a 24h window for
   ask-to-file phrases in assistant text, and auto-filed one issue per
   signal slug. Its dedupe read `gh issue list --state open` only
   (`open_json`) and logged `auto-file: $slug already open (deduped)` on
   a match — so a closed issue re-armed the same immutable transcript on
   the next hourly tick. The cited transcript
   (`~/.cursor/projects/home-nish-workspaces-tooling-fleet-ops-deploy/agent-transcripts/583c41ee-f88b-4b2a-84c5-4f691f9de076/583c41ee-f88b-4b2a-84c5-4f691f9de076.jsonl`)
   still sits on disk unchanged (103,453 bytes, mtime 2026-09-08 22:04
   IST). Closes on the 19 filings span 2026-09-08T23:54Z →
   2026-09-09T16:51Z — roughly one refire per heartbeat tick until the
   session aged out of the scan window. Had the organ lived, the durable
   fix would have been dedupe on the signal key across all issue states
   (or a resolved-signal suppression ledger); recorded for the
   postmortem — there is nothing left to patch.
2. **Both organs deleted on main in one commit.** `f851c86cf`
   ("chore(glue-sweep): delete meta-metrics-scorers (9558 lines, Jev
   0.73)", committed 2026-09-18 14:55 +0530, ancestor of origin/main)
   deleted `bin/fleet-findings-queued` (286 lines),
   `lib/findings-queued.py` (320), `bin/fleet-blind-audit` (1780),
   `bin/fleet-blind-audit-panel`, `lib/blind-audit-cadence.sh`,
   `lib/blind-audit-panel.py`, `prompts/blind-audit.md`,
   `systemd/fleet-blind-audit.{service,timer}` and all seven of their
   test files. `git cat-file -e origin/main:<path>` fails for each
   (re-verified this claim). `lib/findings_ledger.py`, the ledger writer
   the audit mirrored into, went in the follow-up `6fee069b6` ("cut
   (no-glue 3)", PR #7907).
3. **Installed version confirmed — the retirement is live, not just
   merged.** The deploy clone (live install source) HEAD is `c10a0a158`,
   equal to origin/main. On the live box 2026-09-21 ~01:55 IST:
   `systemctl --user cat fleet-blind-audit.service
   fleet-blind-audit.timer fleet-heartbeat.service
   fleet-heartbeat.timer fleet-heartbeat-tier1.service` reports "No
   files found" for all five; `~/.config/systemd/user/` and
   `~/.local/bin/` hold no blind-audit or findings-queued files;
   `crontab -l` has none. The tier1 scheduler the detector ran under is
   gone with the organ.
4. **The audit's "live open-issue" evidence was already stale at
   filing time.** #7235's body cites #4674 as the live open issue for
   the same signal; #4674 actually closed 2026-09-09T06:53:53Z — a week
   before the audit filed. The cited "closed fix" #4612 closed
   2026-09-09T02:54:53Z. The carry-over/replay layer re-panelled a stale
   row as live recurrence, the same defect class `cf8dd5609` fixed for
   dead-path machinery findings (fleet-ops#6568) before the whole organ
   retired.
5. **No live producer.** A repo-wide grep at `c10a0a158` for
   `findings-queued` / `findings_queued` / `blind-audit` / `blind_audit`
   matches only docs, reports, a README narrative line, a code comment
   in `template/extensions/cursor-provider/index.ts`, bench fixtures
   (`.fleet/bench7371/`), stale `__pycache__` blobs and scratch
   `.pr-body-*` records — no unit, timer, workflow, script or manifest
   entry can fire either name.

## Why deletion is the resolution

A recurred failure class is resolved by fixing its producer or retiring
it. Here the whole producer chain — the session-lint detector, the
heartbeat tier1 tick that ran it hourly, and the blind-audit that
converted the flood into recurrence filings — was deliberately removed
under the glue-sweep review (fleet-ops#7828; Jev-scored deletion), not
lost. The signal cannot re-fire: nothing on main or on the box scans
transcripts for unqueued offers, and nothing re-panels closed-fix
recurrences into gap-audit issues. The open siblings #7236–#7239 are
the same signal and resolve identically on their own claims. This PR's
`Closes #7235` performs the close — the same path the 2026-09-18/19
cuts adopted for retired-organ findings once the observe-to-close
machinery itself was swept.

## Verification

- `git merge-base --is-ancestor f851c86cf origin/main` → yes (origin/main `c10a0a158`).
- `git cat-file -e origin/main:bin/fleet-findings-queued`, `:bin/fleet-blind-audit`, `:lib/findings-queued.py`, `:lib/findings_ledger.py`, `:systemd/fleet-blind-audit.timer`, `:systemd/fleet-blind-audit.service`, `:prompts/blind-audit.md` → all absent on main.
- `gh issue view 4612 --json closedAt` → 2026-09-09T02:54:53Z (the "closed fix" the audit cites).
- `gh issue view 4674 --json closedAt` → 2026-09-09T06:53:53Z (closed a week before the audit's "live open-issue" claim).
- `gh issue list -R Nishfleet/fleet-ops --state all --search "583c41ee in:title findings-queued in:title"` → 19 issues; `… "583c41ee in:title gap-audit in:title"` → 9 (#7234 closed via PR #7976; #7235–#7239 open, same signal).
- `systemctl --user cat fleet-blind-audit.service fleet-blind-audit.timer fleet-heartbeat.service fleet-heartbeat.timer fleet-heartbeat-tier1.service` → "No files found" ×5.
- `ls ~/.config/systemd/user/`, `ls ~/.local/bin/`, `crontab -l` greps → zero hits for blind|findings|heartbeat.
- Deploy clone `git rev-parse HEAD` = `c10a0a158` = `git rev-parse origin/main` — live install source carries the deletion.
- `stat` on the cited transcript → present, 103,453 bytes, mtime 2026-09-08 22:04 IST — the immutable evidence the open-only dedup kept re-filing.

run-proof: probes above ran live on netcup-rs2000 2026-09-21 ~01:55 IST
(2026-09-20 ~20:25 UTC) against origin/main `c10a0a158`; commit ancestry
via `git merge-base --is-ancestor`; issue state via `gh issue
list/view`; unit presence via `systemctl --user cat` with
`XDG_RUNTIME_DIR=/run/user/1000`; docs-only record — no unit, timer,
workflow or script path touched.

loose-ends: siblings #7236–#7239 are the same signal's open gap-audit
filings and resolve identically on their own claims; nothing half-done.
