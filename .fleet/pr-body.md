## What

Absorbs the hand-placed `fable-fleet-check.service.d/30-skip-litellm-drained.conf` drop-in into the repo + MANIFEST so deploy symlinks it and the drop-in hunt (fleet-ops#2924/#1548) stays clean.

The drop-in is a **temporary** override (fleet-ops#4410): it sets `Environment=AGENT_CRON_SKIP_LITELLM=1`, routing fable-check back to seat-lib `pick_seat` while the LiteLLM proxy judge chain is drained (openrouter 402 credits + grok-oauth 426 CLI version gate). It uses the existing, tested `AGENT_CRON_SKIP_LITELLM` escape hatch in `bin/agent-cron-run` — a pure config override, **not new machinery** — so no senior-conference routing is needed.

**REMOVE WHEN** the durable seat-lib fallback lands (fleet-ops#4410) or openrouter credits are restored AND the P3 native Cursor adapter exists — then delete this drop-in and re-enable P2.

## Verification

- `bin/fleet-machinery-authorization-gate evaluate` on the diff → `PASS` (drop-in `.conf` is not a new unit; `fable-fleet-check` is allowlist class a).
- `tests/machinery-authorization-gate.test.sh` → all OK, exit 0.
- `tests/install-manifest-comment-purity.test.sh` → OK, exit 0.
- `tests/install-manifest-bak-sprawl.test.sh` → OK, exit 0.
- `tests/manifest-required-bins.test.sh` → OK, exit 0.
- `tests/agent-cron-fable-check-litellm-routing.test.sh` → OK, exit 0 (escape hatch still works).
- `tests/fleet-ops-drift-metrics-dropin.test.sh` → PASS, exit 0.
- `tests/pi-transport-check-dropin-428.test.sh` → OK, exit 0.
- Full CI suite (81 tests): 76 pass, 5 fail — all 5 failures are **pre-existing on clean main** (escalation-coverage-canary timeout, prometheus-retention-40d + system-dropins-shape `install.sh --check --system` routing, rule-enforcement + timer-manifest live-timer drift). My change introduces zero new failures.
- `sgscan --base origin/main` → "No new security findings", exit 0.

run-proof: machinery-authorization-gate evaluate PASS; 7 relevant test suites green; sgscan clean; full-suite delta vs main = 0 new failures.

net-positive-because: absorbing a live hand-placed drop-in into the repo + MANIFEST is the point of the gap-audit finding — it makes the override reproducible and repo-sourced so the drop-in hunt stays clean; the added lines are the drop-in file + its MANIFEST entry + explanatory comments.

Closes #4415
