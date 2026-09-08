# Fable-check brief — repo copy (fleet-ops#4460)

This is the **repo copy** of the hourly fleet judge brief
(`agent-state/fleet-landing-watch/fable-check.md`, runtime packet served to
`agent-cron-run fable-check`). A brief rebuild starts from this file so the
standing rules below survive regeneration instead of living only in the live
agent-state file and being lost on the next rebuild.

The live packet is the same content plus the run-time header order and
measure instructions that do not change this file's standing rules. If this
file and the live packet disagree, this file wins on the standing rules.

## Blind-spot rules (Nish, 2026-09-08 10:10 IST: "what are we blind to? ... fix all")

- **Every number you report must be a verbatim line from this run's measure.sh
  output or a command you ran in this run, quoted next to it.** A number with
  no command is written as `unverified:<n>`. Origin: the orchestrator itself
  reported Alibaba credits "per month" and a "nightly" cadence as fact on
  2026-09-08; both were guesses.
- **Caught-by-hand rule:** anything Nish or the orchestrator notices by hand
  that measure.sh did not show (2026-09-08 examples: 19 red deploys under
  "main is green"; 55 `discarded` issues under "nothing new") becomes a
  measure.sh line the SAME run, and you say so in the header:
  `new-measure: <what>`. A blind spot named twice without a measure line is a
  fault.
- **Count is mandatory.** `measure.sh` prints `new_measures_7d=<n>` and
  `caught_by_hand_7d=<n>` from the decisions-ledger + fable-state. When you
  emit a `new-measure: <what>` header line, record it so
  `new_measures_7d` moves. The metric invariant every run is
  `new_measures_7d >= caught_by_hand_7d` — every caught-by-hand item gets a
  measure line that same run. A caught-by-hand item with no measure line is a
  fault.
- **Header order from now on:** `product:` (signups/activated/paying, #4456)
  → `waste:` (empty-success, treadmill, #4457) → `usd_24h:` (fleet-ops#4459)
  → `new_measures_7d:` / `caught_by_hand_7d:` → shipped/24h →
  workers/ready. Merges are the fourth number, not the first.

## Weekly Fleet Review handoff

The weekly fleet review's FIRST section is "Caught by hand this week"
(`prompts/weekly-fleet-review.md`, fleet-ops#4460). Feed it this run's
`new-measure:` header lines, the week's decisions-ledger entries, and any
Nish Telegram/chat correction no metric surfaced first — the review lists
them and, for each, names the measure.sh line that now covers them (citing
the commit) or files the measure line in its ≤5 actions.
