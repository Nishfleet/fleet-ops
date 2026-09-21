# Doc-drift sweep — always-loaded agent files + vault standing rules (#7452)

Advisory. Date 2026-09-22. Base `1b151b2428f8`.

Child of the Jev epic (#7370). Site `doc-drift-sweep`. Reuses the LiteLLM `/jev`
pass-through (no new script, per step 5 of the worker packet) and the committed
`docs/reports/` convention of the sibling observe-close reports.

## What this answers

For every paragraph in the three surfaces Pi loads or defers to, does the prose
still match the code and live state? Each paragraph gets:

- `stale` (boolean, Jev probability) — a referenced artifact/unit/command is
  deleted or the described organ/state no longer exists;
- `contradicts` (boolean, Jev probability) — it directly conflicts with another
  authoritative source or verified live state;
- `fix_kind` (choice) — `delete` / `update` / `keep`.

Per the orchestrator decision on this issue, evidence is the read-only live status
of each referenced artifact, with a full paragraph and a line/byte anchor — a Jev
probability alone is **not** drift evidence. Unknowns are retained explicitly.

## Method (reproducible, no new files executed)

1. Paragraphs are split on blank lines and on top-level bullets; each keeps its
   full text (never truncated), `surface:start-end` anchor and a sha256 of the
   paragraph body.
2. For every backtick span that names a path, systemd unit or command, the sweep
   probes live status read-only: `test -e`, `systemctl --user cat`, `command -v`.
3. Each chunk of 8 paragraphs is one `POST 127.0.0.1:4000/jev` with a question
   record (`stale__<id>`, `contradicts__<id>`, `fix_kind__<id>`); answers and
   per-call usage are written to `doc-drift-sweep-7452.jsonl`.
4. The `live_state` field in each Jev state includes the verified 2026-09-22 facts
   (glue-sweep deletions, the gardener weekly organ, the public-repo hygiene rule).

One `/jev` POST failed with **HTTP 503 Service Unavailable** on the first pass;
the 8 affected paragraphs were re-graded one-per-call on retry, so coverage is
complete (96/96).

## Coverage

| surface | paragraphs graded | with referenced artifacts |
|---|---|---|
| pi-AGENTS.md | 42 | 6 |
| claude-CLAUDE.md | 32 | 6 |
| vault-rules.md | 22 | 1 |

Totals: 96 paragraphs, 26 with `stale` >= 0.5, 13 with
`contradicts` >= 0.5, fix_kind {'update': 24, 'keep': 72}.

## Top 30 by Jev stale probability

| # | paragraph (surface:lines) | stale | contra | fix_kind | evidence / note |
|---|---|---|---|---|---|
| 1 | `claude-CLAUDE.md:5-5` | 0.71 | 0.53 | update | Content dupe of vault 'Never ask obvious things'; not a live-state drift. |
| 2 | `claude-CLAUDE.md:12-12` | 0.70 | 0.55 | update | — |
| 3 | `claude-CLAUDE.md:11-11` | 0.70 | 0.49 | update | — |
| 4 | `claude-CLAUDE.md:13-13` | 0.69 | 0.49 | update | — |
| 5 | `claude-CLAUDE.md:10-10` | 0.68 | 0.55 | update | — |
| 6 | `claude-CLAUDE.md:4-4` | 0.68 | 0.54 | update | — |
| 7 | `claude-CLAUDE.md:8-8` | 0.68 | 0.49 | update | referenced artifact missing: pi-issue@ |
| 8 | `pi-AGENTS.md:24-24` | 0.67 | 0.82 | update | — |
| 9 | `vault-rules.md:17-17` | 0.67 | 0.44 | update | — |
| 10 | `vault-rules.md:13-13` | 0.67 | 0.40 | update | — |
| 11 | `vault-rules.md:15-15` | 0.66 | 0.39 | update | — |
| 12 | `vault-rules.md:3-3` | 0.65 | 0.39 | update | referenced artifact missing: standing-rules-archive.md |
| 13 | `claude-CLAUDE.md:9-9` | 0.64 | 0.54 | update | — |
| 14 | `vault-rules.md:8-10` | 0.64 | 0.39 | update | — |
| 15 | `vault-rules.md:14-14` | 0.63 | 0.38 | update | — |
| 16 | `pi-AGENTS.md:7-7` | 0.62 | 0.84 | update | `tests/` still present (23 files); #7828 OPEN. Parenthetical is accurate, not stale. |
| 17 | `vault-rules.md:16-16` | 0.62 | 0.39 | update | — |
| 18 | `pi-AGENTS.md:25-25` | 0.61 | 0.79 | update | — |
| 19 | `vault-rules.md:5-6` | 0.61 | 0.38 | update | — |
| 20 | `pi-AGENTS.md:36-41` | 0.59 | 0.81 | update | — |
| 21 | `pi-AGENTS.md:29-34` | 0.58 | 0.80 | update | `grep -c idle-fleet-alarm` on host CLAUDE.md = 0; the generator was deleted (glue sweep); `docs/pi-agents.md` states nothing else is rendered or mirrored. |
| 22 | `pi-AGENTS.md:5-5` | 0.57 | 0.82 | update | — |
| 23 | `pi-AGENTS.md:6-6` | 0.55 | 0.82 | update | — |
| 24 | `pi-AGENTS.md:11-23` | 0.53 | 0.82 | update | Enumeration is identical to the vault paragraph; vault rules say a surface is a pointer, not a second source. |
| 25 | `claude-CLAUDE.md:48-48` | 0.51 | 0.41 | keep | referenced artifact missing: AGENTS.md |
| 26 | `claude-CLAUDE.md:45-45` | 0.50 | 0.42 | keep | — |
| 27 | `claude-CLAUDE.md:49-49` | 0.49 | 0.44 | keep | referenced artifact missing: global-standing-rules.md |
| 28 | `claude-CLAUDE.md:52-52` | 0.49 | 0.40 | keep | — |
| 29 | `claude-CLAUDE.md:51-51` | 0.48 | 0.45 | keep | — |
| 30 | `claude-CLAUDE.md:50-50` | 0.48 | 0.42 | keep | — |

## Evidenced drift — the edits in this PR

1. **`pi-AGENTS.md:29-34` — update.** The paragraph made the "generated
   `idle-fleet-alarm` block" in the host `CLAUDE.md` the winning authority for
   live-state wording. That block no longer exists (`grep -c idle-fleet-alarm` =
   0), its generator was deleted in the glue sweep, and `docs/pi-agents.md` now
   states nothing else is rendered or mirrored. The same paragraph already names
   the vault `global-standing-rules.md` as the wording authority, so the dead
   pointer is removed and the vault pointer stands alone.
2. **`pi-AGENTS.md:78` — update.** "New `bin/` files: the PR body carries
   `research:` + `help-first:`" describes a workflow that can never trigger:
   new scripts are banned (worker packet step 5, vault rules), and `bin/` holds
   only pre-existing files. Replaced with the live rule.

## Candidates for #7464 (volume, not drift) — reported, not edited here

- `pi-AGENTS.md:11-23` re-lists the vault's reserved classes verbatim; the vault
  rule says "a surface is a pointer, not a second source". Collapsing it to a
  pointer removes ~8 lines.
- `pi-AGENTS.md:86-102`: two overlapping prod-D1-migration sections where the
  second explicitly voids the first's decision. Merge into one.
- Host `CLAUDE.md:5-13`/`23-29` duplicate the vault rules and AGENTS.md's live
  state. Jev scored the whole block ~0.7 stale on duplication alone. #7464 owns
  the "<=5KB always-loaded" consolidation.

## Unknowns retained

- The `GH_TOKEN` scope claim is not probeable without expanding the token
  (`/user` is 403 for an installation token), so it is graded `keep` on reading
  alone, not on live evidence.
- `@cloudflare/vitest-pool-workers` -> `@cloudflare/vitest-plugin` and the
  `env.AI.run("typesafe/jev", ...)` claim are external and were not re-verified.
- Jev over-flags invariant bullets: "Secrets never get printed" and "`main`/
  `master` are protected" scored `contradicts` 0.82/0.79 while being accurate.
  Treat the probabilities as a ranking, never as a verdict.

## Related

- #7370 (Jev epic), #7371 (reuse the Jev organ — `/jev` pass-through), #7464
  (red-tape cut; its item 5 consumes this report), #7828 (script-suite deletion).
