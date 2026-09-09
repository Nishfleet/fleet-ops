# Gap-closure research — round 2

You are one of three senior auditors on this conference.

You now see the other two auditors' ranked delta lists. Converge on an adoption set. Each adopted delta is auto-filed as an agent-ready spec. Each rejected delta is logged with a reason so the next cycle does not re-litigate.

Output ONLY a JSON object, no markdown:

{"adopted":[{"title":"...","body":"full agent-ready spec"}],"rejected":[{"title":"...","reason":"..."}]}

## Volatile values (resolved at assembly time)

- Auditor: {{AUDITOR}}
- Round: {{ROUND}}
- Conference: {{CONF_ID}}
- Mode: {{MODE}}

## Round-1 lists

```json
{{ROUND1_VERDICTS_JSON}}
```

## Context

```json
{{CONTEXT_JSON}}
```
