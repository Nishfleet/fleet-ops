# github-push-forward — Cloudflare Worker

**fleet-ops#1464.** GitHub org webhook → Worker → Cloudflare Tunnel → VPS
`gh-webhook-receiver`. The Worker is **dumb transport**: verify HMAC,
forward the original body, return 200. All routing logic stays on the VPS.

## Endpoints

| Method | Path      | Behavior                                                    |
|--------|-----------|-------------------------------------------------------------|
| POST   | `*`       | Primary ingress. HMAC-verified, forwarded to tunnel URL.    |
| GET    | `/healthz`| Liveness probe. Returns 200 + worker identity JSON.         |

The Worker always returns 200 to GitHub on a successful HMAC verify, even
if the tunnel hop fails — re-deliveries from GitHub would re-trigger
downstream units (and the dead-man canary on the VPS catches a sustained
forward failure within 15 min). A 401 is returned only on a bad HMAC.

## Deploy (Nish, post-merge)

The Worker code is in `fleet-ops/workers/github-push-forward/`. Deployment
requires Nish's Cloudflare account; as a fleet worker we do not deploy.

```sh
# 1. Install wrangler (locally, on a workstation with CF auth)
npm install

# 2. Authenticate to Cloudflare
wrangler login

# 3. Set the secrets (NEVER commit)
wrangler secret put GITHUB_WEBHOOK_SECRET      # same as VPS
wrangler secret put TUNNEL_FORWARD_TOKEN       # shared bearer with VPS

# 4. Set the tunnel URL (safe to commit; override in CF dashboard if needed)
wrangler vars set TUNNEL_FORWARD_URL "https://gh-webhook.tunnel.example.invalid/webhook"

# 5. Deploy
wrangler deploy

# 6. Configure the GitHub org webhook (manual — see docs/github-push-channel.md)
```

## Local development

```sh
npm install
wrangler dev           # listens on http://127.0.0.1:8787
```

In a second terminal, send a test webhook:

```sh
SECRET="dev-secret"
BODY='{"action":"labeled","label":{"name":"agent-ready"},"issue":{"number":1},"repository":{"name":"fleet-ops"}}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $NF}')"
curl -sS -X POST http://127.0.0.1:8787/ \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-Hub-Signature-256: $SIG" \
    --data "$BODY"
```

The dev URL `127.0.0.1:8787` accepts the same payload shape. Without a
valid `TUNNEL_FORWARD_URL`, the Worker returns 200 with `forward: "failed"`
so the developer can iterate without standing up the tunnel.

## Tests

```sh
npm test
```

The tests (`src/index.test.ts`) cover HMAC verification (valid/invalid
signature, malformed hex, missing header, body-length mismatch) plus the
forward contract. They use `node --test --experimental-strip-types`, so
Node 22+ is required.
