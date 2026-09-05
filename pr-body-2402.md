## What

Verification record for the 2026-08-30 FleetMainRed incident (trunk red 15:05Z -> 15:40Z). The red is already resolved by fix-forward PR #2406; this PR records the chain, proves main green with a fresh run on the current head, and notes the residual finding's resolution.

## Root cause (verified live)

- Breaking commit: `35964e8` (PR #2399) added `tests/unit-escalation-write-journal-evidence.test.sh` outside the P14 reachable set (no ci.yml listing, no host, no live/destructive tag, no known-orphan entry).
- `p14-test-listing-gate` failed main push run 33317457363 with the orphan FAIL -> trunk red -> FleetMainRed (this issue).
- "P14 tests / PR checks" is a NON-required check by documented design (tests/auto-revert-required-check-gate.test.sh scenario A), so #2399's auto-merge (armed 14:38:22Z) landed 14:39:12Z before the P14 verdict; auto-revert correctly halted (scenario A) with this fix-forward-tracked issue.
- Fix-forward: #2406 (b7e19b5) hosted the orphan from tests/ci-standards-audit.test.sh. Main green since.

## Verification

- Fresh remote run on current main head `da10f9950`: push-triggered CI run 33331499649 (created 2026-08-30T19:39:54Z, conclusion=success); all check-runs on the head completed (P14, Gitleaks, Semgrep, Shellcheck, systemd-analyze success; auto-revert + mass-close guard skipped) -> rollup SUCCESS -> fleet_main_ci_green = 1.
- Local (worktree at da10f9950, no local changes): tests/p14-test-listing-gate.test.sh all OK (previously-orphaned test now reachable), tests/unit-escalation-write-journal-evidence.test.sh OK, tests/escalation-units-shape.test.sh OK.

run-proof: fresh push run https://github.com/Nishfleet/fleet-ops/actions/runs/33331499649 conclusion=success on da10f9950 (event=push, not a rerun).

## Mechanical-fix

Class: "new tests/*.test.sh merged outside the P14 reachable set turns main red". Existing mechanisms that fired in this incident: p14-test-listing-gate (detector, hosted in ci-standards-audit.test.sh) and auto-revert scenario A (auto-files the halt issue). mechanism-impossible: binding "P14 tests / PR checks" as a required check — the only change that stops a P14-red merge at merge time — is branch-protection config under Administration scope; the worker app token is 403 on branch-protection read/write (verified) and workers are platform-rejected from .github/workflows/** edits. P14 non-required is the fleet's documented design; flipping it is an admin decision.

## Out-of-scope finding (filed, then resolved)

tests/ci-standards-audit.test.sh fails on the VPS at tests/seat-health-seat-dead.test.sh D10 (c25-wall null vs 86400): pre-existing on main, unrelated to this incident — the live seat-health extension (hot-patched for open #2415) sets corpse usable_at=null; the in-repo closure test expectation was stale; CI cannot see it (test skips without the extension). Filed as #2422, resolved by #2425 (c455587, merged 2026-08-30T19:05Z); current main's D10 expectation matches the extension.

Closes #2402