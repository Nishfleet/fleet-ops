## What changed

For repo fleet-ops, the agent-ready spec-gate (`lib/agent-ready-spec-gate.py`) now refuses any issue body that does not carry a `moves:` line naming one of the product metrics: `sessions_to_pr_pct`, `product_merges_per_day`, `reverts_per_100_merges`, `packet_bytes`, `no_usable_seat_events`, `scout_candidate_age`. No `moves:` line = SPEC-GATE refused, the same path as a missing `termination:`.

The three first-admission callers (`bin/lifecycle-label-sweep`, `bin/pi-audit-tally`, `bin/fleet-heartbeat-auditor`) now pass `--repo` to the gate so it can enforce the fleet-ops rule. Non-fleet-ops repos are unaffected.

## Verification

Ran the gate directly across all four cases:

```
$ printf 'termination: test -f README.md\nmoves: product_merges_per_day\n' | python3 lib/agent-ready-spec-gate.py check-body --repo fleet-ops
SPEC-GATE: ok            (rc=0)

$ printf 'termination: test -f README.md\n' | python3 lib/agent-ready-spec-gate.py check-body --repo fleet-ops
SPEC-GATE: refused — body has no termination:/accept:/required:/metric: or no moves: line naming a product metric (fleet-ops#3255)   (rc=1)

$ printf 'termination: test -f README.md\nmoves: bogus_metric\n' | python3 lib/agent-ready-spec-gate.py check-body --repo fleet-ops
SPEC-GATE: refused ... (rc=1)

$ printf 'termination: test -f README.md\n' | python3 lib/agent-ready-spec-gate.py check-body --repo 0509
SPEC-GATE: ok            (rc=0)
```

Test suite green:

```
$ bash tests/agent-ready-spec-gate.test.sh
OK: (a) live repo passes spec-gate verify
OK: (a) led-work-supply-agent-ready is enforced in the rule matrix
OK: (b) product spec (termination:) is accepted
OK: (c) control-plane spec (required:) is accepted
OK: (d) prose-only body is refused
OK: (e) termination: with no command is refused
OK: (h) fleet-ops body with moves: is accepted
OK: (h) fleet-ops body without moves: is refused
OK: (h) fleet-ops body with invalid moves: is refused
OK: (h) non-fleet-ops body without moves: is unaffected
OK: (f) first-admission script that drops the gate is rejected
OK: (g) nested CI host
OK: agent-ready-spec-gate: live verify, product spec, control-plane spec, refuse, unwired, fleet-ops moves
```

Caller scripts pass `bash -n`; gate passes `python3 -c "import ast"`. sgscan: no new security findings.

run-proof: `bash tests/agent-ready-spec-gate.test.sh` -> all OK (transcript above); direct `check-body --repo fleet-ops` accept/refuse cases above.

loose-ends-canary: pr:nishfleet/fleet-ops#3255 moves-line gate

Closes #3255
