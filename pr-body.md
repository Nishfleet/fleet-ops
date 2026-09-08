## Summary

#4523 is the cycle-6 repeat of the cycle-4 #4210 class: the glm-5-3 senior auditor
being resolved to the unwired `zenmux/z-ai/glm-5.3-free` ladder slug, whose preflight
always refuses (no health data), so every termination conference files a blind-seat
dissent. The cycle-4 fix (#4236) added `resolve_free_glm_conf_seat()` to land on a live
wired seat and fall back to a usable capable seat, but it still regressed.

Root cause is a one-line `set -u` bug in `_conf_seat_has_health_data()` (the shared
health check the free-GLM and devin resolvers both call): it ends with `[ -n "$hc" ]`,
but when a candidate seat has **no** health ledger (no ledger file and the global
sidecar does not name that exact provider/model), `hc` is left unset by `local hc`.
Under the conference's `set -euo pipefail`, referencing `$hc` is a **fatal nounset
error**, not a false test.

In production the resolver's step-2 fallback scans `enumerate_seats` over the full
`config/pi-models.json`; the first wired free-class seat without a ledger crashes the
whole `resolve_free_glm_conf_seat()` command-substitution subshell (`line 103: hc:
unbound variable` in the cycle-6 journal at 2026-09-08T09:49:09Z). The resolver returns
non-zero, so the panel falls back to the always-unwired `zenmux/z-ai/glm-5.3-free`
ladder slug -> preflight refuse -> dissent issue. That is why the glm-5-3 auditor kept
landing on a blind seat even when a usable capable seat (devin/glm-5-2) existed and the
glm-5-2 auditor correctly used it.

The fix is `[ -n "${hc:-}" ]`, which turns a no-ledger seat into a normal non-match so
the resolver skips it and falls through to the live usable seat — the exact behavior
#4238 intended but was defeated by the nounset crash.

This is unique to the conference resolver; the sibling candidate issues #4522 (glm-5-2)
and #4524 (senior) are the same this-cycle, glossed out, and this issue's scope is the
glm-5-3 class. A scoped regression test pins the no-ledger crash mode.

## Root cause proof

`set -euo pipefail` + `_conf_seat_has_health_data()` before the fix:

```
$ bash -c 'set -euo pipefail; g(){ local hc; [ -n "$hc" ]; }; g'
env: hc: unbound variable
```

Live production journal, cycle-6 termination conference (2026-09-08T09:49:09Z):

```
bash[858096]: /home/nish/.local/bin/fleet-gap-closure-conference: line 91: hc: unbound variable
[fleet-gap-closure-conference] no usable free-GLM seat; glm-5-3 keeps ladder slug zenmux/z-ai/glm-5.3-free (preflight will refuse)
[fleet-gap-closure-conference] panel resolved: glm-5-2=devin/glm-5-2 glm-5-3=zenmux/z-ai/glm-5.3-free senior=cursor/cursor-grok-4.6-high
```

Even though `glm-5-2` resolved to devin/glm-5-2 (a usable capable seat), glm-5-3's
resolver aborted on the no-ledger scan and fell back to the unwired slug.

## Verification

In the issue workspace (origin/main base), reproducing under `set -euo pipefail` with
the fix in place:

```
OK: no-ledger seat returns non-match (rc=1), no crash under set -u   # this died before the fix
OK: ledger seat marked healthy (rc=0)
PASS: fix holds under set -u
```

Full test suite, this worktree, exit 0:

```
$ bash tests/fleet-gap-closure-loop.test.sh   # exit 0, 35 OK, no FAIL
OK: glm-5-3 skips a no-ledger free seat without crashing (set -u / fleet-ops#4523)   # new scenario D
$ bash tests/fleet-gap-closure-conference-senior-seat.test.sh   # exit 0
$ bash tests/role-quality-gates.test.sh   # exit 0
```

Regression pin: reverting the one-line fix makes scenario D fail with the exact
production symptom (`hc: unbound variable`, then `{"provider":"zenmux","model":
"z-ai/glm-5.3-free"}`); with the fix it passes and lands on the usable capable seat.

`sgscan --base origin/main`: no new security findings.

run-proof: tests/fleet-gap-closure-loop.test.sh (exit 0, incl. new scenario D);
tests/fleet-gap-closure-conference-senior-seat.test.sh (exit 0); role-quality-gates
(exit 0); sgscan clean.

net-positive-because: a regression-pinning test (51 lines) outweighs the 13-line
conference fix — the durable detector is the point of the mechanical fix (fleet-ops#366).

## Test plan

1. Unit: `_conf_seat_has_health_data` must not throw `set -u` on a no-ledger seat.
2. Conference regression (scenario D): a wired free-class seat with no ledger file
   present in `enumerate_seats` must be skipped (non-match) and glm-5-3 must fall
   through to the usable capable seat — not the unwired ladder slug.
3. Existing scenarios A/B/C and the glm-5-2 scenarios stay green.

Closes #4523