fix(litellm): bench dead-credit deployments so /health unhealthy_count=0

Head of the #6054 gate deadlock: 4x openai/deepseek/deepseek-v4-pro (xkiro, dead-credit, #3284) still deployed in the active senior/judge/worker-capable/worker-cheap groups, 503ing /health (unhealthy_count=4 at 15:47Z). That parks #5792 (awaiting-runtime-gate, accept: unhealthy_count=0), which parks #5806, which gates 0509#3195-#3210. Box at 94% idle next to ready work.

What changed (deletion-first: zero new files, zero new machinery):

- config/litellm-proxy.yaml: the 4 dead-credit xkiro deployment entries leave model_list; ONE `benched:` top-level block holds them with a dated one-line reason (2026-09-12, dead-credit #3284) and the `was: [senior, judge, worker-capable, worker-cheap]` census. `benched` is inert: not routed, not counted by the canary's expected-census (only `- model_name:` lines count).
- libexec/fleet-litellm-health-canary.py: #5792's accept-line drill, inside the existing canary — a POPULATED census that still carries an unhealthy deployment exits 1 naming the affected groups (verdict: health-deployment-unhealthy). Organ-up is not fleet-green: the 2026-09-12 unhealthy_count=4 starved the box while every organ heartbeat stayed 1. prom + state still write BEFORE the exit so the affected-group gauge stays scrapeable through the failure.
- tests: tests/fleet-litellm-organ.test.sh #18/#18b; tests/forced-bad-deployment-replay.test.sh expectations moved to the post-bench shape (senior 3 -> 2 deployments).

Convergence (exactly ONE proxy restart — already executed, by the prior unit run before it was killed):

- live ~/.config/fleet-ops/litellm-proxy.yaml is diff-identical to this branch; fleet-litellm-proxy.service restarted ONCE at 21:58:43 IST (16:28:43Z), NRestarts=0 since, single ActiveEnterTimestamp. No further restart needed: the unit read the converged config at 21:58:43.
- the repo file is the source of truth (fleet-ops#5811): this PR lands the converged shape in the repo, so main matches live again. Until it lands, origin/main still shows the 4 deployments while the live proxy serves 13.

Verification:

- tests/fleet-litellm-organ.test.sh -> ALL OK, incl. #18: new canary exit 1 + health-deployment-unhealthy verdict + prom gauge scrapeable + proxy_up=1 preserved; #18b: all-healthy (benched) census quiet exit 0.
- fails-before proof: the #18 scenario run against origin/main's canary exits 0 (drill absent, blind) — the test fails before and passes after.
- tests/forced-bad-deployment-replay.test.sh -> ALL OK (senior=2, 2 live rungs + worker-capable fallback; negative allowed_fails=5 drift check still fails correctly).
- tests/agent-cron-fable-check-litellm-routing.test.sh, tests/pi-seat-source-litellm.test.sh, tests/fleet-token-economy.test.sh, tests/fleet-ops-3310-infra-death-class-switch.test.sh -> ALL OK.
- sgscan --base origin/main -> No new security findings.
- live /health: unhealthy_count 4 -> 0 (healthy_count=13); new canary against the live proxy: proxy_up=1 status=200 census=13 expected=13 groups=5, EXIT=0.
- pi --print --provider litellm --model senior: 3/3, exit 0.
- 60-min post-convergence window (21:59-22:59 IST, fully elapsed): 5 pi-issue@* exit-1 records, ALL reason=no-seat start-bounces in 21:59:03-21:59:12 IST (post-StartLimitBurst churn); zero 401/402/403/429 deaths.

run-proof:

- unit fleet-litellm-proxy.service: active since 21:58:43 IST, NRestarts=0 (the ONE convergence restart).
- timer fleet-litellm-health-canary.timer: 60s cadence, service Result=success ExecMainStatus=0 (23:09:00 IST) — the deployed census stays all-healthy under the current canary, and this PR's drill makes the NEXT dead deployment fail loud.
- live senior probe: 3/3 (above).

organ-heartbeat: libexec/fleet-litellm-health-canary.py — organ fleet-litellm-health-canary.timer (registered, 60s, still firing success); the drill preserves the absent()-style invariant by keeping prom/state written before any exit, so the affected-group gauge stays scrapeable through the failure.

loose-ends: #5806 accept line still cites ram_gb_per_worker=1.0 — a key deleted with lib/seat-lib.sh in #4263 and absent from config/seat-caps.json. #5806's termination clause must be re-worded against the post-#4263 governor before its capacity proof can run; tracked on #5806, deliberately not bundled here (separate, per #6054).

Closes #6054
