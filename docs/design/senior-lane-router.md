# Senior-lane router — design (fleet-ops#5792)

Status: living mirror of `config/litellm-proxy.yaml`. The router
retry/cooldown/roster numbers landed via PR #5811 (2026-09-12); the roster
collapsed to a single upstream per group during the 2026-09-18/19 seat
failures (fleet-ops#7862) and the repo re-converged to the live file on
2026-09-21 (the #6732 closed-incident posture). Companion doc:
`docs/design/litellm-vs-seat-lib.md` (the P0 design record — historical, not
a mirror).

Source of truth: `config/litellm-proxy.yaml` on `main`. This doc mirrors that
file; the file wins on any drift.

## 1. The senior ladder

Every model group — `worker-cheap`, `worker-capable`, `senior`, `judge`,
`worker-private` — currently carries exactly ONE deployment
(verified in `config/litellm-proxy.yaml`, 2026-09-21):

| # | Model | Provider / api_base | Tags | Order | max_parallel |
|---|---|---|---|---|---|
| 1 | `openai/z-ai/glm-5.3-flash` | paretoinference `https://api.paretoinference.com/v1` | prepaid (+group tag) | 1 | 2 (worker-private: 1) |

Every other rung sits in the yaml's `benched:` block with a dated reason and a
restore contract (green `/health` AND, for worker groups, a real
`finish_reason=tool_calls` probe). The live proxy may carry additional
restored rungs ahead of their mirror PR — on 2026-09-21 that was the
`cline/stealth/union-alpha` set owned by fleet-ops#7366.

The single-upstream shape means `order:` does no work today — under
`routing_strategy: simple-shuffle` it is documentation anyway
(fleet-ops#4643). Failover is cooldown + group fallbacks, and
`health_check_concurrency: 1` serialises `/health` so the shared pareto
account is not 429'd by a parallel census (fleet-ops#7862).

## 2. Router settings (converged 2026-09-21)

| Setting | Value | Meaning |
|---|---|---|
| `num_retries` | 0 | no same-group retry — with one upstream per group a retry can only re-hit the same wall (the #6732 retry-storm lesson, re-measured 2026-09-20: 588 RouterRateLimitError rejections in 88 min under 300/2/2) |
| `allowed_fails` | 1 | a single failure cools a deployment down |
| `cooldown_time` | 60 | benched for 1 minute |
| `timeout` | 1800 | 30 min per call (senior work is long) |
| `retry_policy` | Auth 2, RateLimit **0**, Timeout 1, InternalServer 2, BadRequest 0, ContentPolicy 0 | rate-limit retries are what flooded the fallback chain; auth/server errors still retry |
| `allowed_fails_policy` | AuthenticationErrorAllowedFails **0**, RateLimit 1, Timeout 1, InternalServer 1 | a single auth error instantly benches a deployment |

If groups regain multiple healthy upstreams, `num_retries>=2` becomes
meaningful again — that is the original #5792 spec, suspended only by the
single-upstream roster.

## 3. The guarantee: one bad deployment never reaches a worker

When a provider key has no spend left it returns HTTP 403 (spending limit) or
402 (insufficient credits) — LiteLLM surfaces those as authentication errors.
With `AuthenticationErrorAllowedFails: 0` plus `AuthenticationErrorRetries: 2`:

1. the very first failing call against that deployment counts as an
   allowed-fail at threshold 0 → the deployment is benched immediately
   (`cooldown_time: 60`);
2. the router retries on another deployment — and once the group is
   exhausted, the `fallbacks` matrix hands the request to the next group;
3. the client never sees the 403/402, and a worker never exits 1 on it.

The `fallbacks` matrix terminates every group at a live route:

| Group | Fallback chain |
|---|---|
| `worker-cheap` | → `worker-capable` |
| `worker-capable` | → `worker-cheap` |
| `senior` | → `worker-capable` |
| `judge` | → `senior` |
| `worker-private` | → `worker-capable` |

`worker-capable` must not dead-end — that was fleet-ops#4404. The two worker
groups fall back to each other; if both are down the call errors LOUDLY rather
than silently degrading (fleet-ops#7761: a non-tool-calling rung in a worker
group produces empty-run workers that exit 0 — worse than an error).

Dead-deployment detection rides the proxy's own
`litellm_deployment_state` metric: the `FleetLitellmDeploymentUnhealthy` rule
in `config/fleet_rules.yml` fires when a raw deployment row stays >0 for 10m
(the post-sweep successor of the retired health-canary organ — the canary's
job, expressed as a stock Prometheus rule).

## 4. History (do not re-decide)

The prepaid Grok and OpenRouter rungs were benched in the yaml by PR #5811 on
2026-09-12 after live probes (403 personal-team, insufficient credits, 401
dead key — see the header comment in `config/litellm-proxy.yaml`). Nish's
money decision of 2026-09-12 stands: prepaid rungs stay benched until a green
probe is cited in a PR.

2026-09-20/21 audit trail (fleet-ops#5792 converge): the live yaml carried
unmerged outage-repair edits — synthetic worker-cheap (re-failed on the same
429 subscription wall; direct probe 2026-09-21) and nemotron-3-ultra
worker-capable (failed the tool_calls gate 5/5 — the #7761 class). Both were
re-benched live and recorded in their `benched:` entries. The Cline
union-alpha rungs + `custom_provider_map` remain live-only under
fleet-ops#7366; the repo shape omits them deliberately so it deploys as
written.

This doc records that history; it does not reopen it.
