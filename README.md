# fleet-ops

The fleet's operational surface under version control: systemd user units,
shell scripts, and Pi prompts that run on Nish's VPS. CI-gated so no unit,
script, or prompt lands unseen.

## What lives here

- `systemd/` — user units (services + timers) the fleet runs under
  `systemctl --user`.
- `bin/` — shell scripts the units exec.
- `prompts/` — Pi agent prompts fed to workers on stdin.
- `config/` — fleet configuration. `seat-caps.json` is the per-seat ceiling
  map; `intake-repos.json` is the declared set of repos enrolled in
  pi-intake/pi-scout (see [Intake enrolment](#intake-enrolment)).
- `systemd/fleet-sync.{service,timer}` — the whole deploy mechanism: every
  two minutes, `git pull --ff-only` + `systemctl --user daemon-reload`, plus
  `promtool check rules` and a prometheus reload when the alert rules changed.

## Install

There is no installer. Every live user-scope path is a **symlink into this
repo**, so a `git pull` is the deploy — the file the fleet runs and the file
in git are the same inode. Nothing is copied, so nothing can drift, and the
5,948 LOC that used to copy files and then hunt for the drift copying caused
(`install.sh`, `MANIFEST`, `bin/fleet-ops-deploy`, `bin/fleet-deploy-check`,
`bin/fleet-ops-drift.py`) were deleted on 2026-09-18.

`systemd/fleet-sync.timer` keeps the clone current. It is the only deploy
machinery on the box:

```
systemctl --user list-timers fleet-sync.timer
systemctl --user start fleet-sync.service   # force a sync now
journalctl --user -u fleet-sync.service -n 50
```

`git pull --ff-only` fails loudly on a dirty or diverged clone. That is
correct: the live source must be clean `origin/main`, and a failed
`fleet-sync.service` is visible to the failed-unit sweep.

### Wiring a NEW unit (one-time, by hand)

`man systemctl`: *"link PATH... Link a unit file that is not in the unit file
search path into the unit file search path. This command expects an absolute
path to a unit file."* Add the unit file to `systemd/`, merge it, then once:

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

Same idiom for a new `bin/` helper (`ln -sfn <repo>/bin/<x> ~/.local/bin/<x>`),
a `lib/` module (`~/.local/lib/pi-packet/<x>`), a Pi prompt
(`~/.pi/agent/prompts/<x>.md`), or a `libexec/` script
(`~/.local/libexec/<x>`). One `ln -sfn`, once, and git owns it from then on.

### The exceptions: files that must stay COPIES

Four classes are deliberately copies, not symlinks, and a `git pull` does
NOT update them. Refresh by hand when the repo file changes:

| live path | repo source | why a symlink is wrong |
|---|---|---|
| `/etc/prometheus/fleet_rules.yml` | `config/fleet_rules.yml` | prometheus runs as `prometheus`; `/home/nish` is `0750 nish:nish`, so it cannot traverse into the repo. **Handled automatically** by `fleet-sync.service` (promtool check + copy + reload). |
| `~/.pi/agent/extensions/**.ts` | `template/extensions/**` | the providers `import '../seat-health.ts'`, which resolves against the symlink's real path — into the repo, where that sibling does not exist (fleet-ops#3263). |
| `~/.local/state/pi-packet/seat-caps.json`, `~/.pi/agent/models.json`, `~/.local/state/pi-packet/model-candidates.json` | `config/seat-caps.json`, `config/pi-models.json`, `config/model-candidates.json` | live state the git working tree must not rewrite on every checkout (fleet-ops#2910/#3722/#3322). |
| `/etc/**` (systemd drop-ins, `sysctl.d`, `audit/rules.d`, `default/prometheus`, `prometheus/*.yml`) | `config/`, `etc/`, `systemd/system/` | cross a privilege boundary. |

```
# a changed pi extension:
install -D -m 0644 <repo>/template/extensions/<x>.ts ~/.pi/agent/extensions/<x>.ts
# a changed /etc file:
sudo -n install -D -m 0644 -o root -g root <repo>/<src> /etc/<dest>
sudo -n systemctl daemon-reload          # for /etc/systemd/system/**
sudo -n augenrules --load                # for /etc/audit/rules.d/**
sudo -n sysctl --system                  # for /etc/sysctl.d/**   (Nish-reserved)
# a changed root unit:
sudo -n systemctl link /home/nish/workspaces/tooling/fleet-ops-deploy-clone/systemd/system/<unit>
```

### Devin workspace-trust key (fleet-ops#4825)

`install.sh` used to merge `skip_workspace_trust: true` into
`~/.config/devin/config.json` on every deploy, so a Devin auto-update that
rewrote the config could not silently wall the seat. That merge is gone with
the installer. The live config carries the key today; if the Devin CLI ever
refuses with *"Refusing to run in an untrusted workspace"*, re-apply it once:

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
while worktrees are attached. New fleet-ops worktrees are created from the
deploy-clone (fleet-ops#410).

The old non-canonical-checkout guard lived in `install.sh`: it refused a
mutating install from any other tree, because an install from a worktree
retargeted every live symlink at a tree that could be deleted. With no
installer there is nothing to point the wrong way — the symlinks are set once
and only `fleet-sync.service`, pinned to the canonical path, touches the tree.

## systemd by default

`nohup pi ... &` dies when the launching shell ends. The four `EXTLOAD-OK`
lines it leaves behind look like a dead seat. Use the thin systemd wrapper:

```
pi-systemd-run --unit mypacket --stdin /path/to/packet.md --deadline 42 \
  --deliverable /path/to/outcome.md -- \
  pi --print --provider minimax --model MiniMax-M3
```

That is `systemd-run --user --collect --no-block`. Not a dispatcher: no
retry ladder, no seat rotation, no queue. This invocation is the canonical
flag signature (single source, fleet-ops#5683): `--deadline` is the grace
budget and `--deliverable` the artifact the run MUST produce; the wrapper
also adds the healthchecks dead-man (start/complete ping) and OnFailure
escalation, so exit 0 with no deliverable is a FAILURE, not a success
(fleet-ops#4266). Watch with
`systemctl --user status mypacket.service`.

If the packet clones a repo, use a reference clone against the local
bare mirror (fleet-ops#1213), not a full GitHub copy:

```
git clone --reference-if-able /home/nish/workspaces/.mirrors/<repo>.git \
  https://github.com/Nishfleet/<repo>.git <dest>
```

Never `--dissociate` on throwaway worktrees. Never push to a mirror
(read-only fetch target). A missing or corrupt mirror degrades to a
plain clone. `git-mirror-update` keeps the mirrors on the existing
5-min `fleet-metrics-export` tick (no new timer).

A short log with no verdict after `nohup` or `&` is a **launcher fault**
(the session reaped the process). A log containing `rate_limit` /
`ETIMEDOUT` / `quota` is a **lane fault** (rotate the seat). Do not mix
them up.

The Claude PostToolUse hook `~/.claude/hooks/guard_pi_packet.py` classifies
these from the redirected packet log. Launcher faults advise `pi-systemd-run`;
lane faults advise seat rotation.

Overlapping `systemctl start` of a live intake tick or of a live `pi-issue@`
worker is a no-op — systemd will not start a unit that is already running.

## Claim shared files before editing (interactive sessions)

Queued work has an atomic lock — the `claim/issue-N` branch. Interactive
sessions used to bypass it, so two agents could fix the same control-plane
file minutes apart without either knowing (fleet-ops#55: two sessions
fixed the same `seat-lib.sh` bug in one hour). `bin/fleet-claim` gives
interactive work a claim path that is one command, agent-agnostic (git +
gh, not a Claude hook), and visible before any PR exists — a pushed branch
is the fleet-visible occupied sign.

Before touching anything shared (`seat-lib.sh`, `seat-caps.json`, a systemd
unit, a hook, this repo), run:

```
fleet-claim conflicts fleet-ops lib/seat-lib.sh   # pre-flight: anyone on it?
fleet-claim start    fleet-ops lib/seat-lib.sh    # reserve it (one command)
# ...edit, commit, push, open PR...
fleet-claim release  fleet-ops lib/seat-lib.sh    # free it when done
```

- `start` pushes `claim/adhoc-<scope>` from `main` with a create-only
  `--force-with-lease`, so two agents starting the same scope collide
  atomically — the second gets `claimed-by-other` and stops. Convention:
  **use the shared file path as the scope** so two agents on the same file
  pick the same branch name.
- `conflicts` is the pre-flight the standing rule asks for, made
  agent-agnostic. It scans every live `claim/adhoc-*` branch whose scope
  token matches the file path **or basename**, plus every open PR whose
  file set overlaps (via `gh`, when available). Exit 1 if anything is
  found. Basename matching catches the realistic case where two agents
  name the same file differently (`lib/seat-lib.sh` vs `seat-lib.sh`).
- `check <scope>` reports free/claimed for one scope; `release <scope>`
  deletes the branch.

It is warn-shaped, not a hard block: a second agent on the same file is
sometimes legitimate, and a false block during control-plane repair is
worse than a duplicated diff. The Claude-only `guard_shared_file_collision`
hook covers the open-PR window; `fleet-claim` covers the pre-PR window that
the hook cannot see.

Stale interactive **sessions** are no longer reaped by a bespoke timer:
`interactive-session-reap` was deleted on 2026-09-18 after 113 consecutive
hourly runs that each reaped nothing. `systemd-oomd` is the native reaper
under real memory pressure. sshd, tailscaled, and the intake timers are out
of scope: they do not live in `session-*.scope`. `claim/issue-*` and
`claim/adhoc-*` branches are released by the agent that claimed them.

## CI

`.github/workflows/ci.yml` runs four jobs on every PR and push to main:

1. **semgrep** — `--config p/default`. TODO: add the fleet's
   `no-hand-built-orchestration.yml` ruleset from Nishfleet/siterep-public at
   an exact commit SHA once packet p56 merges it. Until then the
   orchestration-specific rules are NOT applied — flagged loudly.
2. **shellcheck** — `bin/*` (pinned binary + sha256).
3. **unit-verify** — `systemd-analyze verify --man=no` on every `systemd/*`
   file. Proven to catch breakage: a malformed unit (bad section header,
   missing `=`) makes verify exit nonzero with a clear message.
4. **gitleaks** — full history secret scan (pinned binary + sha256, `--redact`).

All actions are pinned to exact commit SHAs. Every job has a timeout.

The tests job calls `.github/workflows/reusable-pr-checks.yml` (`workflow_call`).
That file is the batched CI standard for every current and future repo: one
job, `timeout-minutes`, PR concurrency, npm cache, job-level path gating, and
gitleaks. Callers pass `inputs`; they do not copy the steps. The four required
check names stay as local jobs because a `uses:` job reports as
`caller / callee` and branch protection still lists `Gitleaks`, `semgrep`,
`Shellcheck`, and `systemd-analyze`.

New repos copy `template/.github/workflows/` (wired to this repo at `@v1`).

A further reusable workflow, `.github/workflows/ci-failure-telemetry.yml`, is
the central CI failure telemetry set. Other repos call it with
`workflow_call`; it is an alert, not a required check. It runs two detectors:
the merge-queue semantic-conflict detector (fires when the same check is
green on `pull_request` and red on `merge_group`, names the check, and
publishes the `pull_request` vs `merge_group` failure-rate split) and the
repeat-deterministic detector (fires when the same
`(workflow, job, step, assertion, event)` signature fails 3+ times within
6h — an assertion failure is not retryable, so the alert says stop, do not
re-arm). Both detectors also publish a headline decomposition: top failure
signatures ranked by count (every distinct tuple, not just the ones that
fired the alert) and the `pull_request` vs `merge_group` divergence in
percentage points — the single most diagnostic number for whether failures
are semantic merge conflicts (large divergence) or flaky tests (small
divergence). A headline "21.8% CI failure rate" without this decomposition
cannot drive any action (fleet-ops#21).

A sixth, `.github/workflows/ci-required-check-purity.yml`, flags required
checks that compare a computed value against a shared committed baseline
with exact equality (or that fail unless the PR edits that baseline). It
is advisory: warn, do not block. The rule itself is in `docs/ci-standard.md`.

A seventh pair, `.github/workflows/red-on-main-detector.yml` (reusable) and
`.github/workflows/red-on-main-watch.yml` (15-minute sweep, synced to other
Nishfleet repos), watches **every** workflow on main — including ones that
have never been green. Auto-revert still only watches proven-green
workflows; this detector alerts, it does not revert. A workflow whose
first ever main run fails is called out as merged untested against main.

An eighth, `.github/workflows/ci-standards-audit.yml`, is the central
conformance audit. It reads every non-archived repo from the GitHub API,
resolves each repo's real default branch, then publishes a per-repo,
per-workflow gap matrix for the CI standard: `timeout-minutes` on every
job, `concurrency` with `cancel-in-progress` on PR-triggered workflows,
dependency caching, job-level path filtering (with trigger-level path
filters on required checks flagged as an error), and `auto-revert.yml`
presence and eligibility. It can also open fix PRs for the one gap that is
safe to fix mechanically: missing `auto-revert.yml` on repos that already
have a green push-to-main CI workflow and required checks.

## Allowlist

There is no manifest and no installer. A path is live because something
symlinks to it from `~/.config/systemd/user/`, `~/.local/bin/`, or
`~/.pi/agent/prompts/`. EnvironmentFile= targets (e.g. `hc.env`, `deploy.env`,
`cf.env`) are never tracked — only the units that reference them.

## Fleet heartbeat — DELETED 2026-09-18

`fleet-heartbeat.timer`/`.service`, `bin/fleet-heartbeat-tier1` and
`prompts/heartbeat.md` are gone. Their jobs live in the organs that already
did them: `pi-intake@<repo>.timer` picks up queued work, PR auto-merge is a
GitHub workflow, and a failed unit pages through the `SystemUnitFailed` rule
in `config/fleet_rules.yml`. Its healthchecks.io dead-man is superseded by
`bin/keystone-hc-ping` (`~/.config/fleet-ops/keystone-hc.env`).

## Intake enrolment

`config/intake-repos.json` is the **declared set** of repos that run
pi-intake/pi-scout. It is the single source of truth for which repos are
enrolled — adding or removing a repo is a PR against that file, not a
`systemctl enable`. This replaces the old imperative enrolment that was
silently reverted without a record (fleet-ops#32).

Each enrolled repo needs two preconditions, both verified by the reconciler
before its unit is enabled:

1. A git checkout at `/home/nish/workspaces/products/<name>` — intake does
   `git -C <checkout>/<name> fetch origin` and the worker creates its
   worktree from it. Packet clones (when a worker clones instead of
   worktree-add) use `git clone --reference-if-able
   /home/nish/workspaces/.mirrors/<name>.git
   https://github.com/Nishfleet/<name>.git <dest>` (fleet-ops#1213).
   Mirrors are read-only fetch targets; never push.
2. The three labels `agent-ready`, `agent-in-progress`, `agent-blocked`
   present on the repo — the `ExecCondition` in `pi-intake@.service`
   silently no-ops without them, so an `agent-ready` issue on a label-less
   repo looks queued and is actually inert (the gap fleet-ops#25 was filed
   for).

`fleet2` is permanently excluded (standing rule: no second dispatcher,
ever). `siterep` is excluded (archived). Both are recorded in the file's
`excluded` list with reasons, and `tests/intake-repos-shape.test.sh`
fail-closes if `fleet2` ever reappears in `repos`.

The reconciler that converges systemd state to this file is fleet-ops#32;
this file is the coverage decision (#25) it consumes. The reconciler is
`bin/intake-reconcile`, triggered by `systemd/intake-reconcile.{path,
service,timer}` (file-change trip + 30-minute sweep). Every enable, disable,
mask-detect or precondition-fail writes one line to
`$HOME/.local/state/intake-reconcile/audit.log` with
`<iso8601> <unit> <action> actor=reconciler why=<reason>` so the four
silent reversions that prompted this issue have no recurrence path.

### `depends-on:` in ticket bodies (fleet-ops#4808)

An `agent-ready` issue can carry a `depends-on:` line naming issues or PRs
that must be **DONE** before it is claimable. This is how a seam batch is
sequenced — e.g. `0509#2218` must land before the six sources that depend on
it, so those sources are not claimed (and their workers spawned) until the
seam is merged. Without the gate, intake claims regardless and a human has to
hand-gate by removing `agent-ready`.

The line format is one `depends-on:` line in the body, naming each dependency
as a same-repo `#<n>` or a cross-repo `owner/repo#<n>`:

```
depends-on: #2218, Nishfleet/0509#2181
```

Prose like `depends-on: none` or `depends-on: any of the above` yields no
references and does not gate the claim.

A dependency is **DONE** when the referenced issue is:

- closed (any close reason), OR
- has a merged PR whose branch is `claim/issue-<n>` or `fable/issue-<n>`, OR
- has any merged PR linked via "closes #n" (a cross-referenced PR).

If any named dependency is not DONE, intake skips the issue for that tick
with the log line `skipped-depends-on:#<n>` (same shape as the other skip
reasons) and leaves it `agent-ready` — it is re-checked next tick once the
dependency lands. A dependency cycle (A depends on B depends on A) skips both
with `depends-on-cycle` instead of a misleading `skipped-depends-on:#n`.
Resolution is memoised per tick (one gh call per referenced issue per tick).

### `collision-gate:` in ticket bodies (fleet-ops#5165)

The 0509 ticket format carries a `collision-gate:` line naming tickets that
share a file with it — the later ticket must not be claimed while an earlier
same-file ticket is still open, or its worker produces a PR racing the
blocker's. The same gate also lives in Fable's judge packet and
`agent-state/fleet-landing-watch/ticket-gates.json`, but the body line is the
ticket's own declaration and intake honours it even when the gate file is
stale or absent.

The line may carry a parenthetical annotation before the colon:

```
collision-gate (Fable 2026-09-10 09:40 IST): shares app/lib/x.ts with #2350, #2356
```

Each named ticket is resolved to DONE with exactly the `depends-on:` rules
above. If any is not DONE, intake skips the issue for that tick with
`skipped-collision-gate:#<n>` (first unmet ref named) and leaves it
`agent-ready`. An org-less `repo#<n>` token on the line — e.g. the
`permanent fix fleet-ops#4808` trailer — is not a ref and is ignored.
Collision gates are one-directional, so no cycle detection applies.

## Excluded pending manual review

- `backlog-console-refresh.service.retired-20260819`

## Four-plane resilience drill — DELETED 2026-09-18 (was `fleet-resilience-drill`, issue #455)

> Removed with the synthetic-drill sweep: 1474 lines of rehearsal whose stub units died
> by design. The seat_sentinel live proof (#5106) went with it — see
> `tests/fleet-seat-recovery-units.test.sh` section 4b/4c for the retired-assurance note.
> The commands below no longer exist.

Single-VPS resilience is detection + repair + a regular drill, not a second
copy of a stateless thing. The adopted-delta list and specs live in
[docs/resilience-blueprint.md](docs/resilience-blueprint.md). The VNC
break-glass runbook is [docs/break-glass-access.md](docs/break-glass-access.md).

```
fleet-resilience-drill          # run the four-plane drill, print proof, exit 0/1
fleet-resilience-drill --check  # report whether the repo files are present
```

The drill never kills live tailscaled or live heartbeat. Resurrection is an
isolated `Restart=always` stub. State recovery reuses #388. Compute
break-glass is GitHub-hosted runners. Keystone healthchecks.io URLs (intake,
scout, reconcile, restore) live in `~/.config/fleet-ops/keystone-hc.env`
and must be four distinct checks. Unset URLs
are a LOUD skip. A shared URL is a LOUD fail.

## Worker RAM admission (issue #45)

Admission carries no RAM charge: the concurrency bound is
`min(target_concurrent, Σ declared provider caps)` — `seat_max_concurrent()`/
`admit_ceiling()` in `lib/litellm-seat.sh` read the provider-level `cap`
fields of the cap map (fleet-ops#4263 deleted the hand-tuned
`ram_gb_per_worker` charge together with `lib/seat-lib.sh`; the model rows
of the map are the per-model lanes, not this bound) — and RAM safety is
per-unit `MemoryMax` + systemd-oomd, not a governor division. Known repos
override the per-unit limits via intake-written drop-ins: fleet-ops#3930 set
`MemoryMax=4G` with **no `MemoryHigh`** for fleet-ops + 0509 (the throttle
band is what makes oomd pressure-kill a random sibling, so it was removed;
4G is now the hard stop with a clean local OOM at the cap), while the heavy
class of #3281 writes 3G/2G for heavy|keystone packets — this proof's own
unit (fleet-ops#5806) ran that heavy drop-in.

`bin/ram-measure` and `bin/ram-metric-compare` are deleted along with the
heartbeat that called them; their last samples remain under
`~/.local/state/ram-measurement/` (live 2026-08-26: `pi-issue@` cgroup
`memory.current` p95 822.6 MB — the 35 MB figure in older comments is VmRSS,
not cgroup cost). Live RAM is now `systemctl --user show -p MemoryPeak
<unit>` and `systemd-cgtop`.

## Gap-closure loop (issue #180)

The fleet closes its own gaps as a loop on top of the #157 blind audit (the
audit engine is unchanged). Heartbeat tier1 starts
`fleet-gap-closure-loop.service` once per tick. That oneshot does **one**
phase transition and exits: audit → research (cycle 1 and every 4th) → fix →
drill → measure → conference.

A cycle with findings never convenes the conference. A clean cycle with green
SLOs and passing drills does. Three senior auditors vote via
`fleet-gap-closure-auditor@` (formerly a sibling of the deleted `pi-audit@` panel, which was the
admission panel); only unanimous DONE closes the intensive loop (the daily
blind-audit timer stays). Two-of-three continues and the dissent is filed as a
`gap-audit` issue. A later finding or a quality-snapshot FAIL reopens the loop.

While the loop is converging, intake prefers those gap-audit issues over
product work (`fleet-gap-closure-yield`). `pi-intake-priority`, which treated
`gap-audit` as critical until unanimous DONE, was deleted on 2026-09-18 — it
had no caller and had never run.

Live validation of a full cycle (real drill + real conference) is a follow-up
once merge-to-live has installed these units. This repo ships the machinery
and the stubbed acceptance tests.



