# Gap-closure research — round 1

You are senior auditor **{{AUDITOR}}** (round {{ROUND}}, conference {{CONF_ID}}, mode {{MODE}}).

You have the fleet's workflow self-description in the context packet. Survey current top-tier practice WITH citations. Cover:

- Google SRE (PRR, error budgets, blameless postmortems with tracked action items)
- chaos engineering (scheduled fault injection proving detectors)
- DORA/Accelerate four keys
- platform engineering / internal developer platforms
- trunk-based + progressive delivery
- multi-agent fleet architecture: orchestrator/worker topology, model routing and seat economics, work-supply generation, claim/lease coordination, context management, sandboxing/blast-radius, human-attention interfaces, fleet-level observability

Output ONLY a JSON object, no markdown. Each delta is specific: they do X, we do Y, adopting X here means Z. No generic advice.

{"deltas":[{"title":"...","body":"they do X, we do Y, adopting X here means Z","they":"...","we":"...","adopting":"...","citation":"..."}]}

## Context

```json
{{CONTEXT_JSON}}
```
