# Silent-drop ledger — swept 2026-09-11 (IST)

Source of the order: Nish, 2026-09-11 — "EVERY FINDING WILL BE QUEUED FOR FIXING
AND NOT DROPPED SILENTLY? NO DUCT TAPE ANYWHERE!!!". Trigger: the blind-audit
filing cap (1 finding/run) left 2161 panel-PASS findings since 2026-08-20
unfiled (fix in flight: unit `blind-audit-cap-fix-2`). This sweep covers every
OTHER place where a finding, verdict, alert, or work item can be capped,
truncated, sampled, or skipped without landing in a durable place the queue or
the hourly judges read.

Scope read (2026-09-11): repo-canonical `bin/`, `lib/`, `scripts/`, `prompts/`,
`systemd/` in `~/workspaces/tooling/fleet-ops`; installed copies under
`~/.local/bin` (symlinks → `fleet-ops-deploy-clone/bin/*`, deploy surface, not
source of truth) and `~/.local/lib/pi-packet` (flat copy of individual `lib/`
scripts; mirrors on deploy). Grep-then-read; grep alone was never treated as
evidence.

Canary: `tests/silent-drop-canary.test.sh` — fails when a new
findings-cap token (`MAX_FINDINGS`/`MAX_FILINGS`/`MAX_ISSUES`/`MAX_ACTIONS`/
`auto_file_cap`) or a swallow-on-failure `gh issue comment|create|edit …
|| true` appears in `bin/`/`lib/` without an allowlist entry plus a row here.

## Findings table

| # | file:line | What is dropped | Where it goes today | Disposition |
|---|-----------|-----------------|---------------------|-------------|
| 1 | `bin/fleet-blind-audit:92` (`AUDIT_MAX_FINDINGS` default 1) | Panel-PASS findings beyond the cap — `skipped: max findings reached` (line 764) | verdict log only (`REPORT_DIR/verdicts.jsonl`), nothing filed; 2161 findings unqueued since 2026-08-20 | (b) QUEUED — fix in flight: unit `blind-audit-cap-fix-2` (carry-over ledger; also fixes dedupe swallowing, geometry: worktree `fleet-ops` changes 2026-09-11). No duplicate issue filed. |
| 2 | `lib/scout-money-path-walk.mjs:40` (`MAX_FINDINGS = 4`) | Money-path findings beyond 4, silently discarded by `addFinding` with no count anywhere | stdout wagon report only (appended to the scout RESEARCH CONTEXT) | (a) FIXED in this PR — suppressed findings are now counted and a LOUD line is printed in the report body the scout judge reads |
| 3 | `bin/claim-reconcile:225` | Release notification comment when `gh issue comment` fails (`\|\| true`) | nowhere | (a) FIXED in this PR — failure now logs an ALERT line and returns 1 so the tick fails loudly and the next tick re-comments |
| 4 | `lib/fleet-questions.sh:297-306` (`fq_unfiled_count`) | Unfiled-question issues whose create fails: the seen-key was recorded BEFORE the create and failures vanished into `\|\| true` — never retried, never reported | nowhere | (a) FIXED in this PR — key is recorded only on successful create; a failed create logs an ALERT and is retried next run |
| 5 | `lib/spec-judge.sh:448,567,571,588,639,760` | 6 `gh issue comment … \|\| true` calls; worst is the judge failure-fallback "spec-judge unavailable" comment whose loss leaves the batch claimed unjudged with no record | log `$LOG` file only; nothing retryable | (b) QUEUED [fleet-ops#5438](https://github.com/Nishfleet/fleet-ops/issues/5438) — exact fix there; allowlisted in canary until it lands |
| 6 | `bin/lifecycle-label-sweep:461,480,516,547` | 4 notification comments (`\|\| true`) explaining label moves (reclassify, demote, observe-to-close) | nowhere on failure | (b) QUEUED [fleet-ops#5439](https://github.com/Nishfleet/fleet-ops/issues/5439) |
| 7 | `scripts/rewrite-0509-author.sh:311,334` | stage8 resume-PR link and stageR rollback-done notices (`\|\| true`) — dropped exactly at the two highest-stakes moments of a history rewrite | `$LOG` file only | (a) FIXED 2026-09-11 ([fleet-ops#5449](https://github.com/Nishfleet/fleet-ops/pull/5449), [fleet-ops#5440](https://github.com/Nishfleet/fleet-ops/issues/5440)) — rc captured, gh output kept in `$LOG`, ALERT logged on failure |
| 8 | `lib/pi-intake-tick.sh:2115,2232,2239,2299,2300,2317,2318,2385,2386,2462,2463` | Park/label/comment calls with `\|\| true` (observe-to-close, awaiting-runtime-gate parking, size-capsized) | issue keeps its old label → park re-derived and retried next tick (dedupe is by current label state, not a seen-key) | (c) BY-DESIGN — re-derivation is the carry-over; no finding is consumed |
| 9 | `bin/fleet-escalation-canary:634,664-668` (`auto_file_cap_per_tick`) | Mechanism-issue filings beyond the per-tick cap (`skipped_cap`) | LOUD `ESCALATION-CANARY-PENDING` line + tick increments `pending`; the uncovered/stale rows come back from the rule matrix every tick | (c) BY-DESIGN — cap + LOUD + carry-over by re-derivation (fleet-ops#479) |
| 10 | `lib/rule-enforcement.py:426-503` | Same cap, defined/validated by the matrix parser (source of truth for row 9) | n/a | (c) BY-DESIGN — companion to row 9 |
| 11 | `bin/fleet-role-gate-audit:148` (`auto_file_cap_per_tick // 5`) | Gate-audit failure filings beyond cap | LOUD + auto-file path as row 9; rows re-derived from the catalog each run | (c) BY-DESIGN — same mechanism class as row 9 |
| 12 | `bin/fleet-rulebook-redteam:44` (`RULEBOOK_MAX_FINDINGS=5`, line 330 break) | Red-team report findings beyond 5 | full findings report is written to `$REPORT_MD` on disk (time-stamped report dir) — capped only in what is FILLED | (b) QUEUED [fleet-ops#5441](https://github.com/Nishfleet/fleet-ops/issues/5441) — report is durable on disk, filings need the same carry-over ledger as row 1 |
| 13 | `lib/pi-intake-tick.sh:1948` (spec-judge fleet rate cap, `SPEC_JUDGE_RATE_MAX`) | Judge launches skipped when the hourly cap is hit ("skipped (fleet-wide rate cap reached)") | batch stays agent-ready, judging re-derived next tick | (c) BY-DESIGN — no work item is consumed; carry-over by re-derivation (fleet-ops#4801) |
| 14 | `lib/pi-intake-tick.sh:~1963,2029` (self-maintenance claim cap / skipped-capacity) | Claims and agent-ready claims beyond per-tick cap | issue stays agent-ready, re-derived every tick | (c) BY-DESIGN — fleet-ops#3254 |
| 15 | `bin/pi-audit-tally:412` (`head -c 160`) | Console-log truncation of a PASS reason judged keyword-only | full untruncated reasons persisted in the candidate's `.evidence-refusal-reasons` ledger and replayed into the escalate comment | (c) BY-DESIGN — the durable place exists (fleet-ops#3574/#3121) |
| 16 | `prompts/weekly-fleet-review.md:10` ("at most 5 specced agent-ready issues or decisions-ledger discards") | Weekly-review actions beyond 5 | decisions-ledger discards are the durable side-channel the prompt mandates | (c) BY-DESIGN — fleet-ops#1146 (max 5 actions + discards) |
| 17 | `prompts/scout.md:151-156` (`SCOUT_RESEARCH_FLOOR`, default 5) | Research-floor candidate filings beyond 5 | cap applies per run with a hard floor of 1 and explicit scout-candidate labels; unfiled remainder re-scored next run by the same floor rule | (c) BY-DESIGN — floor-plus-cap, carry-over by re-derivation (fleet-ops#4560/#4850) |
| 18 | `bin/hermes:13-32` (outbound message gate 3/24h) | Non-urgent outbound sends beyond the ceiling | always-on ledger in the gate itself (urgent bypass listed) | (c) BY-DESIGN — the gate has an always-on ledger (fleet-ops#1534) |
| 19 | `lib/pi-intake-tick.sh:2317` transit park failures (`\|\| true`) | Second occurrence of a park comment may be lost in rare dual failures (edit + comment failing together) | covered by row 8 carry-over: next tick re-parks and re-comments | (c) BY-DESIGN — same re-derivation as row 8 |

## Fixed in this PR (under 300 lines of code)

- `lib/scout-money-path-walk.mjs` — LOUD suppressed-findings count in the report body.
- `bin/claim-reconcile` — release comment failure is now an ALERT + rc 1, not `\|\| true`.
- `lib/fleet-questions.sh` — seen-key written only after a successful issue create; failed creates are alerted and retried next run.
- `tests/silent-drop-canary.test.sh` — the canary described at the top.

## Known-by-design exceptions in scope (listed to show they were checked)

- Weekly review max 5 actions + discards — fleet-ops#1146 (row 16).
- Self-maintenance claim budget — fleet-ops#3254 (row 14).
- Outbound message gate 3/24h — fleet-ops#1534 (row 18).
