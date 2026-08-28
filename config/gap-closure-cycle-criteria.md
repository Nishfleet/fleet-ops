# Gap-closure cycle criteria

The intensive loop in fleet-ops#180 is CLEAN only when every line below is
true. The weekly blind-audit floor (#157) keeps running either way.

## Required every cycle

1. **Audit** — `fleet-blind-audit.service` completed and wrote a durable
   report.
2. **Manual-seam lens** — that report contains a `## Manual-seam lens`
   table. The harness writes the table; the reviewer does not get to skip
   it.
3. **Seams closed** — every enumerated hand-performed operation since the
   last cycle is one of:
   - **matched** to an open or merged mechanism issue, or
   - **filed** this run via the standard queue (`gap-audit`), or
   - **accepted-as-manual** with a dated reason.
4. **No unmatched seams.** An unmatched seam counts as a cycle finding.
   The loop must not convene the DONE conference while any remain.
5. **Fix / drill / SLO** — as specified on #180. This file does not
   replace those; it adds the seam hunt as a standing Audit-phase
   criterion.

## Evidence the lens enumerates

Hand-performed operations since `last-blind-audit-run` (else trailing 24h),
from:

- memoryctl outcome records
- the actions log
- GitHub issue / comment / label events authored outside worker claim
  identities (`claimed by pi-…`, `[gap-audit]`, `Filed by fleet-blind-audit`)
- `systemctl start` events with no timer or trigger parent

## Accepted-as-manual (listed, not "fixed")

These stay Nish's. They appear in the table with an ISO date and a reason.
They are not mechanism bugs:

- money, cards, paid trials
- privacy, security, legal
- product direction
- merge to `main` / production deploy

Anything a human or flagship did twice that is not in that list is a
machinery defect and must get a queued mechanism.

## Cycle 1 check

Verify previously queued mechanisms did not regress (still open, or closed
by a merged PR — not silently gone), then hunt what the last window missed.
