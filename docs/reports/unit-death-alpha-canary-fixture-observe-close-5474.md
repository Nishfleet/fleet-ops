# Observe-close for #5474 — the [UNIT-DEATH] alpha record is a fixture; no unit `alpha` exists or ever did

fleet-ops#5474 (filed 2026-09-11T16:28:14Z under the `nish3451` login)
asks its claim to "claim it, diagnose, resume" a dead unit `alpha`,
recorded reason `beta`, journal block empty. The claim's finding: no
such unit exists on this host — the record is a stub with placeholder
values, already classified by a prior fleet pass as a canary fixture.
There is no unit to resume and no describable job to dispatch, so this
report is the disposition record the issue body asks for and the PR's
`Closes #5474` trailer performs the close, matching the established
observe-close pattern (the #7142 record in this directory; the #6665
record, PR #7972; the #4142 record, PR #7979; the #7234 record,
PR #7976).

## What was found

1. **The record does not match the unit-death dispatcher's output.**
   The fleet-ops#5456 A(ii) path (`resume_dispatch_unit` in the since-
   deleted `bin/stop-escalation-dispatch`) filed issues titled
   `[unit-death] <unit>.service — died, resume exhausted (hop=<N>)`
   with a `STOP-REASON:` path, a `detected:` timestamp and a real
   `<details>` journal tail, authored by `nishfleet-worker[bot]` via a
   minted App token. #5474 differs on every axis: title
   `[UNIT-DEATH] alpha (escalation exhausted)`, fields `- Unit: alpha`
   / `- Reason: beta` / `- Seen:`, a `-- No entries --` journal block,
   and author `nish3451` (a human login, not the dispatcher's bot
   identity). The phrasing "the escalation chain ... exhausted its
   budget (auditor 2-dispatch cap for the trip hash)" matches no
   emitter in repo history (`git log -S` for `trip hash`,
   `auditor 2-dispatch cap` and `exhausted its budget` finds no code
   that ever produced it) — the record was hand-authored.
2. **No unit `alpha` exists on netcup-rs2000, in any scope or in
   history.** `systemctl --user list-units --all`,
   `systemctl list-units --all` (system scope),
   `systemctl --user list-unit-files` and `ls ~/.config/systemd/user/`
   each contain no `alpha` entry; `journalctl --user -u 'alpha*'`
   reports `Failed to add filter for units: No data available` (no
   journal for any such unit, ever retained); a user-journal grep for
   `alpha` since 2026-09-10 returns only unrelated `union-alpha` seat
   lines and intake notes; `git log -S alpha` over the repo's
   `systemd/`, `etc/` and `config/` trees finds no unit file (the only
   hits are the `union-alpha` LiteLLM seat, a different thing). The
   live `STOP-REASON.json` names `fleet-seat-bench-truth.service`,
   unrelated.
3. **The fleet already classified the issue as a fixture.** A prior
   intake pass recorded in the user journal (2026-09-19 18:22 IST):
   `3455, 5474, 5751 | skipped-claim-lost — branches held (5474 is a
   canary fixture: `Unit: alpha, Reason: beta`, empty journal ...)`.
   The dispatch's `alpha`/`beta` pair are placeholder values, not a
   redaction — a real unit-death record always carries the unit's
   journal tail, and this one's is structurally empty.
4. **The machinery a real chain-exhaustion signal would come from is
   deleted.** The CAP-REACHED / 2-dispatch-cap path this record's
   wording imitates lived in the escalation tower, deleted 2026-09-18
   (`9f0cba02c`, "delete escalation-tower (16948 lines)"). The
   spec-gate refuse/relabel loop this issue sat in (172 comments,
   hourly `spec-gate: refused agent-ready` from 2026-09-11) emitted
   its last comment 2026-09-18T08:54Z and stopped with the same sweep.
5. **Why the issue was still open.** It sat at the agent-ready queue
   head for ten days, repeatedly skipped on a stale claim branch
   (intake journal notes, fleet-ops#7796/#7790), while the refuse/
   relabel loop ran. With the claim refreshed 2026-09-21T08:19:58Z the
   disposition is recorded here and the close lands through the
   merged-PR path — the close path the fleet adopted once the
   observe-to-close sweep was retired.

## Verification

- `gh issue view 5474 -R Nishfleet/fleet-ops --json author,body,
  labels` → author `nish3451` (is_bot false), label
  `agent-in-progress`, body fields `Unit: alpha` / `Reason: beta` /
  journal `-- No entries --`.
- `gh api repos/Nishfleet/fleet-ops/issues/5474/comments` → 172
  comments, all `nishfleet-worker[bot]` spec-gate refusals
  2026-09-11T16:49Z → 2026-09-18T08:54Z, then silence until the claim
  comment 2026-09-21T08:20Z.
- `systemctl --user list-units --all | grep -i alpha` → empty;
  `systemctl list-units --all | grep -i alpha` → empty;
  `systemctl --user list-unit-files | grep -i alpha` → empty;
  `ls ~/.config/systemd/user/ | grep -i alpha` → empty;
  `journalctl --user -u 'alpha*' -n 20` → `Failed to add filter for
  units: No data available`.
- `journalctl --user --since 2026-09-10 | grep -i alpha` → only
  `union-alpha` seat lines and intake notes, incl. the 2026-09-19
  `5474 is a canary fixture` classification quoted above.
- `git log --all -S 'trip hash'`, `-S 'auditor 2-dispatch cap'`,
  `-S 'exhausted its budget'` over fleet-ops history → no emitting
  code ever existed; `git log --all -S alpha -- systemd/ etc/ config/`
  → `union-alpha` seat hits only.
- `~/workspaces/agent-state/STOP-REASON.json` → names
  `fleet-seat-bench-truth.service` (2026-09-18), unrelated;
  `~/workspaces/agent-state/fleet-escalation-completion/` chain files
  contain no `alpha` reference.

run-proof: probes above ran live on netcup-rs2000 2026-09-21 ~13:55
IST against fleet-ops origin/main `cd3ab9112`; unit and journal state
via `systemctl`/`journalctl` user+system scopes; dispatcher output
shape quoted from `git show 9f0cba02c` (the deletion diff of
`bin/stop-escalation-dispatch`); issue authorship and comment history
via `gh api`/`gh issue view`; docs-only record — no unit, timer,
workflow or script path touched.

loose-ends: none — docs-only resolution record for a fixture
dispatch; nothing half-done.
