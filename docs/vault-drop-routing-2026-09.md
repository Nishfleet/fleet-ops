# Jev shadow: vault agent-drop routing (fleet-ops#7766)

Shadow read of the site `vault-drop-routing`. For each agent-drop capture
Jev answers two questions: which project or area it belongs to, and what
note type it is. The answers are logged beside the placement already
written into the capture. Advisory only. Nothing here writes to the vault.

The first delivery of this report (PR #8192) was graded D and reverted by
#8234. This is the redo. The numbers below are computed from
`docs/reports/vault-drop-routing-2026-09.jsonl`, which is committed next to
this file, so anyone can recompute them.

## Run

- 500 captures, the newest 500 `.md` files under
  `00 Inbox/agent-drop/` in `/home/nish/workspaces/tooling/nish-vault` by
  mtime. 500 scored, 0 skipped. Six calls came back 502 or 503 on the
  first pass and were retried once; all six then returned 200.
- Window: responses stamped 2026-09-22T05:45:41Z to 2026-09-22T05:48:36Z.
- Rows: `docs/reports/vault-drop-routing-2026-09.jsonl`, 500 lines,
  468575 bytes, sha256
  `e6f6a5d96156d1b63a0baaca8eaf6308d76a732bac3289f8ec332b9f785f0609`.
  The same rows are appended to
  `~/.local/state/pi-packet/jev/vault-drop-routing.jsonl` on this host;
  the committed file is the evidence, the host file is the log.
- Usage: 844372 input tokens, 98044 output tokens. At the proxy's priced
  rate of $0.042 per million input tokens that is about $0.035.
- No vault writes. The `*.sync-conflict-*` check returned nothing before
  the run, so the reads went ahead.

## The questions

Both are `choice` questions, asked together in one POST per capture,
because they are independent judgments over the same state.

`area`, one option per vault area: `fleet-ops`, `0509`, `babystoryapp`,
`drishti`, `hermes`, `hoteldealsapp`, `promptly`, `siterep`, `tinystudio`,
`nish-vault`, `nish`, `agent-infra`, `global`, `other`. The criteria follow
the vault's top level. `02 Projects/` holds the nine project names.
`global` is a fleet-wide standing rule. `agent-infra` is machinery that is
not a repo: `agent-state`, `agent-worktrees`, `memory`, `extensions`,
seats. `nish` is Nish himself or a note whose only subject is his shell
cwd. `other` is the catch-all.

`note_type`, five options. `decision` settles a durable choice or rule.
`runbook` is a procedure someone would follow again. `outcome` is a result
of real work: what changed, what was proved, what was measured.
`reference` is a durable fact that is neither a result nor a decision.
`noise` has no durable value: a duplicate, or a pure status ping.

State per call: the capture text capped at 5200 characters, its path, and
a one-paragraph summary of the vault's top-level map. One POST to
`http://127.0.0.1:4000/jev` with the `LITELLM_JEV_KEY` bearer. The body is
`{"state": {...}, "questions": {...}}`, which is the contract the proxy
forwards to the v4 evaluation endpoint.

## The baseline

There is no live curator. `_system/shared-memory/agent-contract.md` says so
outright: "There are no receipts or curators; memory is the session plus
this markdown." What survives of the old curator's placement is the
frontmatter the capture writer stamps:

- `memory_scope` on 467 of 500 captures (33 absent),
- `memory_kind` on 484 of 500 (16 absent).

Scopes are project ids, not area names, so the comparison maps them:

- `projects/<name>` and `projects/<name>-<8+ hex>` map to `<name>` where
  `<name>` is one of the nine projects.
- `projects/agent-state-*`, `agent-worktrees-*`, `memory-*`,
  `extensions-*`, `seats-*` map to `agent-infra`.
- `projects/nish-*` maps to `nish`. `global` stays `global`.
- Anything else (`kb/...`, an unknown project slug) maps to `other`.
  Four captures land there.

Kinds map as `outcome` to `outcome`, `rule` to `decision`, `feedback` and
`research` to `reference`, `session-draft` and `capture` to `noise`. The
mapping is stated here because the agreement numbers depend on it.

## Verdict

| metric | value | 15% gate |
|---|---|---|
| agreement with the stamped placement, area | 421/467 = **90.1%** | — |
| agreement with the stamped placement, note type | 472/484 = **97.5%** | — |
| confident (p ≥ 0.9) agreement, area | 353/371 = **95.1%** | — |
| confident (p ≥ 0.9) agreement, note type | 463/464 = **99.8%** | — |
| confident disagreements, area | 18/371 = **4.9%** | PASS |
| confident disagreements, note type | 1/464 = **0.2%** | PASS |

`p` is the probability of the chosen option. Both confident-disagreement
rates are under the 15% no-go line in `docs/jev-benchmark-2026-09.md`.

## Confident disagreements, for a human pass

Read against the capture text, every one of the 18 is the stamped scope
being wrong and Jev being right. The writer stamps the cwd it happened to
be in. Jev reads the note.

The whole `projects/nish-*` group is one bug. Eight captures about fleet
work are stamped as Nish's personal project because the session's shell was
there: the 0509 green-deploy follow-up, the hermes gateway rewire (twice),
the siterep.net uptime probe, the fleet-ops#5477 seam match, the
fleet-ops#3447 packet-size ceiling, and the merged-PR-close watchdog repair
(twice).

`global` is stamped on notes that are about one repo. The LiteLLM P4
drills, the unit-escalation false-trip fix, the #6610 stop-gate scoping,
and the pi-scout recovery are all fleet-ops work.

`agent-worktrees-*` is stamped on three notes whose subject is the repo the
worktree belongs to, not the worktree: 0509#3486, fleet-ops#6814, and
0509#2383.

The remaining three are single bad slugs. `kb/10-products/records/2026` on
the 0509 paid-quality-wedge feedback. `projects/nish-vault-*` on a note
tracing a Cloudflare D1 rows-written overage. `projects/porkbun-mcp-server-*`
on a note about Cursor and Devin not responding on the Mac.

Note type has one confident disagreement: a capture the writer marked
`capture` (mapped to noise) that Jev calls an `outcome`. It is the same
LiteLLM P4 drills note, and it does record work that was done, so the
outcome call is the defensible one.

## What this does not do

No band edge is applied. `config/jev-bands.json` does not exist on main
after the glue wipe, and nothing reads one. The 0.9 line used above is the
confident-positive edge the issue's own gate states, not a value loaded
from a table. Routing stays advisory: the report is the deliverable, and
scoring of the site belongs to fleet-ops#7754.
