## Summary — the P14 suites, red on main, now have a measure line

4th caught-by-hand sighting: the P14 suites (shellcheck / semgrep /
systemd-analyze + the ~109-suite verify command) run as PR checks only, so
the check-run view of main HEAD is structurally blind — 4 red mains inside
24h, all caught by hand (model_cap, senior_seat_available,
mark_seat_empty_run/mark_seat_spawn_fail, the shellcheck rc=1 #6158 fixed).

measure.sh gains one line:

    p14-main(main=<12hex>): red suites=shellcheck,b-red,c-gone detail=<path> suites=2
    p14-main(main=<12hex>): ok suites=109

What it runs: the ci.yml `tests` shape — the three static steps with
ci.yml's exact semantics, plus the suite list, PARSED from
.github/workflows/ci.yml (reusable-pr-checks.yml merely executes what
ci.yml passes it — ci.yml is the single source, parsed, never copied) —
against a throwaway worktree of exactly the measured main sha (absolute
temp path, registration pruned, nothing leaked — the #5687 class).
Listed-but-missing suites are named (the #3740 class). Every suite runs
`</dev/null` under `timeout -k 30` (the #3969 hang-kill class); the #6159
sighting — the #22 suite draining the loop's inherited list, pass
truncated at 22/109 — has its own 26-suite regression drill.

Cost (the issue's "runs cheaply — cache by main sha"): the whole verdict
is cached by the 12-hex main sha. Facts (ok/red) are immortal;
UNAVAILABLE verdicts decay after 1h and retry, never frozen blind. The
judge pays the pass once per main-advance; every later read of the same
main is an instant cache hit. Under Actions the line short-circuits
(UNAVAILABLE:ci-context) — the Actions P14 job already covers that exact
commit, and a 109-suite pass inside the 3 measure.sh-executor suites blew
the 30-min budget. Suites that re-execute measure.sh inside the loop see
MEASURE_P14_MAIN=0 and stay silent — the recursion dies.

must-not honored: no new scheduled unit (the line rides measure.sh's
existing invocation), no existing gate weakened (P14, ci.yml, the gates:
untouched), and this is the measure line, not #3345 — no branch
protection, no required-check change; the suites stay advisory on main,
this makes the blindness VISIBLE, which is what the judge acts on.

Detector: lib/measure-p14-main.sh (sourced, not run — the
lib/attest-waiting.sh pattern), wired at the measure.sh tail with the
never-fabricate rule: every failure path prints exactly one
UNAVAILABLE:<why> line — never silence, never a fake ok. Env overrides
(MEASURE_P14_MAIN_TREE/SHA/STATE/TIMEOUT_S/SUITE_TIMEOUT_S) keep it
drill-hermetic: fixture trees, a fixture GIT repo for the production
worktree path, no network.

## Verification

- tests/measure-p14-main.test.sh — 10/10 (25s): the broken fixture names
  every red part (`red suites=shellcheck,b-red,c-gone`, detail file
  written); the fixed fixture prints `ok suites=3`; zero budget →
  UNAVAILABLE:timeout, never a fabricated ok; nested call silent; missing
  tree → UNAVAILABLE:tree-missing; production mode measures the COMMITTED
  red→green shas through a real worktree with no leaked registration and
  the verdict tracks the measured commit; the second call returns the
  STORED verdict (cache); Actions guard; the 26-suite stdin-drill stays
  26 (pass not drained).
- tests/p14-test-listing-gate.test.sh — GREEN (21s): the
  ci-standards-audit host line for measure-p14-main.test.sh is pinned by
  name, reachable, not a known orphan.
- tests/ci-standards-audit.test.sh — 3m38: ALL PASS through the #2133
  hang-stall scenarios; the final rfi-stall-2133 assert (and, isolated, a
  different scenario, wd-hang-3883) trips only while the concurrent
  p14-main production compute runs on this host (litellm readiness
  transient — the proxy answers healthy between runs; two isolated
  reruns fail at DIFFERENT scenarios, the contention signature). The
  detector, measure.sh, and the two touched suites: all green. CI's own
  uncontended P14 pass on this PR is the authority for the timing class.
- shellcheck -x measure.sh; shellcheck -x lib/measure-p14-main.sh — CLEAN.
  Both files sit OUTSIDE ci.yml's shellcheck scope (bin/* + install.sh +
  gate-integrity), so proven here: the SC2155 on the #4566 cursor
  export-assign and the SC2094 read-while-open fd coupling in the suite
  loop are fixed this round (`|| true` keeps the masked-return semantics
  provably unchanged; the list is read once into an array, rm before
  iterate).
- sgscan --base origin/main — "No new security findings." rc=0. (The two
  IFS-tampering WARNINGs of the earlier salvage round were adjudicated
  Act-on: the corpus keeps IFS=, out of lib/ — the join helper is pure
  positional.)
- crgate — skipped, not signed in on this machine (rc 3; the skill says
  do not sign in for Nish); the deterministic gates above are green and
  GitHub-side review covers the PR independently.

run-proof: service p14-main-6159.service — pi-systemd-run (deadline 45m,
deliverable = the verdict line, healthchecks dead-man + OnFailure
escalation armed by the wrapper, started 03:13:31 IST): this branch's
measure.sh computing the REAL production verdict against real origin/main
through the throwaway-worktree path, 109 suites, into the shared cache
(~/workspaces/agent-state/measure/p14-main/<12-hex-sha>). Its journal
already shows the detector's earliest production sightings (the #2133
fixture pi-issue-run phase=exit rc=1 lines at 03:17 — the drill class
this suite exists for, now observed INSIDE the very measure line that
exists to catch them). When the verdict lands it is printed, cached, and
the judge's next measure.sh read of the same main returns it instantly;
the deliverable check fails the unit if the line never lands.

organ-heartbeat: measure.sh, lib/measure-p14-main.sh, tests/* —
not-an-organ: none of them is a registered unit or timer; measure.sh is
the judge header's number source, invoked by its existing callers, its
cadence unchanged; the detector adds no scheduling, only lines.

loose-ends: the first production verdict is pending on
p14-main-6159.service (started 03:13:31 IST, deadline 03:58) — if it
prints UNAVAILABLE:timeout(after=N/109) that verdict is honest, cached,
and decays after 1h to retry; the judge-budget constant
(MEASURE_P14_MAIN_TIMEOUT_S, default 2100s vs the ~34min honest pass) is
a one-env-var decision parked here. The ci-standards-audit's
contention-only #2133 residue: the unit's own uncontended MAIN pass
re-exercises it.

Closes #6159
