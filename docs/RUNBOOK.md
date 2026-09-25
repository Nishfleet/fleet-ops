# Runbook

One page. How to run the fleet. What it is, install mechanics and the deploy
rail are in `README.md`; design and enforced rules are in
`docs/ARCHITECTURE.md`.

## Live-state check (the canonical order)

1. `ls ~/workspaces/agent-state/FLEET-PAUSED` — if it exists the fleet is
   deliberately down; respect it. Otherwise step 2 is the truth.
2. `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers`.
3. Same prefix, `systemctl --user list-units --state=failed` — must be empty.
4. `curl -s 127.0.0.1:4000/health/readiness` (expect
   `{"status":"healthy","db":"connected"}`), then
   `curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state` — one
   gauge per deployment (0 healthy, 1 partial, 2 outage).
5. `uptime` for load; merged-PR counts per repo for throughput.

## Deploy and wiring

`deploy-box.yml` (push to main) → `fleet-sync.service` runs
`git pull --ff-only` + `daemon-reload` and fails (`DEPLOY-BLOCKED`) on a dirty
or diverged clone, so the canonical checkout
`/home/nish/workspaces/tooling/fleet-ops-deploy-clone` stays clean on `main`.
Its LINK-GUARD passes fail the unit while any live symlink under
`~/.config/systemd/user/`, `~/.local/bin/`, `~/.pi/agent/` or the vault is
broken or resolves into a throwaway root (`*worktrees/*`, `agent-state`,
`tmp`).

`~/.pi/agent/agents/` holds only the stock agents from `template/agents/`;
per-issue copies (`reviewer-issue-<N>.md`, removed under fleet-ops#8659) are
loaded by nothing.

Wiring a new unit or prompt is one `ln -sfn` into the deploy clone, once
(full commands in README). Four classes stay copies rather than symlinks:
the two `/etc/prometheus` files (fleet-sync does the copy + reload), the two
Pi extension forks, the live-state JSON files under `~/.local/state/` and
`~/.config/fleet-ops`-owned files that cross a privilege boundary.

## LiteLLM stack (rebuild reference)

Fleet-owned Postgres and Redis as user daemons — the distro packages are
stopped/disabled, they are never the fleet's. Cluster at
`~/.local/share/fleet-litellm-postgres` (loopback 127.0.0.1:5432 only, trust
auth, user-owned), Redis at `~/.local/share/fleet-litellm-redis`
(`bind 127.0.0.1`, maxmemory 128mb). `pg_isready` against the socket dir
before enabling the units; a correct deployment shows `active (running)`,
not `active (exited)`.

The proxy runs from `~/.local/venvs/litellm` on a pinned version. **Required
patch after every install or upgrade:** `patch -d
~/.local/venvs/litellm/lib/python3.12/site-packages -p1 <
/home/nish/workspaces/tooling/fleet-ops-deploy-clone/patches/litellm-1.98.0-gchunk-usage-union.patch`
— a plain `pip install` reverts it silently. On a version bump, first check
whether upstream fixed the line; if so drop the patch and this step.

The live config `~/.config/fleet-ops/litellm-proxy.yaml` is a copy of
`config/litellm-proxy.yaml`: `fleet-sync.service` installs it with `install -C`,
which overwrites a hand edit, and `fleet-litellm-proxy-config.path` restarts the
proxy only when the bytes change. Edit the repo file and nothing else; CI checks
it against `config/litellm-proxy.schema.json` (fleet-ops#8724). Keys resolve as `os.environ/<NAME>` from the seat env
files the unit globs (`~/.config/fleet-ops/seats/*.env`), the master key the
same way; `disable_prisma_schema_update: true` stays under `general_settings`
(startup `prisma migrate deploy` stalls every restart without it), and
`DATABASE_URL` is a unit `Environment=` in host-qualified form (the
socket-less form is rejected). Consumer credentials are per-group virtual keys
minted via the admin API, never the master key.

Edits to that file are applied automatically. `fleet-litellm-proxy-config.path`
(`PathChanged=`) triggers `fleet-litellm-proxy-config.service`, which runs
`systemctl --user try-restart fleet-litellm-proxy.service` — the proxy reads
its config only at start, so the restart is the apply step, and `try-restart`
means an edit never starts a proxy that was stopped on purpose. Every save
restarts the proxy (~38 s), so batch edits into one write. Install it with
`systemctl --user link` on the .service, then `systemctl --user enable --now`
on the .path, both from the deploy clone (README "Install").

Backup: `pg_dump -h "$HOME/.local/share/fleet-litellm-postgres/run" -U
litellm litellm | gzip > .../litellm-<ts>.sql.gz` in the restic backup path.
Rollback: stop + disable the three units, drop the fleet-owned cluster and
`rm -rf` its two data dirs (no sudo needed — they are user-owned).

## Break-glass access (SSH is Tailscale-only)

If tailscaled is down, SSH is gone. The out-of-band layer exists today at zero
cost: the netcup provider VNC console.

- Use it when tailscaled will not return (`Restart=always` already applied),
  when the Tailscale interface is absent, or to confirm sshd still binds only
  Tailscale addresses. Never for routine work.
- Steps: netcup panel from a machine that does not depend on this VPS → VNC
  console → login as `nish` → `systemctl restart tailscaled` → `ss -ltn |
  grep ':22'` must show only `100.*`/`fd7a:*` — a `0.0.0.0:22` or `[::]:22`
  line is a public SSH bind, fix it before disconnecting → verify Tailscale
  SSH from another machine, then leave VNC.
- It is not a second SSH listener, not a standing open console, and not a
  live-tailscaled kill (a lockout, not an experiment — that stays a Nish
  game-day). Panel login lives in Nish's password manager; never here.

## Jev bands and modes

The band edges are the one tuning knob for how confident Jev must be before a
caller treats an answer as conclusive. The edges are recorded here and applied
by each caller's own code (the config store was deleted in the glue-zero wipe;
`config/jev-bands.json` does not come back).

| site | edges |
|---|---|
| `alert-dispatch` / `alert-triage` / `alert-repair` / `auto-revert` | 0.9 / 0.1 |
| `claim-check-pr` / `claim-check-report` / `hermes-digest` | 0.5 / 0.5 |
| `dependency-pr-arm` / `merge-queue-batches` / `merge-queue-enqueue` | 0.9 / 0.1 |
| `failure-triage` / `intake-order` / `intake-seat-smoke` | 0.9 / 0.1 |
| `flaky-test-quarantine` / `gha-stuck-run-watch` | 0.9 / 0.1 |
| `intake-repair-seatfault` | 0.6 / 0.6 |
| `reviewer-needs-review` / `scout` / `scout-rank` | 0.9 / 0.1 |
| `second-opinion` / `second-opinion-reserved` / `worker-escalation-target` | 0.5 / 0.5 |
| `worker-context` | RETIRED 2026-09-23 (fleet-ops#8423): 306 of its 450 rows scored 0509 runs whose repo has neither candidate file — 0.9 / 0.1 stamped on surviving rows
| `vault-drop-routing` | log-only, no row read |

(`act_hi` is the confident-positive edge, `review_lo` the confident-negative
one; cascade sites act on a confident band, single-edge sites compare against
one edge.)

Modes: unset/`shadow` (default) calls Jev and logs a row but never changes what
runs — advisory by construction. `off`/`0` makes no call, exact prior
behaviour. `act` may short-circuit the big call at a confident band — only
after a benchmark go row with measured thresholds; the September benchmark was
NO-GO at every measured threshold, so shipped values are standing bands, not
measured ones. Rollback ladder: per-site `JEV_CASCADE_<SITE>_LO`/`_HI`, then
global `JEV_CASCADE_LO`/`_HI`; the mode flag can always take a site `off`.
Failures (no key, timeout, malformed, probability out of [0,1]) fall through to
the existing path; never invent a probability.

Second opinions for reserved decisions run the same card twice with the state
serialized in two orders; `disagreement=true` or `null` routes the card to the
escalation path (step 4: `blocked-on: nish-decision`), agreement never grants
permission. The verdict line and the verbatim python block live in
`prompts/worker.md`; the bands row for `second-opinion` is 0.5/0.5 above.
The proxy owns the spend cap (`jev` virtual key: `max_budget 1.0 USD / 1mo`);
`JEV_SECOND_OPINION=0` rolls a caller back to one call.

## Pending workflow drops

Files under `pending/` are parked GitHub Actions workflows awaiting a token
with the `workflows` scope (the nishfleet-worker App does not have it). Landing
each is `git mv` into `.github/workflows/`, update the referenced callers,
delete the directory:

| dir | drop |
|---|---|
| `pending/p11b` | five reusable workflows (gitleaks, semgrep, review-gate, auto-enqueue, weekly standards apply) |
| `pending/stale` | `stale.yml` triage-close sweep for unclaimed unlabeled issues (fleet-ops#3311) |
| `pending/surface-audit` | the reusable `surface-audit.yml` matrix workflow fleet-ops#1198; `template/.github/workflows/surface-audit.yml` is the thin caller and `template/surface-audit.json` the config template, once that lands |

`repo-standards-apply` (the weekly standards sweep) and its scripts were
removed in fleet-ops#7861, so a new repo is not enrolled automatically while
those drops wait; the exception file `.fleet/standards-exceptions.yml` honours
only `decided_by: nish` entries.
