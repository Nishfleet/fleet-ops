# Second opinions for reserved decisions

Issue: #7429. The same Jev question runs twice with the state serialized in
two different orders — `item` before `context`, then `context` before
`item` — and a `disagreement` flag compares the two answer sets. The named
site was `bin/jev-eval --second-opinion`; that Node helper was deleted in
the 2026-09-18 glue sweep when Jev became the `127.0.0.1:4000/jev` LiteLLM
pass-through, so the feature lives as a verbatim python block in
`prompts/worker.md` (section "Second-opinion Jev call"), wired at the
step-4 `orchestrator`-vs-`nish-decision` triage — the one place a worker
already makes a reserved-class decision.

## Call shape

Write the card to a scratch JSON file and run the block:

```bash
python3 - <site> <ref> <card-path> <<'PY'   # block copied verbatim from prompts/worker.md
```

Card:

```json
{"item": "<the card under judgment>",
 "context": "<the rules, reserved classes, roles, history, thresholds>",
 "questions": {"<qid>": {"type": "boolean|choice|score", ...}}}
```

`questions` is optional; omitting it uses the reserved-class default pair
below. Any extra top-level card keys are retained as extra state fields in
both framings. `ref` cites the real record the card came from. Never put
credentials or unrelated private data in a card.

Each framing serializes `{item, context, ...rest}` as JSON text with the
named order preserved — `item` first, then `context` first. No information
is removed and the first answer is not shown to the second call.

## Reading the verdict line

```
jev second-opinion: disagreement=<true|false|null>; <qid>=<a>/<b> ...; site=<site>; ref=<ref>
```

`disagreement` is:

- `true` if any boolean answers fall on opposite sides of the site's
  `act_hi` edge from `config/jev-bands.json` (fleet-ops#7439; 0.5 as
  shipped), selected choices differ, or numeric scores differ. Score
  comparison is exact and conservative.
- `false` if all answers are valid and agree by those rules.
- `null` for missing/invalid answers, a boolean exactly at the edge, or
  an unreadable bands table, unless another valid pair already proves
  disagreement.

These are comparison rules, not calibrated authority thresholds.

## Reserved-class pattern

Use the canonical reserved classes in `context`: money/pricing, privacy,
security, legal, brand, product direction, customer-data deletion,
destructive/irreversible steps, and authority Nish explicitly reserved.

The default questions are the benchmark pair (`docs/jev-benchmark-2026-09.md`):
`needsNish` (boolean) and `reservedClass` (choice over the canonical
classes plus `auto_fixable`).

Inspect both probabilities before acting. If `disagreement` is `true` or
`null`, route the card and both answers to the existing review/escalation
path — at step 4 that means parking `blocked-on: nish-decision`.
Agreement never grants permission for a reserved action. Keep the existing
approval rule even when both answers say the work is auto-fixable.

The pattern is advisory only. It does not post messages, approve work, or
execute any action. No gate or service is added.

## Logs, failures and rollback

The per-site JSONL log (`~/.local/state/pi-packet/jev/<site>.jsonl`) gets
one call row per framing (`framing: item-first` / `context-first`, each
with `answers`, `probabilities`, `usage`, `ms`, `state_sha256` of its own
serialization) plus one `kind: second-opinion-summary` row carrying both
answers and the flag. Only call rows carry `usage`; exclude summary rows
from call counts. Raw state is not logged.

Each completed call is logged before the next request is made, so a failed
second call leaves the first receipt. The proxy owns the spend cap: the
`jev-eval` virtual key carries `max_budget 1.0 USD / 1mo` and LiteLLM
refuses the call itself once the month's dollar is spent — a refusal reads
as `unavailable`, same as any other Jev failure.

Set `JEV_SECOND_OPINION=0` (or `off`) in a caller's environment to roll
that caller back to a single item-first evaluation. Not running the block
at all keeps the single-call contract. Neither changes any reserved-class
approval rule.

## Real run

At 2026-09-21T21:36:53Z, the block in this branch evaluated the
reserved-class card for
https://github.com/Nishfleet/fleet-ops/issues/5808 (a GitHub Team purchase
request) with the default questions above, site `second-opinion-reserved`.
The two call rows and the summary row are in the local JSONL log at that
site, `ref: Nishfleet/fleet-ops#5808`.

| Framing | needsNish | reservedClass | Input tokens | ms | state_sha256 (prefix) |
| --- | --- | --- | --- | --- | --- |
| item-first | 0.97 | money_pricing | 762 | 542 | 75c5f42d |
| context-first | 0.98 | money_pricing | 761 | 269 | 943ac3f4 |

Disagreement: `false`. The two `state_sha256` values differ, proving both
serializations ran. No payment or approval was performed — this proves a
real two-call run through the pass-through, not calibration accuracy or
deployment.

`python3 tests/jev-second-opinion.test.py` covers agreement/disagreement
across all three question types, the configured edge boundary, missing
answers, card validation, ordering of the two state serializations, log
receipts, off-flag rollback to one call, and fail-open behaviour. Endpoint
responses in that test come from a stub — they are synthetic.
