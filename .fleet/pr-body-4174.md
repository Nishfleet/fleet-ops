## What and why

fleet-ops#4174 (LiteLLM P1 proxy organ) was delivered by #4178 and repaired by #4221; every deliverable and acceptance check is green on main. Two loose ends remained, both closed here:

1. **The issue was never auto-closed.** #4178's body used `Closes fleet-ops#4174.` — the same-repo cross-repo short form GitHub does not auto-close (fleet-ops#695). The issue stayed open and the intake kept re-dispatching workers onto already-merged work. This is the closeout PR on the issue's own `claim/issue-4174` branch with the correct `Closes #4174` trailer.
2. **The proxy unit's documented storm cap was inert.** `StartLimitIntervalSec=60s` / `StartLimitBurst=5` sat in `[Service]`; systemd 255 ignores them there (`systemd-analyze verify` before: `Unknown key name 'StartLimitIntervalSec' in section 'Service', ignoring.`), so the comment's claim "systemd caps the storm with StartLimit* below" silently fell back to the 10s/5 default. This fix moves them to `[Unit]` — the repo convention (pi-intake@.service, fleet-deploy-check.service) — so the P4-drill contract is real: 5 rapid failures parks the proxy for the rest of the minute instead of retry-churning at `RestartSec=2s`.

## Change

- `systemd/fleet-litellm-proxy.service` — `StartLimit*` moved from `[Service]` to `[Unit]`, comments corrected. Single file; no behavior change to any other unit, no new file, no new machinery.

## Verification

- `systemd-analyze verify systemd/fleet-litellm-proxy.service` → PASS (pre-fix: `Unknown key name 'StartLimitIntervalSec' in section 'Service', ignoring.`; post-fix: no unit errors — the only remaining warning is the unrelated VPS system unit `tiny-studio-smb-bridge.service`, untouched by this PR).
- `bin/fleet-organ-heartbeat-check verify` → `OK: all 27 registered organs have an absent() heartbeat rule`.
- `bash tests/fleet-litellm-organ.test.sh` → `ALL OK: fleet-litellm-organ` (registry, absent() rules, prom scrape job, MANIFEST, canary compile + fail-open/fail-loud, no credential in repo, organ-heartbeat verify).
- `bash tests/fleet-organ-heartbeat.test.sh` → `ALL PHASES PASSED`.
- `bash tests/manifest-shape.test.sh` → PASS.
- `bash tests/timer-manifest.test.sh` → shape lock PASS; LIVE check reports the pre-existing `0509-demo-brand-timeline-canary.timer` gap (unit not in this repo; filed as fleet-ops#4247 at 13:51Z, before this unit; unrelated to this diff — the LiteLLM canary timer has a manifest entry).
- Credential scan: diff contains no key material — only comments and the two moved StartLimit keys.
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → `OK: no agent attribution detected`.

## run-proof

- Live systemd units/timers: `fleet-litellm-health-canary.timer` is active on the VPS (proves the organ's canary leg is installed and running on its 60s cadence). The proxy/Postgres/Redis units are deliberately NOT live (fleet-ops#4174: paper + installable, Nish-gated install; runbook `docs/litellm-postgres-setup.md`).
- CI workflows that will gate this PR: `P14 tests` (reusable-pr-checks) + `Shellcheck` + `systemd-analyze` + `Semgrep` + `Gitleaks` on the fleet-ops repo (`.github/workflows/ci.yml`).
- This change adds zero running units, zero timers, zero workflows (net machinery: -0; the program delta was recorded in #4178: +4 running units, +1 config yaml, +1 canary bin, with the P3 delete of seat-lib making the program net-negative).

## Test plan

- Re-run `bash tests/fleet-litellm-organ.test.sh`, `bash tests/fleet-organ-heartbeat.test.sh`, `systemd-analyze verify systemd/fleet-litellm-*.service` after merge — all should stay green.
- Live (Nish-gated later): after the Postgres/Redis/LiteLLM install, `systemctl --user start fleet-litellm-proxy.service` and confirm a crash-loop parks the unit after 5 failures in 60s rather than churning at 2s.

## Rollback

`git revert` this commit. Nothing live depends on the StartLimit placement (the proxy unit is not yet live-installed), so rollback has zero fleet impact.

Closes #4174