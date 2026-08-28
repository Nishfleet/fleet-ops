feat(1464): GitHub push channel via Cloudflare + synthetic canary

Implements the two patterns from fleet-ops#1464:

1. REAL PUSH FROM GITHUB — Cloudflare Worker (`workers/github-push-forward/`) receives org-level webhooks, verifies the GitHub HMAC, and forwards the body through a Cloudflare Tunnel to `libexec/gh-webhook-receiver/serve.py` on the VPS. The receiver re-verifies HMAC (defence-in-depth), dispatches to the matching systemd unit (`pi-intake@<repo>` for `issues/labeled/agent-ready`, `fleet-deploy-check` for `workflow_run/completed/success`), and exports a Prometheus heartbeat.

2. SYNTHETIC CANARY — `bin/gh-webhook-canary.py` fires every 5 min, posts a synthetic `issues/labeled/agent-ready` payload to the local receiver, and bumps the last-green metric. `bin/gh-webhook-canary-deadman.py` checks the metric and writes the alert-repair triage file (plus an optional healthchecks.io fail URL) when the series is missing or stale > 15 min.

The slow `pi-intake@<repo>.timer` cadence drops from `*/15` to `*/20` so it behaves as a reconciler, not the primary trigger. `lib/pi-intake-tick.sh` now increments `fleet_intake_reconciler_caught_total{repo="<repo>"}` per slow-poll catch so a rising count is visible.

New fleet organs (`gh-webhook-receiver`, `gh-webhook-canary`) are registered in `config/fleet-organs.json` with matching `absent()` rules in `config/fleet_rules.yml` (fleet-ops#1010).

Verification:
```
bash tests/gh-webhook-receiver-hmac.test.sh      # 10/10 phases green
bash tests/gh-webhook-canary.test.sh             # 8/8 phases green
bash tests/fleet-intake-reconciler-counter.test.sh # 8/8 phases green
bash tests/gh-webhook-organ-heartbeat.test.sh    # 4/4 phases green
bash tests/timer-manifest.test.sh                # all repo + live timers covered
systemd-analyze verify --man=no systemd/*.service systemd/*.timer
gitleaks git --redact --verbose                    # no leaks
sgscan                                              # no new security findings
find bin -maxdepth 1 -type f ! -name '*.py' ! -name '*.ts' -print | xargs -r shellcheck -x
shellcheck -x install.sh
```
All above passed on the VPS.

run-proof: tests/gh-webhook-receiver-hmac.test.sh + tests/gh-webhook-canary.test.sh + tests/fleet-intake-reconciler-counter.test.sh + tests/timer-manifest.test.sh all passed; systemd user timers active on netcup-rs2000; gitleaks/shellcheck/sgscan clean.

research: official docs and last30days-scale pass (Cloudflare Workers webhooks, GitHub org webhooks + HMAC, Cloudflare Tunnel ingress); compared a hand-built persistent daemon (rejected per no-hand-built-orchestration) and a per-repo GitHub Actions workflow (rejected: one org-level webhook beats N per-repo workflows). Adopted Cloudflare Worker + Tunnel because it keeps the Worker as dumb transport and all logic on the VPS.

help-first: ran `curl --help`, `systemctl --help`, `python3 --help`, and `python3 -m http.server --help` — none can verify a GitHub HMAC signature, forward webhooks through a Cloudflare Tunnel, write a dead-man Prometheus metric, or append an alert-repair triage entry, so the existing tools do not already do this.

Pre-existing (not this PR):
- `tests/rule-enforcement.test.sh` fails locally because `config/rule-enforcement.json` is missing rows for new 2026-08-28 ledger/standing rules; the issue that owns that matrix update is unrelated.
- `tests/ci-standards-audit.test.sh` invokes `tests/seat-health-classifier.test.sh`, which fails only on the VPS because the out-of-repo `~/.pi/agent/extensions/seat-health.ts` is installed and still marks HTTP-200/empty-body as healthy. It is the fleet-ops#1466 closure canary.

Closes #1464
