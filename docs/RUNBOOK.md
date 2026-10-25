# Runbook

One page. How to run the fleet. What it is, install mechanics and the deploy
rail are in `README.md`; design and enforced rules are in
`docs/ARCHITECTURE.md`.

## Live-state check (the canonical order)

1. `ls ~/workspaces/agent-state/FLEET-PAUSED` — if it exists the fleet is
   deliberately down; respect it. Otherwise step 2 is the truth.
2. `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers`.
3. Same prefix, `systemctl --user list-units --state=failed` — must be empty.
   From a shell inside a worker or runner jail this ends `Failed to connect to
   bus: Permission denied` because the jail masks the user manager
   (fleet-ops#9983): the error is the jail, not a host fault, and the
   `root:root` mode-000 socket it reports is systemd's inaccessible
   placeholder. From inside the jail the step stays not run and can never be
   cleared. Partial fallback from any shell: `systemctl --failed` (system
   scope), failed system units only.
4. `curl -s 127.0.0.1:4000/health/readiness` (expect
   `{"status":"healthy","db":"connected"}`), then
   `curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state` — one
   gauge per deployment (0 healthy, 1 partial, 2 outage).
5. `uptime` for load; merged-PR counts per repo for throughput.

## Deploy and wiring

`deploy-box.yml` (push to main) → `fleet-sync.service` runs
a `git fetch` of `main` into `refs/remotes/origin/main` + a
`git merge --ff-only` of that named ref + `daemon-reload`, and fails
(`DEPLOY-BLOCKED`) on a dirty
or diverged clone, so the canonical checkout
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone` stays clean on `main`.
It never uses `git pull`: a polluted `FETCH_HEAD` there merges into
`fatal: Cannot fast-forward to multiple branches` and silently stops every
deploy (fleet-ops#8893). A trailing `merge-base --is-ancestor` pair
asserts `HEAD == origin/main`, so a stopped deploy is a failed unit rather
than a lagging clone.
Its LINK-GUARD passes fail the unit while any live symlink under
`~/.config/systemd/user/`, `~/.local/bin/`, `~/.pi/agent/` or the vault is
broken or resolves into a throwaway root (`*worktrees/*`, `agent-state`,
`tmp`).

`~/.pi/agent/agents/` holds only the stock agents from `template/agents/`;
per-issue copies (`reviewer-issue-<N>.md`, removed under fleet-ops#8659) are
loaded by nothing.

Wiring a new unit or prompt is one `ln -sfn` into the deploy clone, once
(full commands in README). Every root-owned file under `/etc` that the repo
ships lives in `rootfs/` and is `fleet-host-config.service`'s job (Ansible's
`ansible-pull` of `ansible/host.yml`, started by deploy-box.yml on every merge
and by a daily timer). Its `daemon-reload` re-applies a changed slice cap to
the running slice (fleet-ops#8862). A failed run is in
`journalctl -u fleet-host-config.service`; a `Hand-installed` line names a file
to add under `rootfs/`, delete, or list in `/etc/fleet-ops/box-only`. What still
stays a hand copy: the live-state JSON files under `~/.local/state/` and the
`~/.config/fleet-ops`-owned files. The two hand-written Pi extension forks are
gone (fleet-ops#8238).

After a slice change, both the unit and the cgroup must read the new cap:
`systemctl show agent.slice -p MemorySwapMax` and
`cat /sys/fs/cgroup/agent.slice/memory.swap.max` (1073741824, not infinity).

### Shell startup files

Interactive shells do not read `~/.config/environment.d`. The systemd user
manager does, for user units, so a value only a unit needs goes there. Do not
add a loader for it to `~/.bashrc` or `~/.zshrc`. Work that needs a value from
a file runs as a unit or `systemd-run --user` transient with `EnvironmentFile=`,
not from an interactive shell (README, "systemd by default").

The loader that ran the systemd environment generator in those files from
2026-10-07 carried the pi-grok `PI_XAI_CLIENT_VERSION` pin into shells. The pin
was retired (`fleet-ops#10224`), which left the loader with nothing to carry, so
it is deleted (`fleet-ops#10143`).

## Runner guard (fleet-ops#9317)

A guard against habit, not a security boundary. The refusal names the tool to
use instead.
- Pi: the package [`Nishfleet/pi-runner-guard`](https://github.com/Nishfleet/pi-runner-guard),
  pinned by sha in the `~/.pi/agent/settings.json` `packages` list. It refuses
  `sed -i`, `perl -i`, redirects and `tee` into a repo file, python file
  writes, bare `git add -A`/`--all`/`.`, and scratch files in a worktree.
  One-run off switch `PI_RUNNER_GUARD=off`. Its README says how to remove it.
- Claude Code: stock `permissions.deny` in `~/.claude/settings.json`:
  `Bash(sed -i:*)`, `Bash(sed --in-place:*)`, `Bash(perl -i:*)`,
  `Bash(perl -pi:*)`, `Bash(git add -A)`, `Bash(git add --all)`,
  `Bash(git add .)`. The `git add` rules are exact matches, because a prefix
  rule would also block `git add .github/x`, so `git add -A .` still passes.
  Redirects, python writes and scratch files have no stock rule and pass.
  To switch it off, delete those seven lines.
- Check both are on: `jq -r '.packages[]' ~/.pi/agent/settings.json | grep runner-guard`
  and `jq -r '.permissions.deny[]' ~/.claude/settings.json | grep -cE '^Bash\((sed|perl|git add)'`
  (prints 7).

## Dashboards and the CI runner flip

`systemctl --user is-active fleet-grafana.service` prints `active`. The service is
the Quadlet `containers/quadlet/fleet-grafana.container`, read-only for every
viewer. Dashboards, datasources and alerting come from `config/grafana/dashboards/`
and `config/grafana/provisioning/`, edited in this repo only.

Grafana reads the alerting and datasource provisioning files only at start, and the
deploy is a `git merge --ff-only` that never restarts the container.
`fleet-grafana-provisioning.path` (`PathChanged=` on both directories in the deploy
clone) therefore triggers `fleet-grafana-provisioning.service`, which POSTs the stock
admin API `/api/admin/provisioning/alerting/reload` and `/datasources/reload` (Grafana HTTP
API docs, "Reload provisioning configurations"), authenticated as `admin` with
`~/.config/fleet-ops/grafana-admin-password`. Dashboards need no help: their provider
polls every 60 s. To check a rule landed, `GET /api/v1/provisioning/alert-rules` and
compare the rule's `expression` with the repo file. Wire the pair once after merge, like
`fleet-litellm-proxy-config` (README "Wiring a NEW unit"): `systemctl --user link` both
files, then `systemctl --user enable --now fleet-grafana-provisioning.path`. Until it is
wired, reload by hand with `systemctl --user start fleet-grafana-provisioning.service`
once linked, or `curl -X POST` the two endpoints.

Cloudflare cost alarm (fleet-ops#9355): `config/grafana/provisioning/alerting/cloudflare-spend.yaml`
evaluates hourly through the Infinity data source `fleet-cloudflare` (the deploy-ci
analytics token, from `~/.config/cloudflare/deploy-ci.env`). A firing rule opens a fleet-ops
issue labelled `agent-ready` and `priority-now` through the webhook contact point
`cloudflare-spend-dispatch`. The webhook
sends a GitHub App installation token (issues:write on Nishfleet/fleet-ops only), see
"Grafana's GitHub token" below. `grafana_alerting_notifications_failed_total` rising pages hermes-urgent through `cloudflare-spend-delivery.yaml`. Replay a rule by typing a past
window into its GraphQL `filter:` in place of the `${__timeFrom:date:iso}` and `${__timeTo:date:iso}`
macros, run it, then restore the file; close the test issue at once, the dispatcher claims it.

Who gets paged (fleet-ops#9445). Nish's contract is that only a real outage, a money problem,
or something only he can act on interrupts him. Every alert rule carries a `severity` label and
the one policy tree in `cloudflare-spend-contact.yaml` routes on it. `critical` is exactly the
urgent list in `tests/alert_routes_check.py`: the cost alarm, its delivery-failed rule, the nine
paid-plan-idle rules, prompt-cache-hit and the deploy-failed-24h rules. They page `hermes-urgent`
(Telegram) again every hour until they resolve, and cost, plan and cache rules that cannot evaluate
page every 12 hours. Every other rule (router-dead-row, cpu-pressure, the 30-minute deploy-failed
rules, any new rule) is `warning`: it does not page. Every firing alert, of either severity, files
a fleet-ops issue labelled `agent-ready` (`fleet-alert-dispatch`, or the cost-alarm and
router-dead-row variants); the webhook cannot comment or close, so a still-firing alert files a
new issue per repeat. CI fails when a rule has no severity, overrides the tree, is critical
without being on the urgent list (or the reverse), or a critical alert would re-send slower than
hourly. To make a new rule page, add it to the list there with the reason and label it critical.
Switch off the fleet issue route: point the policy root and the last route back at `hermes-urgent`.

Grafana's GitHub token (fleet-ops#9445). A webhook contact point sends one static
Authorization value and a GitHub App installation token lives an hour, so a token pasted into
a file went stale and every delivery answered `401 Bad credentials` for days.
`fleet-grafana-github-token.timer` (every 20 min, and 2 min after boot) starts
`fleet-grafana-github-token.service`, which signs an RS256 App JWT with the nishfleet-worker
key, asks the REST API for an installation token limited to `Nishfleet/fleet-ops` and
`issues:write`, writes it to `$XDG_RUNTIME_DIR/fleet-grafana-github-token/token` (tmpfs,
0700 dir, 0600 file) and starts `fleet-grafana-provisioning.service`, the stock admin-API
reload above. The contact points read the file with Grafana's `$__file{}`, which is
re-read on every provisioning load. Wire once after merge (README "Wiring a NEW unit"):
`systemctl --user link` both files, `systemctl --user daemon-reload`, `systemctl --user
enable --now fleet-grafana-github-token.timer`, then restart `fleet-grafana.service` once so
the quadlet's new mount takes effect. Do it right after the merge deploys: until Grafana restarts, the
provisioning reload the merge triggers cannot find the new mount and
`fleet-grafana-provisioning.service` pages once per provisioning change. Read it: `systemctl --user show
fleet-grafana-github-token.service -p Result -p ExecMainStartTimestamp` and the journal line
`minted a GitHub App token`. A failed mint pages through `OnFailure=`
(`fleet-unit-failed@`), keeps the previous token, and the delivery rule pages hermes-urgent
if a webhook still fails. Switch off: `systemctl --user disable --now
fleet-grafana-github-token.timer` and `systemctl --user mask fleet-grafana-github-token.service`
(the quadlet's `Wants=` also mints once per Grafana start); the webhook then sends an empty token (401), the delivery
rule pages hermes-urgent, and spend alerts still reach Telegram. CI proof:
`tests/github_app_stub.py` plus the "GitHub App token unit mints and refreshes" step run the
unit's real ExecStart under systemd against a stub that checks the JWT the way GitHub does.

`CI_RUNNER` is absent by default and only exists while CI runs on Blacksmith. Set it by hand
(fleet-ops#9670 retired the hourly auto-flip, and deleted the variable it left behind):

    gh variable set CI_RUNNER --org Nishfleet --body blacksmith-4vcpu-ubuntu-2404 -v all

`-v all` keeps the public repos on it; the default is private-only. While it is set, read
`blacksmith usage` and take the largest of its `billable_minutes`, `billing_minutes` and
`runtime_minutes` columns (4-vCPU minutes count double). At 2,850 minutes (95% of the 3,000 free)
or more, delete it again: `gh variable delete CI_RUNNER --org Nishfleet`. Nish owns this call -
check `blacksmith usage` when a month's CI load is heavy, and set the variable again at the start
of a month if CI should run on Blacksmith. There is no automatic guard: the vendor bills past the
3,000 free minutes even with no card on file (fleet-ops#8935), and ships no usage webhook or
alert to trip on (fleet-ops#8936), so a person catches the crossing or nobody does. The retirement
leaves the variable deleted, so CI runs on GitHub-hosted runners until someone sets it again;
that changed nothing running, because nothing read it (fleet-ops#9670).

## Sentry monitors (org 0509-gg)

Warning: a green drive monitor does not mean drive works. The site sits behind Cloudflare
Access until launch (Nish, 2026-10-01), so nothing outside can reach drive's own routes and
the monitor below only proves the wall answered. The app-level check is fleet-ops#10226.

Sentry is the fleet's up/down detector for the product sites (fleet-ops#9014): no VPS probe,
no agent in the loop. The token is in `~/.config/sentry/env` (0600, org read plus write on
uptime monitors), read into a curl config fd so it never lands in argv:

    SENTRY_ENV=~/.config/sentry/env
    AUTH='s|^SENTRY_AUTH_TOKEN=\(.*\)|header = "Authorization: Bearer \1"|p'
    curl -s --config <(sed -n "$AUTH" "$SENTRY_ENV") https://sentry.io/api/0/organizations/0509-gg/uptime/
    curl -s --config <(sed -n "$AUTH" "$SENTRY_ENV") \
      https://sentry.io/api/0/projects/0509-gg/drive/uptime/10494402/checks/

The checks list lags: the 07:48:47Z check was still missing at 07:55Z and appeared at
07:56Z, so an empty tail is not a dead monitor.

Verified on 2026-10-24:

| Kind | Name | id | Project | Target | Green means |
|---|---|---|---|---|---|
| uptime | Drive access wall (pre-launch, private) | 10494402 | drive | `https://drive-pricing.nishant345.workers.dev/` | Access answered: the last response carries `cf-access-domain` |
| cron | liveness-ping | `f2dbf08e-6a6d-49d3-b0e2-2b657205d482` | five-to-nine | `*/5 * * * *`, UTC | 0509's check-in arrived. The other nine monitors in that project are disabled |

Nothing in this repo reads a monitor: no unit, no workflow. So a red is read in Sentry, or
from `/checks/`, and no fleet unit pages on it.

### The checker follows redirects, and asserts on the last response

Measured on 10494402 on 2026-10-24. It records the status of the first response and asserts
on the last. A check at 07:28:47Z showed `httpStatusCode: 302` and still failed
`status_code_check` with `equals` and `value` 302, because the checker had followed to the
Access login page and compared that page's 200. Against the same 302 on the record, `equals`
200 passed at 07:40:47Z and 07:41:47Z. So an assertion on the drive hostname has to describe
the login page, never the redirect.

### drive is private until launch, so the monitor watches the wall

fleet-ops#9014 deleted the dead VPS probes; Sentry carries site up/down instead
(`rootfs/etc/prometheus/prometheus.yml`, the 2026-10-01 block). For drive,
`cloudflare.config.ts` and `test/access-wall.test.mjs` in Nishfleet/drive keep the hostname
behind Access until launch. Access answers every path before the Worker runs (`/api/health`
included, and `/.well-known/cloudflare-access-protected-resource/...` is the one exempt path),
so no public monitor can reach drive's own routes. The "Drive health check" monitor (10494404)
was deleted on 2026-10-24 for that reason: it pointed at `/api/health`, whose 404 the wall
turned into a 302, so its last checks read green on the wall's answer rather than drive's.
The app-level check it pretended to be is fleet-ops#10226.

10494402 watches the wall instead, with a header only the Access login page sends. A PUT body
merges into the monitor, so send only the fields you change:

    PUT /api/0/projects/0509-gg/drive/uptime/10494402/
    {"assertion":{"root":{"op":"header_check",
      "key_op":{"cmp":"equals"},"key_operand":{"header_op":"literal","value":"cf-access-domain"},
      "value_op":{"cmp":"always"},"value_operand":{"header_op":"none"}}}}

It reds if the wall is bypassed (drive's own page carries no `cf-access-domain`), if Access
stops sending that header, or if the hostname stops answering. Proven both ways on
2026-10-24: the same assertion against `x-fleet-absent-header` failed the 07:43:47Z check
with `assertionFailureData` naming that header, and `cf-access-domain` passed every check
from 07:42:47Z on.

### The assertion shape

`assertion` is not in the API reference, so the API's own deserialization errors are the
spec. `op` is one of `and` (with `children`), `or`, `not` (with `operand`),
`status_code_check`, `json_path` and `header_check`. A comparison is `{"cmp": "equals" |
"not_equal" | "less_than" | "greater_than" | "always" | "never"}`, and `always` on a header
value means the header exists. `status_code_check` holds `value` and `operator`.
`header_check` holds `key_op`, `key_operand`, `value_op` and `value_operand`, where an
operand is `{"header_op": "literal", "value": "<name>"}` or `{"header_op": "none"}`.
Sending `cmp` where `value_op` belongs is a 400 and changes nothing.

An assertion change takes effect on the first check that starts after the PUT, not in the
history already written. Read `uptimeStatus` with care: it flips only after
`downtimeThreshold` failures in a row, so one failed check leaves it at 1. The live values are
`intervalSeconds` 300 and `downtimeThreshold` 3; while experimenting, drop the first to 60 and
raise the second to 10, then put both back to 300 and 3.

## LiteLLM stack (rebuild reference)

Postgres, Redis and the proxy are Podman Quadlet containers defined in
`containers/quadlet/fleet-litellm-{postgres,redis,proxy}.container` (images
`postgres:16`, `redis:7`, `ghcr.io/berriai/litellm:v1.98.0`, all
`Network=host`), run as `fleet-litellm-postgres.service`,
`fleet-litellm-redis.service` and `fleet-litellm-proxy.service`. Healthy
check: `systemctl --user is-active fleet-litellm-postgres.service
fleet-litellm-redis.service fleet-litellm-proxy.service` prints `active`
three times. Host data directories stay at
`~/.local/share/fleet-litellm-postgres` and
`~/.local/share/fleet-litellm-redis`.

The proxy version is the image tag in `fleet-litellm-proxy.container`,
bumped in its own PR.

The live config `~/.config/fleet-ops/litellm-proxy.yaml` is a copy of
`config/litellm-proxy.yaml`: `fleet-sync.service` installs it with `install -C`,
which overwrites a hand edit, and `fleet-litellm-proxy-config.path` restarts the
proxy only when the bytes change. Edit the repo file and nothing else; CI checks
it against `config/litellm-proxy.schema.json` (fleet-ops#8724). Keys resolve as `os.environ/<NAME>` from the three
`EnvironmentFile=` entries in `fleet-litellm-proxy.container`: the optional `-%h/.config/fleet-ops/seats/*.env`,
and `-%h/.config/straitly/straitly.env` (the leading `-` marks an optional file), and the
required `%h/.config/fleet-ops/litellm-master-key.env`. The container receives only the names that have a `PodmanArgs=--env=<NAME>` line in
`fleet-litellm-proxy.container` (fleet-ops#9020), so a new `os.environ/<NAME>` in the yaml needs a
matching `PodmanArgs=--env=<NAME>` line; `disable_prisma_schema_update: true` stays under `general_settings`
(startup `prisma migrate deploy` stalls every restart without it), and
`DATABASE_URL` is a unit `Environment=` in host-qualified form (the
socket-less form is rejected). Consumer credentials are per-group virtual keys
minted via the admin API, never the master key. An admin-API call keeps the
key out of argv — `curl -H "Authorization: Bearer $KEY"` leaves the key in
`/proc/<pid>/cmdline` for the life of the curl (fleet-ops#8403) — by handing
curl a config fd:
`curl --config <(sed -n 's|^LITELLM_MASTER_KEY=\(.*\)|header = "Authorization: Bearer \1"|p' ~/.config/fleet-ops/litellm-master-key.env)`.
`sed` rewrites the line into a header; the key never becomes an argument.
`-H @<0600 headers file>` works too. Do not `printf`/`echo` a `$..._KEY`
into the config instead: `printf` plus a key variable is what CI's
secret-scan gate blocks, and the gate is right — the printf form puts the key
back in argv.

Edits to that file are applied automatically. `fleet-litellm-proxy-config.path`
(`PathChanged=`) triggers `fleet-litellm-proxy-config.service`, which runs
`systemctl --user try-restart fleet-litellm-proxy.service` — the proxy reads
its config only at start, so the restart is the apply step, and `try-restart`
means an edit never starts a proxy that was stopped on purpose. Every save
restarts the proxy (~38 s), so batch edits into one write. Install it with
`systemctl --user link` on the .service, then `systemctl --user enable --now`
on the .path, both from the deploy clone (README "Install").

`/jev` is a pass-through with `auth: true`, so any valid virtual key reaches it
and each call books `cost_per_request` against the calling key. Its cap is a
`fleet-jev` virtual key (`POST /key/generate` with `max_budget`,
`budget_duration` `1d` and `rpm_limit`). Today worker.md step 4 and
miss-review still read `LITELLM_JEV_KEY` from `seats/typesafe-jev.env`, which is
not that key; the cap takes effect when the key is minted and that seat file
holds it. LiteLLM v1.98 has no declarative key list, so minting is one
admin-API call, not a config edit.

Backup: the restic backup unit runs `pg_dump -Fc` of the `litellm` database
into `agent-state/backups/litellm.dump` before every run, and that dump is the
only LiteLLM Postgres copy in restic: the raw data dir is not in
`config/restic/include.txt` (a file copy of a running Postgres is not
crash-consistent and churned about 700 MiB a day). Restore with `pg_restore`.
Retention is one policy for the backup and maintenance units, kept 7 daily,
4 weekly and 3 monthly snapshots grouped by host and tags
(`config/restic/retention.env`, `config/restic/README.md` "Retention"). The
restic units are deliberately host-only, not an oversight: the backup,
locked-copy, maintenance, restore-test and verify services, their timers and
the size-guard service live only under `/etc/systemd/system/restic-r2-*`,
because the unit files name the backup targets and this repo is public
(Nish, 2026-10-03, "split"). `/etc/fleet-ops/box-only` lists them, so
`fleet-host-config.service`'s drift check skips them; this repo tracks only the
additive drop-ins under `rootfs/` and the lists in `config/restic/`, so this
section does not schedule them. A box rebuild cannot restore these units from
the repo — copy them off the live box to private storage before wiping it, and
never commit the copies here.

Rollback (immediate): `systemctl --user stop fleet-litellm-postgres.service
fleet-litellm-redis.service fleet-litellm-proxy.service`, then `rm -rf` the
two `Volume=` data dirs named in
`containers/quadlet/fleet-litellm-postgres.container` and
`containers/quadlet/fleet-litellm-redis.container`
(`~/.local/share/fleet-litellm-postgres`, `~/.local/share/fleet-litellm-redis`,
no sudo needed — they are user-owned). Quadlet generates each `.service`
file from its `.container` file, so stopping the units and removing the two
data dirs is the whole state removal.

Rollback (follow-up): delete the three `.container` files in
`containers/quadlet/` in a normal PR.

## Claude session credentials (fleet-ops#9020)

The systemd `--user` manager environment carries no Claude, Exa or Browser Use
names. The manager hands its environment to every user unit, every
`systemd-run --user` transient and every quadlet container, so the names were
removed from it in this order:

1. Delete `~/.config/environment.d/50-agent-secrets.conf`.
2. `systemctl --user daemon-reload`. The manager reads `environment.d` through
   its generator at startup and on reload, so without this the three names the
   file defined stay in the manager environment: `unset-environment` alone did
   not clear them.
3. `systemctl --user unset-environment <NAME>...` for any name that is still
   listed, `ANTHROPIC_BASE_URL` included.
4. Check names only, never values:
   `systemctl --user show-environment | cut -d= -f1 | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|EXA_API_KEY|BROWSER_USE_API_KEY|ANTHROPIC_BASE_URL)$'`
   must print nothing (`grep` exits 1).

A launcher that needs them reads one file, `~/.config/claude/oauth.env`, mode
0600 (`install -m 0600`, owner `nish`), holding `NAME=value` lines for exactly
these names: `CLAUDE_CODE_OAUTH_TOKEN`, `EXA_API_KEY`, `BROWSER_USE_API_KEY`.
`ANTHROPIC_BASE_URL` is not stored: nothing in the fleet needs it. Never
tracked, never printed; check it with `test -s` and `stat -c %a`.

Loading it is the stock property, required (no `-` prefix) so a missing file
fails the unit at start instead of running a session on the wrong login:

```
systemd-run --user --collect --unit <name> -p EnvironmentFile=%h/.config/claude/oauth.env \
  -- claude -p ...
```

The same line in a user unit is `EnvironmentFile=%h/.config/claude/oauth.env`.
It is deliberately not among the optional (`-`) seat globs the proxy reads: a
seat file may be absent, this one may not. In a system unit `%h` is the home of
the user running the manager, `/root` (`man systemd.unit`, Specifiers), not
`User=`, so a system unit with `User=nish` writes
`EnvironmentFile=/home/nish/.config/claude/oauth.env`.
`EnvironmentFile=` loads the whole file: a unit that must not hold all three
names gets its own file per need (`claude-token.env`, `exa.env`, ...), never
the shared one.

Readers in this repo: none (re-audited for every unit, drop-in, quadlet,
workflow, prompt and recipe that starts `claude`, `pi`, `devin`, `opencode`,
`cursor-agent` or a fleet worker):

- `claude-remote-control.service` is a system unit. A system manager never saw
  the user manager environment, so it never inherited these names. Its header
  says why it must stay without them: "that directory also exports
  CLAUDE_CODE_OAUTH_TOKEN, and Remote Control needs the claude.ai login
  instead."
- `agent.yml` jobs run in the `actions.runner.Nishfleet.netcup-agent-N`
  system units (`runs-on: [self-hosted, agent]`), so they did not inherit the
  user manager either. The worker engines read their own credentials: devin and
  opencode their own logins, cursor `seats/cursor.env`, pi the `litellm`
  provider with per-group keys plus `seats/mobbin-mcp.env`.
- `fleet-litellm-proxy.container` took the whole manager environment through
  `--env-host` until #9020; it now passes the named `PodmanArgs=--env=` list.
  Its `anthropic/` rows set `api_base` explicitly and take `MINIMAX_API_KEY`,
  so `ANTHROPIC_BASE_URL` is not read.
- `fleet-sync`, `fleet-unit-failed@`,
  `fleet-litellm-proxy-config`, the postgres, redis and aiostreams quadlets,
  and the `hermes-`, `tailscaled`, `oomd` and slice drop-ins start no agent.

The runner environment is the one thing the repo cannot show (the runner
`.env` and the live `~/.pi/agent` extensions are outside it). If a worker
engine ever needs one of these names, give that runner a drop-in with the line
above for the single file it needs; nothing in this repo asks for it today. A
hand-run `claude -p` or `systemd-run --user` that needs the token passes the
line above.

## Unattended Claude runs (fleet-ops#9502)

Two units run Claude with nobody watching: `tincan-listen-claude-vps.service`
(user unit, the tincan inbox drainer) and `claude-remote-control.service`
(system unit, the Remote Control server). Both used to pass
`--permission-mode bypassPermissions`, which skips every check, so the
`permissions.ask` rules (force-push, `reset --hard`, `reboot`, `restic forget`,
`gh repo delete`, ...) were decorative: exactly the rules that mark a step as
destructive.

Both now run `--permission-mode dontAsk`, which denies a tool call that would
have raised a prompt nobody can answer. The allow list per unit is a file in
this repo under `rootfs/etc/claude-code/roles/`, installed to
`/etc/claude-code/roles/` by `ansible/host.yml`:

| unit | role file | how it is loaded |
| --- | --- | --- |
| `tincan-listen-claude-vps.service` | `tincan-listener.json` | `--settings /etc/claude-code/roles/tincan-listener.json` on `claude -p` |
| `claude-remote-control.service` | `remote-control.json` | spawned sessions read `~/.claude/settings.json` (`claude remote-control` refuses `--settings`) |

`claude remote-control` refuses `--settings` (proved 2026-10-09: `Error:
Unknown argument: --settings`). A `Bash` allow does not swallow the ask list:
`git stash` was still denied under dontAsk with `Bash` in allow (2026-10-09).
`sed -i` stayed denied by the managed deny list. Edit a role file in a PR,
never on the box. The CLI flag is the mode switch: do not set
`permissions.defaultMode` in a role file.

dontAsk on Remote Control is intended: Nish cannot approve a one-off command
from the phone. A denied call is reported in the session and there is no
prompt to tap.

The tincan unit goes live after merge, when fleet-sync has the new file and
the user unit is reloaded (`systemctl --user daemon-reload && systemctl
--user restart tincan-listen-claude-vps.service`). Remote Control stays on
the old `ExecStart` until Nish restarts it.

**Where denials show.** Each denied call is reported twice: in the unit's
journal, and in the run transcript (`claude -p --output-format json` lists
them under `permission_denials`). The tincan transcript is
`~/.claude/projects/-home-nish--local-state-tincan-listen-claude-vps/<id>.jsonl`
(the directory name is the escaped cwd, which is the unit's `StateDirectory`).

**Rollback.** Put `--permission-mode bypassPermissions` back on the `ExecStart`
line of the unit and restart it. That restores today's behaviour: the role
file is then inert and nothing else in the unit changed. Only Nish restarts
`claude-remote-control.service`, because that cuts the phone link.

## Break-glass access (SSH is Tailscale-only)

If tailscaled is down, SSH is gone. The out-of-band layer exists today at zero
cost: the netcup provider VNC console.

- Use it when tailscaled will not return (`Restart=always` already applied),
  when the Tailscale interface is absent, or to confirm sshd still binds only
  Tailscale addresses. Never for routine work.
- Steps: netcup panel from a machine that does not depend on this VPS → VNC
  console → login as `nish` → `systemctl restart tailscaled` → `ss -ltn |`
  `grep ':22'` must show only `100.*`/`fd7a:*` — a `0.0.0.0:22` or `[::]:22`
  line is a public SSH bind, fix it before disconnecting → verify Tailscale
  SSH from another machine, then leave VNC.
- It is not a second SSH listener, not a standing open console, and not a
  live-tailscaled kill (a lockout, not an experiment — that stays a Nish
  game-day). Panel login lives in Nish's password manager; never here.

## Main has no ruleset bypass (2026-10-12)

- Ruleset 23692529 has an empty `bypass_actors`. Check: `gh api repos/Nishfleet/fleet-ops/rulesets/23692529 --jq '.bypass_actors, .current_user_can_bypass'` prints `[]` and `"never"`.
- Repository admins, including every session acting as `nish3451`, merge only through the required checks and the merge queue: `gh pr merge <PR> --auto`.
- Warning: the emergency path removes the merge guard. Only Nish takes it, as org owner, and restores the state after. Restore the admin role (actor 5) with `echo '{"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' | gh api -X PUT repos/Nishfleet/fleet-ops/rulesets/23692529 --input -`. Remove it again with `echo '{"bypass_actors":[]}' | gh api -X PUT repos/Nishfleet/fleet-ops/rulesets/23692529 --input -`.

## The ratchet runs from main (2026-10-12)

- Before: ruleset 23692529 required `ratchet`, an inline job in `ci.yml`, so a PR judged itself by its own copy (#9627). After: `ci.yml` calls `.github/workflows/ratchet.yml` and the ruleset requires `ratchet / ratchet`. 0509 and drive call the same file at `@main` and require the same context. Nothing else in the ruleset changed.
- Order, because the PR's own head cannot report the old name: remove `ratchet` from the required list, merge, add `ratchet / ratchet`. `ci` kept `ratchet` in its `needs` the whole time.
- A reusable workflow cannot be required from another repo on the Free plan: `gh api orgs/Nishfleet/rulesets` answers 403 "Upgrade to GitHub Team", and a repository ruleset `workflows` rule is rejected. So the caller file still lives in the PR. The reusable job fails a PR that edits the caller's `ratchet` job; a PR that repoints the caller's `uses:` is still caught only by review.
- Check: `gh api repos/Nishfleet/fleet-ops/rulesets/23692529 --jq '[.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context]'`.
- Undo (switch the ratchet off, as the Nish-only emergency path): `gh api repos/Nishfleet/fleet-ops/rulesets/23692529 | jq '{name,target,enforcement,bypass_actors,conditions,rules:(.rules|map(if .type=="required_status_checks" then .parameters.required_status_checks|=map(select(.context!="ratchet / ratchet")) else . end))}' | gh api -X PUT repos/Nishfleet/fleet-ops/rulesets/23692529 --input -`.
