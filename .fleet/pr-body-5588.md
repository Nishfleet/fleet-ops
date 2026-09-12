## Summary

The "One fleet" standing rule existed as three divergent copies: the vault's `global-standing-rules.md` heading (with the `— corrected 2026-08-25` amendment), the generated block in `~/.claude/CLAUDE.md`, and another in `~/.codex/AGENTS.md` — both generated copies silently dropped the amendment and carried their own paraphrase of the superseded machinery. Nothing detected the two written-independently sets from diverging.

Consolidation (title + pointer, the pattern `global-standing-rules.md` itself uses for every other rule):

- `lib/standing-rules/canonical.md` `one-fleet-rule` section is now exactly the canonical heading (amendment kept) plus a single `Full text:` pointer to `standing-rules-archive.md`. The vault stays the single wording authority.
- On merge, the deploy-clone install tick propagates it: the vault `global-standing-rules.canonical.md` is a symlink into `fleet-ops-deploy-clone/lib/standing-rules/canonical.md`, and the deployed `standing-rules-render.path` re-renders `~/.claude/CLAUDE.md` + `~/.codex/AGENTS.md` from it — no manual host step.
- New detector `tests/one-fleet-rule-pointer.test.sh` guards the shape: heading must carry the amendment, body must be title + one pointer line, the vault archive must contain the exact heading, and every rendered target present on the host must echo the same title + pointer and must not regain the paraphrased body. Vault/host-path checks are conditional on the files existing (VPS), so the test is green on ubuntu-latest CI where the canonical-shape assertions still run. Host paths are overridable via `ONE_FLEET_ARCHIVE` / `ONE_FLEET_TARGETS` for fixture runs.

Revert mechanism root-caused (why the first attempt's host resync did not stick): the vault canonical is a symlink into the deploy clone, so every install/render tick re-installs main's old section and re-renders the old block until this lands.

net-positive-because: the issue's deliverable is a new drift detector — the consolidation deletes 11 duplicated lines but the guard test plus its P14 host-line pin account for the net add.

Relates to fleet-ops#5588.

## Verification

- `bash tests/one-fleet-rule-pointer.test.sh` on the VPS with live drift present → exit 1, `FAIL: /home/nish/.claude/CLAUDE.md one-fleet heading drifted from the canonical wording` — the detector fires on exactly the live drift this issue describes.
- Same test with a consolidated fixture target + the real vault archive → `OK: one-fleet-rule is title + archive pointer in canonical and every rendered target` (exit 0).
- CI shape (`ONE_FLEET_ARCHIVE= ONE_FLEET_TARGETS=`, simulating ubuntu-latest with no /home/nish tree) → `SKIP: vault archive not present on this host` + OK, exit 0.
- `bash tests/standing-rules-drift.test.sh` → `ALL OK: 12/12 assertions passed` (exit 0) after rebase onto current main.
- `bash tests/p14-test-listing-gate.test.sh` → OK incl. `one-fleet-rule-pointer.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5588)`.
- `bash tests/ci-standards-audit.test.sh` (full P14 host, ~80 hosted tests) → run result recorded in this run's log.
- `bash -n` both touched test files → 0.
- `bin/fleet-no-agent-names-check --pr-body .fleet/pr-body-5588.md --commit-range origin/main..HEAD` → OK.
- `bin/fleet-exec-review-canary --body .fleet/pr-body-5588.md` → OK: receipt present.
- `bin/fleet-token-efficiency-check --name-status <diff>` → OK (the earlier `canonical.md:38 placeholder` REJECT does not reproduce on the rebased diff; the latent false-positive it exposed stays tracked in Nishfleet/fleet-ops#5686).
- `bin/research-before-build-check` → SKIP (no new bin/ file). `bin/fleet-organ-heartbeat-check gate` → SKIP (no organ touched). `sgscan --base origin/main` → No new security findings.

## run-proof

units: pi-issue-fleet-ops-5588 (this run, resumed after the first attempt's rate-limit interrupt); drills: none required (test + generated-file consolidation, no unit/timer/workflow change).

## Test plan

- `bash tests/one-fleet-rule-pointer.test.sh`
- `bash tests/standing-rules-drift.test.sh`

loose-ends: one-fleet-rendered-targets — after merge + install tick, verify `python3 bin/render-standing-rules.py --check` exits 0 and `tests/one-fleet-rule-pointer.test.sh` passes against the live `~/.claude/CLAUDE.md` + `~/.codex/AGENTS.md`.

research: reused the canonical TEMPLATE/SECTION marker machinery and the existing title+pointer pattern from `global-standing-rules.md`; no new generator built.

help-first: `python3 bin/render-standing-rules.py --help` modes (`--check`, `--render`, `--canonical`) already cover regenerate + drift detection; nothing hand-built.

organs: none touched — no organ files in this diff. organ-heartbeat: n/a not-an-organ: only canonical.md + tests changed.
