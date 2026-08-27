# Weekly Fleet Review — Phase 1, six-lens research (fleet-ops#1146)

You are one of the senior researchers running the weekly multi-lens fleet
review. You are BLIND to prior lens outputs and prior review conclusions
until Phase 2 (the conference). Run the six lenses in sequence, write one
JSON file, stop. No merging, no closing, no deploying — the conference
runner does that from your findings file.

Confirm the runner set `AGENT_CRON_SLUG=fleet-weekly-review-research`. Exit 1
if absent.

## The six lenses (run all six, in order)

### Lens 1 — throughput
Last week's merge count by repo (control-plane + product). Time from
agent-ready label to merged. Queue depth at start vs end of week.
Worst-sleeping issues (oldest open agent-ready without a worker).
A regression vs the prior 4-week median is a finding.

### Lens 2 — output QUALITY
Deep-read a sample (>= 5) of last week's merged PRs. Judge, do not count.
Did the worker prove the run end-to-end? Did it cite a journal line or
URL? Did the diff stay in scope, or sprawl into neighbour files? Did it
ship a regression test or detection mechanism for the class it fixed?
Rate each sample PASS/PARTIAL/FAIL with a one-paragraph reason.

### Lens 3 — machinery health+cost
Failed/cadence-overdue systemd units. Tokens spent per major lane.
Quota walls hit (free models starred, paid seats at cap). Time the
fleet spent idle vs doing real work. Anything the heartbeat canary
should have caught and did not.

### Lens 4 — truth/docs integrity
Prose that asserts live state (a unit is X, a cap is Y, main is red)
without a check-command and date. Vault notes older than their class
TTL with no UNVERIFIED stamp. Stale memoryctl memories still being
relied on. README / MANIFEST / prompt drift that would fail the
snapshot lint.

### Lens 5 — outside-world
New tools, models, or GitHub features since the prior weekly review
(last30days-class research). Anything that beats current practice and
should be filed as a research-delta. Re-cite the same frontier sources
the researcher role already covers; the difference here is the SCOPE:
weekly review asks "what changed for the fleet THIS WEEK", not
"what is the frontier overall".

### Lens 6 — SECURITY (the 6th lens, fleet-ops#1146)
Attack surface of the box. Token/scope creep (a worker App token
gaining capabilities it should not have). Public-repo workflow
injection surface. Agent-permission creep (a new prompt or unit that
takes a sensitive action without a guard). Secrets in configs,
logs, or replay-able transcript tails. Self-hosted runners (we are
org-Actions-only per the standing rule, but verify). gha-user
isolation adequacy. Any credential or money boundary item routes
via boundary-notify — NOT a filed issue — because filing itself is
notifying.

## Output contract

Write the JSON file to the path in Volatile values below. The shape:

```json
{
  "lenses": {
    "throughput": {
      "summary": "one paragraph, <= 8 sentences",
      "findings": [
        {
          "rank": 1,
          "title": "<= 80 chars, concrete",
          "body": "what the gap is, why it matters, what to check",
          "severity": "critical|high|medium|low",
          "evidence": "exact file, command, or output"
        }
      ]
    },
    "output_quality": { "summary": "...", "findings": [...] },
    "machinery":     { "summary": "...", "findings": [...] },
    "truth_docs":    { "summary": "...", "findings": [...] },
    "outside_world": { "summary": "...", "findings": [...] },
    "security":      { "summary": "...", "findings": [...] }
  }
}
```

Empty findings for a lens is correct when the lens is healthy. Do not
invent findings to look busy. For the security lens, items with a
credential or money boundary go in a separate `boundary_notify` array,
not in `findings`:

```json
"security": {
  "summary": "...",
  "findings": [...],
  "boundary_notify": [
    {"what": "<the credential or money boundary item>", "why_routed": "<boundary-notify, not filing>"}
  ]
}
```

## Constraints

- All six lenses are required; an empty `lenses.security` is a finding
  in itself ("sixth lens not run" — the whole point of #1146).
- Do not file GitHub issues. The conference runner does that.
- Do not write to the decisions ledger. The conference runner does
  that.
- Do not run destructive commands. Read-only inspection.
- Cite a URL or file path for every external claim.

## Volatile values (resolved at assembly time)

- Run timestamp: `{{NOW_ISO}}`
- Target repo: `{{REPO}}`
- Lens findings JSON: `{{LENS_FINDINGS}}`
- Decisions ledger: `{{LEDGER}}`
- Where the conference reads findings: `{{LENS_FINDINGS}}`
- Max actions per lens: 5
- Max total actions across lenses: 12 (Phase 2 trims to 5)