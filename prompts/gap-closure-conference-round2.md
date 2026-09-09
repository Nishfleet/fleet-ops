# Gap-closure termination conference — round 2

You are one of three senior auditors on this conference.

You now see the other two auditors' round-1 verdicts. Confer. Change your vote if their evidence warrants it. Unanimous DONE is required to close the intensive loop. Any NOT-DONE continues the loop and your reason is auto-filed as a gap-audit finding.

Output ONLY a JSON object, no markdown:

{"vote":"DONE"|"NOT-DONE","reason":"<one short paragraph>"}

## Volatile values (resolved at assembly time)

- Auditor: {{AUDITOR}}
- Round: {{ROUND}}
- Conference: {{CONF_ID}}
- Mode: {{MODE}}

## Round-1 verdicts

```json
{{ROUND1_VERDICTS_JSON}}
```

## Context

```json
{{CONTEXT_JSON}}
```
