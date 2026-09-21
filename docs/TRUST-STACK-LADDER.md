# The correction ladder: every standing rule, its rung, and the mechanism

Companion to `docs/TRUST-STACK.md` section 2. Audited 2026-09-21 across
`~/.claude/projects/-home-nish/memory/MEMORY.md` (the index, ~150 entries),
`~/.claude/CLAUDE.md`, the vault `_system/shared-memory/global-standing-rules.md`,
and `AGENTS.md`.

Rungs, strongest first: **1** structure (no file to put the mistake in) · **2**
static gate (lint, CI check, ruleset, systemd unit property, router config) ·
**3** rule (a line an agent reads) · **4** skill (a loadable method) · **5**
prose (someone has to notice).

Status: **shipped** = the mechanism is live now · **packet #N** = a child issue
carries it · **prose** = it stays at rung 3-5 with the reason stated.

---

## A. Already at rung 1-2 — the mechanisms that work

These are the proof the ladder is right. Every one of them replaced prose that
had failed at least once.

| Rule | Mechanism | Rung | Status |
|---|---|---|---|
| Worker commits are authored `nishfleet-worker[bot]`, never Nish | `GIT_AUTHOR_NAME`/`GIT_COMMITTER_*` `Environment=` lines in `pi-issue@.service` — git env vars outrank repo-local config | 1 | shipped |
| A worker that produces nothing fails loudly | `ExecStopPost=` `test -s "$DELIVERABLE"` → `no-deliverable`, ×12 across `systemd/` | 2 | shipped |
| Two strikes, then change method | `StartLimitIntervalSec=1h` + `StartLimitBurst=3` on `pi-issue@.service` | 2 | shipped |
| A runaway worker must not OOM the host | `MemoryHigh=3G`, `MemoryMax=6G`, `MemorySwapMax=0` (measured `MemoryPeak` n=14) | 2 | shipped |
| Long work must outlive the session | `systemd-run --user` transient units; `Type=oneshot` | 1 | shipped |
| Hang kill | `RuntimeMaxSec` / `TimeoutStartSec=` ×14 | 2 | shipped |
| Sessions live outside `user@1000.service` (RAM governance) | slice placement, `fleet-ci.slice` | 1 | shipped |
| No secret value ever printed | Gitleaks required check + `.gitleaksignore` + secret scanning | 2 | shipped |
| No unsafe pattern merges | semgrep required check, diff-scoped to `merge-base` | 2 | shipped |
| An armed PR with no verify receipt gets disarmed | exec-review canary (fleet-ops#3731) | 2 | shipped |
| A blocking judge finding stops the arm | `blocked-by-judge` label + the arm refusing on it (#4557) | 2 | shipped |
| A gate-touch PR needs `gate-integrity` = pass | required check consulted at arm time (#5238) | 2 | shipped |
| Workers cannot spawn siblings | Pi `subagent` extension `mode=print-safe` + spawn-guard, depth-1 | 1 | shipped |
| Workers cannot run a forbidden toolchain | Pi `permission-gate`, `worker_toolchain_ban=armed`, 6 rules | 2 | shipped |
| Destructive bash needs confirmation | Pi `confirm-destructive` extension | 2 | shipped |
| No writes on a dirty checkout | Pi `dirty-repo-guard` extension | 2 | shipped |
| Only proven Pi extensions may be wired | `config/pi-extensions-allowlist.json` + a CI gate on it | 2 | shipped |
| Non-fast-forward and branch deletion on main are impossible | `main-merge-queue` ruleset rules | 1 | shipped |
| Merges go through the queue | `merge_queue` ruleset rule, `HEADGREEN` grouping | 2 | shipped |
| Seat rotation and fallback are not the worker's problem | LiteLLM router model groups + `fallbacks` | 1 | shipped |
| Jev cannot exceed its cap | the LiteLLM proxy owns the $1/month cap and the spend log; one client only | 1 | shipped |
| pstack cannot bypass the seat governor | `~/.cursor/rules/pstack-models.mdc`, every role `inherit-parent` | 2 | shipped |
| Skills cannot drift between harnesses | every harness symlinks the single vault copy | 1 | shipped (with a known residual, fleet-ops#7841) |
| `.bak-*` skill sprawl cannot recur | `tests/skill-bak-sprawl.test.sh` locks the hash-verify-and-delete class | 2 | shipped |
| Shell in `systemd/` is linted | `shellcheck -x` in `ci.yml` | 2 | shipped |

**Count: 25 rules already at rung 1-2.** The fleet's liveness and safety
discipline is genuinely strong. What follows is where it is not.

---

## B. The big drops — prose today, mechanism available

Ranked by recurrence, using the entries' own language ("recurred", "again",
"three times", "2nd").

| # | Rule | Now | Target | Mechanism | Status |
|---|---|---|---|---|---|
| 1 | **No new scripts, anywhere, in any repo** — `scripts/`, `bin/`, `tools/`, `.github/scripts/`, `ops/`, `*.sh`, `*.mjs` | 3 (`prompts/worker.md` step 5, `CLAUDE.md`, standing rules) | **1 wanted, 2 available** | Rung 1 is a push ruleset `file_path_restriction` — **probed unavailable**, `422 Source public repos cannot have push rules`, and org rulesets `403 Upgrade to GitHub Team`. Rung 2 is a required status check on the added-path set | **packet #8034**; rung 1 parked for Nish |
| 2 | Never work in the deploy clone; it stays clean on main | 3 (step 3, ×2 paragraphs) | 2 | Pi `protected-paths` — already installed and proven live — deny-write on `fleet-ops-deploy-clone` | **packet #8036** |
| 3 | The worktree path must be the absolute `agent-worktrees/` path | 3 | 2 | Same `protected-paths` entry. A relative path resolves into the clone and is refused at the tool call | **packet #8036** |
| 4 | Ollama serves DeepSeek 4.1 flash **only** — recurred 2026-09-19 via two consumers at once | 3 | 2 | The router config is the single consumer of record; `config/litellm-proxy.yaml` + `config/pi-models.json` must not disagree. A CI check comparing the two files is stock and is the class fix. The memory entry explicitly forbids a guard script — a test is not a script | **not yet packeted; see C** |
| 5 | Verification is prose in a PR body that Fable re-runs by hand | 5 | 2 | The `verdict` required check, keyed by head SHA, level from the path map | **packet #8034** |
| 6 | A unit's verifier must be a different model family from its builder | 5 (nowhere stated; true only by accident) | 2 | Router group ordering: `judge`/`senior` resolve to a non-z-ai family first | **packet #8035** |
| 7 | Every correction must be encoded at its lowest rung | did not exist | 3 + habit | The mandatory `encoded: <rung> — <mechanism>` line in every REPORT and reviewer report | **packet #8029** |
| 8 | A worker must stop before systemd kills it | 2, but wrong: `RuntimeMaxSec` kills mid-thought and yields nothing | 3 **above** the gate | `TIMEBOX` in the packet, instructing return-partial-and-stop. The unit property stays as the backstop | **packet #8029** |
| 9 | fleet-ops PRs are gated by no status checks at all | — | 2 | `required_status_checks` added to the `main-merge-queue` ruleset | **packet #8034** |
| 10 | Config `.bak-*` siblings are the record | 5 (convention, unwritten) | 1 | Versioned `config/litellm-proxy.yaml` + PR is the only record; the `.bak-` convention is deleted so it cannot be copied | **packet #8032** |
| 11 | A machine-opened issue must not arrive armed | did not exist | 2 | A `machine-reported` label that the intake rail does not watch, plus Jev `repro_worthy` before relabelling | **packet #8031** |
| 12 | `gh` CLI flag trivia (`--body`, `label` vs `labels`, `--sort`, `mergeQueueEntry`) | 3, ~5 dense lines in step 1 | **delete** | Not a fleet rule. A wrong field exits non-zero and the worker's own inner loop catches it. Keep only the *masked-failure* lessons (#1193, #5010), which the inner loop does **not** catch | **packet #8030** |

---

## C. Stays prose, with the reason

These are judgment, authority, or economics. No mechanism should hold them, and
trying to build one would be the glue the house rules forbid.

| Rule | Rung | Why it stays |
|---|---|---|
| Money, security actions only Nish can take, machine-unfixable blockers come back as questions | 3 | The reserved-classes list is an authority boundary. A gate that enforced it would have to judge intent |
| No payments, cards or paid trials without Nish | 3 | Same. And the failure mode of a wrong gate here is worse than the failure mode of the rule |
| Quality > 300+/day > efficiency; parity work is raised, not shipped | 3 | A motive ordering. Nothing checkable |
| Ambiguity resolves to authority (vendor docs > consensus) | 3 | A reasoning rule |
| Act, don't ask; the ask bar is ambiguity, not category | 3 | Behavioural, and already the most-restated rule in the corpus — but the thing being corrected is a judgment, so a gate would just move the judgment |
| Times in IST, UTC only in logs | 3 | Could be a lint rule; the cost exceeds the harm. Honest rung-3 |
| Design it twice for shape-locking work | **4** | Correctly a skill. It is in the vault skills-library and this document used it |
| blast-radius, why, session-pickup, pause-safely, review-adjudication, unslop | **4** | Correctly skills. They are methods, not constraints |
| Prefer off-the-shelf; name what you searched and rejected | 3 | The naming requirement is the enforcement. A reviewer can check it, which is the point |
| Proofs cite id/path/timestamp; invented samples never count | 3 → partly 2 | The `verdict` check makes the *behavioural* half mechanical (#8034). The "cite a real record" half stays a rule, because only a reader can tell a real id from a plausible one |

---

## D. Dead or contradicted — delete rather than enforce

Gardener work for the weekly consolidation pass (#8036). These index rows point
at retired systems, so every session pays to read them and some risk acting on
them.

| Entry | Why it is dead |
|---|---|
| `netcup-sole-fleet-host` (hostinger-kvm4 RETIRED) | The retirement is the fact; the row is a tombstone. Fold one line into the infra entry and drop the rest |
| `opencode-go-seat-wiring` — "to 09-14" | Self-dated past |
| `codex-retired-for-now` | Codex is retired; the row survives only to say so |
| `deepseek-v4-flash-banned` | Superseded by the live Ollama entry, which states the same ban with the current mechanism |
| `jev-benchmark-nogo-was-starved-state` — "re-run #7909 after 09-21" | Today is 2026-09-21. Either re-run it or retire the row; it cannot stay a pending instruction |
| `mac-glue-wipe-2026-09-19`, `glue-sweep-2-2026-09-19`, `glue-sweep-lessons-2026-09-18` | Three entries for one campaign. Merge into one, keep the lessons, drop the wipe lists |
| `0509-rebuild-charter` + `0509-scripts-to-zero` + `0509-direction-*` + `0509-real-usage-baseline` | Four 0509 rows where one current-state row would do |
| `prepaid-seat-roster-2026-09-12`, `synthetic-devpass-nebius-seats`, `pareto-inference-seat`, `supergrok-seat-revived`, `xkiro-free-models-seat`, `synthetic-one-slot-per-model`, `cursor-seat-worker-engine`, `opencode-go-seat-wiring` | Eight seat rows describing a roster the router already describes authoritatively. The router is the record; the memory should carry only what the router cannot say (which seat is JEV-ONLY, which engine cannot tool-call) |

**The index itself is the strongest argument for the gardener.** The
`memory-index-autocompact` entry warns it truncates at ~24KB **silently** — so
the corpus has a failure mode with no event, which is the named reason the
consolidation pass is scheduled rather than triggered.

---

## E. Counts

| | Rung 1 | Rung 2 | Rung 3 | Rung 4 | Rung 5 | delete |
|---|---|---|---|---|---|---|
| **Now** | 9 | 16 | ~95 | 7 | ~12 | — |
| **Target** | 10 | 24 | ~55 | 7 | ~4 | ~22 |

Twelve rules move down a rung in this epic (section B). Twenty-two index rows
retire (section D). Ten rules are confirmed to stay prose with a stated reason
(section C) — which is itself a result: an `encoded: 5` with a reason is a
legitimate terminal state, and knowing which rules those are stops the fleet
re-litigating them.

The single largest remaining concentration of rung-3 prose is
`prompts/worker.md`, which holds roughly twenty past corrections as sentences.
Packets #8029, #8030 and #8036 take the first six of them out. The rest are the
next wave.
