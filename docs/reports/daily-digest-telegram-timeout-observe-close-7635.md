# Observe-close for #7635 — daily-digest.service died on a single transient Telegram send timeout; the send is a bounded retry whose failure path stays loud, and the wiped Jev advisory tier is back in prose form

triage: daily-digest.service died 2026-09-18T09:00:13+05:30 on ONE transient
Telegram send timeout (`hermes.orig` HTTP call, ~7 s, single attempt, no
retry); the bash organ was cut the same evening by 334a7c9a5 for
`prompts/daily-digest.md` + unit. The first prompt-era fix (#8162) merged with
Opus grade D — its `|| resp=""` plus always-zero `printf|tee` made three
failed sends exit "successfully", and `curl -s` left a blank journal line on
timeout — so Nish ordered revert + redo; the wipe landed as #8234. This PR is
the redo: the send block keeps the bounded 3-attempt retry but captures the
real curl error into `resp` (`-sS` + `2>&1`), writes a greppable
`Telegram send failed after 3 attempts: <error>` line to the journal and
`/tmp/daily-digest-send.json`, and exits non-zero when nothing delivered, and
the deleted `hermes-digest` Shadow Jev tier is restored as one prose-described
POST with a JSONL log line per the #8218 standing rule.

fleet-ops#7635 is the unit-death dispatch (fleet-ops#5456 A(ii)) for
`daily-digest.service`, which died `Failed with result 'exit-code'` at
2026-09-18T09:00:13+05:30 — eight seconds after start, on the send step. The
dispatch asks the claim to "diagnose from the journal, redo the work, and land
it". The failure class is unchanged by the revert: one transient timeout must
not lose a day's digest, and a lost digest must read as a failure, never as a
delivery.

## What was found

1. **The death was the send, and the send had exactly one attempt.** The
   deleted organ `libexec/daily-digest` (removed the same day by `334a7c9a5`)
   ended with one exec, no retry anywhere:

   ```
   # 334a7c9a5^:libexec/daily-digest:361
   exec "$HERMES_BIN" send -t telegram --urgent --class daily-digest --json "$body" </dev/null
   ```

   Timeline from the retained evidence: start 09:00:04, outbound gate
   `ACCEPT OK 2/3 urgent=True class=daily-digest` at 09:00:05
   (`agent-state/lanes/outbound-gate/actions.log`), error JSON at 09:00:12 —
   the Hermes telegram HTTP call timed out after ~7 s. The previous day
   (2026-09-17T09:00:01 `ACCEPT OK 1/3`, message_id 1557) shows the gather
   path was fine; the whole failure class is "the one send timed out".

2. **The live-era prompt delivers when Telegram answers.** Journal (retained
   portion): 2026-09-20 `ok=true message_id=1607` at 09:04:00; 2026-09-21
   `{"ok":true,"message_id":1616}` at 09:05:39; unit `Result=success`,
   `Type=oneshot`, timer `Persistent=yes`. The 2026-09-19 slot is rotated, not
   absent.

3. **The first fix earned Opus grade D and was reverted.** #8162 shipped the
   right idea — a bounded retry — with two real defects: `|| resp=""` threw
   away curl's error and the unconditional `printf | tee` always exited 0, so
   three dead sends closed the block "successfully" and a lost digest was
   indistinguishable from a delivered one; and `curl -s` on a `--max-time`
   timeout prints nothing, so the journal got a blank line where the grade
   claimed "the full error". #8164 repaired the `set -e` hazard but not the
   swallowed failure. Nish ordered revert + redo (issue comment, 2026-09-22);
   #8234's glue-zero wipe removed the shipped detector and every Shadow Jev
   section, including this file's `hermes-digest` tier.

## The redo

- **Send block (`prompts/daily-digest.md`).** Still a bounded loop — up to
  three attempts, five seconds apart, stop on `"ok":true`, never a second
  loop — but the failure path is honest now:
  - `curl -sS ... 2>&1` folds curl's own error text (`curl: (28) Operation
    timed out after 20001 milliseconds ...`) into `resp`, so a timeout is
    never a blank line.
  - `&& rc=0 || rc=$?` records curl's exit instead of blanking `resp`; each
    failed attempt prints `send attempt N failed (curl rc=N): <error>` to
    stderr.
  - On success the real API response is tee'd to
    `/tmp/daily-digest-send.json`. On exhaustion the block tee's
    `Telegram send failed after 3 attempts: <last real error>` — the same
    `Telegram send failed` prefix the original death printed — and ends on
    `false`: the tool call itself reports failure, so a lost digest is loud
    in both the journal and the transcript. The loop's conditionals stay
    `if/then/fi` so the block is still `set -e`-safe (#8164's class).
  - Duplicate-over-lost stands: a retry after a delivered-but-timed-out
    attempt can double-send; a repeated digest beats a lost one.

- **Shadow Jev tier (`prompts/daily-digest.md`).** The wiped `hermes-digest`
  advisory is restored in the only permitted form (fleet-ops#8218): prose.
  One POST to `http://127.0.0.1:4000/jev` written as an inline command, no
  interpreter heredoc, no fenced program, no run-this-file line; `model`
  `typesafe-ai/jev`, `state` carries `site` `hermes-digest`, `rule_tier`
  `digest` and ten metadata counters re-derived from the live sources (never
  the composed prose); `questions` is eleven booleans — one per item plus
  `message_urgent_instant` — each asking whether that reading needed an
  instant urgent notification rather than the scheduled digest. Rows append
  to `~/.local/state/pi-packet/jev/hermes-digest.jsonl` with `tier_p`,
  `disagree` at the site's 0.5 edge (`docs/jev-bands.md`), `advisory_only`
  true and the response `usage`; `JEV_HERMES=0` skips it, and every failure
  path prints `daily-digest: jev advisory unavailable (<reason>); rules
  unchanged` and continues to Send. It changes nothing — it scores what a
  gate WOULD have done, for the flip benchmark (fleet-ops#7754).

- **Detector (mechanical-fix, fleet-ops#366).** No test file returns: #8234
  deleted `tests/` fleet-wide and the no-glue gate keeps it deleted. The
  mechanism is the contract itself plus CI: the send block's non-zero exit is
  verified live below; the `no-glue` job refuses any heredoc/fenced-program
  form of the tier under `prompts/`; and this file's `triage:` line is the
  observe-to-close grep target.

## Verification

All runs on netcup-rs2000, 2026-09-22, in worktree
`/home/nish/workspaces/agent-worktrees/issue-fleet-ops-7635` on
`claim/issue-7635` (origin/main `1359397b2`).

- The shipped send block was extracted verbatim (`sed -n '/^```bash$/,/^```$/p'
  prompts/daily-digest.md`) and executed against a stub `curl` on a temp PATH
  with a stub `sleep`; no network, no credentials:
  - ok-first → one attempt, `{"ok":true,"result":{"message_id":9999}}` tee'd,
    block rc=0.
  - fail-fail-ok → two stderr lines carrying the real error
    (`send attempt N failed (curl rc=28): curl: (28) Operation timed out
    after 20001 milliseconds with 0 bytes received`), third attempt
    delivered, rc=0.
  - hard-down (every attempt times out — the #7635 class) → three real error
    lines, `Telegram send failed after 3 attempts: curl: (28) ...` tee'd to
    the file and printed, block rc=1.
  - hard-down under `bash -euo pipefail` → identical, rc=1, file still
    written (the #8164 set -e class stays covered).
  - apierr (`"ok":false` JSON) → retried, real API error tee'd, rc=1.
- The no-glue `prompts/` scan was emulated locally on this diff — the exact
  gate regex over added lines — clean (no matches).
- The banned-tree checks were emulated too: no added files under
  `bin/ lib/ scripts/ libexec/ ops/ hooks/ .github/scripts/ tests/
  template/extensions/ .fleet/` or any `*.sh|*.py|*.mjs|*.ts`, and no added
  lines inside the deleted trees.
- One real POST to `127.0.0.1:4000/jev` with the tier's payload shape
  (`model` `typesafe-ai/jev`, `state.site=hermes-digest`, boolean questions)
  returned `answers.<key>.probability` values in range (0.08, 0.07) plus
  `usage` — the endpoint and the body contract are live.
- `semgrep --config p/default --baseline-commit "$(git merge-base HEAD
  origin/main)" --quiet --metrics=off` → exit 0, no findings printed.
- Deployment path: the unit `cat`s the deploy clone's
  `prompts/daily-digest.md`; `fleet-sync.service` fast-forwards that clone on
  its timer, so the merged text is live on the next sync tick with no unit
  change.

run-proof: the extracted send block ran green under stubbed curl for
ok-first, fail-fail-ok, hard-down (plain and `set -euo pipefail`) and apierr
in this session; the no-glue scans and the live Jev POST ran in the same
worktree, outputs quoted above.

loose-ends: user-unit-escalation-gap — same-hour escalation for ordinary
user-scope units has not existed since `9f0cba02c` deleted
`systemd/service.d/10-escalate.conf`; filed with evidence as
Nishfleet/fleet-ops#8161, not touched here. deploy-lag — the new send text is
live only after the merge's next `fleet-sync` pull. judge-round-merge —
#8162 merged 4m48s after the judge applied `blocked-by-judge` through the
merge queue; the systemic gap is filed as Nishfleet/fleet-ops#8163.

encoded: 5 — prose in prompts/daily-digest.md; the send contract is executed
by an agent reading a prompt, not a binary the repo can gate, and tests/ is
deleted fleet-wide (no-glue keeps it deleted), so no lower rung exists for
this fix. The mechanism inside the prose is the block's non-zero exit plus
the greppable `Telegram send failed` triage line, drill-verified in this
report's Verification runs.
