# Senior-lane router — design (fleet-ops#5792)

Status: design doc for the senior-lane half of fleet-ops#5792. The router
retry/cooldown/roster numbers described here landed via PR #5811 (2026-09-12);
the seat-caps half is open PR #5834 (Relates, out of scope here). Companion
doc: `docs/design/litellm-vs-seat-lib.md` (LiteLLM-native features replacing
seat-lib buckets).

Source of truth: `config/litellm-proxy.yaml` on `main` (post-#5811). This doc
mirrors that file; the file wins on any drift.

## 1. The senior ladder

The `senior` model group has three deployments (verified in
`config/litellm-proxy.yaml`, 2026-09-13):

| # | Model | Provider / api_base | Tags | Order | max_parallel |
|---|---|---|---|---|---|
| 1 | `openai/z-ai/glm-5.3` | paretoinference `https://api.paretoinference.com/v1` | prepaid, senior | 1 | 2 |
| 2 | `openai/deepseek/deepseek-v4-pro` | xkiro `https://api.xkiro.com/v1` | free, senior | 1 | 1 |
| 3 | `openai/hf:zai-org/GLM-5.3-Flash` | synthetic `https://api.synthetic.new/openai/v1` | prepaid, senior | 2 | 1 |

Two order-1 rungs (pareto glm-5.3, xkiro deepseek-v4-pro) shard traffic first;
synthetic glm-5.3-flash is the order-2 backup rung that only takes load when
the order-1 rungs are cooled down or saturated.

## 2. Router settings (post-#5811)

| Setting | Value | Meaning |
|---|---|---|
| `num_retries` | 2 | up to 2 router retries per request before the client sees the error |
| `allowed_fails` | 1 | a single failure cools a deployment down |
| `cooldown_time` | 300 | benched for 5 minutes |
| `timeout` | 1800 | 30 min per call (senior work is long) |
| `retry_policy` | Auth 2, RateLimit 2, Timeout 1, InternalServer 2, BadRequest 0, ContentPolicy 0 | auth/ratelimit/server errors retry; bad requests and policy violations do not |
| `allowed_fails_policy` | AuthenticationErrorAllowedFails **0**, RateLimit 1, Timeout 1, InternalServer 1 | a single auth error instantly benches a deployment |

## 3. The guarantee: one bad deployment never reaches a worker

When a provider key has no spend left it returns HTTP 403 (spending limit) or
402 (insufficient credits) — LiteLLM surfaces those as authentication errors.
With `AuthenticationErrorAllowedFails: 0` plus `AuthenticationErrorRetries: 2`:

1. the very first failing call against that deployment counts as an
   allowed-fail at threshold 0 → the deployment is benched immediately
   (`cooldown_time: 300`);
2. the router retries the same request on the next rung of the ladder (or the
   order-2 rung, then a fallback group) — never on the benched deployment
   again while it cools;
3. the client never sees the 403/402, and a worker never exits 1 on it.

The `fallbacks` matrix below terminates every group at a live route, so the
retry has somewhere healthy to land:

| Group | Fallback chain |
|---|---|
| `worker-cheap` | → `worker-capable` → `senior` |
| `worker-capable` | → `senior` |
| `senior` | → `worker-capable` (then its own remaining rungs) |
| `judge` | → `senior` |
| `worker-private` | → `worker-capable` |

`worker-capable` must not dead-end — that was fleet-ops#4404.

## 4. History (do not re-decide)

The prepaid Grok and OpenRouter rungs were benched in the yaml by PR #5811 on
2026-09-12 after live probes (403 personal-team, insufficient credits, 401
dead key — see the header comment in `config/litellm-proxy.yaml`). Nish's
money decision of 2026-09-12 stands: prepaid rungs stay benched until a green
probe is cited in a PR. This doc records that history; it does not reopen it.
