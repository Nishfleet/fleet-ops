# Cloudflare credentials on this host

`AGENTS.md` → "Cloudflare credentials on this host" carries the one fact a worker
needs and points here. This file holds which token reaches what, and the gate on
ad-hoc mints. Issue: nish-vault#46 item 4.

## The jail

The worker jail in `agent.yml` mounts an empty tmpfs over
`~/.config/cloudflare` and `~/.config/gh`, because a worker reads outsider
comments and a fooled model must not reach an admin GitHub login or a no-expiry
deploy token. `ci.yml` fails if that jail line, run against planted files, can
read either path. Credential parity holds only for interactive host sessions.
The orchestrator hand-off runs on a runner unit, and `20-lockdown.conf` masks
`~/.config/cloudflare` for every runner, so the hand-off cannot read these files
either (fleet-ops#10352); a packet that needs a Cloudflare token it cannot mint
stays owner-gated.

Jailed workers cannot mint either: the minter file is hidden from them too. A
worker packet whose acceptance needs the Cloudflare API parks with
`blocked-on: orchestrator`.

An interactive host session reads the token from the file, never prints it, and never copies it
into a repo, PR or issue.

## The long-lived tokens

### `~/.config/cloudflare/deploy-ci.env`

`CLOUDFLARE_API_TOKEN`, GraphQL analytics read only, valid only from this VPS's
IPs, minted and rotated by `infra/cloudflare-tokens` (token key `vps-grafana`,
45-day expiry, weekly apply). The file is written 0600 by that config and read
by `ansible/host.yml` into the `grafana-cloudflare-api-token` Podman secret, so
Grafana's Cloudflare data source is the only consumer. The apply's
`ExecStartPost` starts `fleet-host-config.service`, whose `ansible/tasks/secrets.yml`
replaces that secret when the value changes, so a rotation does not wait for the
next host-config run.

It replaced the hand-made `deploy-ci` user token (Workers scripts, D1, KV, Zone
read, GraphQL analytics, no expiry, no IP lock), which Nish approved retiring on
2026-10-23 (fleet-ops#10169). A preview upload or an analytics query from a hand
session takes a 24-hour `job-*` token from the mint gate below.

The old hand-made token is **not yet revoked**: it stays valid in Cloudflare
until the owner deletes it in the dashboard, because the key-maker token may not
delete a standing token and no runner lane can reach the token list. Until that
delete, a copy of the old value still works from this host, so "the old token is
invalid" is a step of the rotation, not a result of the merge.

**Never use it for restore drills or any other D1 create, import, execute-write or
delete.** A restore drill imports a backup into a local SQLite file (`sqlite3`) and
compares row counts there; it never creates a Cloudflare database. Restore drills
need no D1 Write token; a live row count is one read-only `COUNT` query, and it
comes from a `job-*` token.

Scratch D1 databases made by drills wrote 17M rows in 5 days (14-19 Sep) and 205k
rows in one hour (15 Oct, fleet-ops#9781). The `cf-d1-rows-written` alarm fires
above 68,493 rows/h, and when it fires you stop drilling.

### `~/.config/cloudflare/email.env`

`CLOUDFLARE_EMAIL_TOKEN`, narrowed 2026-09-25: Email Routing (addresses, rules,
suppressions), Email Sending, R2 storage and Turnstile only, and it works only
from this VPS's IPs. It cannot create tokens, touch DNS or Workers, or read
analytics. The old account-admin token (`c617a6f2…`) is disabled.

Neither of these two can mint tokens.

## Minting Cloudflare tokens

One minter token, `~/.config/cloudflare/token-minter.env` (0600,
`CLOUDFLARE_API_TOKEN`), holds only User > API Tokens Write, from the dashboard
template "Create Additional Tokens". It mints and deletes tokens and nothing else:
never use it for work, and never source it into a long-running process. It is a
user token, not account-owned, because an account-owned token creator can only
grant a subset of its own permissions (Cloudflare docs). It is IP-locked to this
VPS. It was rolled once on 2026-10-09 because the original value was pasted in
chat; if it is ever exposed again, roll it with `PUT /user/tokens/<id>/value` and
pipe the response straight into the env file with jq, never print it.

Account id: the `account_id` default in `infra/cloudflare-tokens/variables.tf`
(an identifier, not a credential).

**The minter must never be used to edit, roll or delete any token whose name does
not start with `job-`.** That covers the retired `deploy-ci` token, `email`, the
minter itself and everything else. Check the name first.

### The gate

The minter can create a token with any permission Nish's user holds, so it is not
a free pass. Ad-hoc mints by an unjailed session are allowed ONLY when all of
these hold:

1. Name `job-<task>-<UTC stamp>` (for example `job-fleet-1234-20261009T120000Z`).
2. `--expires-on` at most 24h from now (UTC RFC3339).
3. `--condition-request-ip-in` the two VPS addresses (not kept in git; read them
   on the box: `curl -4 -s ifconfig.me` and `curl -6 -s ifconfig.me`).
4. Resources as narrow as the API allows. Cloudflare's token policy documents
   three resource types only: user, account and zone
   (`com.cloudflare.api.account.zone.<ZONE_ID>`). So scope to a specific zone
   whenever the permission group is zone-level. Account-wide is allowed only for
   groups that have no narrower resource: Workers Scripts, D1, Workers KV Storage,
   Workers R2 Storage, Email Routing and Account Analytics. A per-Worker-script
   resource is not in Cloudflare's documented resource list and could not be
   verified (2026-10-09), so do not assume a Workers Scripts token can be limited
   to one script.

Anything long-lived (no expiry, or more than 24h) or broader than the gate goes
only through a reviewed fleet-ops PR to `infra/cloudflare-tokens` (OpenTofu, PR
9489); the PR review is the approval step. That is how the long-lived VPS
`deploy-ci` token moved under the config (fleet-ops#10169, token key
`vps-grafana`); the `email` token has not moved yet. The standing `deploy-ci`
value stays out of scope for the minter until it is deleted: do not mint, roll,
edit or delete it.

### The order of operations

Every job keeps its token in its own 0600 env file,
`~/.config/cloudflare/job-${FLEET_TASK_ID:-<UTC stamp>}.env` (or only in the
process env), so concurrent sessions never share a file, and deletes it when done.

Look up permission group ids by name, never from memory
(`permission-groups list` returns a bare JSON array, so use `.[]`):

    (set -a; . ~/.config/cloudflare/token-minter.env; set +a
     cf user tokens permission-groups list | jq -r '.[] | "\(.id)\t\(.name)"' | grep -i 'cache purge')

Example, a 24h Cache Purge token for one zone (a zone-level group, so the resource
is that zone; the secret never reaches the terminal). Order: dry run, real create,
scoped 403 check, the work, guarded delete, then a 404 check:

    STAMP=$(date -u +%Y%m%dT%H%M%SZ); ZONE=<zone id>
    JOBENV=~/.config/cloudflare/job-${FLEET_TASK_ID:-$STAMP}.env
    NAME="job-${FLEET_TASK_ID:-adhoc}-$STAMP"
    (set -a; . ~/.config/cloudflare/token-minter.env; set +a; umask 077
     PG=$(cf user tokens permission-groups list | jq -r '.[] | select(.name=="Cache Purge") | .id' | head -n1)
     POL=$(jq -nc --arg z "com.cloudflare.api.account.zone.$ZONE" --arg p "$PG" '[{effect:"allow",resources:{($z):"*"},permission_groups:[{id:$p}]}]')
     set -- --name "$NAME" --policies "$POL" \
       --expires-on "$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)" \
       --condition-request-ip-in <vps-ip>/32 <vps-ipv6>/128
     # 1. dry run first: read the request, check name, expiry, IPs and the single zone
     cf user tokens create "$@" --dry-run
     # 2. the real create; the secret goes to the 0600 file, not the terminal
     cf user tokens create "$@" \
       | jq -r '(.result // .) | "CLOUDFLARE_API_TOKEN=\(.value)\nCLOUDFLARE_TOKEN_ID=\(.id)"' > "$JOBENV")
    # 3. scoped check: this token must get 403 on DNS for the zone
    (set -a; . "$JOBENV"; set +a; cf dns records list --zone "$ZONE" >/dev/null && echo "NOT NARROW")
    # 4. the work: (set -a; . "$JOBENV"; set +a; ...)
    # 5. guarded delete: GET the token, require the job- prefix, only then delete with -f
    (ID=$(sed -n 's/^CLOUDFLARE_TOKEN_ID=//p' "$JOBENV")
     set -a; . ~/.config/cloudflare/token-minter.env; set +a
     case "$(cf user tokens get "$ID" | jq -r '(.result // .).name')" in
       job-*) cf user tokens delete -f "$ID" && rm -f "$JOBENV" ;;
       *) echo "REFUSING: token $ID is not a job- token" >&2; exit 1 ;;
     esac
     # 6. the GET must now fail with 404
     cf user tokens get "$ID")

`cf user tokens delete` silently does nothing without `-f`/`--force`, so always
pass `-f`. The final GET must answer 404; if it returns the token, the delete did
not happen.

To check a new token is narrow, call a scoped endpoint it should not reach (step
3: the zone's `dns_records` -> 403 for a Cache Purge token). Do not use `/zones`:
it lists zones for any account token and proves nothing.

To switch minting off: delete the minter token in the dashboard (My Profile > API
Tokens) and remove `token-minter.env`.
