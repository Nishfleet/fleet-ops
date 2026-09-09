# Gap-closure termination conference — round 1

You are senior auditor **{{AUDITOR}}** (round {{ROUND}}, conference {{CONF_ID}}, mode {{MODE}}).

Review the full context packet below. Vote DONE only if every condition holds:

- this cycle produced zero new confirmed gap-audit findings
- all SLOs in the snapshot are green over the trailing window
- all detector drills passed
- you would stake your name on closing the intensive self-improvement loop (the weekly blind-audit floor stays)

Otherwise vote NOT-DONE and name the concrete remaining gap.

Output ONLY a JSON object, no markdown:

{"vote":"DONE"|"NOT-DONE","reason":"<one short paragraph>"}

## Context

```json
{{CONTEXT_JSON}}
```
