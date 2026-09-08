# Escalation matrix — the single home of every question route

Source: Nish 2026-09-08 (parts 1-3, fleet-ops#4474 #4475 #4476). This file is
the **only** place the question-route rows live. The senior conference gate
(#4474) judges each `question` issue as **NISH** or **MATRIX**; the MATRIX
verdict names one route token which the tally applies. Anything the panel
cannot place in a row is a **matrix gap** — the panel posts `matrix-gap:`
and the fable-check adds the row to this doc during its next run, so a
question can never rot for want of a row.

Every new route observed in the wild is a one-line addition below (that is
how the doc grows — not in prose).

## The four routes

| Route token | What it means | Applied by | Where it lands |
|---|---|---|---|
| `NISH` | reserved — only Nish may decide | panel adds `nish-reserved` | on the Nish tab, delivered to his phone via `nish-boundary-notify` (gate-confirmed only) |
| `precedent:` <ledger line> | an existing decision already answers it | tally posts `decision-resolved:` quoting the ledger line | issue resolved, removed from the question tab |
| `orchestrator` | a work-item / decision the fleet owns | tally rewrites `blocked-on: nish-decision` → `blocked-on: orchestrator` | orchestrator decision-sweep (#4260); fable-check must clear or escalate it within **2 runs** |
| `worker` | agent-ready answerable task | tally relabels `agent-ready` with the answer | dispatched like any agent-ready issue |

## The reserved set (NISH rows) — named rows

Anything the standing rules reserve to Nish alone, judged on the **content**,
not the safe default. These exist out of the box:

| Question kind | Route |
|---|---|
| money / pricing / credit / payment | `NISH` (MONEY-BOUNDARY) |
| legal / liability | `NISH` (LEGAL-BOUNDARY) |
| brand / positioning / public voice | `NISH` (PRODUCT-DIRECTION) |
| product direction / roadmap | `NISH` (PRODUCT-DIRECTION) |
| customer-data deletion | `NISH` (CUSTOMER-DATA) |
| credential / secrets policy | `NISH` (CREDENTIAL-BOUNDARY) |
| a reserved authority Nish explicitly named | `NISH` |
| an existing decisions-ledger precedent answers it | `precedent:` |
| any work-order / orchestration decision | `orchestrator` |
| any task with an agent-ready answer | `worker` |

## Matrix gap

A question whose kind is not covered by the reserved set AND has no ledger
precedent is a **matrix gap**. The panel's vote posts `matrix-gap: <reason>`
on the issue and the fable-check **adds a row to this doc** during its next
run, so the question is neither paged to Nish nor dropped — it is immediately
classified. Rows live here, and here alone.

## Guarantees

- **Gate-confirmed only** — only issues the panel confirmed (`nish-reserved` /
  `conference-approved`) ever reach Nish's phone. Nothing pre-gate is
  notified (enforced by the `nish-boundary-notify` confirmed-only query and
  `--dry-run`).
- **Rows live here only** — not repeated in prompts, scripts, or prose. A
  change to routing is a change to *this file*.
- **Answered stays resolved** — an answer (Matrix via `decision-resolved:` or
  a `decision-resolved:` comment from a Nish answer) de-queues the issue;
  `blocked-reconcile` re-queues only unresolved lines.