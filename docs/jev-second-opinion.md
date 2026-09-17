# Second opinions for reserved decisions

Issue: #7429. Extend the installed `jev-eval` helper with `--second-opinion`.
In the repo, run `node bin/jev-eval.mjs --second-opinion < card.json`.

Supply the existing `{state, questions, site, ref}` envelope. For this option,
`state` must be an object with `item` and `context`. Put the complete real card
in `item`. Put the rules, reserved classes, roles, history and relevant thresholds
in `context`. Extra state fields are retained. `ref` cites the real record.
Do not send credentials or unrelated private data.

The helper sends the same questions twice. It serializes the state as JSON text,
first with item before context, then context before item. No information is removed
and the first answer is not shown to the second call.

`second_opinion.a` and `.b` contain answers, usage, latency and the hash of each
framing. Top-level `answers` is the first answer, not a combined verdict.
Top-level usage and latency cover both calls.

`second_opinion.disagreement` is:

- `true` if any boolean answers fall on opposite sides of 0.5, selected choices
  differ, or numeric scores differ. Score comparison is exact and conservative.
- `false` if all answers are valid and agree by those rules.
- `null` for dry runs, missing/invalid answers, or a boolean exactly at 0.5,
  unless another valid pair already proves disagreement.

These are comparison rules, not calibrated authority thresholds.

## Reserved-class pattern

Use the canonical reserved classes in the caller's context: money/pricing,
privacy, security, legal, brand, product direction, customer-data deletion,
destructive/irreversible steps, and authority Nish explicitly reserved.

Ask the same `needsNish` boolean and `reservedClass` choice in both calls.
Inspect both probabilities before acting. If disagreement is `true` or `null`,
route the card and both answers to the existing review/escalation path.
Agreement never grants permission for a reserved action. Keep the existing
approval rule even when both answers say the work is auto-fixable.

The helper is advisory only. It does not post messages, approve work, or execute
any action. No gate or service is added.

## Logs, failures and rollback

The existing per-site JSONL log gets two call rows with `framing` and one
`kind: second-opinion-summary` row containing both answers. Only call rows have
top-level usage; exclude summary rows from call counts. Raw state is not logged.
Dry runs and invented unit-test fixtures remain marked synthetic.

Each completed call is logged and charged before starting the next. The second
call checks the existing spend cap again. If it fails or the cap is reached,
the helper exits nonzero with no success result; the first receipt remains.
The existing cap is checked before a request, not a prepaid token reservation.

Set `JEV_SECOND_OPINION=0` in a caller's environment to roll that caller back to
one evaluation even when it passes the flag. Omitting the flag also keeps the
single-call contract. This does not change any reserved-class approval rule.

## Real run

At 2026-09-17T17:52:36Z, the branch helper evaluated the full current issue
https://github.com/Nishfleet/fleet-ops/issues/5808, a GitHub Team purchase request,
with the reserved-class rules above. The site was `second-opinion-reserved`.
The existing local JSONL log contains the two call rows and summary at that time.

| Framing | needsNish | reservedClass | Class probability | Input tokens | ms |
| --- | --- | --- | --- | --- | --- |
| item-first | 0.97 | money_pricing | 1.0 | 811 | 651 |
| context-first | 0.98 | money_pricing | 1.0 | 810 | 282 |

Disagreement: false. Total input tokens: 1,621. Estimated input cost at the
helper's configured rate: $0.000068082. No payment or approval was performed.
This proves a real two-call run, not calibration accuracy or deployment.

`bash tests/jev-eval.test.sh` also covers agreement/disagreement across all three
question types, ties, missing answers, state retention and ordering, unchanged
questions, log receipts, two-call accounting, second-call failure, cap checks,
dry-run behavior and caller rollback. SDK responses in those tests are synthetic.
