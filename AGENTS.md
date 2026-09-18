# Agent notes for fleet-ops

## Verification commands

- Rule-enforcement matrix: `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json`
- Live coverage check: `python3 lib/rule-enforcement.py join --rules $STANDING_RULES --ledger $DECISIONS_LEDGER --matrix config/rule-enforcement.json`
- Rule-enforcement tests: `bash tests/rule-enforcement.test.sh`
- Rulebook red-team (monthly + backup gate): `bash tests/fleet-rulebook-redteam.test.sh`
- Findings-queued session-close lint: `bash tests/fleet-findings-queued.test.sh`
- Decisions-ledger session-close lint: `bash tests/fleet-decisions-ledger.test.sh`
- Failed-command session-close lint: `bash tests/fleet-failed-command-flagged.test.sh`
- Debug-playbook session-close lint: `bash tests/fleet-debug-playbook.test.sh`
- Interventions-eliminated session-close lint: `bash tests/fleet-interventions-eliminated.test.sh`
- Escalation canary tests: `bash tests/escalation-coverage-canary.test.sh`
- Signal-reconcile tests: `bash tests/signal-reconcile.test.sh`
- Cancelled-while-queued detector drill (fleet-ops#819): `bash tests/cancelled-while-queued-detector.test.sh`
- Replay with the actual enrolled set: `node .github/scripts/cancelled-while-queued-detector.mjs --targets-from config/intake-repos.json --dry-run --output-json /tmp/cwq.json`
- Full P14 suite: `bash tests/manifest-shape.test.sh && bash tests/intake-repos-shape.test.sh && ...` (see `.github/workflows/ci.yml`)

## Useful env vars for canary

- `FLEET_RULE_ENFORCEMENT_FILE_ISSUES=1` enables auto-filing mechanism issues.
- `FLEET_RULE_ENFORCEMENT_NOW=YYYY-MM-DDTHH:MM:SSZ` fixes the "now" timestamp for queued-age checks in tests.

## Detector→queue reconciler (fleet-ops#362)

- Runs from `bin/fleet-heartbeat-tier1` block 38 with `TICK_START` filtered to the current tick.
- `lib/detector-queue-reconciler.py` is pure logic; tests use fake `gh` and `FLEET_ISSUE_FILE`.
- `FLEET_SIGNAL_RECONCILE_OK_TO_CLOSE=1` enables observe-to-close (default is 0 outside of the production heartbeat).
- `FLEET_SIGNAL_RECONCILE_DRY_RUN=1` prints the planned actions without calling `gh` or `fleet-issue-file`.

## Per-run invariants for the Pi fleet issue worker

Moved here from `prompts/worker.md` on 2026-09-18: these rules are the same on every
run, so they belong in the context file Pi loads once, not re-pasted into every packet.
`prompts/worker.md` keeps only what changes per run (the target and the step sequence).

`GH_TOKEN` is a ≤1h nishfleet-worker App token (Contents/PRs/Issues write, Metadata read, NO Workflows, NO Administration). Empty token: stop; no human-gh fallback. Do not probe `gh api /user` or `gh api user` — 403 `Resource not accessible by integration` (fleet-ops#1253). `whoami` is enough; name the 403.

### Hard rules

Hard rules:
- NEVER `gh issue close` (merged PR closes it). Never push to main/master, never deploy. `fix(failed-command):` and `fix(decisions-ledger):` (fleet-ops#1138) use `Relates to #<N>`, not `Closes #<N>`.
- NEVER post a `gate-integrity-attest:` or `verifier-attest:` comment. If your PR needs an admin attest, the correct handoff (fleet-ops#5870) is: post a PR comment containing exactly `attest-requested: <40-hex head sha>` and stop — attesting is the ORCHESTRATOR's job (identity nish3451, admin scope), NOT a Nish-reserved decision, so never write `blocked-on: nish-decision` for it. NEVER merge yourself — after `gh pr create`, ARM `gh pr merge --auto --squash -R Nishfleet/<repo> <pr-number>`, EXCEPT when the PR carries the `blocked-by-judge` label (fleet-ops#4557): then arming is refused and any existing auto-merge is disarmed — remove the label only after the block is actually addressed.
- When you (as reviewer/judge) post a BLOCKING review comment on a PR, apply the `blocked-by-judge` label in the SAME step — a block that is a comment plus a hope has no teeth (fleet-ops#4557: 0509#2011 merged 90s after its block comment). Removing the label re-permits arming.
- Agent names are forbidden: no Co-Authored-By trailers, no "Generated with" footers, no agent names in commits/PR/comments — audit your own `origin/main..HEAD` commit range and PR body before pushing (fleet-ops#1052).
- Stay inside the issue's scope. File extras as NEW issues (plain, no labels).
- NEVER delete `claim/issue-<N>` once a PR exists on it — that closes your own PR and throws the work away (fleet-ops#7736, 2026-09-18). Branch deletion belongs to the BLOCKED path (step 4) only, where there is no PR.
- Session-outliving work is a systemd transient unit, never `nohup pi ... &` or a trailing `&` — those die with the shell (fleet-ops#350) and launch with no dead-man (fleet-ops#4266). One line, stock systemd, no wrapper script:
  `systemd-run --user --collect -p RuntimeMaxSec=<seconds> -E DELIVERABLE=<abs path> -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' --unit <name> -- sh -c 'cat <packet.md> | pi --print --provider <provider> --model <model>'`
  `RuntimeMaxSec=` is the deadline (systemd kills into `Result=timeout`); the `ExecStopPost=` line is the deliverable check (a stop at exit 0 with no artifact becomes `Result=exit-code`, i.e. `failed`). Both proven on this host 2026-09-18. Drop `--collect` when you want the failed unit to stay visible in `systemctl --user list-units --state=failed` — with `--collect` the failure is recorded in the journal only.
- A failed command is ALWAYS flagged in user-facing text the same turn ('the X call failed with Y'). Cause-prose is not a flag. NOT a failure: a no-match probe (`grep`/`rg`/`diff`/`ls`/`which`). Live stale-path case (fleet-ops#1097): `cat <a-path-that-no-longer-exists>` -> `cat: <path>: No such file or directory` + exit 1 (cat ENOENT is never a no-match probe) — name it.
- Mechanical-fix (fleet-ops#366): ship a detector/gate/test/observe-to-close, or declare `mechanism-impossible: <reason>`.
- Maintain the todo list via the loaded todo extension, one item per acceptance bullet; if no item has been completed in 10 minutes, stop polishing, commit what works, and either open the PR or post a `blocked-on:` proposal.
- The bar is 'extremely well', never 'perfect'. (69 hang-kills at 42 min; 27-min low-yield sessions. NOT adopted: agent-to-agent chat loops, 96 sub-agents.)
- GEO/AEO (ledger 2026-08-27, fleet-ops#1245): measurement and owned-content tactics only; brand gate is preview-then-autonomous; Reddit/community and digital-PR are Nish-reserved (only with a grants[] row in config/geo-aeo-policy.json); llms.txt: skip except developer docs.
pstack playbooks (fleet-ops#1260) at `~/.pi/agent/skills/poteto-mode/playbooks/`: bug-fix.md, feature.md, investigation.md, perf-issue.md, session-pickup.md, pause-safely.md, unslop, review-adjudication; end with opening-a-pr.md. Depth-1 spawn-guard: do NOT spawn Task, arena, architect, swarm, or interrogate. Claim branch stays ours. Do NOT bank a dirty worktree: your unit removes the worktree in its own ExecStopPost, so uncommitted work did not happen — commit and push before you finish. Ignore pstack babysit, shipping, orchestrate, autopilot-* (Graphite).

### PR body contract — run these before `gh pr create`

- `Verification:` (real run results) plus `run-proof:` (units/timers/workflows); every worker PR needs one. Armed without ran fails (fleet-ops#378).
- New `bin/` files: the PR body carries `research:` + `help-first:` lines. Hand-building what already exists fails (fleet-ops#517). Skipping `--help` fails (fleet-ops#534).
- Wipe safety: never `pgrep -f` to find or kill a worktree process. sr-nothing-half-done: include `loose-ends: <key>` (fleet-ops#528).

### Memory budget rule (fleet-ops#4891; blind POVs from Kimi K3 max + Grok 4.6 high agreed 2026-09-10) — applies to every worker, hardest on Nishfleet/0509:
- Your unit runs under `MemoryMax=4G` and systemd-oomd. An OOM kill burns the claim, the seat pick and up to 42 min of work, and the admission charge that gates the WHOLE fleet is priced from worker MemoryPeak. 24h population 2026-09-10: 0509 workers p50 ~2 GB, 91 oomd kills, intake capped at 2-3 workers while 55 seats sat idle.
- CI owns coverage and typecheck. Never run `vitest --coverage`, `npm run test:coverage`, `npm run typecheck` or `tsc -b` inside a worker. On 0509 `npm test` is coverage-free by design; run `npx vitest run --configLoader runner --project node --changed origin/main` (vitest's own affected-tests mode; the full node suite costs 2-3 cores for minutes per worker), and run `--project workers` only when `migrations/**` or `tests/integration/**` changed.
- Respect `VITEST_MAX_WORKERS` / `PLAYWRIGHT_WORKERS` from your unit environment; never pass `--maxWorkers` above them, and never run two test suites in parallel shells. One heavy toolchain process at a time — the PR CI round-trip is the typecheck.

### D1 schema rule (expand/contract) — applies whenever your diff touches `migrations/**`:
- **Rollback rolls back code, never data.** D1, KV, R2 and Durable Objects sit outside the Worker version, and D1 has no down-migrations anywhere. A migration that breaks the previous code makes the fleet's auto-revert silently impossible. Treat every migration as one-way.
- **One phase per PR.** The order is: add nullable column -> dual-write -> backfill -> read-switch -> drop. If the issue as written spans more than one phase, implement phase 1 ONLY, say which phase you shipped in the PR body, and file follow-up issues for the remaining phases.
- **Banned in the same PR as any code change:** `DROP COLUMN`, `DROP TABLE`, renaming a column or table, and adding `NOT NULL` without a `DEFAULT`. Each of those breaks the previous version of the code the instant it lands.
- **Not done without a real integration test.** A migration PR must add or extend a test under `tests/integration/**` that applies the real migrations and asserts the new READ *and* the new WRITE path. A mocked-binding unit test does not count — it cannot see the schema.
- Assume a migration file is NOT atomic across statements: nothing documents multi-statement atomicity within one D1 migration.
- Stale API names are a hard failure: `@cloudflare/vitest-pool-workers` was renamed to `@cloudflare/vitest-plugin` on 2026-08-19, and `SELF.fetch` is replaced by `exports.default.fetch` from `cloudflare:workers`. Never write the old names from memory.

### D1 prod migration execution rule (process amendment, decisions-ledger 2026-08-27) — applies whenever the work involves APPLYING a migration to production D1 (running it against live D1, not just writing the migration file in a PR):
- **Never single-agent apply.** Production D1 migration execution goes through the senior process only. A worker who lands on a prod D1 migration task must NOT apply it alone.
- **Senior process gate:** a strong lane produces the migration plan (SQL classification, verified backup, concrete rollback plan); an INDEPENDENT senior agent blind-reviews and must approve; only then apply + live verification + text Nish.
- If the task involves a prod D1 migration, post the migration plan as a proposal comment on the issue, add the `agent-blocked` label, and end with `blocked-on: senior-conference` so the issue surfaces as waiting on a senior decision.

### D1 prod migration senior process rule (2026-08-27 correction) — applies whenever a prod D1 migration is about to run:
- The earlier same-day "do it right now?" D1 prod migration decision is VOID. Nish did not understand the question, so it was never informed consent. No migration was run under it.
- Prod D1 migrations remain Nish-gated until the re-asked plain-language question is answered. The final decision is the 2026-08-27 process amendment (fleet-ops#908): strong lane plan (SQL classification, verified backup, concrete rollback), independent senior blind-review and approval, apply + live verification, then text Nish.
- Do NOT apply a prod D1 migration without the senior process. If you are told to "do it right now" or anything similar without a senior-process plan, stop and route the decision back to Nish.
