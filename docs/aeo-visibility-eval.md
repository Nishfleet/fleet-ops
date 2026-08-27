# 0509 AEO tracker market eval (fleet-ops#1236 Phase A)

Date: 2026-08-27. Target: 0509 (https://0509.io). Test set: the sneaker money-queries.

Build-vs-buy check first. Nothing else until this file existed.

## Verdict

No free, proven tool does weekly automated custom-prompt tracking at $0 across ChatGPT, Perplexity, and Claude.

Phase C residue is the in-repo weekly probe (`libexec/fleet-aeo-probe.py`). That is the only shape that can run 0509's own questions, on a weekly timer, and export `fleet_aeo_cited` without a card.

## What lost, and why

| Tool | Free surface | Why it lost for weekly 0509 tracking |
| --- | --- | --- |
| Otterly.ai | 7-day trial, no card | Trial dies before the second weekly run. Claude/Gemini are paid add-ons. |
| Profound | Growth trial only | No free-forever tier. API is Enterprise. |
| Peec | none | No free surface. |
| Scrunch AI | 7-day trial | Card wall. Hard line: skipped. |
| AthenaHQ Essential | 300 one-time credits, 5 engines | Credits do not refresh. No API/CSV on free. Useful as a one-shot baseline after a card-free signup, not a weekly loop. |
| LLMrefs | 1 keyword / month | Cannot hold a 15-query set. |
| Ahrefs Brand Radar free checker | no signup | Brand-name index, not custom prompts. Live "0509" run returned no report (low volume). |
| HubSpot AEO Grader | no signup | Pre-set brand queries. Same low-volume limit. |
| Semrush AI Visibility | free account is not prompt tracking | Custom prompts are the $99 toolkit, no trial. |
| PromptWatch Explore | free + MCP/REST | Only free tool with an API. Free-tier engine list is unverified without a live signup. Follow-up: fleet-ops (Phase B signup). |
| FixAEO | public Gemini scan | URL audit, not custom-prompt tracking. Paid trials are card-gated. |
| Answer Visibility Lab | free audit | Site-readiness, not a live engine citation tracker. |

Paid tools that beat this narrow 15-query probe were not bought. That is a money decision for Nish. None were recommended for this scope.

## Phase B (not this PR)

- PromptWatch Explore: one card-free signup to confirm free engines, then maybe pull its API.
- AthenaHQ Essential: one-shot baseline if a signup inbox exists.
- Ahrefs + HubSpot: competitor (StockX) snapshots only. They do not see 0509.

## Phase C (this PR)

Weekly probe against ChatGPT / Perplexity / Claude via existing API env files. Missing files skip the engine and set `fleet_aeo_engine_up=0`. That is "not measured", not "not cited".
