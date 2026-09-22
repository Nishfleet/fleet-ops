# Jev shadow: vault agent-drop routing (fleet-ops#7766)

Shadow run + read for the site `vault-drop-routing`: for each agent-drop
capture, Jev answers **which project/area** the capture belongs to and
**what note type** it is. Logged beside the deterministic path-rule
placement, advisory only, no vault writes.

- Run: 2026-09-22T01:19Z–01:22Z, last 500 agent-drop `.md` captures by mtime
  (2026-09-11T07:48Z → 2026-09-22T~03:40Z IST), **499 scored, 1 transport
  failure skipped** (no synthetic row).
- Log: `~/.local/state/pi-packet/jev/vault-drop-routing.jsonl`, 499 rows,
  mode 0600, 607344 bytes,
  sha256 `81ea05ad04981dbbac918f87fa1685dde3bc2ff29ea5b9b9926d3eb76d28c333`.
- Band row: `config/jev-bands.json` → `vault-drop-routing` = `{act_hi 0.9,
  review_lo 0.1}`, **log-only** (no edge applied). Registered for scoring
  with fleet-ops#7754.
- Row stamps `act_hi: null`: the site row was added by this PR *after* the
  run, so the shared-helper band read found no entry and failed open. The
  confident buckets below use `p >= 0.9`, the `act_hi` this PR pins.
- No vault writes; every read was behind the `*.sync-conflict-*` guard
  (none present before or during the run).

## Verdict

| metric | value | 15% gate |
|---|---|---|
| agreement with the path rule — area | 384/469 = **81.9%** | — |
| agreement with the path rule — note type | 457/486 = **94.0%** | — |
| confident (p≥0.9) agreement — area | 320/346 = **92.5%** | — |
| confident (p≥0.9) agreement — note type | 444/453 = **98.0%** | — |
| independent relabel, confident — area | 1 disagreement / 85 = **1.2%** | PASS |
| independent relabel, confident — note type | 7 / 89 = **7.9%** | PASS |

Both confident-bucket disagreement rates are under the 15% no-go line from
`docs/jev-benchmark-2026-09.md`. On the 26 captures where Jev confidently
contradicted the path rule on **area**, the independent relabel sided with
Jev 25 times, with the path rule 0 times (1 ambiguous).

## The questions and the state

Q1 `area` — `choice`, one option per vault area:
`fleet-ops`, `0509`, `babystoryapp`, `drishti`, `hermes`, `hoteldealsapp`,
`promptly`, `siterep`, `tinystudio`, `nish-vault`, `nish`, `agent-infra`,
`global`, `other`. Criteria are the vault's top-level map (`02 Projects/`
subdirs, plus `global` for fleet-wide standing rules and `agent-infra` for
`agent-state`/`agent-worktrees`/`memory`/`extensions`/seats paths).
`nish` is the catch for Nish's shell cwd; `other` is the catch-all.

Q2 `note_type` — `choice` of 5: `decision` (settles a durable choice or
rule — `04 Decisions`, standing orders, adopted plans), `runbook`
(repeatable procedure — `05 Playbooks`), `outcome` (a result of real work:
what changed/proved/measured), `reference` (durable fact that is not a
result or a decision — `03 Knowledge`, feedback records), `noise` (no
durable value: a duplicate of an already-recorded item or a pure status
ping).

State = the capture text (body, capped at 5200 chars) + a vault index
summary (the top-level map and the `02 Projects/` list). Sent through the
shared helper POST contract from `prompts/worker.md` (`post_jev`: model
`typesafe-ai/jev`, one POST to `127.0.0.1:4000/jev`, `Bearer` seat key read
inside the child from `~/.config/fleet-ops/seats/typesafe-jev.env`). The
run itself used a transient copy of that heredoc (no-glue forbids a new
persistent script); no vault read left the host and no capture text is
committed.

## Baseline: "the curator's placement"

The memory curator organ was deleted 2026-09-18 12:30 UTC in `efaa7fa57`
("cut(memory-vault): delete the memoryctl loop, the vault linters and their
units") — about 2.5h before this issue was filed — so for this window there
is no live curator to compare against. Its placement **value** survives in
the capture frontmatter the capture path writes:

- `memory_scope` → project/area, present on 469/499 captures (30 empty,
  including 8 with no frontmatter at all);
- `memory_kind` → note type, present on 486/499.

These are the deterministic path-rule values the curator echoed verbatim
into the compiled tree (`writer_surface: "curator"`,
`writer_model: "deterministic"`). The compiled tree itself is effectively
absent for this window: **1 of 499** captures has a compiled entry
(`failure-response-standing-order` → `global`). So the comparison below is
against the path rule, which is the only recoverable form of "the curator's
placement".

`memory_kind` → `note_type` map used for the comparison (lossy, stated so
the numbers are replayable): `outcome→outcome`, `session-draft→reference`,
`feedback→reference`, `rule→decision`, `capture→reference`,
`research→reference`, `lesson→runbook`.

## Where Jev disagrees with the path rule

The disagreement is concentrated, and it is exactly where a path rule
cannot read intent:

| raw `memory_scope` | captures | Jev moves it |
|---|---|---|
| `projects/nish-*` (Nish's shell cwd) | 15 | 15/15 to the real project |
| `global` | 30 | 30/30 to `fleet-ops` |
| `projects/agent-worktrees-*` | 3 | 3/3 to the real repo |
| `projects/agent-state-*` | 12 | 8/12 |
| `projects/fleet-ops-*` | 331 | 24/331 |
| `projects/0509` | 69 | 0/69 |

`projects/nish-*` is a path artifact — the capture ran in Nish's shell
workspace, so the rule files a 0509 deploy fix, a siterep probe and a
hermes gateway rewire under "nish". Jev recovers the real project every
time. `global` is the same failure in the other direction: the rule files
fleet standing orders and judge runs as vault-global; Jev files them under
the project they govern. `0509` is 100% stable. Bulk agreement (81.9%)
is high because the bulk is `fleet-ops` and `0509` and the rule is usually
right there.

## Independent relabel (100 items) and the 15% gate

Protocol: 100 captures = the 33 captures where Jev was confident
(p≥0.9) **and** disagreed with the path rule (26 area + 9 type, 2
overlap) + 67 confident agreements drawn at random with seed 7766. A
second pass (the worker model, not Jev) relabelled each capture's `area`
and `note_type` from the **body only** — frontmatter stripped, so the
relabeller could not see the path rule or Jev's answer. 100/100 labelled.

| bucket | area | note type |
|---|---|---|
| all 100 (any p) | 7/100 = 7.0% | 12/100 = 12.0% |
| Jev confident (p≥0.9) | 1/85 = **1.2%** | 7/89 = **7.9%** |
| sided with Jev on confident-vs-rule items | 25 | 6 |
| sided with the path rule | 0 | 2 |
| sided with neither | 1 | 1 |

**Gate: PASS on both.** Jev's confident area calls are near-perfect
against an independent reader (98.8% precision). The type result passes at
7.9%, but read it with the two grey zones below — both are definitional,
not random error.

## Confident disagreements for a human pass

### Area (26) — `path rule → Jev` at p≥0.9

| capture | rule | Jev | p |
|---|---|---|---|
| `2026-09-17T18-54-12Z-...-recover-failed-pi-...` | global | fleet-ops | 1.00 |
| `2026-09-17T18-36-50Z-...-record-scout-repai...` | global | fleet-ops | 0.97 |
| `2026-09-17T13-36-26Z-...-diagnose-cursor-devin...` | other | fleet-ops | 1.00 |
| `2026-09-17T10-45-14Z-...-trace-a-93-cloudflare-...` | nish-vault | 0509 | 1.00 |
| `2026-09-14T17-36-47Z-...-nishfleet-0509-238...` | agent-infra | 0509 | 0.99 |
| `feedback-20260914T164024Z-...-failure-response-standi...` | global | 0509 | 0.93 |
| `2026-09-14T13-39-31Z-...-fleet-ops-6814-dep...` | agent-infra | fleet-ops | 0.99 |
| `2026-09-14T12-03-27Z-...-0509-3486-directio...` | agent-infra | 0509 | 1.00 |
| `2026-09-14T09-47-05Z-...-repair-failed-flee...` | nish | fleet-ops | 0.99 |
| `2026-09-14T09-46-54Z-...-repair-failed-flee...` | nish | fleet-ops | 0.97 |
| `2026-09-14T00-46-08Z-...-fleet-ops-6610-sco...` | global | fleet-ops | 1.00 |
| `feedback-20260913T074032Z-...-failure-response-standi...` | global | fleet-ops | 0.96 |
| `2026-09-13T06-18-05Z-...-repair-failed-scou...` | global | fleet-ops | 1.00 |
| `2026-09-13T06-09-14Z-...-repair-failed-scou...` | global | fleet-ops | 1.00 |
| `2026-09-12-litellm-p4-drills.md` | global | fleet-ops | 1.00 |
| `2026-09-12T08-51-12Z-...-diagnose-fix-unit-...` | global | fleet-ops | 1.00 |
| `2026-09-12T03-29-22Z-...-salvage-and-finish...` | fleet-ops | 0509 | 1.00 |
| `2026-09-12T02-35-58Z-...-fleet-ops-3447-wor...` | nish | fleet-ops | 1.00 |
| `feedback-20260911T225515Z-...-prj-20260822-0509-paid-...` | other | 0509 | 0.97 |
| `2026-09-11T17-49-07Z-...-fleet-ops-5477-man...` | nish | fleet-ops | 1.00 |
| `2026-09-11T17-33-21Z-...-senior-auditor-dia...` | nish | fleet-ops | 0.95 |
| `2026-09-11T17-04-55Z-...-diagnose-siterep-n...` | nish | siterep | 1.00 |
| `2026-09-11T16-10-21Z-...-canonical-findings...` | global | fleet-ops | 0.99 |
| `2026-09-11T15-31-56Z-...-re-wire-hermes-he...` | nish | hermes | 1.00 |
| `2026-09-11T15-27-47Z-...-re-wire-hermes-he...` | nish | hermes | 1.00 |
| `2026-09-11T10-21-53Z-...-0509-green-deploy-...` | nish | 0509 | 0.97 |

The independent relabel agreed with Jev on 25 of these 26 (0 sided with the
path rule). The one it called differently is
`feedback-20260914T164024Z-...-failure-response-standi...` — Nish's
failure-response standing-order change log: the relabel filed it
`fleet-ops`, Jev read `0509` at 0.93, and the rule read `global`; all three
have a case.

### Note type (9) — `memory_kind → Jev` at p≥0.9

| capture | kind | Jev | p | independent relabel |
|---|---|---|---|---|
| `2026-09-18T19-34-45Z-session-draft-21861e06.md` | session-draft | outcome | 0.96 | outcome |
| `2026-09-17T22-11-35Z-session-draft-12ff63da.md` | session-draft | outcome | 0.90 | outcome |
| `feedback-20260913T074032Z-...-failure-response-standi...` | feedback | outcome | 0.95 | reference |
| `feedback-20260913T050059Z-...-failure-response-standi...` | feedback | outcome | 0.92 | reference |
| `2026-09-12T22-02-31Z-session-draft-12ff63da.md` | session-draft | outcome | 0.91 | noise (duplicate of `12ff63da`) |
| `2026-09-12-litellm-p4-drills.md` | capture | outcome | 1.00 | outcome |
| `2026-09-12T09-03-37Z-session-draft-02b7ee9c.md` | session-draft | outcome | 0.90 | outcome |
| `2026-09-12T09-03-37Z-session-draft-a9b4df7a.md` | session-draft | outcome | 0.97 | outcome |
| `2026-09-12T09-03-37Z-session-draft-615fa77b.md` | session-draft | outcome | 0.94 | outcome |

All 9 are `session-draft` or `feedback` records that the path rule maps to
`reference` and Jev calls `outcome`; the independent reader sided with Jev
on 6 of 9. The two grey zones, for the human pass:

- **`session-draft` with real landed work is an outcome.** A session draft
  whose final message records merged PRs, live proofs and repairs is a
  result, not a reference note. The relabel sided with Jev on 6 of the 9; where it did not, 2 were the
  feedback records (reference) and 1 was a near-duplicate draft (noise).
- **Near-duplicates: `noise` or `outcome`?** The relabel called 5
  duplicated captures `noise` where Jev called them `outcome` (e.g. the
  same repair receipt captured twice, the same session captured under two
  ids). This is the one place the independent pass and Jev systematically
  differ, and it is a taxonomy call — "noise" as defined includes
  duplicates, but Jev almost never predicts `noise` (8/499, all
  low-confidence session drafts, p 0.44–0.96). If the human pass rules
  duplicates are noise, Jev's confident type precision is 98.0% → 96.9%
  (still far under the gate); if duplicates are outcome, the 7.9% is
  almost entirely definitional.
- `feedback` records: Jev calls the "this rule helped" receipts `outcome`;
  the relabel called them `reference`. Two items.

## Notes, limits, loose ends

- One transport failure in 500 calls (retried once, then skipped rather
  than writing a synthetic row) — hence 499.
- The relabel is one independent pass by the worker model, not a second
  curator; the 67-item random fill was labelled knowing only run-level
  distributions, and the 33 disagreement items were labelled before any
  per-item Jev answer was inspected.
- Jev's non-`outcome` calls are rare (8 `noise`, 4 `reference`, 4
  `decision`, 1 `runbook`), so the informative signal over the path rule is
  the **area** axis; the type axis mostly confirms the rule.
- Out-of-scope observation, routed to Nish (security class, not acted on):
  `00 Inbox/agent-drop/claude/vps/2026-09-12T09-03-37Z-session-draft-615fa77b.md`
  captures a session in which a raw provider key was pasted into the
  prompt; the value is not reproduced here. The agent-drop path therefore
  receives live credentials.
- No vault writes were made; the vault's pre-existing deleted `06 Council`
  files were left untouched.
- `loose-ends: vault-drop-routing-log-act-hi-null` — the 499 logged rows
  stamp `act_hi: null` because the band row landed after the run; the
  confident edge actually used (0.9) is the value this PR pins, and the
  log is replayable from the sha256 above.
