# GLUE-ZERO — the design that takes fleet-ops to zero hand-rolled code

Nish, 2026-09-21 23:20 IST: *"wipe and replace with properly done up design with
no glue."* Umbrella: [#7828](https://github.com/Nishfleet/fleet-ops/issues/7828).

This document is the design. It is not a status report and it deletes nothing.
Every deletion happens in a child issue of #7828, in the order at the bottom,
and no organ is cut before its consumer has a stock replacement proven on a real
run.

## The test applied to every row

> Is this what ships in the box?

Not "is this good", not "is this short". A shorter script is not a replacement.
A wrapper is not a replacement. A hand-built Pi extension is not a replacement.
The only acceptable answers per organ are:

1. **a stock feature does the job** — name it, give its version and doc line,
   paste a probe from this VPS;
2. **nothing stock does the job** — delete the organ *and* its consumer, and say
   plainly what is lost;
3. **nothing stock does the job and the organ must stay** — name it as a
   declared exception with the reason, so it is one line on a list instead of a
   thing nobody remembers deciding.

Exactly one organ lands in bucket 3 (`permission-gate.ts`). It is called out.

## Live state at design time

Probed on netcup-rs2000, 2026-09-21 ~22:00 IST, before anything was designed.

```
$ ls /home/nish/workspaces/agent-state/FLEET-PAUSED
ls: cannot access '.../FLEET-PAUSED': No such file or directory

$ systemctl --user list-units --state=failed --no-legend
(empty)

$ curl -s 127.0.0.1:4000/health/readiness
{"status":"healthy","db":"connected"}

$ curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state | grep -v 'model_id=""'
... litellm_model_name="z-ai/glm-5.3-flash",model_id="pareto-glm53flash-judge"}           0.0
... litellm_model_name="z-ai/glm-5.3-flash",model_id="pareto-glm53flash-senior"}          0.0
... litellm_model_name="z-ai/glm-5.3-flash",model_id="pareto-glm53flash-worker-private"}  0.0
... litellm_model_name="z-ai/glm-5.3-flash",model_id="pareto-glm53flash-worker-capable"}  1.0
... litellm_model_name="z-ai/glm-5.3-flash",model_id="pareto-glm53flash-worker-cheap"}    1.0

$ pi --version
0.85.1
```

One upstream is wired into the router (Pareto `z-ai/glm-5.3-flash`); every rung
— `worker-cheap`, `worker-capable`, `senior`, `judge`, `worker-private` — is an
alias onto it. Two rungs were in cooldown during this pass and returned
`litellm.RateLimitError ... Received Model Group=worker-cheap / worker-capable`
on a real probe. That is a finding in its own right and not this document's
scope; it is why the design-it-twice proof below needed retries.

## The inventory, and what replaces each

| # | Organ | size | Consumers today | Stock replacement | Bucket |
|---|---|---:|---|---|---|
| 1 | `bin/pi-intake-trigger` + `systemd/pi-intake-trigger.{path,service}` | 44 L | `pi-intake-trigger.service` | one `.path` unit per enrolled repo, `PathExists=` → `Unit=pi-intake@<repo>.service`, plus `ExecStartPre=-/bin/rm -f` on `pi-intake@.service` | 1 |
| 2 | `bin/am-executor-claim` | 174 L | `config/prometheus-am-executor.yml` | `alert-repair@.service` template unit; systemd job merging on an `activating` unit is the singleflight | 1 |
| 3 | `bin/fleet-claim-release` | 276 L | `systemd/pi-issue-failed@.service:21`, `prompts/intake.md:40` | `prompts/claim-release.md` + `pi --print` (the shape `prometheus-am-executor.yml` already uses for alert repair) | 1 |
| 4 | `bin/fleet-silent-pr-close-check` | 196 L | `systemd/pi-issue-failed@.service:29` | none. The class is **prevented** by #3 never deleting a branch; the detector and its Exec line both go | 2 |
| 5 | `bin/fleet-litellm-key` | 35 L | `config/pi-models.json:413` (`!cmd` apiKey) | Pi's own `!cmd` apiKey form pointed at **one vendor command** over a one-key-per-file credential layout | 1 |
| 6 | `libexec/fleet-metrics-probe.sh` | 214 L | `systemd/fleet-metrics-export.service:37`, 3 alert rules + 11 series in `config/fleet_rules.yml` | **nothing stock** for the GitHub/vendor gauges | 2 + Nish |
| 7 | `tests/*.test.sh` | 15 files | **none** — `ci.yml` runs stock tools only | delete; there is no consumer to replace | 2 |
| 8 | `template/extensions/subagent/index.ts` | 11 L | live `~/.pi/agent/extensions/subagent/index.ts` | symlink the whole `subagent/` dir to Pi's shipped example | 1 |
| 9 | `template/extensions/{cursor-provider,devin-provider,seat-env.ts}` | ~830 L | **none** — deleted live 2026-09-19; the units call the vendor CLIs directly | delete; nothing to replace | 2 |
| 10 | `template/extensions/{permission-gate,protected-paths}.ts` | 166 / 49 L | the live guards | **no stock config key exists** (`docs/settings.md:286`) | **3 — declared exception** |
| 11 | `config/pi-extensions-allowlist.json` | 13 proven / 7 banned | none (owners deleted in the 2026-09-18/19 sweeps) | delete | 2 |
| 12 | `.fleet/bench7371/` | 18 files | docs prose only | delete; git history keeps it | 2 |
| 13 | `.fleet/handoff.md`, `.fleet/jev-handoff-template.json`, `pi-issue@.service:142` | 3,839-char Exec | already packeted | **see [#8042](https://github.com/Nishfleet/fleet-ops/issues/8042), not duplicated here** | — |
| 14 | inline shell in `systemd/*` Exec lines | 12 lines > 400 chars | the worker rail | partly stock (below); the App-token mint is the floor | 1 + 3 |

### Three corrections to the audit this design was handed

1. **The `subagent/` fork is 11 lines, not 1,041.** `diff -r` counted the whole
   stock `index.ts` (35,714 bytes, ~1,040 lines) as "changed" because the fleet
   file is a re-export stub. Everything else in the live directory —
   `agents.ts`, `README.md`, `agents/*.md`, `prompts/*.md` — is already a
   symlink into Pi's shipped example. The only fleet content is one
   `console.log`.
2. **There are 15 `tests/*.test.sh`, not 12.**
3. **`cursor-provider/` and `devin-provider/` are dead in both places.**
   `cursor-issue@.service:101` execs `cursor-agent -p …` and
   `devin-issue@.service:91` execs `devin --permission-mode dangerous …`. Neither
   goes through Pi, and neither extension is present under `~/.pi/agent/extensions`
   (deleted 2026-09-19). `seat-env.ts` reads `process.env.PI_AGENT_DIR`, which
   Pi never sets — the variable is `PI_CODING_AGENT_DIR` (`pi --help`,
   Environment section). It has been reading the wrong path for its whole life.

## Two defects found while designing, both worth fixing in the same PRs

**A. The `subagent` fork writes to `pi --help` stdout, and it is the only
extension that does.** It claims `mode=print-safe` in its own handshake string.

```
$ pi --help 2>/dev/null | head -3
EXTLOAD-OK extension=subagent mode=print-safe
pi - AI coding assistant with read, bash, edit, write tools

$ pi --help 2>&1 1>/dev/null | head -3
EXTLOAD-OK extension=permission-gate guard=tool_call rules=6 worker_toolchain_ban=armed
EXTLOAD-OK extension=protected-paths tools=write,edit
EXTLOAD-OK extension=subagent mode=print-safe
```

Be precise about the blast radius, because the obvious reading is wrong: in
`--print` mode Pi replaces `process.stdout.write` before extensions load
(`dist/main.js:502-504` → `dist/core/output-guard.js:45-50`), and the real answer
goes out through a saved handle (`dist/modes/print-mode.js:122`). So a `pi
--print` deliverable is **not** corrupted. But `--help` and `--list-models` are
exempted from that takeover (`dist/main.js:95-96`), and there the `console.log`
lands on line 1 of real stdout. `permission-gate.ts` and `protected-paths.ts`
use `process.stderr.write` and are clean in every mode; the `subagent` stub is
the one that is not. Deleting it (organ 8) fixes this as a side effect.

**B. `seat-env.ts` reads a variable Pi does not set** (see correction 3 above).
Deleting it (organ 9) fixes it as a side effect.

## Organ-by-organ

### 1. Intake trigger → stock `.path` units

`bin/pi-intake-trigger` loops over files in
`~/workspaces/agent-state/pi-intake-triggers/`, checks each name against
`config/intake-repos.json`, runs `systemctl --user start --no-block
pi-intake@<repo>.service`, and `rm -f`s the file. A `.path` unit already does
all of this.

Replacement, per enrolled repo in `config/intake-repos.json`:

```ini
# systemd/pi-intake-trigger@.path
[Unit]
Description=Intake trigger for %i
[Path]
PathExists=/home/nish/workspaces/agent-state/pi-intake-triggers/%i
Unit=pi-intake@%i.service
[Install]
WantedBy=default.target
```

and on `pi-intake@.service`:

```ini
ExecStartPre=-/bin/rm -f /home/nish/workspaces/agent-state/pi-intake-triggers/%i
```

The `ExecStartPre=` `rm` is **load-bearing, not tidying**. `man systemd.path`,
DESCRIPTION:

> When a service unit triggered by a path unit terminates (regardless whether it
> exited successfully or failed), monitored paths are checked immediately again,
> and the service accordingly restarted instantly. As protection against busy
> looping in this trigger/start cycle, a start rate limit is enforced on the
> service unit … the error condition that the start rate limit is hit is
> propagated from the service unit to the path unit and causes the path unit to
> fail as well, thus ending the loop.

So a `PathExists=` unit whose service does not delete the file burns
`StartLimitBurst` (live: 5 in 10s) and takes the watcher down with it. Deleting
the trigger file as the service's first act is what re-arms the watch — the same
ordering the script had, expressed as one unit line. `$TRIGGER_PATH` is **not**
used to carry the filename: `man systemd.exec:3253` says the value is
coalesced and "lossy, and should not be relied upon". The instance name `%i`
carries it instead. The enrolment check the script did against `intake-repos.json` becomes
enrolment itself: only enrolled repos get an enabled `pi-intake-trigger@<repo>.path`.
A trigger file for a deferred repo is then ignored by construction rather than
by a `jq` guard, which is strictly stronger.

`systemd/pi-intake-trigger.path` and `systemd/pi-intake-trigger.service` both go.

### 2. Alert singleflight → a systemd template unit

`bin/am-executor-claim` exists because `prometheus-am-executor`'s `max: 1` is
per-fingerprint and **dies when the command returns**, so a repair whose worker
outlived the command let a second webhook start a second repair 8 minutes later
(2026-09-13). The script adds a `systemctl list-units` consult, a `flock`, a
claim JSON file, a CamelCase→kebab sanitizer and an EXIT trap.

First, what does **not** change: Alertmanager 0.26 has no `exec` receiver type —
every non-notification integration is a webhook (`config/alertmanager.yml`
receivers: `null`, `telegram`, `repair-dispatch` → `http://127.0.0.1:9095/`).
`prometheus-am-executor` is the off-the-shelf listener and stays. Only its
wrapper is in scope.

Second, the correction that makes this design work. systemd merges a `start`
into an existing job **only while the unit is `activating` or `active`**:

```
$ systemctl --user list-jobs --no-legend
4409743 pi-intake@fleet-ops.service start running     # one unit = at most one job

$ systemctl --user show pi-scout@fleet-ops.service -p Type,RemainAfterExit,ActiveState
Type=oneshot
RemainAfterExit=no
ActiveState=activating
```

`man systemd.service:124` — a `Type=oneshot` unit without `RemainAfterExit=`
"will never enter 'active' unit state, but will directly transition from
'activating' to 'deactivating' or 'dead'". And there is **no directive that makes
a second `start` fail because the unit is already up**: `--job-mode=fail` is
scoped to *queued* jobs (`man systemctl:1410`), and `RefuseManualStart=` blocks
all manual starts, not duplicates.

So the singleflight is real **if and only if the repair runs synchronously
inside the unit**, because then the unit is `activating` for the whole repair
and a second webhook's `start` merges into that job. That is precisely the hole
the wrapper was built to plug, and a unit closes it for free — provided nothing
inside detaches.

```ini
# systemd/alert-repair@.service
[Service]
Type=oneshot
Environment=FLEET_ALERTNAME=%i
Environment=HOME=/home/nish
Environment=PATH=/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/sh -c 'exec pi --print --session-dir "$HOME/.pi/agent/sessions/alert-repair" \
  --provider litellm --model worker-cheap < "$HOME/.pi/agent/prompts/alert-repair.md"'
TimeoutStartSec=1800
```

and `config/prometheus-am-executor.yml` becomes one vendor command:

```yaml
commands:
  - cmd: /bin/sh
    args: ["-c", 'exec systemctl --user start --no-block "alert-repair@${AMX_LABEL_alertname}.service"']
    max: 1
    ignore_resolved: true
```

The `sh -c` is not decoration: `prometheus-am-executor`'s `args:` is a fixed
argv list with **no templating of alert labels**, and the alert reaches the
command only through `AMX_LABEL_*` / `AMX_GLABEL_*` environment variables —
confirmed against the binary's own string table:

```
$ strings ~/.local/bin/prometheus-am-executor | grep -o 'AMX_[A-Z_0-9]*' | sort -u
AMX_ALERT_LEN  AMX_ANNOTATION  AMX_EXTERNAL_URL  AMX_GLABEL  AMX_LABEL  AMX_RECEIVER  AMX_STATUS
```

One `sh -c` wrapping one vendor command is the floor, and `max: 1` stays as the
native per-fingerprint cap layered underneath.

The Alertmanager payload the wrapper used to pipe to stdin is not needed: the
repair prompt gets the alert name in `FLEET_ALERTNAME` and reads the live alert
from Alertmanager's own API (`127.0.0.1:9093/api/v2/alerts`), which is fresher
than a webhook body and is the vendor's documented interface. The claim file,
the lock, the sanitizer and the EXIT trap all go.

**The one thing the packet must prove** is that nothing in the repair path
detaches — if `alert-repair@` ever grows a `systemd-run` or a `&`, the unit goes
`dead` while the worker runs and the twin-spawn returns. Proof: fire one real
alert, `systemctl --user list-jobs` shows one job for the whole repair, and a
second synthetic firing during that window produces no second session directory.

### 3. Claim release → a prompt, not a program

`bin/fleet-claim-release` is 276 lines of `gh api` calls wrapped in fail-closed
guards. Every one of those calls is a `gh` built-in; the 276 lines are the
*judgement* around them — is there an open PR, is the branch ahead, is the issue
blocked, which label flips.

The fleet already moved a judgement organ of exactly this shape into a prompt
and deleted the program: `config/prometheus-am-executor.yml` says so in its own
comment — *"The 1,811-line `libexec/alert-repair-dispatch` classified the alert,
picked a seat, applied skip/park/dedupe rules and then ran `pi --print` anyway …
The classification and repair judgement now live in `prompts/alert-repair.md`."*

So: `prompts/claim-release.md`, and `pi-issue-failed@.service` becomes

```ini
ExecStart=/bin/sh -c 'cat "$HOME/.pi/agent/prompts/claim-release.md" | pi --print \
  --provider litellm --model worker-cheap'
Environment=FLEET_INSTANCE=%i
```

The rules the script encoded become rules in the prompt, and they must be
carried over verbatim in meaning, because each one is a paid-for incident:

- the open-PR check is **fail-closed** — a `gh` failure is *unknown*, never
  *zero* (the 2026-09-13 #6258 close);
- an open PR on `claim/issue-<N>` means **hold**: no branch delete, no label
  flip, one comment on the PR and one trace line on the issue;
- no open PR → flip `agent-in-progress` → `agent-ready`, unless the issue is
  `agent-blocked` (then clear `agent-in-progress` only, #3763) or closed;
- **never delete the claim branch.** See organ 4.

### 4. Silent-close detector → prevention, not detection

`bin/fleet-silent-pr-close-check` is an after-the-fact scanner for a class with
exactly one cause: automation deleting a PR's head branch, which makes GitHub
close the PR under the deleting identity with no comment.

Nothing in the box detects that. Something in the box prevents it: **stop
deleting branches from automation.** GitHub's repository setting
*"Automatically delete head branches"* deletes a head branch when — and only
when — its PR **merges**, which is the one case where closing the PR is not a
destruction. It is already on:

```
$ gh api repos/Nishfleet/fleet-ops --jq '{delete_branch_on_merge, allow_auto_merge, default_branch}'
{"allow_auto_merge":true,"default_branch":"main","delete_branch_on_merge":true}
```

Note what is **not** available, so nobody proposes it later: no GitHub rule type
keys off "this branch has an open PR". The repo's one ruleset has a `deletion`
rule scoped to the default branch only, and org rulesets are a paid tier:

```
$ gh api repos/Nishfleet/fleet-ops/rulesets/23692529 --jq '{conditions,rules:[.rules[].type]}'
{"conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},
 "rules":["non_fast_forward","deletion","pull_request","merge_queue","required_status_checks"]}

$ gh api orgs/Nishfleet/rulesets
{"message":"Upgrade to GitHub Team to enable this feature.","status":"403"}
```

Feature branches have zero deletion protection. The only control available is
not issuing the delete. The branch-preservation logic in organ 3
(`wip/issue-<N>` copies, `compare` calls, ahead-by checks, #8003) exists only to
make a delete safe; with no delete, none of it is needed either.

**What is lost, plainly:** the retrospective scan. If some *other* path ever
closes an App-identity PR with no comment, nothing will now flag it. That is
accepted: the only such path in the fleet was the one being deleted, and a
detector for a cause that no longer exists is a checker, which is what this
sweep removes.

The second `ExecStart=` line on `pi-issue-failed@.service` goes with the script.

### 5. LiteLLM key resolver → one vendor command

`bin/fleet-litellm-key` is a 35-line `case` that `source`s one of two env files
and prints one variable. Its only caller is
`config/pi-models.json:413`: `"apiKey": "!/home/nish/.local/bin/fleet-litellm-key master"`.

Pi's `!cmd` apiKey form is the stock feature; the script is only there because
the credential store keeps five keys in one shell-syntax file. Split the store
so each key is its own file and the resolver is `cat`:

```
~/.config/fleet-ops/litellm-keys/master     (mode 600, one line, no newline)
~/.config/fleet-ops/litellm-keys/worker
~/.config/fleet-ops/litellm-keys/senior
~/.config/fleet-ops/litellm-keys/private
```

```json
"apiKey": "!/bin/cat /home/nish/.config/fleet-ops/litellm-keys/master"
```

One vendor command, no script, no `source`, and the per-tier keys become
reachable again without the resolver's `case`. The existing
`litellm-virtual-keys.env` / `litellm-master-key.env` stay as the
`EnvironmentFile=` source for `fleet-litellm-proxy.service`; only the Pi-side
read changes. **No key value appears in the repo or in any log.**

### 6. Metrics probe → nothing stock; a decision for Nish

`libexec/fleet-metrics-probe.sh` writes `/var/lib/prometheus/node-exporter/fleet.prom`.
Exactly what it carries, and who consumes it:

```
$ grep -E '^# HELP' /var/lib/prometheus/node-exporter/fleet.prom | wc -l
11

$ # rules in config/fleet_rules.yml that read those series
FleetMainRed             -> fleet_main_ci_green
CiHostedQueueDepthHigh   -> ci_hosted_runs_queued
CiMergeQueueHeadWaitHigh -> ci_merge_queue_head_wait_seconds
```

Three corrections to the assumption this design started from:

- **`fleet_product_up` is already gone.** It is not in `fleet_rules.yml` any
  more and it is not in `fleet.prom`. The 0509 surface is already covered by
  blackbox_exporter, which is running and scraped:
  ```
  $ curl -s 127.0.0.1:9090/api/v1/targets | ...
  blackbox-0509-search-aliasgap  up   blackbox-0509-search-tier  up   blackbox-0509-timeline  up
  ```
  So the "move reachability to blackbox" half of this organ is **already done**.
  There is nothing left to migrate.
- **`ResticRestoreProofStale` is not affected.** `fleet_restore_drill_*` comes
  from a different writer, `restic-restore-test.prom`.
- **Deletion fails loud, not silent.** `FleetProbeStale` alerts on this file's
  own `node_textfile_mtime_seconds` within 10 minutes, and `absent()` counts.

What remains has **no stock exporter on this host or anywhere**: GitHub Actions
conclusions, hosted-runner queue depth, merge-queue head wait, and Cursor's
prepaid bucket. All are vendor APIs with no `/metrics` endpoint. The two honest
options, and Nish picks:

- **(a) Adopt an off-the-shelf GitHub exporter** for the Actions and
  merge-queue families. That is "prefer proven off-the-shelf", not glue — but it
  is a new installed component with its own App credentials, and no exporter
  covers Cursor's prepaid bucket, so that gauge dies either way.
- **(b) Delete the probe, `fleet-metrics-export.{service,timer}`, and the three
  alert rules.** Lost, plainly: automated notice that `main` went red, that the
  hosted queue is backing up, and that the merge-queue head is stalled — the
  2026-09-12 2h20m stall with 67 queued runs that motivated the probe would now
  pass unnoticed. Prepaid credit draining becomes something a human notices.

This design does **not** choose. It is a cost-versus-blindness trade, which is a
reserved class. Until Nish picks, the probe stays and is the last organ
standing; it blocks nothing else in the sequence.

### 7. `tests/*.test.sh` → nothing, because nothing runs them

15 files. `.github/workflows/ci.yml` on `main` today runs `shellcheck` on
`systemd/*.sh`, `promtool check rules`, `semgrep`, a YAML load over `config/*.yml`
and one `grep` for `secrets.*PAT`. **It does not invoke `tests/` at all.** They
have no consumer; six of them test scripts this design deletes. They go with
their subjects, in the same PR as each subject, so no PR ever deletes a test
and leaves the thing it tested behind.

### 8. `subagent/index.ts` → symlink to the shipped example (design-it-twice below)

### 9. Dead provider extensions → straight delete

`cursor-provider/` (378 L), `devin-provider/` (426 L incl. `rate-limit.ts`) and
`seat-env.ts` have no live install and no consumer (correction 3). Pi's
documented custom-provider mechanism is real, but nothing uses these: the
`cursor-issue@` and `devin-issue@` units exec the vendor CLIs. Delete all three
and their rows in `config/pi-extensions-allowlist.json` (which is itself organ
11).

**What is lost, plainly:** the ability to drive Cursor or Devin *from inside a
Pi session* as a provider. Nothing wants that today; the seats are units.

### 10. The declared exception: `permission-gate.ts` and `protected-paths.ts`

Both are forks of Pi's shipped examples. Both exist for one reason: the pattern
list and the path list are literals in the stock file, and Pi's settings schema
has no per-extension config key.

```
$ grep -nE '^\| `' docs/settings.md | grep -i extension
286:| `extensions` | string[] | `[]` | Local extension file paths or directories |
```

`extensions` names *where to load from*; there is no key that configures a
loaded extension. Nothing else in the schema gates a bash **command pattern** —
`defaultTools`, `--tools`, `--exclude-tools` and `--no-tools` all operate at
tool granularity, not command granularity.

So these stay, as **declared exceptions**, with three conditions:

1. Each fork keeps a header naming the upstream version and the exact reason.
2. The fork carries *only data* — the rule array and the path array. The hook
   body stays byte-identical to upstream, so a Pi upgrade is a two-array merge.
3. `permission-gate.ts`'s `worker_toolchain_ban` rule (blocking `tsc -b`,
   `vitest --coverage`, `npm run typecheck`) is **not** in the exception. It is
   a memory-budget rule wearing a command-pattern costume, and systemd has the
   real control: `MemoryMax=` on `fleet-work.slice`. Move it there and drop the
   rule, which takes the fork from six rules back to stock-plus-three.

And the thing the existing README already admits, which is the reason this is an
exception and not a virtue:

> `rm -rf /tmp/probe-scratch/doomed` — **BLOCKED**… and then the model achieved
> the same deletion with plain `rm` + `rmdir`, which match no pattern.

Pattern gating is a guard against accident. The real controls are the credential
paths being unreachable and the seats being non-interactive.

### 11–12. Config and state corpses

`config/pi-extensions-allowlist.json` was read by `lib/seat-lib.sh`, `install.sh`
and `libexec/fleet-metrics-export.py`; all three were deleted in the 2026-09-18/19
sweeps. It is now a file that describes reality instead of enforcing it. Delete.

`.fleet/bench7371/` (18 files, benchmark inputs and outputs from #7371) is
referenced only by `docs/jev-benchmark-2026-09.md` prose and `.gitleaksignore`.
Delete the directory and the `.gitleaksignore` line; git history keeps the data
and `docs/jev-benchmark-2026-09.md` keeps the conclusions.

### 14. Inline shell in unit Exec lines

Every `Exec` line in `systemd/` was measured. Twelve exceed 400 characters:

| unit:line | chars | verdict |
|---|---:|---|
| `pi-issue@.service:142` | 3,839 | **already packeted — [#8042](https://github.com/Nishfleet/fleet-ops/issues/8042)** |
| `cursor-issue@.service:101` | 722 | prompt assembly is movable (below) |
| `cursor-issue@.service:129` | 702 | to classify with #8042's pattern |
| `devin-issue@.service:119` | 701 | to classify with #8042's pattern |
| `gh-runner@.service:81` | 664 | to classify |
| `fleet-sync.service:28` | 628 | to classify |
| `devin-issue@.service:91` | 608 | prompt assembly is movable (below) |
| `pi-issue@.service:83` | 581 | at the floor (token mint + `pi`) |
| `pi-intake@.service:43` | 486 | to classify |
| `fleet-sync.service:47` | 460 | to classify |
| `pi-scout@.service:28` | 449 | to classify |
| `gh-runner@.service:58` | 434 | to classify |

Two shapes recur and both have partial stock answers:

**Prompt assembly.** `cursor-issue@:101` and `devin-issue@:91` build the prompt
with `{ cat AGENTS.md; echo; sed -e "1,/^---$/d" -e "s/[$]1/$1/g" prompts/worker.md; }`.
The `sed` does two jobs — strip YAML frontmatter, and substitute the issue id.
Both disappear if `prompts/worker.md` ships without frontmatter and refers to
`$FLEET_ISSUE`, with `Environment=FLEET_ISSUE=%i` on the unit: the agent reads
its own environment. The line becomes `cat A B | <vendor> …` — one vendor
command feeding one vendor CLI.

**The App-token mint.** Every worker unit opens with
`GH_TOKEN=$(gh token generate --app-id 4728578 --key … --token-only); export GH_TOKEN`
— six units repeating the same 200 characters. systemd documents the channel
that removes five of the six (`man systemd.exec:2305`):

> The files listed with this directive will be read shortly before the process
> is executed (more specifically, after all processes from a previous unit state
> terminated. **This means you can generate these files in one unit state, and
> read it with this option in the next.**)

So: one `fleet-gh-token.service` (`Type=oneshot`) mints the token into
`/run/user/%U/fleet-gh-token.env` as `GH_TOKEN=…` (mode 600, tmpfs, never the
repo, never a log), a `fleet-gh-token.timer` refreshes it inside the App token's
1-hour expiry, and every worker unit gains two lines:

```ini
Requires=fleet-gh-token.service
After=fleet-gh-token.service
EnvironmentFile=-/run/user/%U/fleet-gh-token.env
```

The mint itself still needs one `sh -c` (a `printf` and a `gh`, because nothing
stock writes a command's stdout in `KEY=value` form — `StandardOutput=truncate:`
writes the raw token with no key, and `LoadCredential=` populates
`$CREDENTIALS_DIRECTORY`, which `gh` does not read). That is the accepted floor:
**one** `sh -c` with two vendor commands, in one place, instead of six copies.

The packet must prove the cross-unit read live, because the man page's wording
is about unit *states* and the `Requires=`/`After=` ordering is what makes the
file exist before the reader's `EnvironmentFile=` is evaluated. Proof: one real
worker run whose journal shows `gh` authenticating with no mint in its own
ExecStart.

## Design-it-twice: the `subagent/` extension

This is the one fork that locks a shape — it sits on the path every delegating
worker takes — so it gets two whole-shape candidates, not one fix.

**What the fork actually is:** 11 lines. One `console.log("EXTLOAD-OK
extension=subagent mode=print-safe")`, then
`export { default } from "<stock>/subagent/index.ts"`. Every other file in the
live directory is already a symlink to the shipped example. The fork adds
**exactly one thing: a load handshake line.**

### Candidate A — symlink the whole directory to the shipped example

`~/.pi/agent/extensions/subagent` → `…/examples/extensions/subagent`, exactly as
`confirm-destructive.ts`, `notify.ts`, `todo.ts` and `plan-mode` already are.
`template/extensions/subagent/` is deleted from the repo.

This works because stock resolves agent definitions from `~/.pi/agent/agents`,
**not** from the extension's own `agents/` directory
(`examples/extensions/subagent/agents.ts:128-133`, `loadAgentsFromDir` accepts
symlinks at `:78`) — and the fleet's four definitions are already there:

```
$ ls -la ~/.pi/agent/agents/
planner.md  -> .../fleet-ops-deploy-clone/template/agents/planner.md
reviewer.md -> .../template/agents/reviewer.md
scout.md    -> .../template/agents/scout.md
worker.md   -> .../template/agents/worker.md
```

So nothing the fleet adds on top of stock lives in the extension at all. It
already lives in agent definitions, which is where the brief asked it to go.

The handshake is lost, and the honest version of that sentence is: **Pi has no
stock non-interactive handshake for this particular extension, and cannot
have one.** The probe looked for every candidate:

| stock mechanism | evidence | covers `subagent`? |
|---|---|---|
| interactive startup header | `dist/modes/interactive/interactive-mode.js:1341` | yes — but TUI only, and every fleet seat is `pi --print` |
| `pi --help` "Extension CLI Flags:" | help:66 lists `--plan` from plan-mode | no — stock subagent calls no `registerFlag` |
| RPC `get_commands` → `"source":"extension"` | `docs/rpc.md:816-845` | no — stock subagent calls no `registerCommand` |
| SDK `loader.getExtensions()` | `docs/sdk.md:929` | yes — but SDK only |
| session JSONL | live record: types are `session`, `model_change`, `thinking_level_change`, `message` | no — extensions are not recorded |
| any log level | `grep -rE "PI_LOG|--log-level|logLevel|PI_DEBUG" dist/` → empty | no such facility exists |

Stock `subagent` registers a **tool**, not a command or a flag
(`examples/extensions/subagent/index.ts:472`), so there is nothing for a stock
introspection surface to report.

The replacement is therefore not another marker but the evidence the house rule
already prefers: **the subagent tool call in the session record of a real run**
(`prove-liveness-by-work-not-by-pid`). A startup banner proves a file was
parsed. A tool call proves delegation works. The proof below is exactly that.

**Cost:** the `EXTLOAD-OK extension=subagent` grep in a unit journal stops
matching. The only thing that greps it, `bin/pi-transport-check --subagent`, was
already deleted on 2026-09-18, and the one test that asserts the fork is a
regular file (`tests/pi-extensions-forks-live.test.sh`) goes with organ 7.

### Candidate B — declare the shipped path in `settings.json`, keep zero files

Pi's settings schema has an `extensions` key, and it is stronger than it looks:

```
docs/settings.md:286  | `extensions` | string[] | `[]` | Local extension file paths or directories |
docs/settings.md:281  Absolute paths and `~` are supported.
docs/settings.md:292  Arrays support glob patterns and exclusions. Use `!pattern` to exclude.
docs/extensions.md:130-133  "extensions": [ "/path/to/local/extension.ts", "/path/to/local/extension/dir" ]
```

So `~/.pi/agent/settings.json` could carry
`"extensions": ["/home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent"]`
and `~/.pi/agent/extensions/subagent` would not exist at all — no file, no
symlink, no directory. Structurally distinct from A: A keeps a filesystem entry
that a `ln -sf` sweep can clobber (it has, twice, #5912); B keeps a JSON string
that such a sweep cannot touch.

**Why B was rejected.** It moves one extension out of the directory the other
nine live in, so the install is in two places and a reader has to know both.
Worse, it makes the extension's path a *pinned absolute path into a versioned
node_modules tree* — a Pi reinstall that changes the layout breaks it silently,
where a symlink breaks loudly (dangling). And it does not actually solve the
clobber it was chosen for: the same sweep that `ln -sf`s the directory would
simply recreate a directory that now shadows nothing. A's clobber risk is real
but it dies with the fork — once the entry *is* the stock target, a blanket
symlink pass is a no-op, which is exactly the outcome.

**Grafted from B:** B's insight that the fleet should own *no file* here is
kept — A is a symlink, not a copy, so the repo's `template/extensions/subagent/`
directory is deleted rather than converted.

**Also noted from B, out of scope here:** because `extensions` takes absolute
paths and globs, the two declared-exception guards (organ 10) could be loaded
straight out of the deploy clone instead of being copied into
`~/.pi/agent/extensions/`. That would make them repo-tracked and deploy-synced
rather than hand-placed files that drift. It is a real improvement and it is a
separate decision from this one; it is filed as its own child issue rather than
smuggled in here.

### Winner: A. Proof

A scratch `PI_CODING_AGENT_DIR` was built with the stock `subagent` directory
symlinked in, the two declared-exception guards copied, and nothing else. The
live `~/.pi` was not touched.

```
$ ls -la $SCRATCH/pi-stock/extensions/subagent
subagent -> /home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent

$ PI_CODING_AGENT_DIR=$SCRATCH/pi-stock \
  echo "Use scout to list the .md file names directly under …/prompts. Then reply with just that list." \
  | pi --print --session-dir $SCRATCH/pistocksess --provider litellm --model worker-cheap
```

**Result — partial, and the gap is named rather than papered over.**

The stock directory loads and the run answers correctly:

```
=== STDERR (first lines) ===
EXTLOAD-OK extension=permission-gate guard=tool_call rules=6 worker_toolchain_ban=armed
EXTLOAD-OK extension=protected-paths tools=write,edit

=== STDOUT ===
- alert-repair.md
- daily-digest.md
- intake.md
- intake-repair.md
- scout.md
- scout-repair.md
- worker.md
```

Session: `…/pistocksess/2026-09-21T16-28-37-840Z_01a0c4cc-4a4f-7755-a1f8-c812101df261.jsonl`.
Note the stderr: with the stock directory in place `EXTLOAD-OK extension=subagent`
is **absent** while the two guards still print — the scratch dir is genuinely
loading stock, and stock is silent by design. The seven filenames are correct.

**What this run does not prove.** The model answered by reading
`~/.pi/agent/agents/scout.md` itself:

```
toolCall -> bash  {"command": "ls .../pi-stock/agents/ ; ls ~/.pi/agents ; ls .pi/agents"}
toolCall -> read  {"path": ".../pi-stock/agents/scout.md"}
```

It never called the `subagent` tool. That is a `worker-cheap` behaviour, not
evidence about the extension — but it is not the proof that was asked for, so
**the delegation half stays open** and is written into the B1 packet as a
required, non-optional gate: one run whose session JSONL contains a `toolCall`
with `name: "subagent"`.

Three forced-delegation retries and a deterministic
`--tools subagent` registration probe were attempted and all returned
`429: No deployments available for selected model` / `litellm.RateLimitError …
Received Model Group=worker-cheap … Available Model Group Fallbacks=['worker-capable']`.
Every rung in the router is the one Pareto upstream, and both worker rungs were
walled for most of this pass. **Candidate A is therefore chosen on the evidence
above plus the structural argument, and confirmed on the delegation gate before
the fork is deleted, not after.**

Note what the stderr shows even before the model answers: with the stock
directory in place, `EXTLOAD-OK extension=subagent` is **absent** while
`permission-gate` and `protected-paths` still print — the scratch dir is
genuinely loading stock, and stock is silent by design.

## Sequence

Rule: a deletion issue is `agent-blocked` with a `blocked-on:` line naming the
issue that lands its consumer's replacement. Only an issue with no design choice
and no blocker is `agent-ready`. The three live paths — alert→dispatch, intake,
claim release — each land their replacement and prove it on one real event
**before** the script is cut.

### Track A — pure deletions (no consumer exists)

| order | issue | scope | label |
|---|---|---|---|
| A1 | dead Pi provider extensions | `template/extensions/{cursor-provider,devin-provider,seat-env.ts}` | `agent-ready` |
| A2 | allowlist corpse | `config/pi-extensions-allowlist.json` + its README references | `agent-ready` |
| A3 | benchmark state | `.fleet/bench7371/` + the `.gitleaksignore` line | `agent-ready` |
| A4 | tests with no subject in this sweep | 9 of the 15 `tests/*.test.sh` | `agent-ready` |

The other six tests are deleted **in the same PR as the organ they test**, never
separately, so no PR ever leaves a tested thing without its test or a test
without its subject.

### Track B — the subagent fork

| order | issue | scope | label |
|---|---|---|---|
| B1 | stock subagent | symlink `~/.pi/agent/extensions/subagent` → the shipped example; delete `template/extensions/subagent/`; delete `tests/pi-extensions-forks-live.test.sh` | `agent-ready` |

### Track C — intake (replacement first, then the cut)

| order | issue | scope | label |
|---|---|---|---|
| C1 | per-repo `.path` units | add `pi-intake-trigger@.path` + `ExecStartPre=-/bin/rm -f` on `pi-intake@.service`; enable one per enrolled repo. **Proof: one real trigger file starts one real intake tick.** | `agent-ready` |
| C2 | cut | delete `bin/pi-intake-trigger`, `systemd/pi-intake-trigger.path`, `systemd/pi-intake-trigger.service` | `agent-blocked`, `blocked-on:` C1 |

### Track D — alert → dispatch (never a gap)

| order | issue | scope | label |
|---|---|---|---|
| D1 | `alert-repair@.service` | add the template unit; repoint `config/prometheus-am-executor.yml`. **Proof: one real alert fires one repair; a second firing inside the window produces no second session.** | `agent-ready` |
| D2 | cut | delete `bin/am-executor-claim`, `tests/am-executor-claim.test.sh` | `agent-blocked`, `blocked-on:` D1 |

### Track E — claim release (never a gap)

| order | issue | scope | label |
|---|---|---|---|
| E1 | `prompts/claim-release.md` | write the prompt carrying all four rules verbatim in meaning; repoint `pi-issue-failed@.service`. **Proof: one real failed worker released, with the trace comment on the issue.** | `agent-ready` |
| E2 | cut | delete `bin/fleet-claim-release`, `bin/fleet-silent-pr-close-check`, their two tests, the second `ExecStart=`, and the `prompts/intake.md:40` reference | `agent-blocked`, `blocked-on:` E1 |

### Track F — LiteLLM key

| order | issue | scope | label |
|---|---|---|---|
| F1 | one key per file | split the credential store; repoint `config/pi-models.json` to `!/bin/cat`. **Proof: one routed tool call through the proxy.** | `agent-ready` |
| F2 | cut | delete `bin/fleet-litellm-key` and its `~/.local/bin` copy on deploy | `agent-blocked`, `blocked-on:` F1 |

### Track G — unit Exec lines

| order | issue | scope | label |
|---|---|---|---|
| G1 | `fleet-gh-token.service` + `.timer` | mint once, `EnvironmentFile=` in six units. **Proof: one real worker run authenticating with no mint in its own ExecStart.** | `agent-ready` |
| G2 | prompt assembly | frontmatter-free `prompts/worker.md` + `Environment=FLEET_ISSUE=%i` on `cursor-issue@` / `devin-issue@` | `agent-blocked`, `blocked-on:` G1 (same files) |
| G3 | the remaining six long Exec lines | classify and cut with the same pattern | `agent-blocked`, `blocked-on:` G1, G2 |

`pi-issue@.service:142` is **[#8042](https://github.com/Nishfleet/fleet-ops/issues/8042)** and is not re-filed here.

### Track H — Nish decides

| order | issue | scope | label |
|---|---|---|---|
| H1 | metrics probe | off-the-shelf GitHub exporter, or delete the probe and accept the blind spot | `agent-blocked`, `needs-nish-decision` |
| H2 | the declared exception | confirm `permission-gate.ts` / `protected-paths.ts` stay, and whether they move to deploy-clone absolute paths in `settings.json` | `agent-blocked`, `needs-nish-decision` |

### The dependency graph in one line

```
A1 A2 A3 A4 B1 C1 D1 E1 F1 G1     (parallel, no blockers)
                    |  |  |  |  |
                   C2 D2 E2 F2 G2 -> G3
H1 H2 wait on Nish; #8042 runs independently
```

## What Nish decides

1. **Organ 6** — adopt an off-the-shelf GitHub Actions exporter, or delete the
   CI/merge-queue/prepaid gauges and their alert rules and accept the blind spot.
2. **Organ 10** — confirm `permission-gate.ts` / `protected-paths.ts` stay as
   declared exceptions under the three conditions above, given the README's own
   finding that pattern gating is defeated by rephrasing.
3. **Organ 14, the App-token mint** — accept `sh -c` + two vendor commands as the
   floor, or fund a different worker identity mechanism.
