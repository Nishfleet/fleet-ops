# Deliberate-states registry

This file lists intentionally-off or intentionally-paused things so the
mechanical blind audit does not re-flag them as gaps.  Every entry MUST have an
expiry date.  An expired entry is itself a loud `gap-audit` finding.

| state | reason | expiry | owner |
|---|---|---|---|
| fleet-paused | 92 fleet timers deliberately stopped pending migration onto Pi. 10 remain up for box protection and console visibility. | 2026-09-02 | Nish |

## Rules for adding an entry

1. `state` is a short, hyphenated tag. The audit matches it case-insensitively.
2. `reason` explains *why* the thing is off and what would have to change before
   it is turned back on.
3. `expiry` is an ISO-8601 UTC date. When it passes, the audit files a
   `gap-audit` issue: "deliberate state `<state>` expired on `<expiry>`".
4. `owner` is the human or unit that can renew or clear the entry.
