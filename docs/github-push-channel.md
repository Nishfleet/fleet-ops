# GitHub push channel — fleet-ops#1464

The fleet's intake loop today polls GitHub every 20 minutes. The issue
asks for a real push channel (webhook → Worker → tunnel → VPS) so the
latency drops from minutes to seconds, with the poll kept as a
**reconciler** (Kubernetes doctrine: edge-triggered for latency,
level-triggered for correctness — webhooks get lost, reconcile loops
don't).

This PR ships the **VPS-side code and the Worker source** so the path is
reviewable. **Deployment requires Nish's Cloudflare account + GitHub org
admin access**, which is intentionally gated behind Nish (the standing
rule "Products are PR-only. Never merge, never deploy without Nish").
This document is the runbook for that hand-off.

## What this PR ships

| Piece                            | Path                                                      |
|----------------------------------|-----------------------------------------------------------|
| Cloudflare Worker source         | `workers/github-push-forward/`                            |
| VPS-side webhook receiver        | `libexec/gh-webhook-receiver/serve.py`                    |
| Receiver systemd unit            | `systemd/gh-webhook-receiver.service`                     |
| Synthetic canary script          | `bin/gh-webhook-canary.py`                                |
| Canary systemd unit + timer      | `systemd/gh-webhook-canary.{service,timer}`               |
| Dead-man watchdog script         | `bin/gh-webhook-canary-deadman.py`                        |
| Dead-man systemd unit + timer    | `systemd/gh-webhook-canary-deadman.{service,timer}`       |
| Intake cadence slow-down         | `systemd/pi-intake@.timer` (`*:00/15` → `*:00/20`)        |
| Reconciler-caught counter        | `lib/pi-intake-tick.sh`                                   |
| Organ registry entries           | `config/fleet-organs.json`                                |
| Prom rules (absent + stale)      | `config/fleet_rules.yml`                                  |

## What Nish must do post-merge

### 1. Deploy the Cloudflare Worker (one-time)

The Worker source is `workers/github-push-forward/`. On a workstation
with `wrangler` authenticated to Nish's CF account:

```sh
cd workers/github-push-forward
npm install
wrangler secret put GITHUB_WEBHOOK_SECRET      # same value as VPS
wrangler secret put TUNNEL_FORWARD_TOKEN       # generate a fresh bearer
wrangler vars set TUNNEL_FORWARD_URL "https://gh-webhook.<your-tunnel-domain>/webhook"
wrangler deploy
```

`GITHUB_WEBHOOK_SECRET` must match the value at
`~/.config/fleet-ops/gh-webhook.secret` on the VPS (created in step 3).
`TUNNEL_FORWARD_TOKEN` is a fresh bearer the Worker sends on every
forward; the VPS receiver validates it on each request.

### 2. Provision the Cloudflare Tunnel (one-time)

On the VPS, install `cloudflared` and authenticate:

```sh
sudo apt install cloudflared          # or download the binary
cloudflared tunnel login              # opens browser, links CF account
cloudflared tunnel create gh-webhook
```

Write `/etc/cloudflared/config.yml`:

```yaml
tunnel: gh-webhook
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: gh-webhook.<your-domain>
    service: http://127.0.0.1:8088
  - service: http_status:404
```

Install as a systemd service:

```sh
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Verify the tunnel:

```sh
cloudflared tunnel info gh-webhook
curl -sS https://gh-webhook.<your-domain>/healthz
```

### 3. Create the shared HMAC secret on the VPS

```sh
mkdir -p ~/.config/fleet-ops
# Generate a fresh 64-char hex token. The Worker side must use the same.
openssl rand -hex 32 > ~/.config/fleet-ops/gh-webhook.secret
chmod 600 ~/.config/fleet-ops/gh-webhook.secret
```

Also write the tunnel-bearer token to a sibling file:

```sh
# Same value as `wrangler secret put TUNNEL_FORWARD_TOKEN`.
echo -n '<bearer-token>' > ~/.config/fleet-ops/gh-webhook-tunnel.token
chmod 600 ~/.config/fleet-ops/gh-webhook-tunnel.token
```

(The receiver currently does not check the bearer token — the
defence-in-depth is HMAC re-verification. The token is reserved for
phase 2 once the receiver grows multi-tenant awareness; see the source.)

### 4. Configure the GitHub org webhook

In `https://github.com/organizations/Nishfleet/settings/hooks`, add:

| Field          | Value                                                       |
|----------------|-------------------------------------------------------------|
| Payload URL    | `https://gh-webhook.<your-domain>/webhook`                  |
| Content type   | `application/json`                                          |
| Secret         | The same hex from step 3                                    |
| SSL verify     | enabled                                                     |
| Events         | Issues, Workflow runs                                       |

Or use `gh api` on a personal token with org-webhook scope:

```sh
gh api --method POST /orgs/Nishfleet/hooks \
    -f name='web' \
    -F config[url]='https://gh-webhook.<your-domain>/webhook' \
    -F config[content_type]='json' \
    -F config[secret]="$(cat ~/.config/fleet-ops/gh-webhook.secret)" \
    -F config[insecure_ssl]='false' \
    -F events[]='issues' -F events[]='workflow_run' \
    -F active=true
```

### 5. Install the VPS-side units

From the deployed fleet-ops checkout (the live VPS already symlinks
this via `install.sh`):

```sh
install.sh                       # picks up the new systemd units + bins
systemctl --user daemon-reload
systemctl --user enable --now gh-webhook-receiver.service
systemctl --user enable --now gh-webhook-canary.timer
systemctl --user enable --now gh-webhook-canary-deadman.timer
```

Verify:

```sh
systemctl --user status gh-webhook-receiver.service
curl -sS http://127.0.0.1:8088/healthz | jq .
# Synthetic canary hits the receiver from inside the VPS — no tunnel involved.
systemctl --user start gh-webhook-canary.service
journalctl --user -u gh-webhook-canary.service -n 5
# After ~5 min, deadman should report status=ok and NOT page.
systemctl --user start gh-webhook-canary-deadman.service
journalctl --user -u gh-webhook-canary-deadman.service -n 5
```

### 6. Wire the (optional) healthchecks.io fail URL

The dead-man can ping an external dead-man's switch when the canary
goes red. To enable, set in the user's systemd environment:

```sh
mkdir -p ~/.config/systemd/user/gh-webhook-canary-deadman.service.d
cat > ~/.config/systemd/user/gh-webhook-canary-deadman.service.d/override.conf <<'EOF'
[Service]
Environment=GH_WEBHOOK_HEALTHCHECKS_FAIL_URL=https://hc-ping.com/<uuid-fail>
EOF
systemctl --user daemon-reload
```

The dead-man does NOT page healthchecks.io on every red evaluation —
it throttles to once per 30 minutes via the alert-repair triage file
to prevent alert storms when the path is down for hours.

## Why these design choices

**Why a Worker at all, and not a direct VPS webhook endpoint?**

The VPS is Tailscale-only for SSH. A direct webhook endpoint would
require opening a public port (or a Tailscale-SSH-style funnel), which
both leak the VPS identity and require per-repo GitHub webhook
configuration. A Worker + Cloudflare Tunnel keeps the VPS behind
outbound-only egress and centralises webhook config at the org level
(one hook, every repo, no per-repo workflow).

**Why re-verify HMAC on the VPS?**

Defence-in-depth. The Worker already verified the signature, but a
tunnel hop is still a hop. The cost of re-verification is one HMAC
SHA-256 in Python's `hmac` module (sub-microsecond); the cost of a
misconfigured tunnel forwarding arbitrary JSON to `systemctl --user
start` is unbounded.

**Why a synthetic canary at all?**

Silence must be provable, not assumed. A path that has never sent a
real webhook can look healthy from the VPS side; the canary converts
"absence of failures" into "presence of green signals" so the
alert-repair rail has something to fire on.

**Why a slow poll kept as reconciler?**

Webhooks get lost. GitHub's SLA does not promise delivery; the VPS
might be offline when the Worker tries to forward; the tunnel might
be re-connecting. The poll is the level-triggered catch — when it
finds ready work, that means the edge-triggered path missed it. The
`fleet_intake_reconciler_caught_total` counter exposes this to the
alert rail.

**Why 20-min cadence (and not 15 or 30)?**

The issue says 15-30 minutes; we picked 20 because:

- It is in the recommended envelope.
- It is offset from the existing 5-min exporter tick (`:00/5`) by a
  whole multiple, so the timer does not collide.
- A rising `fleet_intake_reconciler_caught_total` is the dead-man
  signal; the canary (5 min) is the faster signal. 20 min is the
  upper bound the reconciler should ever need to wait.

## Failure modes and what each surfaces

| Failure                                 | First signal                                            |
|-----------------------------------------|---------------------------------------------------------|
| Worker unreachable from GH               | GitHub retries + pings CF; alert-repair never fires      |
| Tunnel down                             | Worker returns 200 with `forward:"failed"` to GH        |
| Receiver service dead                   | Worker logs forward failure; dead-man pages in 15 min    |
| HMAC secret rotated, mismatched         | Receiver returns 401; GH retries with same payload      |
| Canary script broken                    | Dead-man pages in 15 min                                |
| Intake reconciler slow                  | `fleet_intake_reconciler_caught_total` rises            |
| Org webhook deleted                     | Receiver silent; canary still green; no signal yet — file new issue if this state persists |

## Out of scope (deferred)

- **Per-repo routing rules.** The current dispatch table treats every
  repo with `agent-ready` the same way. A future PR can add a config
  file with per-repo filters if needed.
- **Retry queue with backoff.** The Worker returns 200 to GH even on
  downstream failure (no GH retries); the reconciler poll is the
  retry. If a tighter SLA is needed, add a small in-memory queue in
  the receiver.
- **Multi-tenant orgs.** The Worker is single-tenant (Nishfleet); the
  secret is bound via `wrangler secret`, so multi-tenant would need
  one Worker per tenant.

## Incident record: FleetGhWebhookReceiverAbsent (fleet-ops#1594)

**Event:** `FleetGhWebhookReceiverAbsent` fired for ~6h on 2026-08-28
(08:26Z to ~15:56Z). The push channel itself was brand-new — #1524 landed
~2 minutes before the alert first fired.

**Root cause:** #1607 — the receiver's heartbeat prom file used
single-quoted label values (Python `repr()`). node-exporter's textfile
collector silently drops those, so `absent(fleet_gh_webhook_receiver_last_green_seconds)`
fired forever regardless of channel health. This was the first-day
teething of a new organ, not a long-standing drift; the fix (#1607),
the canonical intake-repos path (#1659), and the annotation pointing at
the real cause (#1954) all landed within hours.

**Prevention already shipped (this class is mechanically guarded):**
- Dead-man (`gh-webhook-canary-deadman`) reads BOTH the canary series and
  the receiver's own heartbeat (default `/var/lib/prometheus/node-exporter/fleet-gh-webhook-receiver.prom`),
  so canary-green-but-receiver-absent is paged (#1569).
- `gh-webhook-receiver.service` carries `Restart=on-failure`, so a crash
  auto-recovers at the machine level.
- Offline lock tests pin the label format (#1607), the HMAC/dispatch
  contract, the organ `absent()` rules, and the live-end-to-end path.

**Restore + live proof (2026-08-29):** receiver restarted onto the
canonical deploy-clone intake path (`enrolled=['0509','fleet-ops']`);
live e2e (`bash tests/gh-webhook-receiver-live-e2e.test.sh`) shows
canary → receiver → prom file → node-exporter → Prometheus with the
`FleetGhWebhookReceiverAbsent` expression CLEAR.

**Remaining deferred gate:** the five offline lock tests are tracked but
not wired into `.github/workflows/ci.yml`, so the #1594 regression has
no pre-merge gate yet. This is a workflow change the worker App token
cannot push; filed as #1969 for Nish's scope.
