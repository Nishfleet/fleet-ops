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
- `ansible/update.yml` — the daily safe full update of the box (see
  [Daily update](daily-update.md)). `fleet-update.service` runs it as root
  (`ansible-pull`).
- `mac/` — the Mac's daily `topgrade` job: `com.nish.topgrade.plist` (the
  launchd agent) and `topgrade.toml` (the steps it runs, see
  [Mac daily update](mac-daily-update.md)). `tests/test_mac_topgrade.py` pins
  both.
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
  [template/README.md](../template/README.md)).
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `intake-repos.json` is the declared set of
  repos enrolled in the agent-ready queue (see [Intake enrolment](intake-enrolment.md)).
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
  `fleet-sync.service` copies into `~/.claude/agents` ([remote-control.md](remote-control.md) "Subagents on
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
- `systemd/beacon-hermes-poll.service` — Beacon's own Hermes watcher (owner: Nish), exactly
  `~/.local/bin/beacon endpoint hermes sync --watch --interval 1m`. Every minute it reads
  new sessions from `~/.hermes/state.db` (gateway and Telegram sessions included) and appends
  `harness.name=hermes`, `collection_method=poll` events to
  `~/.beacon/endpoint/logs/runtime.jsonl`. It runs outside the sandbox, so the Hermes units
  have no `.beacon` write path and Beacon's Hermes hooks stay uninstalled
  (`beacon endpoint hooks uninstall --harness hermes`; never `hooks install --harness hermes`
  again, it would capture twice). `fleet-sync.service` step 2i links it and enables it on every
  deploy. Off switch: remove that step and its enable line, then
  `systemctl --user disable --now beacon-hermes-poll.service`.
- `systemd/fleet-cua-desk-check.service` and `.timer` — fail, and so page through
  `fleet-unit-failed@`, when `cua sandbox ls --local` does not list `local:desk`
  as `ready`, or when a routine's `lastOutcome` in `~/.cua/persistent/routines.json`
  starts with `failed` (2026-10-18: the desk was pruned and three daily walks failed
  with no page). Hourly; it only reads. `fleet-sync.service` step 2h links both and
  enables the timer on every deploy. Off switch: remove that step and its enable
  line, then `systemctl --user disable --now fleet-cua-desk-check.timer`.
- `systemd/fleet-provider-watch.service` and `systemd/fleet-provider-watch.timer` — the
  daily provider watch: each router provider's model list is compared with
  the host snapshot, and a change files one fleet-ops issue with no model id in it.
  [provider-watch.md](provider-watch.md) has the run, off and delete steps.
- `systemd/syncthing.service` and `tigervnc.service` — stock vendor
  binaries (Syncthing, TigerVNC) run under systemd. They were hand-placed on the
  host with no repo copy (fleet-ops#9645); they decide nothing and wrap
  nothing. Syncthing's binary is a package now, from Syncthing's own apt
  repository (`ansible/tasks/syncthing.yml`), so the daily dist-upgrade keeps it
  current and `ExecStart` names `/usr/bin/syncthing`; the hand-placed copy under
  `~/.local/bin` was retired (#10844). TigerVNC's binary is still hand-placed.
  The live path under `~/.config/systemd/user` is a symlink into the
  deploy clone, so `fleet-sync.service` pulls every edit and LINK-GUARD checks
  the link. Install on a fresh host: `ln -s` each file from the deploy clone's
  `systemd/` into `~/.config/systemd/user/`, then `systemctl --user daemon-reload`
  and `enable --now`. The files match what ran before, so adopting them
  restarted nothing: a unit edit applies at the unit's next restart (never restart
  `tigervnc.service` while a remote-desktop session is live). `ci.yml` runs
  `systemd-analyze verify` on the three units. Switch one off with
  `systemctl --user disable --now <unit>`; delete it by removing its file here
  and the live link, then `systemctl --user daemon-reload`.
- `rootfs/etc/systemd/system/tincan-listen-claude-vps.service` — the live Agent Tincan
  wake for claude-vps, a **root** unit (fleet-ops#9974): it runs as `nish` under
  `ProtectSystem=strict` with an explicit bind list, and it sets its own
  `Environment=CLAUDE_CONFIG_DIR=` line, so it needs no drop-in. The user-level
  copy and its `10-nish-seat.conf` drop-in were deleted in fleet-ops#10125
  because nothing linked or ran them.
  - Run it now: `sudo systemctl start tincan-listen-claude-vps.service`, then
    `sudo journalctl -u tincan-listen-claude-vps.service -f`.
  - Switch it on: `sudo systemctl enable --now tincan-listen-claude-vps.service`.
  - Switch it off: `sudo systemctl disable --now tincan-listen-claude-vps.service`
    (requests to claude-vps then queue until a session checks its inbox).
  - Delete it: switch it off, delete the file here, add
    `/etc/systemd/system/tincan-listen-claude-vps.service` to the `retired`
    list in `ansible/host.yml` (that task, not the file deletion, removes the
    installed copy on the next config run), then `sudo systemctl daemon-reload`.
- `systemd/tincan-listen-command-code.service`,
  `tincan-listen-cursor-vps.service`, `tincan-listen-devin-vps.service`,
  `tincan-listen-fleet-worker.service`, `tincan-listen-opencode.service`,
  `tincan-listen-pi.service` and
  `rootfs/etc/systemd/user/cua-desk-daemon.service` — the six Tincan wake services
  and the Cua desk daemon (fleet-ops#10133, #10140). Each wake service runs
  `tincan listen` for one agent: command-code, Cursor, Devin, the free pi worker,
  OpenCode and the paid pi seat, each reading its own
  `~/.config/tincan/<agent>.json` and prompt and writing its state under
  `~/.local/state/tincan-listen-<agent>`. The OpenCode lane signs in to the
  router with a virtual key of its own, kept in the fleet's local seat directory
  (worker-cheap only, capped per day), minted with `POST /key/generate` like
  every other consumer credential, because a prompt-injected message in that
  lane could make the run print its environment. The router's master key is not
  in any listener's environment (fleet-ops#10221). `cua-desk-daemon.service` is the Cua
  daemon the desk agent runs on, with `CUA_MESH=prefer` and the seat b env file.
  The six wake services were hand-placed regular files under
  `~/.config/systemd/user` with no repo copy, so a git pull carried no edit to
  them; the files here are the bytes that ran before, and `fleet-sync.service`
  step 2j links each one on every deploy (the `default.target.wants` links
  already point at these paths, so a hand disable stays off: step 2j has no
  `enable` line). The desk daemon is
  root-owned, installed from `rootfs/etc/systemd/user/` by
  `fleet-host-config.service`, because `systemd-analyze verify` cannot stub the
  bundled `cua` binary; step 2k retires its hand-placed copy once the installed
  one is there, and repoints its wants link at the installed file so the link
  does not dangle. Run one by hand with `systemctl --user start <unit>`: all seven
  are enabled already (the wants link names the unit, and step 2j keeps the six
  wake links pointed at the repo files). A unit edit applies at that unit's next
  restart. The OpenCode lane will not start without its own key file, so mint
  that lane's virtual key (`models` `["worker-cheap"]`, a daily cap and a rate
  limit) into the fleet's seat directory before its first start, the way the
  Cursor lane's seat file is provisioned: a missing file fails the unit and
  pages, which is the point, because the lane has no fallback to the admin key.
  Off switch, one unit at a time:
  `systemctl --user disable --now tincan-listen-command-code.service`
  `systemctl --user disable --now tincan-listen-cursor-vps.service`
  `systemctl --user disable --now tincan-listen-devin-vps.service`
  `systemctl --user disable --now tincan-listen-fleet-worker.service`
  `systemctl --user disable --now tincan-listen-opencode.service`
  `systemctl --user disable --now tincan-listen-pi.service`
  `systemctl --user disable --now cua-desk-daemon.service`
  Delete one of the six wake services by removing its name from
  `fleet-sync.service` step 2j, its file here and the live link, then
  `systemctl --user daemon-reload`. Delete the desk daemon with
  `systemctl --user disable --now cua-desk-daemon.service` (it removes the wants
  link), then remove its file under `rootfs/etc/systemd/user/` and step 2k, then
  `systemctl --user daemon-reload`.
- `systemd/fleet-pr-sweep@.service` and `systemd/fleet-pr-sweep@.timer` — start
  the agent-dispatch sweep in `Nishfleet/<instance>` every hour with one
  `gh workflow run`, because GitHub fired the sweep's own cron only 4 to 5
  times a day (measured 2026-10-11). It runs on an Actions-only nishfleet-worker
  App token minted per start and revoked on stop, never the owner's personal
  login (fleet-ops#10601). The sweep's `stuck-prs` job is what moves
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
- `systemd/tincan-listen-devin-vps.service.d/20-umask.conf` sets `UMask=0077` on
  the Devin Tincan listener (unit file moved into `systemd/` with fleet-ops#10133),
  so its session-text output files are owner-only and the drop-in applies on every
  deploy. Applies at the next restart.
  That drop-in covers the listener only. The Devin CLI runs in two more places,
  and both started it group-writable: under the `netcup-agent` runners at the
  units' 0022, which made a new log group-readable, and in nish's login shells
  at `pam_umask`'s 0002, which made it group-writable (audit W1a,
  `nish-vault#30`).
  `rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-.service.d/20-umask.conf`
  sets `UMask=0077` for every `netcup-agent` runner — a prefix drop-in, because
  their unit files come from the runner's own `svc.sh` — and
  `rootfs/etc/zsh/zprofile` sets `umask 077` for nish's login shells, which is
  how sshd and tmux start one. Both apply at the next runner restart and the
  next login. The check after a fresh CLI run: `find ~/.local/share/devin
  -not -type l \( -perm -g+w -o -perm -o+w \) | wc -l` must print 0 (a symlink
  always shows mode 777, so it is excluded).
- `systemd/tincan-listen-issue-desk.service` — wakes `issue-desk`, the Tincan
  teammate that turns one request into one queued issue (`needs-triage`, so the
  [admission job](triage-admission.md) decides whether a worker starts)
  and answers with its URL. Stock `tincan listen --exec`, and the three tools it
  may use live in `pi-extensions/issue-desk/` (its README has the allowlist, the cap, the off
  switch and the delete steps). Pi starts with no built-in tools, no other
  extensions, no MCP and no skills, so the model cannot run anything else. Install
  by hand from the deploy clone (link, then `enable --now`): it is not enabled by
  `fleet-sync.service`.
- `pi-extensions/` — Pi extensions the fleet's own agents load through stock Pi
  (`-e <path>`), never a wrapper. `pi-extensions/issue-desk/` is the only one so far.
- `rootfs/etc/systemd/user/gpg-agent.service.d/20-oom-omit.conf` — the OOM guard on
  `gpg-agent.service`, the stock GPG credential cache every signing unit loads
  (`ManagedOOMPreference=omit`, so systemd-oomd never selects it, and
  `MemoryMax=512M`). It was a hand-placed file under `~/.config/systemd/user`
  (fleet-ops#10138), which shadows `/etc/systemd/user`, so the repo copy would
  have been inert: `ansible/host.yml` lists that file in `retired`, so
  `fleet-host-config.service` deletes the live copy and reloads nish's user
  manager, and gpg-agent reads these bytes at its next start. The unit file is
  the distro's, so the repo ships the drop-in only.
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
  The chat id is the Telegram chat the bot posts to: read it from an existing
  box's `telegram_chat_id`, or from the old `/etc/prometheus/alertmanager.yml`
  if a box still has that copy (the play refuses to retire it while it is the
  only source).
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
  `DEPLOY-BLOCKED` and fails, `git fetch` + `git merge --ff-only` plus one
  `sh` line that runs two `git merge-base --is-ancestor` probes and, unless
  `HEAD` equals `origin/main`, prints `DEPLOY-BLOCKED` with the branch, the
  commits that are not on main and the fix (fleet-ops#9967), `systemctl
  --user link` of `fleet-unit-failed@.service` and
  `systemctl --user daemon-reload`, `systemd-tmpfiles --user --create`,
  user-scope `install -C` copies (`config/pi-models.json` to
  `~/.pi/agent/models.json`, `config/litellm-proxy.yaml` to
  `~/.config/fleet-ops/litellm-proxy.yaml` behind a `cmp` guard,
  and a LINK-GUARD pass
  that fails the unit on a throwaway-target live symlink, and on a dangling
  one outside the `~/.pi/agent/skills` mirror, which logs instead
  (fleet-ops#7743, #9967). Root-owned files (`/etc/**`, `agent.slice`, everything under
  `rootfs/`) are not this unit's job: `fleet-host-config.service` installs them
  as root from its own clone.

