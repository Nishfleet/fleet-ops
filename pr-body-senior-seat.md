fix(fleet-gap-closure-conference): split senior seat on TAB, not slash (fleet-ops#4211)

## Why

find_senior_seat, the live seat-lib path, emits provider<TAB>model.
bin/fleet-gap-closure-conference used to split the resolved senior seat on '/',
so BOTH SENIOR_PROVIDER and SENIOR_MODEL became the whole tab-separated
string, preflight refused the seat (no health data), and the senior auditor
dissent blocked the termination conference.

## Verification

bash tests/fleet-gap-closure-conference-senior-seat.test.sh  (all OK)

run-proof: tests/fleet-gap-closure-conference-senior-seat.test.sh -- senior
seat resolves cursor/cursor-grok-4.6-high in both TAB and slash forms.

Closes #4211
