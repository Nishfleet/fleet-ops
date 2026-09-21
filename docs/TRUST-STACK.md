# The fleet kitchen: Lauren Tan's trust stack applied to the fleet itself

Source: Lauren Tan (@poteto), "how i shipped 2,500 PRs last month", Cursor Compile,
2026-09-21. Local transcript with timestamps:
`nish-vault/00 Inbox/agent-drop/claude/vps/2026-09-21-poteto-2500-prs-talk-transcript.md`.
Her plugin: `github.com/cursor/plugins` `pstack/`.

Track A applies her model to the 0509 product. This is Track B: the same model
applied to the machinery that produces the PRs. Her thesis is that fan-out is
escaped by trust, not by more agents (talk 06:22), and that trust comes from
three things — verification the agent runs itself, a correction ladder that
pushes every lesson as far down as it will go, and a gardener who keeps the
substrate clean (talk 07:04, 16:28, 24:26).

Everything below is stock. No new units, timers, scripts, hooks, wrappers or
Pi extensions. Every row names the stock feature and its vendor doc, and every
probe in the log at the end was run on this VPS with its output pasted.

## 0. The measured baseline

Run 2026-09-21 on this VPS, GitHub search API, 30-day window:

| Repo | merged | closed unmerged | merged with "revert" in title |
|---|---|---|---|
| Nishfleet/fleet-ops | 2013 | 392 | 67 |
| Nishfleet/0509 | 1212 | 260 | 56 |
| **total** | **3225** | **652** | **123** |

Query: `gh api -X GET /search/issues -f q="repo:Nishfleet/<r> is:pr is:merged merged:>=2026-08-22"`.

Read the third column as the trust metric. 123 reverts against 3225 merges is a
3.8% revert rate, and 652 closed-unmerged is 17% of throughput thrown away. The
fleet is already at Lauren's fan-out and past her trust threshold in the wrong
direction: it is spending flagship-grade orchestration on catching slop after
the merge instead of making it unmergeable before. The product this throughput
serves had 15 users. Throughput is not the limiter. Trust is.

This document's done-predicate: **the revert rate and the closed-unmerged rate
both fall, with concurrency unchanged.**

## 1. Verification the worker runs itself

Today a worker's proof is prose in a PR body — the `Verification:` /
`run-proof:` lines in `prompts/worker.md` step 7 — and Fable re-runs it by hand.
Prose is rung 5 on the ladder in section 2: it only works if a reader notices.
At 3225 merges a month, no reader notices.

### 1.1 The verdict ladder

Adopt pstack's ledger vocabulary verbatim (orchestrate playbook, "Verification"):

```
live-verified > unit-test-verified > type-check-only > verifier-blocked > verifier-failed
```

Her two load-bearing rules come with it:

- **CI green is an input to a verdict, not a verdict.** Gitleaks, semgrep,
  `codex-node-checks` and friends prove the diff is not poisoned. They do not
  prove the feature works.
- **A new head SHA voids the row.** The verdict is keyed by PR number plus the
  40-hex head SHA, so a restack or a review fixup re-opens verification.
- `verifier-blocked` is not a pass. `verifier-failed` gets a fix unit, not a
  re-verify.

### 1.2 Where the verdict is recorded — no new file

Three stock surfaces already exist and between them carry the whole ledger:

| Fact | Stock surface | Why this one |
|---|---|---|
| The verdict itself, gating merge | A **required status check** named `verdict` on the `main-merge-queue` ruleset | Check runs are keyed by head SHA by construction, so "a new head SHA voids the row" is free. Doc: https://docs.github.com/rest/checks/runs |
| The level reached | The same check's **title/summary**, e.g. `verdict: live-verified` | Visible in `gh pr checks` without opening a file |
| The level, queryable in bulk | A **PR label** `verdict/live-verified` etc. | `gh pr list --label` gives the gardener a population without cloning. Labels are repo-scoped and free |
| The evidence | The existing PR body `Verification:` receipt | Already contracted in `prompts/worker.md` step 7 and enforced by the exec-review canary |

No ledger file. No `orchestrate/` store. The repo already has one.

### 1.3 Design it twice — the contested fork

This is the shape that locks in everything downstream, so it went through the
design-it-twice skill.

**Candidate A — one required check per verdict level.** The ruleset requires
`verdict/live-verified`. A PR that only reaches `unit-test-verified` never
satisfies it and sits forever.

**Candidate B — one required check named `verdict`, level in the output.** The
ruleset requires `verdict`. It passes at any level; the level lives in the
summary and the label.

**Screen.** A fails on the first docs-only PR: requiring live verification of a
README change either blocks it forever or forces the worker to fake a live run
to clear the gate, which is worse than no gate — it manufactures exactly the
prose-proof this section exists to kill. B fails the opposite way: it passes a
behavioral change at `type-check-only`, which is Lauren's "behavioral work needs
better than type-check-only" violated by the mechanism itself.

**Rejected: Candidate A**, because a gate that cannot be satisfied is a gate
that gets bypassed, and the `main-merge-queue` ruleset's bypass list is where
that pressure would land. A gate whose failure mode is "someone adds a bypass
actor" is worse than the prose it replaced.

**Synthesis (ship this).** One required check named `verdict`. It selects its
own required level from the changed paths, and passes only if the level reached
meets or beats the level required:

| Changed paths | Required level |
|---|---|
| Anything under `app/`, `workers/`, `migrations/` (0509) or `systemd/`, `prompts/`, `config/` (fleet-ops) | `live-verified` |
| Test-only, or code with no runtime surface | `unit-test-verified` |
| `docs/`, `*.md`, comments | `type-check-only` |

The path→level map is data in the workflow, not logic in a script. The grafted
win from the rejected candidate A: the **label** is still per-level, so the
gardener gets A's queryability without A's gating rigidity.

### 1.4 The verifier is a different model family from the builder

pstack states it twice — "Run a unit's verifier on a different model family
from its worker" (orchestrate, Roles) and again under Verification. The fleet
honours it by accident today: the Opus reviewer in `prompts/worker.md` step 8
is Claude and the workers are not. Accident is rung 5. Make it a stated rule in
two places at rung 3, and a router fact at rung 2:

- **Packet rule** (section 6): every packet whose VERIFY is judgment-laden names
  the verifier's model group explicitly, never `inherit-parent`.
- **Router rule**: the `senior` group that step 8 passes to the reviewer
  subagent must not resolve to the same upstream `api_base` as the group the
  worker ran on. Today it does — see section 9.

## 2. The correction ladder

Lauren's sequence, strongest first (talk 16:28–18:35, and the closing slide at
36:08):

| Rung | Name | What it means for the fleet |
|---|---|---|
| 1 | Codebase / structure | The mistake is categorically impossible. There is no file to put it in, no field to set wrong |
| 2 | Static gate | A lint rule, a CI check, a GitHub ruleset, a systemd unit property, a router config value. It blocks |
| 3 | Rule | A line in `CLAUDE.md`, `AGENTS.md`, a standing rule. The agent reads it, usually |
| 4 | Skill | A loadable method the agent invokes when it recognises the situation |
| 5 | Style guide / prose | Someone has to notice. At this throughput, nobody does |

**The house rule this yields:** when you correct a worker, you have not finished
until you have named the lowest rung that correction could live at, and either
moved it there or written down why it cannot move.

### 2.1 The finding that dominates the audit

`prompts/worker.md` is a 10-step prompt in which nearly every sentence is a
past correction preserved as prose, each carrying its own issue number —
fleet-ops#1055, #1219, #1244, #4884, #1193, #5010, #6206, #1250, #4260, #3634,
#3758, #5786, #5687, #477, #1185, #3679, #7401, #4557, #5238, #3731, and more.
That file is the fleet's style guide, and it is doing the job of the whole
ladder by itself. It is rung 5 with rung-2 ambitions.

Each of those numbers is a lesson that was learned and then parked at the
weakest rung available. Several are mechanically enforceable today:

| Correction now in prose | Issue | Rung now | Rung available | Stock mechanism |
|---|---|---|---|---|
| Never work in the deploy clone; it must stay clean on main | #3634, #3758 | 3 (prose in step 3) | 2 | Pi `protected-paths` extension — already installed and proven (`EXTLOAD-OK extension=protected-paths tools=write,edit`, probe 9). Add the deploy-clone path to its config |
| Worktree path must be the absolute `agent-worktrees/` path | #5687 | 3 | 2 | Same `protected-paths` extension, deny-write on the deploy clone subtree. A relative path resolves into the clone and is refused at the tool call |
| No new scripts anywhere: `scripts/`, `bin/`, `tools/`, `.github/scripts/`, `ops/`, `*.sh`, `*.mjs` | #7942, #7828, 0509#3679 | 3 (step 5) | **2, but not by push ruleset — see 2.2** | Required status check on the path set; Pi `permission-gate` (`worker_toolchain_ban=armed`, probe 9) |
| A claim of "already in production" must cite a SHA on origin/main | #5786 | 3 | 2 | Already partly rung 2 via the packet-verdict checker and the dead-man; fold into the `verdict` check of section 1 |
| Armed PR with no verification receipt gets disarmed | #3731 | 2 | 2 | Shipped. The exec-review canary. Keep |
| `blocked-by-judge` blocks the arm | #4557 | 2 | 2 | Shipped. Keep |
| `gate-integrity` must be pass before arming a gate-touch PR | #5238 | 2 | 2 | Shipped. Keep |
| gh CLI field/flag traps (`--body`, `label` vs `labels`, `--sort`, `mergeQueueEntry`) | #1055, #1219, #1244, #4884, #6206 | 3 | **5 — delete** | These are not fleet rules, they are `gh` 2.93.0's API surface. They belong in nobody's prompt. A wrong field exits non-zero and the worker's own inner loop catches it. Cutting them shortens the prompt without losing a guard |
| Worker commits must be authored `nishfleet-worker[bot]` | — | **1** | 1 | Shipped, and the model case for the whole ladder: `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` are set in `pi-issue@.service`, so the correct identity is structural. The unit's own comment says it: "they are set once in the unit instead of restated in prose the model can forget" |

That last row is the template. The fix that works is the one the worker cannot
reach.

### 2.2 Probed: push rulesets are not available

The obvious rung-1 move for "no glue" is a GitHub **push ruleset** with
`file_path_restriction` making `scripts/**`, `ops/**` and `**/*.sh`
categorically un-pushable. It was probed on the real repo and it is not
available:

```
$ gh api -X POST /repos/Nishfleet/fleet-ops/rulesets --input push-ruleset.json
{"message":"Validation Failed",
 "errors":["Source public repos cannot have push rules"],
 "status":"422"}
```

Nishfleet repos are public by decision (memory: `repos-public-by-decision`,
2026-09-17), and organisation-level rulesets are a paid feature on this account:

```
$ gh api /orgs/Nishfleet/rulesets
{"message":"Upgrade to GitHub Team to enable this feature.","status":"403"}
$ gh api /orgs/Nishfleet --jq '.plan.name'
free
```

So the rung-1 version of "no glue" is **unavailable without either going
private or paying for GitHub Team**. Both are Nish's calls, not the fleet's —
parked in section 12.

**The rung-2 fallback that does work on a public repo in a free org:** a
required status check that fails when the diff adds a path in the forbidden set,
wired into the existing `main-merge-queue` ruleset's `required_status_checks`.
fleet-ops's ruleset currently has **no `required_status_checks` rule at all**
(probe 3: rule types are `non_fast_forward`, `deletion`, `pull_request`,
`merge_queue`), while 0509's has four. That gap is itself a finding.

**Rejected fallback:** CODEOWNERS plus `require_code_owner_review` on those
paths. It works mechanically, but it routes every touch to Nish for approval,
which breaks the standing `merge-own-green-prs` rule and puts a human back in
the 3225-PR path. A gate that only Nish can clear is a gate that stops the
fleet, not one that improves it.

### 2.3 Rung inventory — full per-rule audit

See `docs/TRUST-STACK-LADDER.md` (same PR) for the row-per-rule table across
`MEMORY.md`, `CLAUDE.md`, the vault standing rules and `AGENTS.md`, with counts
per rung and the shipped/packeted/stays-prose column.

## 3. The gardener

Lauren's gardener nips patterns before they propagate (talk 24:26). The fleet's
codebase is three things: `fleet-ops`, the memory index, and the standing rules.
All three grow weeds.

**Named reason for a schedule.** The house rule is event-driven over scheduled.
Consolidation has no event: drift accrues silently between runs and nothing
fires when a memory entry goes stale. That is the named reason, and it is the
only scheduled item in this design.

**Owner: Fable, not a worker.** The memory directory is
`~/.claude/projects/-home-nish/memory/` — session-scoped Claude state, outside
any repo. A `pi --print` worker has no business writing it, and the
`index-autocompact` memory entry records that the index truncates silently at
~24KB, which is a failure a worker would not notice.

**Mechanism: the stock skill `anthropic-skills:consolidate-memory`**, read at
`~/.claude/remote/plugins/*/skills/consolidate-memory/SKILL.md`. It already does
exactly the three passes needed — take stock, merge overlaps and retire dated
files, tidy the index under 200 lines and 25KB. Nothing to build.

**No new timer.** `fleet-sync.timer` and `daily-digest.timer` are already armed
(probe: `systemctl --user list-timers` shows 8 timers, `daily-digest.timer` at
09:00 IST daily). The consolidation pass is one weekly item on the existing
`daily-digest` Fable turn, not a ninth timer.

**Pruning dead units — the knip equivalent.** systemd already reports it:

```
$ systemctl --user list-unit-files --state=disabled
systemd-tmpfiles-setup.service disabled enabled
1 unit files listed.
$ systemctl --user list-unit-files | tail -1
89 unit files listed.
```

One disabled unit out of 89, and it is systemd's own. The unit tree is clean;
what is not clean is `config/`, which carries six `litellm-proxy.yaml.bak-*`
files in `~/.config/fleet-ops/` — exactly the "innocent-looking pattern that
spreads" Lauren warns about, because the next agent to edit the router will copy
the convention and leave a seventh. Gardener item, packeted.

## 4. Skills that teach workers to work like engineers

### 4.1 Probed: Pi already discovers pstack, and `~/.agents/skills` is the wrong path

The brief proposed installing pstack-portable with
`npx skills@latest add theoklitosBam7/pstack-portable -g -y` into
`~/.agents/skills`. **Do not run it.** Probed live:

```
$ ls ~/.agents/skills
ls: cannot access '/home/nish/.agents/skills': No such file or directory
$ ls ~/.pi/agent/skills | wc -l
120
$ echo 'Name the exact skill file you would load to strip AI tells from prose,
  and print its absolute path...' | pi --print --provider litellm --model worker-cheap
EXTLOAD-OK extension=permission-gate guard=tool_call rules=6 worker_toolchain_ban=armed
EXTLOAD-OK extension=protected-paths tools=write,edit
EXTLOAD-OK extension=subagent mode=print-safe
The skill is **unslop** — its file is `SKILL.md`.
Absolute path: `/home/nish/.pi/agent/skills/unslop/SKILL.md`
```

Pi reads `~/.pi/agent/skills`, which already holds 120 skills including the full
pstack set (all 21 principles, all 23 playbooks — inventory in
`docs/pstack-adoption.md`, verified 2026-08-27). Installing a second copy into a
directory Pi does not read would create drift with nothing consuming it, and
`docs/pstack-adoption.md` already records one such drift incident
(fleet-ops#3441, a re-sync that ran the wrong direction and destroyed the
house-adapted `blast-radius`).

**Deviation from the brief, on evidence: the install is not performed.** The
artefact it would produce already exists at a different path and is already
canonical.

### 4.2 The split — who loads what

pstack is installed but, per `docs/pstack-adoption.md`, "Fleet flows never
invoked it. Armed, never fired." That is the real gap: not installation,
invocation. The split:

| Skill | Loaded by | Why |
|---|---|---|
| `principle-*` (21), `tdd`, `unslop`, `no-comments`, `technical-writing`, `blast-radius` | **Worker**, named in the packet | These are how-to-build methods. They apply inside one unit |
| `create-verification-skill`, `maintain-verification-skill` | **Worker**, only on packets that build or repair a verifier | Directly serve section 1 |
| `orchestrate`, `autopilot-full`, `autopilot-stack`, `swarm`, `arena`, `interrogate` | **Fable only** | They spawn. The `subagent` extension runs `mode=print-safe` and the spawn-guard forbids a depth-1 worker launching siblings. A worker that loads `orchestrate` will try to fan out and be refused — wasted tokens and a confusing failure |
| `session-pickup`, `pause-safely`, `reflect` | **Fable only** | Session-level, and the fleet's units are `Type=oneshot` with no session to resume |

Enforcement rung: the packet names the skills (rung 3). The spawn-guard already
refuses the Fable-only ones structurally (rung 1) — so the split is a cost
optimisation and a clarity win, not a safety gate.

## 5. The trust curve, reconciled with max concurrency

Lauren: 1–5 agents is escaped by trust, not fan-out (talk 06:22). The house
standing order is max safe concurrency and "idle capacity next to ready work is
a defect".

These do not conflict, and neither changes. State the reconciliation as a rule:

> **Concurrency is governed by capacity. Merging is governed by verification.**
> Fan out to the governors — RAM, per-worker caps, seat caps — and never idle a
> lane. Nothing produced by that fan-out reaches `main` without a `verdict`
> check at the level its changed paths require. Fan-out multiplies throughput;
> it cannot multiply slop, because the gate is per-PR and keyed by head SHA.

The 123 reverts in section 0 are what fan-out without that gate produces. The
gate is the thing that makes the standing order safe to keep.

## 6. Briefs are the product

pstack: "Your prompts to agents are your only product, and a sloppy brief
compounds into slop across the whole tree" (orchestrate, The brief). Her
template:

```
GOAL SCOPE CONTEXT ACCEPTANCE VERIFY TIMEBOX FORBIDDEN REPORT STANDING
```

The fleet's packet shape, from the live sample `Nishfleet/0509#3864`:
`GOAL`, `STOCK FEATURE OR LIBRARY` (a table with version and vendor doc),
`FILES IN SCOPE` + out-of-scope, `FORBIDDEN`, `PROOF REQUIRED`.

Comparison:

| pstack field | Fleet packet today | Action |
|---|---|---|
| GOAL | `**GOAL.**` | Present |
| SCOPE | `FILES IN SCOPE` + "Out of scope, rejection if touched" | Present, and stronger — it names the rejection |
| CONTEXT | `STOCK FEATURE OR LIBRARY` table + `blocked-on:` | Present, and stronger — the version and vendor-doc columns have no pstack equivalent. **Keep this; it is the fleet's own invention and it is better** |
| ACCEPTANCE | folded into `PROOF REQUIRED` | **Split it out.** Acceptance is what "done" means; proof is how you show it. #3864 mixes them |
| VERIFY | `PROOF REQUIRED` | Present, and #3864's is excellent — numbered, with exact commands |
| **TIMEBOX** | **absent** | **Add.** The only hard gap. Today the cap is `RuntimeMaxSec` on the unit, which kills the worker mid-thought and produces nothing. A TIMEBOX in the packet tells the worker to return partial findings *before* systemd kills it |
| FORBIDDEN | `**FORBIDDEN.**` | Present, and stronger — #3864's forbidden section names the specific catastrophic case (renaming a required check) |
| REPORT | implicit in step 10 ("print exactly one final line") | **Add explicitly**, with the encode-lessons line from 6.1 |
| STANDING | in `AGENTS.md`, loaded by Pi | Present by a different mechanism. Pi loads `AGENTS.md` per run, which is better than pasting — it cannot decay across resumes. **Keep the mechanism, do not adopt verbatim pasting** |

**Three additions, no removals:** `ACCEPTANCE` as checkable lines separate from
proof; `TIMEBOX` with the return-partial instruction; `REPORT` with a named
shape. Everything else the fleet already has or does better.

### 6.1 Encode the lesson, every run

pstack: "When you catch yourself restating an instruction, append the line
before you act (`principle-encode-lessons-in-structure`)", and at close,
"encode recurring corrections into `preferences.md` or the brief template".

Fleet form — one line, mandatory, at the end of every reviewer report on a
worker PR and in every packet's `REPORT` shape:

```
encoded: <rung> — <the mechanism>            e.g. encoded: 2 — semgrep rule in config/rules/
encoded: 1 — Environment= line in pi-issue@.service
encoded: none — no correction was needed
encoded: 5 — prose in prompts/worker.md, because <reason the lower rungs cannot hold it>
```

`encoded: 5` is legal but must carry a reason. An `encoded: 5` with no reason is
a review failure. This is the ladder made into a habit rather than a document:
every run either strengthens a rung or explains why it could not.

## 7. The outer loop

Hers subscribes to Slack and Sentry and kicks off agents that reproduce bugs and
open PRs (talk 32:33). The fleet's equivalents, audited:

| Trigger | Stock mechanism | State |
|---|---|---|
| New labelled issue | `pi-intake-trigger.path` (a systemd `.path` unit) + `pi-intake@<repo>.timer` | **Live and event-driven.** A `.path` unit is the correct stock primitive and it is already in use |
| Alert fires | `prometheus-am-executor.service` → `prompts/alert-repair.md` | **Live.** Terminates in dispatch, per the standing rule |
| Repo drift / opportunity scan | `pi-scout@fleet-ops.timer` | Live, scheduled |
| GitHub events | `~/.config/fleet-ops/gh-webhook.secret` exists | Secret present. Consumer not established in this audit — **gap, packeted to confirm or retire** |
| **Product error tracking** | **none** | **The real gap.** See 7.1 |

### 7.1 Error tracking → the issue rail

Track A picks 0509's error tracker (Workers Logs notifications, or Sentry's
native GitHub integration). Both open a GitHub issue natively — no webhook
receiver of ours, which keeps it stock. This side defines what the rail accepts.

**Issue shape a machine may open:**

| Field | Requirement |
|---|---|
| Label on arrival | `machine-reported` — never `agent-ready`. A machine-opened issue is a report, not a packet |
| Title | The error class plus the surface, not the stack frame |
| Body | First seen, last seen, occurrence count, affected route or worker, one stack trace, and the release SHA |
| Forbidden in body | Customer data, tokens, full request bodies |

**Jev triages before anything is armed.** POST `127.0.0.1:4000/jev`, key from
`~/.config/fleet-ops/seats/typesafe-jev.env`, first opinion only, per the
standing rule:

- Question: `repro_worthy` — is this a real defect a worker can reproduce from
  the evidence in this issue, as opposed to noise, a third-party outage, or a
  duplicate of an open issue?
- `p >= 0.9` → relabel `agent-ready`, the existing intake rail takes it.
- `p <= 0.1` → close as noise with the probability recorded on the issue.
- Anything between → `needs-orchestrator`. Fable decides. This is the
  fall-through the standing rule requires, not a coin flip.
- Log the verdict and own it. Never invent a probability.

The rail itself needs no change: `agent-ready` already means "armed" and
`pi-intake-trigger.path` already watches for it. The only new thing is a label
and a triage question.

## 8. Liveness and retries

pstack: only side effects count as progress; probe read-only, never resume to
check; two retries then abandon. Audited against the fleet:

| Rule | Fleet state |
|---|---|
| Side effects, not transcripts, are progress | **Shipped.** `ExecStopPost` checks `test -s "$DELIVERABLE"` and fails the unit with `no-deliverable` if empty. 12 `ExecStopPost=` across `systemd/` |
| Transcript mtime is not liveness | **Shipped as a rule** (memory `prove-liveness-by-work-not-by-pid`: check CPU time plus output mtime) and reinforced by `pi-print-units-silent-until-exit` |
| Never resume an agent to check on it | **Shipped as a rule** (`agent-interrupt-may-be-cosmetic`: check the PR before re-dispatch) |
| Two retries, then abandon | **Shipped at rung 2.** `StartLimitIntervalSec=1h` + `StartLimitBurst=3` on `pi-issue@.service`, plus the `two-strikes-change-method` rule. systemd enforces the count; the rule enforces the method change |
| Retry by failure mode (cap-hit → smaller scope; tool-error → different model) | **Gap.** `Restart=` is mode-blind. The router's `fallbacks` cover the model-swap case for a seat outage, but a *tool* error retries on the same seat. **Packeted** as a router-config question, not a wrapper |
| Bound your own infra retries | **Gap at the Fable layer.** No stated cap on Fable's own tool-abort retries. Rung 3, one line |
| Hang kill | **Shipped.** `RuntimeMaxSec` / `TimeoutStartSec=` × 14 |

Six of eight already hold. The fleet's liveness discipline is its strongest
area, and it is strong precisely because it lives at rung 2 in unit properties
rather than in prose.

## 9. The kitchen ratio

Lauren's kitchen runs on the ratio of line cooks to sous chefs to dishwashers
(talk 01:39). The fleet's equivalent is builder seats to verifier seats, and it
must be counted, not assumed.

Live count, 2026-09-21:

```
$ curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state
{api_base="https://api.paretoinference.com/v1", litellm_model_name="z-ai/glm-5.3-flash", model_id="pareto-glm53flash-senior"} 0.0
{api_base="https://api.paretoinference.com/v1", ... model_id="pareto-glm53flash-judge"} 0.0
{api_base="https://api.paretoinference.com/v1", ... model_id="pareto-glm53flash-worker-capable"} 1.0
{api_base="https://api.paretoinference.com/v1", ... model_id="pareto-glm53flash-worker-cheap"} 1.0
{api_base="https://api.paretoinference.com/v1", ... model_id="pareto-glm53flash-worker-private"} 0.0
{api_base="https://ai-gateway.vercel.sh/v4/ai/evaluation-model", litellm_model_name="unknown"} 0.0
$ curl -s 127.0.0.1:4000/health/readiness
{"status":"healthy","db":"connected"}
```

**Distinct upstream `api_base` values serving work: two.**
`api.paretoinference.com` (z-ai/glm-5.3-flash) and `ai-gateway.vercel.sh`
(the Jev evaluation model, JEV-ONLY by standing rule and not a general seat).

### The ratio, stated

| Role | Seats | Family |
|---|---|---|
| Builder (`worker-cheap`, `worker-capable`, `worker-private`) | 3 groups | **z-ai / GLM-5.3-Flash** |
| Verifier (`senior`, `judge`) | 2 groups | **z-ai / GLM-5.3-Flash — the same family** |
| Typed-decision (`jev`) | 1 | typesafe, JEV-ONLY |
| Reviewer of last resort | Fable / Opus | Claude — a different family, but it is Nish's own session, not a seat |

**Ratio: 3 builders : 0 family-independent verifier seats : 1 human-session
reviewer.**

### The arithmetic says verification is the bottleneck

pstack requires the verifier to be a different model family from the builder.
On the current router, `senior` and `judge` resolve to the same `api_base` and
the same weights as `worker-capable`. So step 8 of `prompts/worker.md` — the
reviewer round that is supposed to be the quality gate — is **a model reviewing
its own family's work**, which is the failure mode the rule exists to prevent.
Every verification that genuinely satisfies the rule today runs through Fable,
a single human-attended session. One verifier for 3225 merges a month is the
bottleneck, and it is the mechanical explanation for the 123 reverts.

**The fix is a seat re-role, not a new seat** (no spend; `zero-revenue-no-spend`
stands). The prepaid roster already carries non-GLM engines that are wired but
not currently in a healthy rung — xAI/SuperGrok (grok-4.6 at $0 via
`xai-oauth`), Cursor (`grok-4.6-high`), and the Kimi/Hermes rungs. **Packet: make
`judge` resolve to a non-z-ai family first, before any GLM rung, and leave the
GLM rung only as the last fallback.** That is a `config/litellm-proxy.yaml`
ordering change — config only, no adapter — and it converts the existing
reviewer round from ceremony into an actual cross-family check.

Until that lands, the honest statement for the packet template is: **the
reviewer round is same-family and is therefore not a verdict.** Only the
`verdict` check of section 1 and Fable's own re-run are.

## 10. Proposed rewrites — for Fable to apply, not edited here

**`~/.claude/CLAUDE.md`, replacing the "Broken means fix it now" line in
Failures and the "Proofs run on real records" line in How work runs:**

> Broken means fix it now, same turn, then prove it green by re-running. A
> finding is a work item, not a message: find, fix, verify, log, report. Every
> correction closes by naming the lowest rung it could be encoded at —
> structure, static gate, rule, skill, prose — and moving it there, or stating
> why it cannot move; a correction left at prose needs a reason, and the run's
> report carries the line `encoded: <rung> — <mechanism>`. Proofs run on real
> records and cite id/path/timestamp; invented samples never count. A verdict is
> the required `verdict` check keyed by head SHA at the level the changed paths
> demand — CI green is an input to a verdict, never a verdict, and a new head
> SHA voids the row. Concurrency is governed by capacity and merging is governed
> by verification: fan out to the governors, and let nothing reach main
> unverified. A unit's verifier runs on a different model family from its
> builder; where the router cannot supply one, the packet says so rather than
> claiming a review it did not get.

**Vault `_system/shared-memory/global-standing-rules.md`, appended as one rule
in the reserved-classes section's neighbourhood:**

> **The correction ladder.** Corrections are encoded at the lowest rung that
> holds them: 1 structure (the mistake has no file to live in), 2 static gate
> (lint, CI check, GitHub ruleset, systemd unit property, router config), 3
> rule, 4 skill, 5 prose. Prose is the last resort and always carries its
> reason. A rule that has recurred twice is a defect in the rung it sits at, not
> in the agent that broke it — move it down or delete it. The fleet's own
> substrate — fleet-ops, the memory index and these rules — is gardened weekly
> by Fable on the existing digest turn, because drift accrues without an event.

## 11. Probe log

Every probe run on this VPS, 2026-09-21, output pasted at the cited section.

| # | Probe | Result | Section |
|---|---|---|---|
| 1 | `gh --version` | `gh version 2.93.0 (2026-05-27)` | — |
| 2 | `gh api /repos/Nishfleet/fleet-ops/rulesets` | one ruleset, `main-merge-queue`, branch, active | 2.2 |
| 3 | ruleset rule types | `non_fast_forward`, `deletion`, `pull_request`, `merge_queue` — **no `required_status_checks`** | 2.2 |
| 4 | 0509 ruleset checks | `Gitleaks`, `codex-node-checks`, `semgrep`, `preview-assert` | 1.2 |
| 5 | `gh api /orgs/Nishfleet/rulesets` | `403 Upgrade to GitHub Team` | 2.2 |
| 6 | POST push ruleset with `file_path_restriction` | `422 Source public repos cannot have push rules` | 2.2 |
| 7 | `curl 127.0.0.1:4000/health/readiness` | `{"status":"healthy","db":"connected"}` | 9 |
| 8 | `litellm_deployment_state` | 2 distinct `api_base`; all worker+judge groups on one family | 9 |
| 9 | `pi --print --provider litellm --model worker-cheap`, skill-naming prompt | returned `/home/nish/.pi/agent/skills/unslop/SKILL.md`; `EXTLOAD-OK permission-gate … worker_toolchain_ban=armed`, `protected-paths`, `subagent` | 4.1 |
| 10 | `ls ~/.agents/skills` | does not exist; `~/.pi/agent/skills` has 120 | 4.1 |
| 11 | `systemctl --user list-unit-files --state=disabled` | 1 of 89, systemd's own | 3 |
| 12 | `systemctl --user list-timers` | 8 armed; `daily-digest.timer` 09:00 IST | 3 |
| 13 | `systemctl --user list-units --state=failed` | 0 | — |
| 14 | unit property census in `systemd/` | `TimeoutStartSec`×14, `Restart`×12, `ExecStopPost`×12, `MemoryMax`×8, `MemoryHigh`×5, `CPUQuota`×3, `CPUWeight`×2, `TasksMax`×1 | 8 |
| 15 | 30-day PR counts, both repos | 3225 merged / 652 closed-unmerged / 123 revert-titled | 0 |

## 12. Only Nish can decide

1. **Rung 1 for "no glue" costs money or privacy.** Push rulesets with path
   restrictions are unavailable on public repos in a free org (probe 6, probe
   5). Making `scripts/`, `ops/` and `*.sh` categorically un-pushable requires
   either GitHub Team, or making the repos private — and `repos-public-by-decision`
   (2026-09-17) says never re-ask the privacy question. Both are reserved
   classes. The rung-2 fallback in 2.2 ships regardless and needs no decision.
2. **The `judge` seat re-role** (section 9) is config-only and free, so the
   fleet will packet it. But if none of the non-GLM prepaid rungs is healthy
   when the packet runs, restoring cross-family verification would need a paid
   seat — a money call.
3. **A standing rule that contradicts observed reality:** `prompts/worker.md`
   step 8 presents the reviewer round as the quality gate, and the router makes
   it same-family. Until the re-role lands, the fleet is claiming a review it is
   not getting. Flagged here rather than silently fixed because it changes what
   past PR bodies mean.
