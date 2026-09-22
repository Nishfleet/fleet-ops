# gmail-cleanup shadow scorecard — phase-1 design + access findings (fleet-ops#7765)

2026-09-22, worker run `pi-issue-fleet-ops-7765`. The issue's phase 1 designs
a typed archive / keep / unsubscribe-then-archive question and scores 400 real
threads through site `gmail-cleanup`, blind-labeled on 120, precision reported
against the 15% disagreement gate. Scope amendment (orchestrator, 2026-09-18):
mail content is privacy-class — the scorer is a **local** model, nothing leaves
the host; Jev proper waits for Nish's explicit clearance.

## What this run shipped

- `docs/gmail-cleanup-card.json` — the full typed-question
  card: state schema (sender, subject, snippet, labels, thread age,
  owner-replied, list-unsubscribe header, category), the `disposition` choice
  question with criteria, a `confidence` score question, the stratified
  400-thread sampling plan, the 120-item blind-label rule, and both gates.
- A **proven** local executor (below) — the exact bring-up the scorecard run
  will reuse.

## Blocking finding: no live Gmail read path on this VPS

The issue's mechanics note ("the Gmail MCP is read-only") describes the Mac.
On this host the only mailbox credential is Hermes's
`~/.hermes/google_ea_readonly_token.json` (scopes `gmail.readonly` +
`calendar.readonly`). Its refresh token is dead:

```
POST https://oauth2.googleapis.com/token  →  HTTP 400
{"error":"invalid_grant","error_description":"Bad Request"}   (2026-09-22 ~06:35 UTC)
```

A re-auth flow was started and abandoned —
`~/.hermes/google_ea_oauth_pending.json` (2026-08-22) holds a PKCE
`state`/`code_verifier` for redirect `http://localhost:1`, i.e. the flow waits
for a Google consent click that never happened. There is no logged-in Google
session in any on-box browser profile (`browser-harness-chrome` user-data has
only facebook.com cookies; `~/.config/google-chrome` has no profile), so the
consent cannot be completed agent-side.

Alternatives checked and ruled out: Gmail IMAP (no app password exists),
Google Workspace delegation (no service account on the box), camofox browser
MCP (no Google session; the shared wrapper
`~/.local/bin/camofox-browser-mcp-shared` no longer exists).

**Unblock is a Nish action**: re-run the Hermes Google EA auth (or complete
the pending PKCE flow) so a fresh `gmail.readonly` token lands on this host.
Until then no thread sampling can run — "real records only" forbids
proceeding on fabricated input.

## Blocking finding resolved: the local model seat now exists

The amendment assumed "the local Ollama seat already on the VPS
(glm-5.3-flash)". None existed — no ollama binary, daemon, or listener.
Corrections made this run:

- `glm-5.3-flash` **cannot** run locally: `ollama pull glm-5.3-flash` →
  "file does not exist … `glm-5.3-flash:cloud` is available as a cloud model".
  The named seat is ollama.com-cloud-only, which would ship mail content
  off-host — exactly what the amendment forbids.
- `glm-4.7-flash` is local-runnable on the registry but is a 19 GB pull —
  over this box's ~8 GB free RAM. Aborted at 35% and cleaned up.
- Installed Ollama 0.34.2 user-space at `~/.local/lib/ollama` (symlink
  `~/.local/bin/ollama`) and pulled **`qwen3:4b-instruct`** (2.5 GB,
  non-thinking instruct — the right shape for deterministic structured
  answers).
- Smoke test, `POST 127.0.0.1:11434/api/chat` with a JSON-schema `format`
  forcing `{choice, probabilities}`: synthetic promo thread →
  `{"choice":"archive","probabilities":{"archive":0.95,"keep":0.04,
  "unsubscribe_then_archive":0.01}}`, 53 eval tokens in 6.8 s on CPU.
  Measured throughput ≈ 8 tok/s eval → the 400-thread scorecard is ~80 min
  of compute, well inside a transient-unit deadline.

Model substitution is recorded honestly: scorecard rows will name
`qwen3:4b-instruct`, and its precision is a **lower bound** — if a 4-B local
clears the 0.95 archive-precision gate, Jev proper (once privacy-cleared)
clears it too.

## Executor recipe (what the scorecard run does)

```bash
# seat — transient unit, lifetime bounded by the job (no permanent unit is
# installed; the ollama binary at ~/.local/lib/ollama, its ~/.local/bin
# symlink and the pulled weights at ~/.ollama/models do persist):
systemd-run --user --unit ollama-gmail7765 \
  -p RuntimeMaxSec=14400 -p MemoryMax=10G -- ~/.local/bin/ollama serve

# per thread: POST 127.0.0.1:11434/api/chat, model qwen3:4b-instruct,
# temperature 0, JSON-schema format = the question card's output contract;
# state built from Gmail API threads.get?format=metadata
#   (metadataHeaders: From, Subject, List-Unsubscribe; labelIds; internalDate)
# The scoring pass itself runs as its own transient unit with the stock
# dead-man: -E DELIVERABLE=<abs scorecard path> and
#   -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"''
# and no --collect, so a scoreless stop stays listed under
# `systemctl --user list-units --state=failed`.
# rows append to the site jsonl; committed artifacts carry
#   thread_id + sha256(sender|subject|snippet) only — no mail text in the repo.
```

## What remains (next run, once the token is live)

1. Gmail API `users.threads.list`/`get` (readonly) → stratified 400-thread
   sample → local scorecard run → 120-item blind audit → precision report
   committed under `docs/reports/gmail-cleanup-7765/` (ids + hashes only —
   `.fleet/**` is inside the no-glue added-path ban).
2. If the p >= 0.9 archive bucket is >= 0.95 precise: file the phase-2
   apply issue (archive-only, never delete, dry-run list first, Chrome
   filter path unchanged).

## Privacy envelope

Mail content never left the host at any point this run. The only
network egress was github.com (ollama binary), registry.ollama.ai (model
weights), and oauth2.googleapis.com (the failing refresh). Committed
artifacts contain no sender/subject/snippet text — ids and hashes only.

## Mechanical-fix note (fleet-ops#366)

mechanism-impossible: the deliverable is a design card plus access findings;
the scorecard that would emit `gmail-cleanup` rows is blocked on a
privacy-class credential, so there is no consumer to gate or observe. The
`gmail-cleanup` site row is deliberately absent from `config/jev-bands.json`
— `tests/jev-bands.test.py` pins the table to sites a consumer emits, so
registration lands in the same PR as the runner that emits it. The one real
defect this run produced (a premature site row) was caught by that existing
gate, not prose.

encoded: none — the existing rung-2 gate (tests/jev-bands.test.py) already caught the premature site row; no new mechanism needed.
