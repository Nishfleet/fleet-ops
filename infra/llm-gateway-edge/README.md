# Edge guard of the gh-aw pilot gateway

OpenTofu config for the three hand-made Cloudflare objects behind the tunnel
that carries the gh-aw pilot's two router paths (fleet-ops#11371, finding 2;
design #11311, tunnel PR #11394):

| Object | Resource | What it does |
|---|---|---|
| Access app "gh-aw pilot gateway" | `cloudflare_zero_trust_access_application` | Only callers with a valid Access JWT reach the origin; the JWT is read from the `Authorization` header as one JSON value |
| Access policy | `cloudflare_zero_trust_access_policy` | Service Auth: admits only the service token `gh-aw-pilot` |
| Late-transform rule | `cloudflare_ruleset` (`http_request_late_transform`) | Sets `x-litellm-api-key` to the pilot router key, so only that key reaches the router |

The connector independently verifies the Access JWT (`originRequest.access` in
`config/cloudflared/llm-gateway.yml`, pinned by `tests/test_llm_gateway_tunnel.py`),
so a deleted or loosened Access app cannot open the path. That check pins the
app's AUD tag; after any apply, compare this stack's `access_aud` output with
the value in the config — the CI test fails when they drift.

CI runs `tofu fmt -check`, `tofu init -backend=false` and `tofu validate` here
(`cloudflare-tokens-tofu` in `.github/workflows/ci.yml`). It never plans or
applies: this box has the credentials, CI has none.

## State

State holds the pilot router key (it sits inside the transform rule), so it
lives outside the repo like the `infra/cloudflare-tokens` state:
`/home/nish/.local/state/fleet-ops/llm-gateway-edge/terraform.tfstate`,
encrypted with the same `TF_ENCRYPTION` file
(`~/.config/cloudflare/tofu-state-encryption.env`; see
`infra/cloudflare-tokens/state-encryption.env.example`).

## Apply

1. Mint a token with: `Access: Apps and Policies Read` and `Write` (account),
   `Access: Service Tokens Read` (account), `Zone Read` and zone-ruleset edit
   on `nish.sh`. The mint gate is `docs/cloudflare-credentials.md`.
2. Export it: `CLOUDFLARE_API_TOKEN` comes from a 0600 env file under
   `~/.config/cloudflare/`, never from the repo or a shell history line.
3. Set the key: read the header value from the live rule (GET the zone
   ruleset, phase `http_request_late_transform`) and set
   `TF_VAR_pilot_router_key` in the same shell. Never print it.
4. `tofu init && tofu plan` — after the import below, an empty plan means the
   config matches the live objects.
5. `tofu apply`.

The objects exist today (made by hand on 2026-10-31), so the first run imports
them instead of creating replacements:

```sh
tofu import cloudflare_zero_trust_access_application.pilot_gateway "$ACCOUNT_ID/<app-id>"
tofu import cloudflare_zero_trust_access_policy.service_auth "$ACCOUNT_ID/<policy-id>"
tofu import cloudflare_ruleset.pilot_key_transform "$ZONE_ID/<ruleset-id>"
```

Find the ids with the same token: list Access apps and pick the one named
"gh-aw pilot gateway"; list its policies; GET the zone's rulesets by phase
`http_request_late_transform`. If the plan after import shows drift in app
settings this config does not set (session duration, custom deny pages), add
them to `main.tf` so the next reviewer sees the real shape instead of a
permanent diff.

## Scope

The tunnel itself, its DNS record and its credentials file stay hand-made
(docs/RUNBOOK.md, "gh-aw pilot gateway"); this stack is only the edge guard.
The pilot router key has no money budget: the per-row caps are the only spend
limit (docs/RUNBOOK.md names the host step that gives it one).
