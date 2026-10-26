# Cloudflare tokens for GitHub Actions

OpenTofu config that makes one narrow Cloudflare API token per repo, writes it
into that repo's existing GitHub Actions secret, and replaces it every 30 days.

The key that makes keys (the minter token) stays on the VPS. **It must never go
to GitHub**: not as a repo, org or environment secret, not in a workflow, not in
a variable. GitHub only ever holds the narrow tokens this config writes.

Providers: `cloudflare/cloudflare` v5, `integrations/github`, `hashicorp/time`
(`time_rotating`). Account: the `account_id` default in `variables.tf`.

Status: applied for the 10 repos that were in the list on 2026-10-09 with the
minter token (`~/.config/cloudflare/token-minter.env`); the plan resolved every
permission group name against the live API. Which jobs have run on the new
tokens is in the PR body. A weekly timer renews them (see "Renewal").
`inish-mail-filter` was added by #9919 and is not applied yet: the first `tofu
apply` after that merge creates its token and writes its secret, so the state
holds it before any run has used it. `fleet_console` (fleet-console-worker) was
applied by hand on 2026-10-20 and is now in `main.tf`, so the weekly apply no
longer destroys it; `seo-fix-kit` is new and is created by the next apply.

## What it creates

| Token key | Repo | Secret written | Account permissions | Zone permissions (all zones in the account) | Runs on | IP lock |
|---|---|---|---|---|---|---|
| `drive` | drive | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, D1 Write, Queues Write, Account Settings Read | none | GitHub-hosted (`deploy-production.yml`, `d1-export.yml`) | none |
| `0509-deploy` | 0509 | `CLOUDFLARE_API_TOKEN` (environment `production`) | Workers Scripts Write, D1 Write, Queues Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`deploy-production.yml`) | none |
| `0509-reports` | 0509 | `CLOUDFLARE_API_TOKEN` (repo) | D1 Read, Workers Scripts Read, Account Analytics Read | none | GitHub-hosted (`e2e-scheduled.yml` backup-proof, jev-failures, soak-report; `evals.yml`) | none |
| `0509-settings` | 0509 | `CLOUDFLARE_SETTINGS_TOKEN` (repo) | Workers R2 Storage Write | Zone Read, Email Routing Rules Write | GitHub-hosted (`cloudflare-settings.yml`) | none |
| `0509-support-inbox` | 0509-support-inbox | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, Account Settings Read | none | GitHub-hosted (`deploy-production.yml`) | none |
| `siterep-public` | siterep-public | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`deploy-production.yml`) | none |
| `TinyStudio.io-public` | TinyStudio.io-public | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, Workers R2 Storage Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`deploy-production.yml`) | none |
| `inish-site` | inish-site | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`ci.yml` deploy job) | none |
| `aiconverter-app` | aiconverter-app | `CLOUDFLARE_API_TOKEN` (repo) | Pages Write, Account Settings Read | none | GitHub-hosted (`deploy.yml`) | none |
| `tinystudio-in` | tinystudio-in | `CLOUDFLARE_API_TOKEN` (repo) | Pages Write, Account Settings Read | none | GitHub-hosted (`deploy-public-site.yml`) | none |
| `inish-mail-filter` | inish-mail-filter | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, Account Settings Read | none | GitHub-hosted (`deploy-production.yml`) | none |
| `seo-fix-kit` | seo-fix-kit | `CLOUDFLARE_API_TOKEN` (repo) | Workers Scripts Write, D1 Write, Queues Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`deploy-production.yml`: D1 migrations apply, `wrangler deploy` with custom domains and a queue consumer) | none |
| `fleet_console` | fleet-console-worker | `CLOUDFLARE_API_TOKEN` (repo), plus a repo `CLOUDFLARE_ACCOUNT_ID` | Workers Scripts Write, Account Settings Read | Zone Read, Workers Routes Write | GitHub-hosted (`deploy-production.yml`) | none |

The `mailbox` repo is the former `0509-support-inbox` repo (same repo id): the
`0509-support-inbox` entry above writes its secret through the GitHub rename
redirect, so it needs no entry of its own.

**No token is IP-locked.** Every job that reads a Cloudflare secret runs on
`ubuntu-latest`, and GitHub-hosted runners have no fixed address (an IP-locked
deploy token failed on them with Cloudflare error 9109). The lock exists in the
config (`vps_only = true` adds `condition.request_ip` with the addresses in `vps_cidrs`;
they are not kept in git; see "VPS-only tokens" below) and is for a
token whose jobs all run on the VPS self-hosted runners. No Cloudflare job does
today.

`CLOUDFLARE_ACCOUNT_ID` is an identifier, not a credential, and stays as it is
(org secret, plus repo secrets in drive, 0509-support-inbox and the 0509
`production` environment). The one in fleet-console-worker is managed by
`github_actions_secret.account_id_fleet_console`; the state already holds it
under that address, so the next plan shows no destroy for it, and `tofu destroy`
would delete it.

Permission groups are looked up by name from the
`cloudflare_api_token_permission_groups_list` data source (one lookup for the
account scope, one for the zone scope), never by hard-coded id. A name Cloudflare
does not know fails `tofu plan` with an "Invalid index" error instead of minting
a weaker token. To change what a repo may do, edit its `account` and `zone` lists
in `main.tf`.

Existing org secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` are
visible to all Nishfleet repos. A repo or environment secret of the same name wins
over the org secret, so the new tokens take over with no workflow change. The org
`CLOUDFLARE_API_TOKEN` stays in place as the fallback for any repo this config
does not manage; delete it by hand once every consumer is proven on its own token.

## State

State holds every token value in plain text, so it never sits in the repo. The
backend is `local` with the path

    ~/.local/state/fleet-ops/cloudflare-tokens/terraform.tfstate

(written out as `/home/nish/...` in `versions.tf`, because a backend block cannot
expand `~` or read variables). Create the directory private before the first run
and keep the umask tight so the state file and its `.backup` are `0600`:

    umask 077
    mkdir -p -m 700 ~/.local/state/fleet-ops/cloudflare-tokens

`.gitignore` also ignores `.terraform/`, `*.tfstate*`, `*.tfplan`, `*.tfvars` and
`crash.log`, as a second lock. Never copy the state into a PR, issue or comment,
and never run `tofu show`, `tofu state show` or `tofu output -json` in a shared
transcript. The outputs in this config are dates only. The `.terraform.lock.hcl`
file is committed on purpose: it pins the provider versions.

The state file is the only record of the live tokens' values. The directory is
in `config/restic/include.txt` (installed to `/etc/restic/include.txt` by
`ansible/host.yml`), so the nightly restic backup carries it. Known gap: until
that include reaches the box (the next `fleet-host-config` run after merge) the
state is not backed up, and `/etc/restic/` itself is root-owned, so this repo
cannot prove what the live list holds; check with
`grep cloudflare-tokens /etc/restic/include.txt`. If the state is lost, delete
the old tokens in the Cloudflare dashboard (names start `gha-`) and apply again
to mint fresh ones.

### State encryption

The state file holds the token values as OpenTofu wrote them, so the state is
encrypted with OpenTofu's own state encryption (AES-GCM, key derived from a
passphrase). The passphrase and the method settings are not in this repo: they
are one `TF_ENCRYPTION` line in a private env file that
`cloudflare-tokens-apply.service` loads when it exists
(`EnvironmentFile=-`). `state-encryption.env.example` is the template. The file
lives next to the other Cloudflare env files under `~/.config/cloudflare/`, so
the nightly backup carries it with the state; without the passphrase the state
cannot be read, so keep that backup.

Turn it on once, by hand, with no one else applying at the same time:

    umask 077
    cp infra/cloudflare-tokens/state-encryption.env.example ~/.config/cloudflare/tofu-state-encryption.env
    # replace the placeholder with the output of: openssl rand -base64 32
    systemctl --user start cloudflare-tokens-apply.service

The first apply reads the plain state through the `fallback` member and writes
it encrypted. OpenTofu writes `.backup` only when the state changes, so the old
`.backup` stays a plain copy: after checking that
`grep -c '"resources"' ~/.local/state/fleet-ops/cloudflare-tokens/terraform.tfstate`
prints 0 and `tofu plan` (run as below) shows no changes, delete that one
`terraform.tfstate.backup`; the next state change writes an encrypted one. Then
delete the `fallback` member from the env file so a plain state is refused from
then on. With the passphrase lost, treat it like a lost state (see above).

A hand run of `tofu` needs the same variable. Do not `source` the file (a shell
strips the quotes in the JSON); use the unit, or
`systemd-run --user --wait --pipe -p EnvironmentFile=$HOME/.config/cloudflare/tofu-state-encryption.env -p WorkingDirectory=<deploy clone> ~/.local/bin/tofu -chdir=infra/cloudflare-tokens plan`.

## Apply

Install: OpenTofu `1.13.1` is installed by `ansible/host.yml` (pinned release,
sha256 checked) into `~/.local/bin/tofu`.

    cd infra/cloudflare-tokens
    set -a; . ~/.config/cloudflare/token-minter.env; set +a
    GITHUB_TOKEN=$(gh auth token) tofu init
    GITHUB_TOKEN=$(gh auth token) tofu plan
    GITHUB_TOKEN=$(gh auth token) tofu apply

Run it from an interactive session of the admin login, not from a jailed worker:
the worker jail hides both `~/.config/cloudflare` and `~/.config/gh` on purpose
(AGENTS.md, "Cloudflare credentials on this host"). The GitHub login needs admin
on each repo to write its secrets.

`~/.config/cloudflare/token-minter.env` holds `CLOUDFLARE_API_TOKEN=<minter>`: a
user token with `API Tokens Write` plus every permission group listed above
(Cloudflare only lets a token create tokens whose permissions are a subset of its
own). Lock it to the VPS addresses. It is `0600`, it is read by this directory
only, and it is not a GitHub secret.

### First apply

Read the plan before applying. The plan resolves every permission group name
against the live API, so it is the first real proof of the names. After the
apply, run one workflow per repo (a `workflow_dispatch` of the deploy or
export job) and add any permission group a job reports as missing to that
repo's list in `main.tf`. Permissions here were derived by reading each workflow
and `wrangler` config, not by running them.

## VPS-only tokens

`vps_cidrs` defaults to `[]` (the addresses are not kept in git). No token sets
`vps_only` today, so the empty default changes nothing. Before any token in
`main.tf` sets `vps_only = true`, supply the addresses to every `tofu` run,
including the weekly `cloudflare-tokens-apply.service`, for example
`TF_VAR_vps_cidrs='["<ipv4>/32","<ipv6>/128"]'` in that unit's environment, or a
gitignored `*.tfvars` file. Read the addresses on the box with
`curl -4 -s ifconfig.me` and `curl -6 -s ifconfig.me`. The `precondition` on the
token resource stays: with `vps_only = true` and an empty `vps_cidrs`, the plan
fails (fail-closed) instead of minting an unlocked token.

## Rotation

Each token has a `time_rotating` resource (30 days, `rotation_days`) and
expires 45 days after it was made (`expiry_days`). When 30 days have passed, the
next `tofu apply` replaces the `time_rotating` resource, which replaces the token
(`replace_triggered_by`) and rewrites the GitHub secret. The new token is created
first and the old one deleted after the secret is rewritten
(`create_before_destroy`), so a running deploy never sees a dead token. Token
names end in the creation date, so the old and new tokens can coexist.

Rotation happens only when `tofu apply` runs. If no apply happens within 45
days of the last one, the tokens expire and the deploys that read them fail. The
renewal timer below is what runs it.

## Renewal

Rotation is time-driven: Cloudflare keys expire on a date, so a schedule is the
right trigger (not an event).

| Unit | File | What |
|---|---|---|
| `cloudflare-tokens-apply.service` | `systemd/cloudflare-tokens-apply.service` | oneshot: `tofu -chdir=infra/cloudflare-tokens apply -auto-approve -input=false`, run from `~/workspaces/tooling/fleet-ops-deploy-clone` |
| `cloudflare-tokens-apply.timer` | `systemd/cloudflare-tokens-apply.timer` | `OnCalendar=weekly`, `Persistent=true`, `RandomizedDelaySec=1h` |

Weekly, because tokens rotate at 30 days and expire at 45: the apply does nothing
for three weeks, then replaces them, and two missed weeks still leave slack.

- Credentials: `EnvironmentFile=%h/.config/cloudflare/token-minter.env`. No env
  file holds a GitHub token on this host, so the unit takes `GITHUB_TOKEN` from
  `gh auth token` (the `~/.config/gh/hosts.yml` login). That login needs admin on each repo.
- State: the unit sets no state path. It uses the `backend "local"` path in
  `versions.tf` (`~/.local/state/fleet-ops/cloudflare-tokens/terraform.tfstate`),
  the same file as a hand apply. The provider cache goes to
  `~/.cache/fleet-ops/cloudflare-tokens-tofu` (`TF_DATA_DIR`) so the deploy clone
  stays clean for `fleet-sync.service`; `ExecStartPre` runs `tofu init`.
- Failure is loud: `OnFailure=fleet-unit-failed@%N.service` sends the
  healthchecks.io fail ping (fleet-ops#9033), and the unit shows in
  `systemctl --user list-units --state=failed`. Logs:
  `journalctl --user -u cloudflare-tokens-apply.service`.
- `tofu` is installed to `~/.local/bin/tofu` by `ansible/host.yml` (root, on the
  `fleet-host-config` run after merge). Until then the unit fails on a missing
  binary.

Wire it once, by hand, after the PR is merged and `fleet-sync` has pulled it
(README "Wiring a NEW unit"):

    systemctl --user link /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/cloudflare-tokens-apply.service
    systemctl --user link /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/cloudflare-tokens-apply.timer
    systemctl --user enable --now cloudflare-tokens-apply.timer
    systemctl --user start cloudflare-tokens-apply.service   # first run now, then read the journal

The user units live in `systemd/`, not in `ansible/host.yml`: that playbook is
the root-owned half (it installs `tofu` and the restic list).

Switch the renewal off: `systemctl --user disable --now cloudflare-tokens-apply.timer`.
To retire it for good, also `systemctl --user unlink` both unit names and delete
`systemd/cloudflare-tokens-apply.service` and `.timer` from the repo. The tokens
then keep working until their expiry date (at most 45 days after the last apply).

## Switch it off and delete it

1. `tofu destroy` (same environment as apply). It deletes every Cloudflare token
   this config made and every GitHub secret it wrote.
2. The workflows then read nothing (or fall back to the org secret). Recreate
   whichever secrets you still want by hand.
3. Remove `infra/cloudflare-tokens/`, the renewal units in `systemd/`, the
   `cloudflare-tokens-tofu` job and the tofu stub step in
   `.github/workflows/ci.yml`, the OpenTofu tasks in `ansible/host.yml`, and the
   state line in `config/restic/include.txt`.
4. Delete `~/.local/state/fleet-ops/cloudflare-tokens/` and
   `~/.config/cloudflare/token-minter.env`, and revoke the minter token in the
   Cloudflare dashboard.

To pause rotation without deleting anything, switch the timer off (see
"Renewal"); the tokens keep working until their expiry date.

## CI

`cloudflare-tokens-tofu` in `.github/workflows/ci.yml` runs `tofu fmt -check`,
`tofu init -backend=false` and `tofu validate` with `opentofu/setup-opentofu`
pinned by SHA. It has no Cloudflare or GitHub credential and never plans.
