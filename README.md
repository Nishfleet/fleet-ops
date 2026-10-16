# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — the user units the fleet runs under `systemctl --user`:
  services, timers, slices, four `.path` units (`fleet-litellm-proxy-config.path`, `fleet-gh-login-check.path`,
  `fleet-hermes-xai-login-check.path`, `fleet-grafana-provisioning.path`) and one `.scope.d` drop-in (`tmux-spawn-.scope.d`).
  `fleet-grafana-github-token.timer` re-mints the one-hour GitHub App token Grafana's
  alert webhook sends (fleet-ops#9445); switch off with
  `systemctl --user disable --now fleet-grafana-github-token.timer` plus `systemctl --user mask
  fleet-grafana-github-token.service` (the quadlet also mints once per Grafana start; docs/RUNBOOK.md).
- `rootfs/` — root-owned host config, laid out like `/` (`rootfs/etc/X` is
  installed at `/etc/X`): system units, slices and drop-ins, `nftables.conf`,
  `sysctl.d/`, `audit/rules.d/`, polkit rules and the prometheus config.
- `ansible/host.yml` — the Ansible playbook that installs `rootfs/`.
  `fleet-host-config.service` runs it as root (`ansible-pull`) on every merge
  and once a day, and fails on a hand-installed file.
- `ansible/update.yml` — the weekly safe full update of the box (see
  [Weekly update](#weekly-update)). `fleet-update.service` runs it as root
  (`ansible-pull`).
- `infra/cloudflare-tokens/` — OpenTofu config that makes one narrow Cloudflare
  token per repo and writes it into that repo's GitHub Actions secret, replaced
  every 30 days. Its README says how to apply, rotate and delete it.
- `containers/quadlet/` — `*.container` Podman quadlet units for the
  LiteLLM proxy, its Postgres and Redis, Grafana and aiostreams.
- `docs/` — `ARCHITECTURE.md`, `RUNBOOK.md`, `jev-call-sites.md`,
  `mac-rescue-2026-10-09.md` (the disposition of the Mac rescue bundles),
  `mac-scheduled-tasks.md` (the disposition of the Mac's 11 desktop
  scheduled tasks), `quality-bar.md` and `incidents/` (one blameless
  write-up per outage, named `YYYY-MM-DD-<slug>.md`).
- `template/` — `agents/`, `cursor-rules/`, `devin-config.json` and
  `README.md`, source files the live host links or copies by hand (see
  [template/README.md](template/README.md)).
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `intake-repos.json` is the declared set of
  repos enrolled in the agent-ready queue (see [Intake enrolment](#intake-enrolment)).
  `config/litellm-proxy.schema.rejects/` holds one YAML per rule
  `config/litellm-proxy.schema.json` must refuse: the bench block, a router
  cooldown over 60, a zero row cooldown, a row cooldown, one case per
  judge-group rule (the fallback rows back on order 1, the paid row's rpm
  raised, its concurrency raised, a fourth judge row, the paid row doubled
  as its own fallback, a fallback row renamed, both fallbacks on one key, and
  a swap of the paid row's model, host or key, or of a fallback's model or
  host), a router with no Redis pin store, a router affinity TTL below 300 and
  a router affinity TTL above 600, an `optional_pre_call_checks` list without
  `session_affinity`, one case per cache-declaration rule (a row with no
  `supports_prompt_caching` flag, a row with no `cache_proof`, a
  non-cacheable worker row not on `order: 2`, and a worker row forced onto
  `order: 1`), a router whose `allowed_fails_policy` drops
  `NotFoundErrorAllowedFails`, a router whose `NotFoundErrorAllowedFails` is
  not 0, a router with no `allowed_fails_policy` block at all, and a row whose
  own `allowed_fails_policy` names `NotFoundErrorAllowedFails` at anything but
  0 (a row-level threshold resolves before the router policy, so a row
  override would re-open the two-404 leak). CI validates every file in the directory against the schema
  and each must fail, so a loosened schema goes red. A new schema rule gets a
  reject file in the same PR.
- `config/grafana/` — the fleet-view Grafana provisioning
  (`provisioning/datasources/`, `provisioning/dashboards/`,
  `provisioning/alerting/`) and `dashboards/fleet.json`. Only provisioning
  files go under `provisioning/` (Grafana loads every file there and stops on
  a bad one); promtool fixtures live in `config/grafana/tests/`.
  `containers/quadlet/fleet-grafana.container` mounts all four read-only, so
  the UI cannot save edits.
- `config/claude-agents/` — the `helper` and `scout` subagent files
  `fleet-sync.service` copies into `~/.claude/agents` (README "Subagents on
  the Max config dir").
- `config/user-tmpfiles.d/agent-worktrees.conf` — the `systemd-tmpfiles`
  age-out rules `fleet-sync.service` applies on every sync: an
  `agent-worktrees/` dir untouched for 3 days goes, and so do the dated files
  under `.pi/agent/sessions`, `.cursor/chats/*/` and
  `.local/state/pi-issues`.
- `credentials/` — `app-manifest.json`, the worker GitHub App manifest
  (`.github/workflows/agent.yml` cites it for the App's grant).
- `.agents/skills/verify-fleet/` — the verify-fleet skill. `SKILL.md` says how
  to run one real fleet unit and collect proof (invocation id, journal,
  artifact, exit, CPU and memory peak); `fleet-map.md` holds one row per unit,
  timer, path, slice or template.
- `.semgrep/` — `no-glue.yml`, the no-glue rule `ci.yml` runs
  (`docs/ARCHITECTURE.md` already names it).
- `systemd/retro-weekly.service`, `systemd/retro-weekly.timer`, `systemd/retro-weekly-api.socket` and `systemd/retro-weekly-api.service` — the weekly
  /retro (fleet-ops#9314, rebuilt in #9641): one Claude Code call on the
  Anthropic API reads a week of sessions inside a bwrap jail with no gh login and
  no GitHub token, and writes a private report to the vault. `prompts/retro-weekly.md`
  is the job; `config/retro-public-deny.txt` is the check every follow-up issue
  must pass before it is filed; `config/retro-weekly-claude.json` is the tool
  list. README "Weekly retro" has the run, off and delete steps.
- `systemd/fleet-provider-watch.service` and `systemd/fleet-provider-watch.timer` — the
  daily provider watch: each router provider's model list is compared with
  the host snapshot, and a change files one fleet-ops issue with no model id in it. README
  "Provider watch" has the run, off and delete steps.
- `systemd/amp-runner-nish.service`, `amp-runner-rajeev.service`,
  `executor.service`, `syncthing.service`, `tigervnc.service` and the drop-in
  `systemd/tincan-listen-claude-vps.service.d/10-nish-seat.conf` — stock vendor
  binaries (Amp, Executor, Syncthing, TigerVNC) run under systemd, and the
  second-login env line for the Tincan listener. They were hand-placed on the
  host with no repo copy (fleet-ops#9645); they decide nothing and wrap
  nothing. The live path under `~/.config/systemd/user` is a symlink into the
  deploy clone, so `fleet-sync.service` pulls every edit and LINK-GUARD checks
  the link. Install on a fresh host: `ln -s` each file from the deploy clone's
  `systemd/` into `~/.config/systemd/user/` (the drop-in goes into
  `tincan-listen-claude-vps.service.d/`), then `systemctl --user daemon-reload`
  and `enable --now`. The files match what ran before (only the two Amp
  `Description=` lines lost their account names), so adopting them restarted
  nothing: a unit edit applies at the unit's next restart (never restart
  `tigervnc.service` while a remote-desktop session is live). `ci.yml` runs
  `systemd-analyze verify` on the five units; the drop-in is not a unit file,
  so only its parent unit is verified. Switch one off with
  `systemctl --user disable --now <unit>`; delete it by removing its file here
  and the live link, then `systemctl --user daemon-reload`.
- `systemd/fleet-pr-sweep@.service` and `systemd/fleet-pr-sweep@.timer` — start
  the agent-dispatch sweep in `Nishfleet/<instance>` every hour with one
  `gh workflow run`, because GitHub fired the sweep's own cron only 4 to 5
  times a day (measured 2026-10-11). The sweep's `stuck-prs` job is what moves
  any PR left waiting over 15 minutes: it arms a head a reviewer approved, asks
  the review job for a head with no verdict, sends a claim PR back to its worker, or files a `needs-orchestrator`
  issue for a PR no worker owns. One instance per repo with an agent-dispatch
  stub (fleet-ops, 0509, drive, aiconverter-app,
  TinyStudio.io-public, siterep-public, rera-report-card), linked and enabled by
  `fleet-sync.service` on every deploy. Off switch: remove its step 2a and enable
  line, then `systemctl --user disable --now 'fleet-pr-sweep@*.timer'`.
- `systemd/later-sweep.service` and `systemd/later-sweep.timer` — promote an
  issue to `agent-ready` once the `due: <date> <time> IST` line in its body has
  passed, every 15 minutes, in the repos `config/intake-repos.json` enrols. A
  one-shot transient `later-*` timer is lost when the user manager restarts, so
  an issue due later the same day sat unread for a day (fleet-ops#9376); a
  persistent timer cannot be lost that way. One `gh issue list` per repo, then
  one `gh issue edit --add-label agent-ready` per promoted issue, at most five a
  run. Each list is the repo's 300 newest open issues, so a repo that carries
  more open issues than that is swept only inside that window. `jq` makes the
  whole decision, so no model reads an issue body and there is no session to
  jail: only an issue authored by `nish3451` or the worker App is promoted, and
  an issue that already carries `agent-ready` or any park label is skipped.
  `fleet-sync.service` step 2f links and enables it on every deploy. Off switch:
  remove that step and its enable line, then `systemctl --user disable --now
  later-sweep.timer`.
- `systemd/fleet-gh-login-check.service`, `.path` and `.timer` — fail, and so
  page through `fleet-unit-failed@`, when the box's github.com gh login is gone,
  revoked or not `nish3451`. The path unit checks on every change to
  `~/.config/gh/hosts.yml`, the timer hourly. Wire once with `systemctl --user
  link` of all three, then `enable --now` the `.path` and `.timer`. Switch off:
  `systemctl --user disable --now fleet-gh-login-check.timer
  fleet-gh-login-check.path` and delete the files.
- `systemd/fleet-hermes-xai-login-check.service`, `.path` and `.timer` — fail, and
  so page through `fleet-unit-failed@`, when `hermes auth status xai-oauth` does
  not say `xai-oauth: logged in` (the SuperGrok login behind Hermes's `x_search`,
  which hides itself silently when it dies). The path unit checks on every change
  to `~/.hermes/auth.json`, the timer hourly. Wire once like the gh check above.
  Fix a BROKEN line with `hermes auth add xai-oauth --no-browser`. Switch off:
  `systemctl --user disable --now fleet-hermes-xai-login-check.timer
  fleet-hermes-xai-login-check.path` and delete the files.
- `systemd/leviathan-index@.service` and `systemd/leviathan-index@.timer` —
  the Leviathan session-log search index, refreshed every 15 minutes per
  instance (`claude`, `pi`): an FTS5 index over the session JSONLs that
  answers "what did an old session say about X" in milliseconds (fleet-ops#9313).
  Config and index live in `~/.local/share/leviathan/` (0700), installed from
  `config/leviathan/` by `fleet-sync.service`; the binary is installed by
  `ansible/host.yml` from a pinned release. Off switch, under 2 minutes and
  nothing re-enables it: `systemctl --user disable --now leviathan-index@claude.timer leviathan-index@pi.timer`,
  then `rm ~/.local/bin/leviathan && rm -rf ~/.local/share/leviathan` —
  `host.yml`/`update.yml` only install and version the binary and
  `fleet-sync.service` only refreshes unit and config bytes, so no fleet unit
  ever re-enables a timer. Wire new instances only after `fleet-sync.service`
  has run once with the configs merged (the 15-minute tick pages on a missing
  config). Each run rebuilds the index from the files on disk, so it mirrors
  the logs and keeps the same retention; the index never holds more than the
  logs do.
- `rootfs/etc/prometheus/fleet_rules.yml`, `rootfs/etc/alertmanager/alertmanager.yml`
  and the `rule_files` and `alerting` blocks of `rootfs/etc/prometheus/prometheus.yml`
  — the dead-man and the pages. Prometheus loads eleven rules:
  `Watchdog` (always firing), `SystemUnitFailed` (visible, pages nobody),
  `NodeExporterDown` (the `node` target down for 5 minutes, severity nish),
  `HermesGatewayDown` (`hermes-gateway.service` has no active sample for 5
  minutes while the `node` target is up), `PrometheusConfigReloadFailed`
  and `AlertmanagerConfigReloadFailed` (stock reload metrics, severity nish),
  `BackupStale` (the nightly off-site backup timer has not fired for
  30 hours), `BackupFailed` (a backup unit stayed failed for an hour),
  `SiteDown` (a `site-*` blackbox probe failed, or could not run, for 10 minutes),
  `AISpendHigh` (LiteLLM paid spend over 40 USD in 24 hours) and
  `AISpendMetricMissing` (that spend metric absent for a day). Every one but
  the first two pages. Alertmanager sends `Watchdog` every 5 minutes as a plain webhook to
  an outside healthchecks.io check, which alerts when the pings stop, and sends
  `severity=nish` alerts to Telegram. The ping URL, the bot token and the chat
  id are hand-placed 0600 files in `/etc/prometheus` (`deadman_url`,
  `telegram_bot_token`, `telegram_chat_id`); the repo holds none of them.
  `.github/workflows/ci.yml` runs `promtool check config`, `promtool check
  rules`, `amtool check-config` and `promtool test rules
  config/prometheus-tests/`. Off switch, temporary, under 2 minutes: `sudo systemctl
  disable --now prometheus-alertmanager.service`, then pause the check on
  healthchecks.io so it stops alerting. The next `fleet-host-config.service`
  run starts Alertmanager again, so for a lasting off, merge a PR that removes
  the enable task in `ansible/host.yml` and the `rule_files` and `alerting`
  blocks. Delete it: that same PR also removes the rule file, the Alertmanager
  config and options, the playbook tasks and the CI step; then `sudo rm
  /etc/prometheus/deadman_url /etc/prometheus/telegram_bot_token
  /etc/prometheus/telegram_chat_id` and delete the check on healthchecks.io.
  Stopping Alertmanager does not touch
  `hermes-gateway.service`.
- `systemd/fleet-sync.service` (started by
  `.github/workflows/deploy-box.yml` on push) — the whole deploy mechanism:
  a clean-clone check that prints
  `DEPLOY-BLOCKED` and fails, `git fetch` + `git merge --ff-only` plus two
  `git merge-base --is-ancestor` probes that fail unless `HEAD` equals
  `origin/main`, `systemctl --user link` of `fleet-unit-failed@.service` and
  `systemctl --user daemon-reload`, `systemd-tmpfiles --user --create`,
  user-scope `install -C` copies (`config/pi-models.json` to
  `~/.pi/agent/models.json`, `config/litellm-proxy.yaml` to
  `~/.config/fleet-ops/litellm-proxy.yaml` behind a `cmp` guard,
  and the leviathan index units, their configs and the tmpfiles rule to
  `~/.local/share/leviathan/` and `~/.config/user-tmpfiles.d/`, fleet-ops#9313),
  and a LINK-GUARD pass
  that fails the unit on a dangling or throwaway-target live symlink
  (fleet-ops#7743). Root-owned files (`/etc/**`, `agent.slice`, everything under
  `rootfs/`) are not this unit's job: `fleet-host-config.service` installs them
  as root from its own clone.

## Install

There is no installer. Every live user-scope path is a **symlink into this
repo**, so a push to `main` is the deploy (`deploy-box.yml` runs
`fleet-sync.service`, a fetch plus `--ff-only` merge, described below) — the
file the fleet runs and the file in git are the same inode. Nothing is copied,
so nothing can drift, and the
5,948 LOC that used to copy files and then hunt for the drift copying caused
(`install.sh`, `MANIFEST`, `bin/fleet-ops-deploy`, `bin/fleet-deploy-check`,
`bin/fleet-ops-drift.py`) were deleted on 2026-09-18.

`deploy-box.yml` starts `fleet-sync.service` on every push to main, which
keeps the clone current. It is the only deploy machinery on the box:

```
systemctl --user status fleet-sync.service
systemctl --user start fleet-sync.service   # force a sync now
journalctl --user -u fleet-sync.service -n 50
```

The unit fails loudly on a dirty or diverged clone. That is
correct: the live source must be clean `origin/main`, and a failed
`fleet-sync.service` fires `OnFailure=fleet-unit-failed@` (healthchecks.io
fail ping, fleet-ops#9033).

The sync is a `git fetch` of `main` into `refs/remotes/origin/main`
followed by a `git merge --ff-only` of that named ref — never
`git pull`, which merges the multi-entry `FETCH_HEAD` and dies with
`Cannot fast-forward to multiple branches` when anything else in the
clone has written that file (fleet-ops#8893). Two `merge-base
--is-ancestor` lines then assert `HEAD == origin/main`, so a deploy
window that ends a commit short fails the unit instead of leaving the
live clone quietly behind.

### Wiring a NEW unit (one-time, by hand)

`man systemctl`: _"link PATH... Link a unit file that is not in the unit file
search path into the unit file search path. This command expects an absolute
path to a unit file."_ Add the unit file to `systemd/`, merge it, then once:

```
systemctl --user link  /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>
systemctl --user enable --now /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>   # timers and .path units
systemd-analyze verify /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>
```

`systemctl --user list-unit-files | grep linked` shows the linked set.
Retiring a unit is the mirror image: `systemctl --user disable --now <unit>`
then `systemctl --user unlink <unit>` (or `rm ~/.config/systemd/user/<unit>`)
and delete the file from `systemd/`.

Drop-in directories (`<unit>.service.d/*.conf`) are not unit files, so
`systemctl link` does not take them. Symlink them by hand, once:

```
mkdir -p ~/.config/systemd/user/<unit>.service.d
ln -sfn /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/<unit>.service.d/<x>.conf \
        ~/.config/systemd/user/<unit>.service.d/<x>.conf
```

Same idiom for a new Pi prompt (`~/.pi/agent/prompts/<x>.md`). One `ln -sfn`,
once, and git owns it from then on. New scripts are not added at all: the
glue-zero rule (docs/ARCHITECTURE.md) allows config values, unit lines and
prompt lines only — a stock feature replaces an organ or nothing does.

### The exceptions: files that must stay COPIES

These classes are deliberately copies, not symlinks, and a `git pull` does
NOT update them. The rows marked **Handled automatically** are refreshed by
`fleet-sync.service` (user files) or `fleet-host-config.service` (root files)
instead — a hand copy of one of those is wasted work,
the next sync overwrites it. The rest are refreshed by hand.

| live path                                                                                                                   | repo source             | why a symlink is wrong                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `~/.pi/agent/models.json`                                                                                                   | `config/pi-models.json` | **Handled automatically** by `fleet-sync.service` (install -C, fleet-ops#8568). A copy, not a symlink, because `~/.pi/agent` is an overlay mount in worker containers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `~/.local/state/pi-packet/model-candidates.json`                                                                            | `none (live-only)`      | live state the git working tree must not rewrite on every checkout (fleet-ops#2910/#3722/#3322).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `~/.pi/agent/settings.json`                                                                                                 | `none (live-only)`      | pi writes this file itself at runtime (provider/model switches and its own bookkeeping keys), so a repo copy would be overwritten and a symlink would fight pi. Every fleet caller passes `--provider litellm --model <group>`, so its `defaultProvider`/`defaultModel` affect only bare interactive `pi` runs (fleet-ops#8568). Its `compaction.reserveTokens: 40000` pairs with the worker `contextWindow: 140000` in `config/pi-models.json`: pi compacts at window − reserve = 100k (fleet-ops#9081: spend-log worker prompts averaged 71k and p90 was 141k, so a 256k compact point never fired). Reply budget is window − context − 4096, so a turn at the compact point still gets the full 32k `maxTokens` (140000 − 100000 − 4096 = 35904). The 96000/8192 pairing cut replies to ~4.8k (fleet-ops#8634) and is not used. The real model windows are ~1M; 140000 is a budget, not a limit. |
| `/etc/**` (system units and drop-ins, `sysctl.d`, `audit/rules.d`, `polkit-1/rules.d`, `prometheus/*.yml`, `nftables.conf`) | `rootfs/etc/**`         | cross a privilege boundary. **Handled automatically** by `fleet-host-config.service`: Ansible (`ansible/host.yml`) checks the prometheus and nftables files, installs every file under `rootfs/` as root, and reloads only the daemon whose file changed. A new root file is a new file under `rootfs/`; nothing is installed by hand.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `~/.local/share/leviathan/` (`leviathan-index@.service`, `leviathan-index@.timer`, `claude.toml`, `pi.toml`) and `~/.config/user-tmpfiles.d/leviathan.conf` | `systemd/leviathan-index@.timer`, `config/leviathan/*.toml`, `config/user-tmpfiles.d/leviathan.conf` | **Handled automatically** by `fleet-sync.service` (install -C before the daemon-reload, fleet-ops#9313). The timer fires every 15 minutes, so the unit and config bytes must exist on the box before the PR that ships them merges — a git merge refuses a clone with untracked files in the way, so nothing may read these from the deploy clone. The live unit links are hand-set once (`systemctl --user link ~/.local/share/leviathan/...`); a `user-tmpfiles.d` symlink would dangle pre-merge and be read dead by `systemd-tmpfiles --create` on every sync. Each run rebuilds the index from the files on disk, so the index mirrors the logs and never holds more than the logs do. |

```
# a changed /etc file: merge it under rootfs/etc/. deploy-box.yml then runs
systemctl start fleet-host-config.service    # polkit allows user nish; no sudo
journalctl -u fleet-host-config.service -n 60 --no-pager   # PLAY RECAP failed=0
```

Files kept off GitHub on purpose (they reveal access paths or backup targets)
are listed in `/etc/fleet-ops/box-only` on the box, so the drift check skips
them. That list is the only hand-kept root file.

For `agent.slice` specifically, a hand copy is not enough to check the change
landed: `daemon-reload` re-applies the limit to the running slice, so confirm
both the unit and the cgroup read the new cap.

```
systemctl show agent.slice -p MemorySwapMax      # 1073741824, not infinity
cat /sys/fs/cgroup/agent.slice/memory.swap.max   # same number
```

### Devin workspace-trust key (fleet-ops#4825)

`install.sh` used to merge `skip_workspace_trust: true` into
`~/.config/devin/config.json` on every deploy, so a Devin auto-update that
rewrote the config could not silently wall the seat. That merge is gone with
the installer. The live config carries the key today; if the Devin CLI ever
refuses with _"Refusing to run in an untrusted workspace"_, re-apply it once:

```
jq '. * ($o[0]) | del(.respect_workspace_trust)' --slurpfile o <repo>/template/devin-config.json \
   ~/.config/devin/config.json > /tmp/devin.json && mv /tmp/devin.json ~/.config/devin/config.json
```

### Canonical checkout (fleet-ops#372)

The live source — the tree every live symlink resolves into:

`/home/nish/workspaces/tooling/fleet-ops-deploy-clone`

It must stay on branch `main`, clean. Feature and auditor work uses a linked
worktree. `products/fleet-ops` still points at the worktree parent
(`/home/nish/workspaces/tooling/fleet-ops`) until no linked worktrees remain
there; that parent carries the pre-rewrite init history (16 commits with no
merge-base against `origin/main`). Do not deploy from it and do not delete it
while worktrees are attached. Workers do not create worktrees from the
deploy-clone: each `git clone`s into its own
`agent-worktrees/issue-<repo>-<N>` directory (`.mirrors` as an optional
reference), and the deploy clone is mounted read-only in the worker jail
(fleet-ops#410).

The old non-canonical-checkout guard lived in `install.sh`: it refused a
mutating install from any other tree, because an install from a worktree
retargeted every live symlink at a tree that could be deleted. With no
installer there is no mass-retarget path, but hand wiring can still point
one link the wrong way — on 2026-09-18 a session linked the
`standing-rules-render` units and the vault canonical rules file into a
churning checkout, and they dangled when the files vanished, taking the
standing-rules render down (fleet-ops#7743). The guard for that is in
`fleet-sync.service`: the LINK-GUARD step fails the unit — on every deploy
push to main and at boot — while any symlink under `~/.config/systemd/user`,
`~/.local/bin`, `~/.pi/agent` or `~/workspaces/tooling/nish-vault` is broken
or resolves into a throwaway root (`*worktrees/*`, `agent-state`, `tmp`).
Live links belong to the canonical checkout and the stable install dirs
(`~/.local/share`, `~/.local/lib`), never to a tree a session can delete or
re-clone.

## systemd by default

A backgrounded `pi` dies when the launching shell ends, and the four
`EXTLOAD-OK` lines it leaves behind look like a dead seat. Detached runs are a
systemd transient unit. There is no wrapper script: `bin/pi-systemd-run` (523
lines) and `bin/pi-detached-deadman` (410 lines) were deleted on 2026-09-18 and
replaced by two stock `systemd-run` properties.

```
systemd-run --user --collect --unit <name> \
  -p RuntimeMaxSec=<seconds> \
  -p Requires=fleet-worker-github-token@<repo>.service \
  -p After=fleet-worker-github-token@<repo>.service \
  -p "EnvironmentFile=$XDG_RUNTIME_DIR/fleet-worker-github-token/<repo>.env" \
  -p "TemporaryFileSystem=$HOME/.config/gh" \
  -p 'ExecStartPre=/bin/sh -c '"'"'test -n "$GH_TOKEN"'"'"'' \
  -E DELIVERABLE=<absolute artifact path> \
  -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' \
  -- sh -c 'cat /path/to/packet.md | pi --print --provider <provider> --model <model>'
```

`<repo>` is the Nishfleet repo the worker targets. `Requires=` pulls in
`fleet-worker-github-token@<repo>.service`, which mints a one-hour nishfleet-worker
App token limited to that repo into `$XDG_RUNTIME_DIR/fleet-worker-github-token/<repo>.env`;
the `EnvironmentFile=` is required (no `-`), so a failed mint means the worker never
starts, and `ExecStartPre=` fails an empty `GH_TOKEN` before any work. `TemporaryFileSystem=`
blanks the human gh login for the run, as agent.yml's jail does, so a worker cannot fall
back to it (fleet-ops#9738). The launch line exits non-zero when it refuses.

`RuntimeMaxSec=` is the deadline: systemd kills an over-running unit into
`Result=timeout`. The `ExecStopPost=` line is the deliverable check: a stop at
exit 0 that left no artifact becomes `Result=exit-code`, i.e. `failed`, which is
what `OnFailure=` and the failed-units pass key off. Both halves were proven on
this host on 2026-09-18 (RED: no artifact -> `Result=exit-code`; GREEN: artifact
written -> `Result=success`; `RuntimeMaxSec=5` against `sleep 60` ->
`Result=timeout`).

Drop `--collect` when you want the dead unit to stay listed in
`systemctl --user list-units --state=failed`. With `--collect` systemd unloads
the unit as soon as it dies, so the failure survives only in the journal
(`journalctl --user -u <name>`).

Watch a live run with `systemctl --user status <name>.service`.

Not a dispatcher: no retry ladder, no seat rotation, no queue. `RuntimeMaxSec=`
and the deliverable check together are the whole of what the retired wrapper's
`--deadline` and `--deliverable` flags did (fleet-ops#4266); the healthchecks
dead-man ping and the `fleet_detached_job_died` gauge went with the script, and
the `DetachedJobDied` alert that read that gauge was deleted with them — systemd
already records the death.

If the packet clones a repo, use a reference clone against the local
bare mirror (fleet-ops#1213), not a full GitHub copy:

```
git clone --reference-if-able /home/nish/workspaces/.mirrors/<repo>.git \
  https://github.com/Nishfleet/<repo>.git <dest>
```

Never `--dissociate` on throwaway worktrees. Never push to a mirror
(read-only fetch target). A missing, stale or corrupt mirror degrades to a
plain clone — which is exactly why the `git-mirror-update` refresher was
deleted in the 2026-09-18 glue sweep: `--reference-if-able` borrows whatever
objects the mirror already has and fetches the rest from GitHub, so a mirror
that stops being refreshed costs a little bandwidth, never correctness. The
mirrors under `/home/nish/workspaces/.mirrors` are left in place (14G) and
are still worth borrowing from; refresh one by hand with
`git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all` if it ever
drifts far enough to matter.

One trap lives inside the mirror itself (fleet-ops#5737): a mirror whose
fetch refspec covers `refs/heads/*` and `refs/tags/*` only never updates any
leftover `refs/remotes/origin/*` refs — `git show origin/main:<file>` against
the mirror then silently serves hours-old content while `main` is current.
Map the heads namespace into the remote-tracking one so the two spellings
cannot disagree, then refresh:

```
git -C /home/nish/workspaces/.mirrors/<repo>.git config --add \
  remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C /home/nish/workspaces/.mirrors/<repo>.git fetch --all
```

Every fetch then force-moves `refs/remotes/origin/*` to the same SHAs as
`refs/heads/*`, so a stale spelling heals on the next fetch instead of
lying. A mirror cloned fresh from GitHub carries no `refs/remotes/` at all
— its `origin/main` spelling fails loudly instead of lying until the first
fetch seeds it (correctly, under the refspec above). A mirror cloned from
another mirror inherits whatever remote-tracking refs the source carries —
the refspec above is what keeps them honest either way. Never
hand-`update-ref` `refs/remotes/origin/*` in a mirror.

A short log with no verdict after a backgrounded launch is a **launcher fault**
(the session reaped the process). A log containing `rate_limit` /
`ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do not mix
them up.

The Claude PostToolUse hook `~/.claude/hooks/guard_pi_packet.py` classifies
these from the redirected packet log. Launcher faults advise the transient-unit
one-liner above; lane faults advise seat rotation.

## Claim shared files before editing (interactive sessions)

Queued work has an atomic lock — the `claim/issue-N` branch. Interactive
sessions claim the same way, with stock git only: push a
`claim/adhoc-<scope>` branch from `main` before touching a shared file.
A pushed branch is the fleet-visible occupied sign, and a create-only push
collides atomically for a second claimant. Convention: **use the shared
file path as the scope** so two agents on the same file pick the same
branch name. `git ls-remote origin 'refs/heads/claim/*'` plus `gh pr list`
is the pre-flight conflict check; delete the branch when done.
`bin/fleet-claim`, the helper that wrapped this, was deleted in the glue
sweep — the stock push is the whole mechanism.

Stale interactive **sessions** are no longer reaped by a bespoke timer:
`interactive-session-reap` was deleted on 2026-09-18 after 113 consecutive
hourly runs that each reaped nothing. `systemd-oomd` is the native reaper
under real memory pressure. sshd, tailscaled, and the runner services are out
of scope: they do not live in `session-*.scope`. `claim/issue-*` and
`claim/adhoc-*` branches are released by the agent that claimed them.

## Weekly update

`fleet-update.timer` starts `fleet-update.service` every Sunday at 03:30 IST.
It runs `ansible/update.yml` as root through `ansible-pull`:

1. Pause: set the repo variable `FLEET_DISPATCH_PAUSED=true` in each queue
   repo, stop the work timers, wait until no runner has a job (up to 150 min),
   stop the runner services. `agent-dispatch` stays enabled: only its
   worker-starting jobs skip, and `hold-risky` keeps holding risky PRs. (It was
   `gh workflow disable` until 2026-10-05; a disabled workflow drops every
   trigger, the guard included.)
2. Prune: apt cache, Docker containers stopped for a day, dangling Docker and
   Podman images, old build cache, the npm and uv caches.
3. Update: `apt dist-upgrade`, `autoremove`, `needrestart -r a`, then each
   user-level tool through its own updater (npm globals, pi, claude and its
   plugins, cursor-agent, devin, uv, bun, rclone).
4. Resume, even when a step failed: start the runners, set
   `FLEET_DISPATCH_PAUSED=false` where this run set it, restart the timers,
   sweep each queue. The repos it paused are listed in
   `/var/lib/fleet-ops/dispatch-paused-by-update` from before the first set
   until every flag is clear again, so a run killed before this step (timeout,
   SIGKILL) is undone by the next run, which clears those flags first. A flag
   set by hand is never in that file and stays set.
5. Verify: the netcup runners online, each queue's sweep run accepted by
   GitHub, pi answering a real call with its extensions loaded and every
   extension in `~/.pi/agent/settings.json` pinned (full SHA for `git:`, exact
   version for `npm:`), no failed unit, router ready, Remote Control up. Any
   problem fails the unit, which pages.

It never reboots. When a package needs a reboot, it opens one
`needs-nish-decision` issue. The daily security updates (`unattended-upgrades`)
stay on; `rootfs/etc/needrestart/conf.d/50-fleet.conf` makes them only list
services on old libraries, so they never restart a service mid-job.
`claude-remote-control.service` is never restarted, by either path. A change to
it is therefore staged on merge: the file is copied in and the running server
keeps its old session until Nish restarts it, because that restart cuts his
phone link (#9425). The staged file as of 2026-10-08 adds
`--no-create-session-in-dir`, so relayed coordinator work no longer piles into
one standing session. Each request from the phone or a claude.ai/code project
relay then gets its own session with a fresh context. The one standing session
it replaces was measured at $52.0 over 21.0 h with a 69k average context; the
number after the restart is the real test.

- Apply a staged change to it. Nish does this, because it cuts the phone link
  for about a minute:
  1. `sudo systemctl daemon-reload` — without it systemd keeps the `ExecStart`
     line it already loaded, so the new flag never takes effect.
  2. `sudo systemctl restart claude-remote-control.service`.
  3. `systemctl --no-pager status claude-remote-control.service` shows
     `active (running)` with no restart loop, and one message sent from the
     phone is answered by a session with a fresh context.

- Run it now: `sudo systemctl start --no-block fleet-update.service`, then
  `journalctl -u fleet-update -f`.
- Switch it off: a PR that drops "Enable the weekly update" in
  `ansible/host.yml` and adds a task with `state: stopped, enabled: false`.
  In an emergency: `sudo systemctl disable --now fleet-update.timer`.
- Delete it: remove `ansible/update.yml`, the two `fleet-update` units and
  `50-fleet.conf`, and add their `/etc` paths to `retired` in `ansible/host.yml`.

## Remote Control stays on (OOM storm 2026-10-09)

The phone link must not drop, and when it does someone must hear within
seconds. Measured on 2026-10-09: a secret scan (trufflehog over a full git
history) started from one Remote Control session grew to 15.4G RSS on the 32G
host. Nothing capped `claude.slice`, and everything under Remote Control
inherited `OOMScoreAdjust=-900`, which scores a 15G scan the same as an idle
session. The kernel killed the unprotected services instead (hermes, the
router, the executor) and stalled the link for about two minutes with all 8G
of swap full. Nothing alerted anyone.

| Piece | File | Takes effect |
| --- | --- | --- |
| `claude.slice` `MemoryHigh=14G` / `MemoryMax=18G` / `MemorySwapMax=2G` (normal use 6-7G, incident peak 21.5G) | `rootfs/etc/systemd/system/claude.slice` | at the daemon-reload after merge |
| `OOMPolicy=continue`: a killed child no longer stops the whole unit | `claude-remote-control.service.d/50-alert-on-stop.conf` | at the daemon-reload after merge |
| `ExecStopPost=` starts `fleet-unit-failed@claude-remote-control.service`, the existing healthchecks.io fail ping (fleet-ops#9033) | same file | next restart of Remote Control (Nish) |
| `OOMScoreAdjust=-900` to `-500`, so a runaway session child can be chosen | `claude-remote-control.service` | next restart of Remote Control (Nish) |
| `OOMScoreAdjust=-500` for `hermes-gateway.service` | `hermes-gateway.service.d/70-oom-protect.conf` | next restart of hermes (it restarts itself) |

The alert uses `ExecStopPost=` because `OnFailure=` never fires for this unit:
it fires on `failed`, and `Restart=always` with `StartLimitIntervalSec=0`
(`selfheal.conf`) sends every exit to auto-restart. A deliberate restart by
Nish pings too. The ping needs `HC_URL_RECONCILE` in
`~/.config/fleet-ops/keystone-hc.env`; unset, the handler logs SKIP and exits 0.
That check is shared with every `fleet-unit-failed@` caller and is fail-only,
so it stays down until it is re-armed with a success ping, and a second drop
while it is still down does not page again.

The LiteLLM router gets no `OOMScoreAdjust`: it runs in the user manager,
which cannot lower the value below its own 100 (measured:
`systemd-run --user -p OOMScoreAdjust=-500` reads back 100). The cap above is
what keeps it from being the victim.

Switch off: delete `50-alert-on-stop.conf` (alert and `OOMPolicy`), the
`MemoryHigh`/`MemoryMax`/`MemorySwapMax` lines in `claude.slice`, or
`70-oom-protect.conf`, then `systemctl daemon-reload`. Delete the file from
`rootfs/` and add its path to `retired` in `ansible/host.yml`, otherwise the
next run installs it again. The running `ExecStopPost=` and `-500` stay until
Remote Control is next restarted.

### Remote Control keeps the Max login (2026-10-10)

`claude-remote-control.service.d/10-max-config.conf` sets
`CLAUDE_CONFIG_DIR=/home/nish/.claude-max`. The default login in `~/.claude`
is now a Team seat whose organization policy disables Remote Control, and on
that login the server exits at once and `Restart=always` loops on it (the
link was down from 10:52 to 10:56 UTC on 2026-10-10). The drop-in keeps the
link on the separate Max config dir whatever the default login is. A new
config dir registers a new Remote Control environment on claude.ai; the old
one stays listed as offline.

Switch off: delete the file, add its path to `retired` in `ansible/host.yml`,
`systemctl daemon-reload`, and restart Remote Control, only once the default
login allows Remote Control again.

### Subagents on the Max config dir (2026-10-11)

Claude Code reads subagents from `$CLAUDE_CONFIG_DIR/agents`, so with the
drop-in above every Remote Control thread got "helper not found", and the
model-lanes gate denies every other subagent type: no thread could delegate.
`config/claude-agents/` now ships `helper.md` and `scout.md` (until now
hand-placed in `~/.claude/agents`). `fleet-sync.service` step 2d copies them
there, `config/user-tmpfiles.d/claude-max-agents.conf` links
`~/.claude-max/agents` to `~/.claude/agents` (step 5), and step 5b fails the
sync if that path is anything but the link. Edit an agent here, by PR; a hand
edit of the live file is overwritten on the next sync.
`tests/test_claude_max_agents.py` runs those unit lines against a temp home.

Switch off: delete the three step-2d install lines and step 5b, the tmpfiles
file and its live copy in `~/.config/user-tmpfiles.d/`, then
`rm ~/.claude-max/agents`. The live agent files stay as plain files.

## Agent autonomy drop-in

`rootfs/etc/claude-code/managed-settings.d/50-agent-autonomy.json` is a Claude
Code managed-settings drop-in; Claude Code merges every
`/etc/claude-code/managed-settings.d/*.json` into its managed settings. The
hand-installed `/etc/claude-code/managed-settings.json` is not touched and
`/etc/claude-code` is not in `owned_dirs`. It does four things:

- Tells the auto-mode safety checker which orgs and repos are ours.
- Allows auto-merge (`gh pr merge --auto`) of an agent's own green PR in the
  repos whose rulesets require checks. Not `--admin`, not approving, not any
  other repo.
- Allows cleanup of an agent's own comments and its own systemd units.
- Adds a prompt hook on agent messages to Nish that bounces asks about routine,
  reversible steps, so the agent does the step and reports the result. Reserved
  matters (money, secrets, irreversible steps, safety gates) still go through.

Every `autoMode` array keeps `"$defaults"`, so these rules add to the built-in
ones and never replace them. `ansible/host.yml` installs the drop-in with a
`validate:` that refuses a file that is not a JSON object (a drop-in that does
not parse stops Claude Code from starting on the whole box), and the `ci` check
"Claude Code managed-settings drop-ins parse and keep the autoMode defaults"
holds both rules before merge.

- Verify: `claude auto-mode config` prints the effective rules, which now
  include the entries from the drop-in beside the defaults.
- Switch it off: a PR that deletes the file from `rootfs/` and adds
  `/etc/claude-code/managed-settings.d/50-agent-autonomy.json` to `retired` in
  `ansible/host.yml`. Remove the "Claude Code managed-settings drop-ins" ci
  step and the install task in the same PR once no drop-in is left.

## Browser tool: Chrome DevTools MCP

One free browser tool for every agent CLI on the box: the Chrome DevTools MCP
server driving the system `/usr/bin/google-chrome` headless (DISPLAY is unset),
in a throwaway profile (`--isolated`, deleted on exit), with usage statistics
and CrUX lookups off. Chrome starts on the first browser tool call and exits
when the client disconnects; an idle server is one Node process (about 170 MB).
A page load peaked at about 1.1 GB across the Node process and Chrome. This is
the default browser (vault `global-standing-rules.md`); browser-use cloud stays
for narrow fan-out only and its entries are not touched.

`config/chrome-devtools-mcp/package.json` and `package-lock.json` own the pin
(one exact version plus the lockfile's integrity hashes, bumped by a PR; no
`npx` and no `@latest` at runtime); `ansible/host.yml` owns the argument list.
The play copies both files under `~/.local/share/chrome-devtools-mcp`, runs
`npm ci --ignore-scripts` there when they changed or `node_modules` is missing
(not `npm -g`: the weekly `npm update --global` would move a global install
past the pin) and links `~/.local/bin/chrome-devtools-mcp` to it.

Every task that touches nish's home runs `become_user: nish`, never as root:
nish controls those paths, and a root task would follow a planted symlink
(`~/.config/mcp` to `/etc`, `mcp.json` to a root-only file). The tasks sit
after `flush_handlers` and before the credential assert, so a missing
credential file does not hold them back.

| Agent | How it gets the tool |
|---|---|
| Claude Code | `chrome-devtools` plugin in Nishfleet/claude-mods, enabled by `rootfs/etc/claude-code/managed-settings.d/60-chrome-devtools.json`; `fleet-sync.service` fetches and fast-forwards the claude-mods clone (a failure fails the unit). Worker lanes run `--strict-mcp-config`, which hides plugins, so `agent.yml` passes `--mcp-config` with `config/worker-mcp.json` (bare `chrome-devtools-mcp` from `~/.local/bin`). |
| Pi | the play merges the entry into `~/.config/mcp/mcp.json`, the shared MCP file pi-mcp-adapter reads (lazy lifecycle; other servers in it are kept). `rootfs/etc/tmpfiles.d/chrome-devtools-profiles.conf` ages out profile dirs a killed server leaves in `/tmp`. |
| OpenCode | the play writes `/etc/opencode/opencode.json`, OpenCode's managed config. |
| Devin, command-code | `devin mcp add` and `cmd mcp add --scope user`, run by the play when the entry is missing or its output lacks the command or any argument; a CLI that is not installed is skipped. |
| Cursor | the play swaps the dead `camofox-browser` entry in `~/.cursor/mcp.json` for `chrome-devtools`, keeping the other servers. Cursor still asks for approval (`cursor-agent mcp enable chrome-devtools`). |
| Hermes | one `chrome-devtools` line under `mcp_servers:` in `~/.hermes/config.yaml`, added when absent and `mcp_servers:` is a bare key (`mcp_servers: {}` or no key is left alone). Its built-in `browser` toolset needs the `agent-browser` CLI and its own Chromium, which this box does not have. |
| Codex | not installed; the play drops the dead `camofox-browser` table from `~/.codex/config.toml`. |

- The Devin, OpenCode and Pi worker lines in `agent.yml` pass no flag that hides these configs (no `--config`, `--no-mcp` or `--no-extensions`), so those workers get the tool as well; the jail binds `/` read-write, so Chrome and the link are visible in it.
- Verify: `chrome-devtools-mcp --version` prints the pin; `devin mcp get chrome-devtools`, `opencode mcp list`, `cursor-agent mcp list`.
- Switch off for one agent: remove its task (for Claude Code set
  `chrome-devtools@nish-mods` to `false` in `enabledPlugins`); `copy` never
  deletes, so also add `/etc/opencode/opencode.json` to `retired` for OpenCode.
- Delete it all: remove the OpenCode tasks and the tasks from "Create the Chrome
  DevTools MCP install directory" through "Add the chrome-devtools entry under
  Hermes' mcp_servers" in `ansible/host.yml`, `config/chrome-devtools-mcp/`, the
  `60-chrome-devtools.json` drop-in and
  `tests/test_chrome_devtools_mcp.py` with its `ci.yml` step, then
  `devin mcp remove` and `cmd mcp remove` the entry by hand.
- The check is the `ci` step "Chrome DevTools MCP is pinned once and wired into
  every agent": the args match in every fragment, and the Cursor, Codex and
  Hermes tasks run twice against temp copies (the second run changes nothing).

## CI

`.github/workflows/ci.yml` runs one job, `ci`, on every PR and push to main. Its
checks are stock: the secret-expansion grep,
`jq` config sanity, actionlint, zizmor, shellcheck, and systemd-analyze verify
over `systemd/`. The stock linters are joined by repo-specific gates: a no-glue
semgrep rule at `.semgrep/no-glue.yml`, a no long-lived personal-access-token
(PAT) grep, `nft -c` over `rootfs/etc/nftables.conf`, `ansible-playbook --syntax-check` over `ansible/host.yml` and `ansible/update.yml`, a no shell `${...}` or bare
`%s/%u/%h` check inside systemd Exec lines (fleet-ops#8382), pi seat ids
resolving to `config/litellm-proxy.yaml` `model_name` (fleet-ops#8332), and
Ollama rungs serving only the permitted slug on the native provider
(fleet-ops#8332, fleet-ops#9253), the Claude Code managed-settings drop-ins
(each file under `rootfs/etc/claude-code/managed-settings.d/` is a JSON object
and every `autoMode` array keeps `"$defaults"`), the litellm-proxy
schema gate: `config/litellm-proxy.yaml` must validate against
`config/litellm-proxy.schema.json`, and every
`config/litellm-proxy.schema.rejects/*.yaml` must fail the same check
(fleet-ops#8653), so a loosened schema goes red.

### Ratchet: workflow and script code only shrinks

The `ratchet` job in `ci.yml` calls `.github/workflows/ratchet.yml`, the one definition of the rule. It fails a PR whose net added lines (additions minus
deletions, `git diff --numstat` against the merge base) under `.github/workflows/`,
`.github/actions/`, `scripts/` and `bin/` are greater than 0. A PR that adds lines must delete at least
as many, so removing glue earns room. There are no exceptions in this repo: a new
mechanism is a component in its own repo, behind an official extension point. The job
self-tests on throwaway repos every run (growing fails; shrinking and an in-place edit pass).
A web or product repo adds a workflow with one job named `ratchet` that calls
`uses: Nishfleet/fleet-ops/.github/workflows/ratchet.yml@main` on `pull_request` and `merge_group`,
and requires the check `ratchet / ratchet` in its ruleset. Run from `@main`, the rule is
the base branch's, not the PR's; and a PR that edits the caller's `ratchet` job fails the check.
Not covered, because the Free plan has no org required workflows or org rulesets (the API answers
403, and a repository ruleset `workflows` rule is rejected): a PR can still repoint the caller's
`uses:` at another repository (fleet-ops#9627). Pin `@main`, never a SHA: the `agent` runner group allows
only `@main`, and a SHA pin queues forever. The check is in `ci`'s `needs` and in the `main-merge-queue`
ruleset's required status checks as `ratchet / ratchet`. To switch it off, remove that
context from the ruleset (Settings, Rules, `main-merge-queue`) and from `ci`'s `needs`. Deleting
the job alone does not switch it off: a required check that never reports blocks the PR.

`.github/workflows/secret-scan.yml` is the gitleaks scan (pinned binary +
sha256, `--redact`). fleet-ops has no deploy target. All actions are pinned to exact commit
SHAs. `agent.yml`, `ci.yml`, `deploy-box.yml`, `lighthouse.yml` and
`secret-scan.yml` set `timeout-minutes` on their jobs. `agent-dispatch.yml`
sets none. Its `new`, `rework`, `ejected` and `unblocked` jobs
call `agent.yml` through `uses:` and inherit its limits, while its `list` and `close-claim`
jobs run their own steps on `ubuntu-latest` with no `timeout-minutes`.

`.github/workflows/lighthouse.yml` is the fleet's one Lighthouse speed budget, stock LHCI
assertions in `config/lighthouserc.json` (LCP 1500 ms, interactive 3000 ms, CLS
0.05, script 150 KB, total 500 KB, no console errors; sizes are bytes there,
153600 and 512000). A web repo calls it with
`uses: Nishfleet/fleet-ops/.github/workflows/lighthouse.yml@main` and
`with: urls:` (one page URL per line); callers cannot change the assertions. It no longer prints the LCP breakdown to the step summary (removed to offset the `ratchet` job, fleet-ops#9622); the assertions are unchanged.

## Allowlist

There is no manifest and no installer. A path is live because something
symlinks to it from `~/.config/systemd/user/`, `~/.local/bin/`, or
`~/.pi/agent/prompts/`. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`,
`cf.env`) are never tracked — only the units that reference them.

## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
agent-dispatch. It is the single source of truth for which
repos are enrolled — adding or removing a repo is a PR against that file, not a
`systemctl enable`. This replaces the old imperative enrolment that was
silently reverted without a record (fleet-ops#32). `later-sweep.service` reads
this list too, so the overdue sweep follows enrolment without a second list.

Each enrolled repo needs three preconditions:

1. A git checkout at `/home/nish/workspaces/products/<name>` — the worker
   creates its worktree from it. Packet clones (when a worker clones instead
   of worktree-add) use `git clone --reference-if-able
/home/nish/workspaces/.mirrors/<name>.git
https://github.com/Nishfleet/<name>.git <dest>` (fleet-ops#1213).
   Mirrors are read-only fetch targets; never push.
2. The six labels listed in `required_labels` in `config/intake-repos.json`
   — `agent-ready`, `agent-in-progress`, `agent-blocked`, `agent-failed`,
   `needs-orchestrator`, `strong-only` — must be present on the repo —
   agent-dispatch fires only on the `agent-ready` label, so on a repo missing
   any required label an issue looks queued and is inert (fleet-ops#25).
3. An `.github/workflows/agent-dispatch.yml` stub whose
   `on.pull_request_target.types` lists all nine events — `dequeued`,
   `auto_merge_disabled`, `closed`, `auto_merge_enabled`, `synchronize`,
   `labeled`, `opened`, `reopened`, `ready_for_review`. `hold-risky` is the
   only door into `review-risky`, a `pull_request_target` trigger fires only
   for the types its own repo's stub lists, and `pull_request_target` reads
   that stub from the base branch — so a short list leaves the repo with no
   review and no coordinator gate on risky PRs (fleet-ops#9722, #9726).
   fleet-ops's own stub is the reference.

`excluded` in the file lists repos that are never enrolled (fleet2: no
second dispatcher, ever; archived repos). `deferred` lists repos paused with
the reason and the condition to re-enrol, and `fleet-ops` itself is in it.
Only `repos` is enrolled.

The `bin/intake-reconcile` reconciler and its `intake-reconcile.{path,
service,timer}` units were deleted in the glue sweep — the file itself is
the enrolment mechanism (fleet-ops#32, #25).

## Triage admission (needs-triage)

An open issue labelled `needs-triage` in an enrolled **product** repo
(`repos` with `product: true` in `config/intake-repos.json`) gets a Jev verdict
instead of waiting for a person to add `agent-ready`. The `admit` job in
`.github/workflows/agent-dispatch.yml` runs on the hourly sweep, on the
`needs-triage` label event and on `workflow_dispatch` (`task=admit`, optionally
`issue=<N>`). It asks the router `/jev` the same way `agent.yml` does: "Admit
this issue for an automated worker now?", with the title, body and labels as
state.

- p >= 0.9: `agent-ready` added, `needs-triage` removed.
- otherwise: `needs-orchestrator` added, `needs-triage` removed, for a person to decide.

Only the issue author `nish3451` is admitted. The newest `needs-triage` label
event must also come from `nish3451`. Non-owner issues are skipped with a notice
and left as `needs-triage` (no Jev call). A daily cap (`vars.ADMIT_DAILY_MAX`,
default 10) counts `triage-admit: admitted` comments since IST midnight and
stops early when reached. The job runs only when
`(inputs.agent_mode || vars.AGENT_MODE) == 'live'`. Issue title and body are
wrapped in `<ISSUE_TEXT>` fences so the model treats them as data, never as
instructions.

Every issue gets one comment with p, the model and the run link. An issue whose
title, body or labels touch secrets, money or payments, or customer-data
deletion, or that carries `blocked-on: nish-decision`, `nish-reserved` or
`needs-nish-decision`, never reaches Jev and never gets `agent-ready`: it goes to
`needs-orchestrator`. `Nishfleet/fleet-ops` is never acted on (fo#8304). If Jev
gives no answer the label stays and the next sweep retries. The labels are
written with the worker App token, so the `agent-ready` and `needs-orchestrator`
events start the next job.

**Switch it off:** set the repo variable `ADMIT_TRIAGE` to `off` on the calling
repo (`gh variable set ADMIT_TRIAGE --body off -R Nishfleet/<repo>`).
**Delete it:** remove the `admit` job, `tests/test_triage_admit.py`, its step in
`ci.yml`, and this section. CI runs the job's real scripts against a fake `gh`
and a fake router (`tests/test_triage_admit.py`).

## Red main issues

The hourly sweep (the `red-main` job in `agent-dispatch.yml`, on the caller's `GITHUB_TOKEN`) keeps exactly one open `agent-ready` issue per workflow file in an enrolled repo whose latest finished run on the default branch failed (CI included; disabled, dynamic and agent-dispatch workflows are skipped, and so are runs from forks). The issue body starts with the line `red-main: <workflow file>` and names the failing run, its first failing step and the last green sha. A `GITHUB_TOKEN` label fires no event, so the next sweep's `agent-ready` listing starts the worker.

- A new failing run adds a comment (marker `red-main-run: <run id>`), at most one a day.
- A green latest run closes the issue with a link to that run.
- An issue closed after a failing run is not filed again for that run.
- An issue is filed for a workflow at most once a day, and at most three new issues a day per repo, so a workflow that flips between red and green cannot start a worker every hour.
- Builders do not file their own issue for a red main: they use this one (fleet-ops#9308).

The sweep polls the latest run instead of reacting to `workflow_run`: that trigger takes literal workflow names in each caller stub (no wildcard), so a new or renamed workflow would be missed in every repo, and a missed event would leave an issue open after main turned green. The sweep reads the state itself, so it also closes.

**Switch it off:** set the repo variable `RED_MAIN` to `off` on the calling repo. **Delete it:** remove the `red-main` job, `tests/test_red_main_sweep.py`, its name in the `gated` list and test step of `ci.yml`, and this section. `Nishfleet/fleet-ops` is not swept.

## Workflow notes

Reasons and switches that used to sit as comments in the workflow files.

### agent-dispatch.yml: repo variables

```
Events that put work on the agent queue. Repo variable AGENT_MODE:
  shadow (default) = only issues also labelled shadow-actions, no rework
  live             = every agent-ready issue, plus rework on red CI
Repo variable MISS_REVIEW:
  off (default, unset) = miss-review jobs never start
  live                 = a miss event starts one different-family review
To switch miss-review off: set MISS_REVIEW to off, or delete the variable.
To delete it: revert the miss-review jobs in this file and the miss-review
path in agent.yml (Gate, Worker, Arm, Deliverable, Clean).
Repo variable ORCHESTRATE:
  off                  = the orchestrate job never starts
  live (default, unset) = a needs-orchestrator label starts one hand-off run.
  Default on (Nish 2026-10-04, "on for everything the fleet touches"), so a
  newly stubbed repo cannot sit off by omission.
Cost controls on the orchestrate job (fleet-ops#9351), one line per part:
  Daily cap: ORCHESTRATE_DAILY_MAX hand-off runs per IST day, default 10. Off: set the variable to 0.
  Model/turns pin: Sonnet (ORCHESTRATE_MODEL, default claude-sonnet-5-5), 40 turns. Off: label the issue needs-opus (Opus, 80 turns), or set ORCHESTRATE_MODEL to off for all.
  Hook skip: the session runs with --settings '{"disableAllHooks":true}'. Off: set ORCHESTRATE_HOOKS to on.
  Runner: pi on a LiteLLM seat (ORCHESTRATE_SEAT, default worker-capable), fleet-ops#9407. Off: set ORCHESTRATE_RUNNER to claude, or label the issue needs-opus.
    ORCHESTRATE_MODEL, ORCHESTRATE_HOOKS and the 40/80 turn pin apply to the claude runner only; pi has no turn cap, and the 3000 s timeout is its wall.
  Delete all three: revert the cap and pick blocks of the "Check the issue" step and the model/--settings lines of the session step here,
    the "Orchestrate cap and session args" step in ci.yml, and cap_cases and session_cases in config/orchestrate-events.json (or revert the merge commit).
To switch orchestration off: set ORCHESTRATE to off.
To delete it: revert the orchestrate job in this file, the workflow-path
detector in agent.yml's Gate, and prompts/orchestrator-handoff.md. A run
already in flight finishes: the label gate only stops new ones.
Repo variable FLEET_DISPATCH_PAUSED (the caller repo's, like the others):
  true                   = every job that starts a worker or picks work to
                           start skips, and the paused job logs one summary
                           line per skipped event
  anything else or unset = not paused
ansible/update.yml sets it to true for the weekly update and back to false in
its always: block, then sweeps. It replaces `gh workflow disable`: a disabled
workflow drops every trigger, so hold-risky could not hold a PR armed in that
window (2026-10-05, 08:11-10:47Z). hold-risky and close-claim never read it;
ci.yml fails if a guard job gains the condition or a dispatch job loses it.
Repo variable ADMIT_TRIAGE:
  off                   = the admit job never starts
  anything else or unset = an issue labelled needs-triage in an enrolled product
  repo, filed AND labelled by the human owner login alone and admitted by Jev
  (p >= 0.9), is queued. A bot login never admits; anything below 0.9 goes to
  the orchestrator. Caps: ADMIT_DAILY_MAX admissions per IST day (default 10)
  and ADMIT_BUDGET_SEC a run (default 780). Runs only while AGENT_MODE=live,
  so a shadow-mode repo gets no agent-ready it did not ask for.
  To delete it: remove the admit job, tests/test_triage_admit.py, its ci.yml
  step and the README section.
The orchestrate and admit jobs are the self-hosted jobs here: org runner group
`agent` (id 3) must list this file @refs/heads/main in selected_workflows,
or the job queues forever next to idle runners. Delete that entry with them.
```

### agent-dispatch.yml: stuck-prs STUCK program

stdin: {pr: {headRefOid, mergeable}, comments: the PR's issue
comments (API objects), red: names of failed required checks on the
head}. Out: {class, reason, url}. class is arm, review or stuck.
Only verdicts on the CURRENT head count, in the words agent.yml's
review job writes. Nothing arms without a reviewer or approver
approval of that head: an unreviewed head, held or not, is sent to
the review job, the same one hold-risky starts. A conflict or a red
check is stuck whatever the review said. Each review the sweep asks
for leaves a `stuck-review: <sha>` comment, so after three asks
with no verdict (a review job that died before it wrote one) the
head is stuck: STUCK re-asks once the marker is 15 minutes old.
config/stuck-pr-cases.json runs this program in CI.

## Worker capacity

The concurrency bound is the runner count (#8429): 22 `agent` runners
(`actions.runner.Nishfleet.netcup-agent-1..22` in org runner group 3, shared
by every enrolled repo including drive since 2026-10-06; live count:
`gh api orgs/Nishfleet/actions/runner-groups/3/runners --jq .total_count`;
sized from measured memory pressure, fleet-ops#8860), all in `agent.slice` (`rootfs/etc/systemd/system/agent.slice`,
26G/28G, `MemorySwapMax=1G`). RAM safety is per-unit `MemoryMax` plus
systemd-oomd, not an admission charge. Live RAM is
`systemctl --user show -p MemoryPeak <unit>` and `systemd-cgtop`.

## Private detail scan

Pull requests are scanned for private infrastructure detail: personal home
paths, the local seat config path, Tailscale addresses and names, and account
ids written next to an account id name. The rules are in
`.github/gitleaks-private-detail.toml` (they extend the gitleaks defaults). Only
the commits a PR adds are scanned, so old history cannot fail a PR. The job is
`private-detail-scan` and it is not a required check.

- Allow one line: put `gitleaks:allow` in a comment on that line.
- Switch it off: set the repository variable `PRIVATE_DETAIL_SCAN` to `off`
  (`gh variable set PRIVATE_DETAIL_SCAN --body off`). Delete the variable to
  switch it back on.
- Remove it: delete the `private-detail-scan` job and the rules file.
- The rules file is not named `.gitleaks.toml` on purpose, because gitleaks loads
  that name by itself and the full-history scans would start failing on old
  commits.

## Weekly retro

`retro-weekly.timer` starts `retro-weekly.service` every Monday at 07:00 IST.
It is built so a fooled model cannot do harm, not so it is asked not to.

- The model runs in a bwrap jail: the system is read-only, `/home` is an empty
  tmpfs, and only the session logs and steering files are bound back read-only. The gh login, the Cloudflare tokens, the
  seat files, the App key and the other Claude logins are not there.
- It has no GitHub token. A later step in the unit files at most three
  follow-up issues using the worker App's issues-only installation token
  (`fleet-grafana-github-token.service` mints it) with an empty `gh` config
  directory. Repo and labels are fixed in the unit.
- The report goes to the vault's `_system/retro/` and syncs to the Mac. A
  follow-up issue is a fixed five-line file (class, count, fix rung, owning
  repo and fix kind, each from a list); the unit builds the public title and
  body from a template, then `config/retro-public-deny.txt` must find no session
  id, path, quote, time of day, link, email or secret shape in it. One refusal
  fails the unit and files nothing.
- The jail has no network. The only way out is `retro-weekly-api.socket`, served
  by `systemd-socket-proxyd` to `api.anthropic.com:443` and nothing else.
- Follow-up issues carry only the label `retro` (`needs-orchestrator` would start
  a paid orchestrator run per issue), one open issue per class.
- The call is Claude Code to the Anthropic API with the model pinned in the unit.
  The `ollama` seat is a cloud service (`api_base` is `https://ollama.com`), so
  it is not used. The pin check fails the unit if the call was anything else
  and prints a `retro-provider:` line.

- Run it now: `systemctl --user start retro-weekly.service`, then
  `journalctl --user -u retro-weekly -f`.
- Switch it on: `systemctl --user enable --now retro-weekly.timer`.
- Switch it off: `systemctl --user disable --now retro-weekly.timer`.
- Delete it: switch it off, delete the four units (service, timer, api socket and api service), `prompts/retro-weekly.md`, the two
  `config/retro-*` files and step 2e of `systemd/fleet-sync.service`, then
  `systemctl --user unlink retro-weekly.service retro-weekly.timer retro-weekly-api.socket retro-weekly-api.service`.

## Provider watch

Providers change their offerings and publish no change event (Command Code moved to
one model only, OpenCode added a free slug), and nothing on the box noticed. A daily
schedule is the only way to see it, so `fleet-provider-watch.timer` starts
`fleet-provider-watch.service` every day at 06:30 IST (a few minutes of random delay,
`Persistent=true`).

No model id is ever stored in or filed on this public repo. The snapshot, the changed-id
lists and an optional ignore list live on the host, in the unit's `StateDirectory`
(`~/.local/state/provider-watch`, mode 0700); the repo keeps only `config/provider-watch.json`.

- One run reads each distinct provider (api_base plus the `os.environ/` key name, unique by key
  variable) from `config/litellm-proxy.yaml` and GETs its OpenAI-style `<api_base>/models` listing
  with that provider's key. A base with no `/v1`-style tail (`https://ollama.com`, the MiniMax
  `/anthropic` base) gets `/v1/models`. `curl --retry 2 --retry-delay 20` (three tries, 20 s apart;
  curl does not retry 401 or 403), so a blip does not page. The key goes to curl in a 0600 header
  file in the unit's runtime directory (`-H @file`), never argv.
- The keys come from the same per-provider key files the LiteLLM container reads; the unit lists
  the ones it needs one by one (not the whole directory), so the master key and the Claude logins
  are not in its environment. A missing file fails the unit with a plain line naming that provider
  while every other provider is still checked (`EnvironmentFile=-`); CI fails when a router key has
  no file line in the unit.
- First run for a provider: the sorted ids are saved to `catalog.json` in the state directory and
  nothing is filed (`provider-watch: <name> seeded, <n> models, nothing filed`).
- Later runs diff against that snapshot. A change writes the added and removed ids to
  `changes/<UTC date>-<provider>.txt` in the state directory (no cap), files ONE issue per changed
  provider, and then updates the snapshot, so a change is not filed twice. A provider whose filing
  fails keeps its old snapshot and fails the unit.
- The issue is fixed text only: title `Provider watch: <provider> model list changed`, the added and
  removed counts, the sentence "The ids are in the host state file changes/<date>-<provider>.txt
  under the StateDirectory of fleet-provider-watch.service." and the acceptance bullets. No text
  from the network reaches it. Labels `provider-watch` (created if missing, never rewritten) and
  `needs-orchestrator`: fleet-ops#8304 says control-plane work is never self-admitted, and the vault
  standing rule (`global-standing-rules.md`, nish3451/nish-vault#23) makes this one exception, from
  Nish on 2026-10-15, so the worker App's label starts one orchestrator hand-off run per issue (a
  paid model session, capped by `ORCHESTRATE_DAILY_MAX`). That run is on this host as the runner
  user, unjailed, so it reads `~/.local/state/provider-watch/changes/<file>` directly; the body
  tells it to keep ids out of issue text, PR text and commits. An issue with the same title that is open, or was created in the last 7 days even if
  closed, means the change is not filed again (the snapshot still updates). At most 3 issues per
  run; the rest wait for the next run.
- The acceptance bullets: a seat marked `"billing": "flat"` in `config/provider-watch.json` may get
  a real call to free or in-plan ids only; every other seat's body forbids all calls and sends the
  ids back as a `needs-nish-decision` line (the unit decides, not the model; MiniMax is marked flat
  on the router config header: "he is on the flat MiniMax Yearly Plus plan (5-hour and weekly
  limits, no per-token bill)", Nish 2026-10-09; the OpenCode keys are unlimited for
  one DeepSeek flash model only, so they are not marked). Then an eval-score before any router weight
  (`tests/evals`), a router PR only inside the standing rules (no new spend, 3 to 5 providers,
  removing a router row needs Nish's yes, no extra weight for a lower score), and a plain
  `needs-nish-decision` line for anything that costs money or needs his login.
- Every id must match `^~?[A-Za-z0-9._:/-]{1,64}$` and hold no `//` or `www.`, or that provider is
  refused: the unit fails with a line showing the first offender sanitized to `[A-Za-z0-9_-]`, and
  nothing is recorded or filed for it. Only a change to `ignore.txt` or to the provider's `watch`
  clears it.
- A listing that is still 5xx, 408, 429, a timeout, empty, or empty after the filters logs
  `provider-watch: <name> listing unavailable (HTTP <code>), skipped; outages page through
  litellm_deployment_state` and does not fail the unit. Any other non-200 (404 from a wrong listing
  path or api_base, 400) fails it, so a provider cannot silently drop out of the check. HTTP 401 or
  403 means a dead or expired key or login: the unit fails (`OnFailure=` pages) with one plain line
  naming the provider and what Nish must do, and no issue is filed. A router row with a key but no
  https api_base, or a key variable outside `^[A-Z][A-Z0-9_]*_API_KEY(_[0-9]+)?$`, is refused.
- `config/provider-watch.json` holds only generic per-provider settings: `watch` (an ERE; only ids
  matching it are compared; Cline lists a large catalogue that changes about weekly, so it watches
  only `:free`, `-free`, `deepseek/`, `z-ai/` and `cline` ids), `billing` (`flat`) and `listing`
  (`none` skips a provider with no listing endpoint). Ids to hide (early-access names) go one
  extended regex per line in `ignore.txt` in the state directory, matched case-insensitively; they
  never go in git.
- Not covered: outages (`litellm_deployment_state` in Grafana already pages those) and
  `not covered: price/limit pages, no API`.

- Run it now (it files a real issue on a change): `systemctl --user start fleet-provider-watch.service`, then
  `journalctl --user -u fleet-provider-watch -f`.
- Switch it on (once): `systemctl --user enable --now fleet-provider-watch.timer`. `fleet-sync.service`
  links the pair on every deploy (step 2g) but never enables it. The first run seeds the snapshot.
- Switch it off: `systemctl --user disable --now fleet-provider-watch.timer`.
- Read a change: `cat ~/.local/state/provider-watch/changes/<date>-<provider>.txt`. Reset a
  provider: delete its key from `catalog.json` (the next run seeds it again).
- Delete it: switch it off, delete `systemd/fleet-provider-watch.service`,
  `systemd/fleet-provider-watch.timer`, `config/provider-watch.json`, `tests/test_provider_watch.py`
  (and its name on the pytest line of the gh-login step in `ci.yml`), the two rows in
  `.agents/skills/verify-fleet/fleet-map.md` and step 2g of `systemd/fleet-sync.service`, then
  `rm` the two links in `~/.config/systemd/user/`, run `systemctl --user daemon-reload` and
  `rm -r ~/.local/state/provider-watch`.
