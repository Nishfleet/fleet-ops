# Observe-close for #4518 — 0509 direction question: resolved OPTION 2 (Acquisition), ledgered, live

Issue #4518 was filed by the hourly judge (fable-5.1-xhigh, under
fleet-ops#4456) on 2026-09-08 as a `question (Nish)`: `signups_24h=0
signups_30d=0`, last signup 2026-06-23, ~47 product PRs/day merging into
0509 — "where should product effort go?" It offered four options
(1 fix measurement, 2 acquisition, 3 activation, 4 deliberate hold) and
recommended 1 as precondition then 2.

The question is answered and the answer is executed. This report is the
resolution record; no new code is needed.

## Resolution path (all on the issue thread / landed on main)

- **Option 1 (precondition) ran first and settled the measurement:**
  0509#1872 closed COMPLETED via 0509 PR 1965 (merged
  2026-09-08T05:52Z), wiring the OAuth signup event. A fresh
  `measure.sh` run posted to #4518 on 2026-09-09 read
  `signups_24h=0 signups_30d=0 last_signup=2026-06-23` — the zero is
  real, not a blind spot.
- **Nish authorized the panel** 2026-09-08 23:55 IST ("queue fix" on
  "this work restores supply, it does not pick direction"), keeping veto
  via a later `decision-resolved:` comment.
- **Senior panel resolved the question:** 2-of-3 majority
  (devin/glm-5-2, senior/cursor-grok-4.6-high; the free GLM-5.3 seat was
  walled on all three attempts and skipped, not a dissent) posted
  `decision-resolved: OPTION 2 — ACQUISITION` on #4518 at
  2026-09-08T18:31:51Z. Target metric: **signups/week** (D1
  `user.createdAt` trailing 7d). Scope: unpaid distribution only —
  landing/compare pages, listings, SEO/AEO measured+owned-content;
  Reddit/community and digital-PR stay Nish-reserved per
  `config/geo-aeo-policy.json`; no paid spend; 0509 stays on the polish
  track. MATRIX-decided, Nish-vetoable.
- **Decision is ledgered:** vault
  `_system/shared-memory/decisions-ledger.md` §"2026-09-09 — 0509
  direction: Acquisition, metric signups/week (senior panel,
  MATRIX-decided, Nish-vetoable)" records the entry so it is never
  re-asked; overturn requires a superseding `decision-resolved:` on
  #4518.
- **Execution landed via #4562 → PR #4570** (merged
  2026-09-08T19:51:11Z, merge commit `e19b19c26`): `prompts/scout.md`
  gained the Direction section — `source: direction#4518` ranked above
  every other A.6 citation, a ≥half citation cap on filed 0509
  candidates, yield metric signups/week, `direction_cap: <cited>/<filed>`
  reporting — plus `lib/packet-assembly.sh` injection and a
  stale-question detector in `lib/fleet-questions.sh`.

## What still stands vs. what the sweep retired

- `prompts/scout.md` Direction section is on `origin/main` and in the
  deployed copy `~/.pi/agent/prompts/scout.md` (4 `direction#4518`
  citation lines in each), which `pi-scout@.service` invokes as
  `/scout <repo>` hourly.
- `lib/packet-assembly.sh`, `lib/fleet-questions.sh` and the #4570
  tests were deleted in the 2026-09-18/19 no-glue sweep (`6fee069b6`,
  PR #7907) — the injection shim and detector went with their organs;
  the prompt-side Direction contract survived and is the live mechanism.
- Live evidence (2026-09-21): `pi-scout@0509.timer` armed (hourly, last
  run ~3h before this check); `gh issue list -R Nishfleet/0509 --search
  "direction#4518"` returns 33 issues citing the direction — the
  acquisition supply line is running.

## Gate/claim history

A `pi-issue-fleet-ops-4518` run claimed the issue 2026-09-18T14:01:37Z
and parked it `blocked-on: nish-decision` — although the
`decision-resolved:` comment already existed since 2026-09-08. The
gate-release of 2026-09-20T21:33:23Z released it to `agent-ready`
citing that same comment as evidence, and dispatch re-claimed it for
`devin-issue@fleet-ops-4518.service` at 2026-09-20T21:40:06Z. The
question was never un-answered; only the close record was missing.

## Verification (2026-09-21, worktree claim/issue-4518 at 1f45de170)

- `gh issue view 4518 -R Nishfleet/fleet-ops --comments`: the
  `decision-resolved: OPTION 2 — ACQUISITION` comment (2026-09-08
  T18:31:51Z) and the gate-release ledger line are present on the
  thread.
- `git merge-base --is-ancestor e19b19c26 origin/main` — PR #4570's
  merge commit is an ancestor of main.
- `grep -c direction#4518 prompts/scout.md` → 4 on origin/main; 4 in
  `~/.pi/agent/prompts/scout.md` (deployed).
- `systemctl --user list-timers` shows `pi-scout@0509.timer` armed.
- `gh issue list -R Nishfleet/0509 --search "direction#4518"` → 33
  citing issues (open and closed).
- `grep` for `lib/fleet-questions.sh` / `lib/packet-assembly.sh` on
  main → both absent; `git log --follow` ends at deletion commit
  `6fee069b6` (PR #7907).

## Disposition

Resolved. The question has a recorded, Nish-vetoable answer; the answer
is ledgered in the canonical decisions ledger and is live in the scout
prompt and in filed 0509 work. This report supplies the close evidence;
no detector, script or config change is required.
