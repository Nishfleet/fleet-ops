# TTL policy for recorded facts

Implements fleet-ops#1263 (item 2 of #1145). `memoryctl-recall` enforces
this at the recall/compile layer. Authors do not mark claims stale by
hand; expired notes become `UNVERIFIED` on load.

## Frontmatter schema

On every TTL-governed vault note:

```
observed: <ISO8601>
ttl: <duration>          # optional; the class default applies when omitted
class: <class name>
check-command: <optional command string>
```

`class` is one of: `drill-status`, `seat-caps`, `seat-health`,
`decision-ledger`, `evidence`, `procedure`.

Duration is an integer plus a unit: `s` (seconds), `m` (minutes),
`h` (hours), or `d` (days). Example: `5m`, `1h`, `7d`.

`observed` is the moment the fact was last checked, as ISO 8601
(prefer UTC, `Z` suffix).

`check-command` is printed literally next to an expired claim so the
agent can refresh it. Recall never executes that string.

## Class defaults

# ttl-defaults
drill-status: 5m
seat-caps: 1h
seat-health: 1m
decision-ledger: 7d
evidence: 30d
procedure: 90d
# /ttl-defaults

A per-note `ttl:` overrides the class default. Notes with neither
`class` nor `ttl` are not TTL-governed and pass through unchanged.

## Recall rule

A governed note is expired when `(now - observed) > ttl`. Equal-to-ttl
is still fresh. Missing or unparseable `observed` is expired (fail closed).

Expired notes are rewritten:

```
UNVERIFIED: <original body>
<check-command>
```

The preamble starts with one receipt line:

```
[recall: N loaded, M UNVERIFIED]
```
