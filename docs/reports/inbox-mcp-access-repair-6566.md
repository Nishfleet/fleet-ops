# 0509-support-inbox Access service-token repair — issue #6566, 2026-09-20

Live credential repair, completed and verified from this host. No code change
shipped; the durable artifacts are this record plus the rewritten on-host
credential file.

## Root cause (corrects the issue's theory)

The issue read the edge rejection as a revoked/expired
`claude-support-inbox-mcp` token. Live evidence shows a different failure:

- `~/.config/cloudflare/inbox-mcp-service-token.json` was overwritten on
  2026-09-07 by a short-lived `fleet-pw-signup` mint — token_id
  `e0234704-215e-4c07-b8d2-dc3e71b5bd5c`, expired `2026-09-07T17:12:51Z`.
  The file held a dead token; that is what the edge rejected.
- The two original `claude-support-inbox-mcp` service tokens
  (`102231e3-6497-4efd-b006-18c40c022bf5`, `f04b55c0-6b8a-42c1-af90-1469cba62035`,
  minted 2026-06-11, expiry 2027-06-11) still exist server-side, and
  non_identity policy `0a7ec9bb` still pins `102231e3` — but service-token
  secrets are never re-exposed after minting, so the originals are unusable
  to this host.
- Access app `b79d74fb-36af-44ea-949b-856f078433b1` ("0509-support-inbox -
  Cloudflare Workers", aud `e7eb8386…`, domain
  `0509-support-inbox.nishant345.workers.dev`) pins service tokens by id in
  its policies — a bare mint is not admitted without a policy pin.

## Actions (2026-09-20, this host)

- Probed host API tokens against
  `/accounts/f670a698e17bf160c8e4679823e68916/access/service_tokens`:
  `deploy.env` and `deploy-ci.env` read a scoped-empty list and POST
  `auth.forbidden` (code 1010). `CLOUDFLARE_EMAIL_TOKEN` (`email.env`) and
  the `deploy.env.bak-p60b-20260824` rotation-backup token both hold Access
  service-token write.
- Two `probe-scope-check-do-not-use` service tokens created during the scope
  probe were deleted in the same run (HTTP 200 on DELETE).
- Minted service token `claude-support-inbox-mcp`, id
  `ed4c9418-087d-41be-8a08-813e42162ae3`, duration 8760h, expires
  `2027-09-20T02:44:23Z`.
- Rewrote `~/.config/cloudflare/inbox-mcp-service-token.json` (0600) with the
  new `client_id`/`client_secret`/`name`/`token_id` — the same shape
  `setup-inbox-mcp.py` writes.
- PUT policy `0a7ec9bb-6f95-4e90-ac4d-90573457c9ff`
  ("claude-mcp-service-token", `non_identity`, precedence 2) on app
  `b79d74fb`, adding a `service_token` include for `ed4c9418`. The original
  `102231e3` pin was kept — its secret may still be live in off-host MCP
  configs, and dropping the pin would break that path.

## Verification (real records)

- Before: `curl -H "CF-Access-Client-Id/Secret: <stored>" \
  https://0509-support-inbox.nishant345.workers.dev/api/v1/mailboxes` →
  `302` to `nish345.cloudflareaccess.com`, meta JWT
  `service_token_status:false` (reproduced this run with both the dead file
  contents and the freshly minted, not-yet-pinned token).
- After the policy PUT: same probe → `HTTP 200` with the live mailbox list
  JSON (`alerts@0509.io` unreadInboxCount 72, plus the billing@/support@
  mailboxes) — Access admitted the service token and the worker answered.

## Leftovers, deliberately untouched

- Server-side rows with no surviving secret were left in place; deleting
  them is a separate call: service tokens `102231e3`, `f04b55c0`
  (claude-support-inbox-mcp, expire 2027-06-11), `e0234704` (fleet-pw-signup,
  expired), `35d57497` (pi-3393-alternativeto-20260913, expired); policies
  `e87bd44e` (pins the dead fleet-pw-signup id) and `500ff1d3` (pins the
  expired pi-3393 id).
- The writer that clobbered the credential file on 2026-09-07
  (`fleet-pw-signup` mint) was not located on this host; until it is found,
  the next unrelated mint can kill this lane again.
- `deploy.env`/`deploy-ci.env` return success + an empty list on
  `access/service_tokens` while a differently-scoped token sees the real
  rows — a scoped-view quirk, not an empty account. Do not trust a silent
  list from those tokens.
