# Observe-close for #7635 — daily-digest.service died on a single transient Telegram send timeout; the old organ was cut the same day and the new send is now a bounded retry

triage: daily-digest.service died 2026-09-18T09:00:13+05:30 on ONE transient Telegram send timeout (`hermes.orig` HTTP call, ~7 s, single attempt, no retry); the bash organ was cut the same evening by 334a7c9a5 (on origin/main) for `prompts/daily-digest.md` + unit; the live-era prompt delivered message_id 1607 (2026-09-20) and 1616 (2026-09-21), unit Result=success, next fire Tue 2026-09-22 09:00 IST; the residual failure class (one timeout still loses the digest) is fixed in this PR by a bounded 3-attempt send retry in `prompts/daily-digest.md` plus the `tests/daily-digest-send-retry.test.py` detector.

fleet-ops#7635 is the unit-death dispatch (fleet-ops#5456 A(ii)) for
`daily-digest.service`, which died `Failed with result 'exit-code'` at
2026-09-18T09:00:13+05:30 — eight seconds after start, on the send step. The
dispatch asks the claim to "diagnose from the journal, redo the work, and land
it". This run diagnosed the death from the issue's journal snapshot plus the
deleted organ's own source, re-ran the dispatch's job under the live-era
implementation, and fixed the underlying failure class: the send is a bounded
retry loop now, so one transient timeout can no longer lose a day's digest.

## What was found

1. **Proof-shape match (real dispatch, not a fixture).** `gh issue view 7635`
   fields: `title=[unit-death] daily-digest.service — died, resume exhausted
   (hop=non-packet)`, `author=app/nishfleet-worker`,
   `created=2026-09-18T03:30:15Z`, `labels=agent-in-progress`. The body carries
   the live journal tail: `Starting daily-digest.service` (09:00:04) → the error
   JSON → `Main process exited, code=exited, status=1/FAILURE` (09:00:13) →
   `Failed with result 'exit-code'` → `Triggering OnFailure= dependencies.` The
   named unit, the journal, the detected timestamp and the OnFailure firing all
   line up with the dispatcher's real record; the STOP-REASON path the dispatch
   names holds an unrelated stale record today (`fleet-seat-bench-truth.service`,
   2026-09-18T15:00), which does not change the dispatch's own journal.

2. **The death was the send, and the send had exactly one attempt.** The
   deleted organ `libexec/daily-digest` (removed the same day by `334a7c9a5`)
   ended with one exec, no retry anywhere:

   ```
   # 334a7c9a5^:libexec/daily-digest:361
   exec "$HERMES_BIN" send -t telegram --urgent --class daily-digest --json "$body" </dev/null
   ```

   `bin/hermes` (repo shim, `de9a6101a` era) is a policy gate that ends in
   `exec "$REAL" send "${shift_args[@]}"` with
   `REAL=/home/nish/.hermes/hermes-agent/venv/bin/hermes.orig`; the
   `Telegram send failed: Timed out` string is produced inside that Hermes
   binary — outside this repo. Timeline from the retained evidence: start
   09:00:04, outbound gate `ACCEPT OK 2/3 urgent=True class=daily-digest` at
   09:00:05 (`agent-state/lanes/outbound-gate/actions.log`), error JSON at
   09:00:12 — the Hermes telegram HTTP call timed out after ~7 s. The previous
   day (2026-09-17T09:00:01 `ACCEPT OK 1/3`, message 09:00:04,
   `message_id 1557`, `"mirrored": true`) shows the gather path was fine; the
   whole failure class is "the one send timed out".

3. **The organ was cut the same evening, on purpose — and the rewrite left the
   failure class open.** `334a7c9a5` ("cut(digest): daily-digest becomes a Pi
   prompt on the same timer", Fri 2026-09-18 23:59 IST; `git merge-base
   --is-ancestor 334a7c9a5 origin/main` → exit 0) deleted `libexec/daily-digest`
   (361 lines), `bin/hermes` (177) and `tests/daily-digest.test.sh`, and added
   `prompts/daily-digest.md` plus `systemd/daily-digest.{service,timer}`. But
   its Send section shipped a single `curl --max-time 20` with no retry — one
   `Timed out` would still lose the day's digest, now by a different path, with
   no dispatcher left to file a follow-up. That residue is what this PR fixes.

4. **The live-era implementation re-executed the job twice since.** Journal
   (retained portion): 2026-09-20 09:00:00 → 09:04:00, "The digest was sent
   successfully — Telegram API returned `ok=true message_id=1607`"; 2026-09-21
   09:00:00 → 09:05:39, ``{"ok":true,"message_id":1616}` — delivery
   confirmed`. Unit state: `Type=oneshot`, `Result=success`, `NRestarts=0`,
   `OnFailure=` (empty). Timer: `LastTriggerUSec=Mon 2026-09-21 09:00:00 IST`,
   `NextElapseUSecRealtime=Tue 2026-09-22 09:00:00 IST`, `Persistent=yes`. The
   2026-09-19 run is **not verifiable either way** — the user journal's oldest
   retained entry is 2026-09-19T21:33:11 IST, so that morning's slot is
   rotated, not absent.

5. **The fix, in the prompt (no new scripts).** `prompts/daily-digest.md` Send
   section now ships a bounded retry loop: up to **3 attempts, 5 s apart**,
   stopping the moment the API response contains `"ok":true`; the final
   response is `tee`d to `/tmp/daily-digest-send.json` so the journal carries
   the delivery proof even when `pi --print` drops the last assistant text; if
   all three attempts fail the full error is printed plainly; an explicit
   no-second-loop guard prevents a duplicate send after a success. The
   duplicate-over-lost tradeoff (a rare retry after a delivered-but-timed-out
   attempt) is stated in the prompt and accepted: a repeated digest beats a
   lost one.

6. **A detector ships with it (mechanical-fix, not prose).**
   `tests/daily-digest-send-retry.test.py` extracts the shipped send block and
   executes it three ways with a stubbed curl (in a temp dir; stub bash
   functions, no network, no credentials): fail-fail-ok → exactly 3 attempts,
   `"ok":true` printed, 2 failure lines on stderr; ok-first → exactly 1
   attempt and silent stderr (no double send); hard-down → capped at 3
   attempts and no false `"ok":true`. It also asserts the loop bounds,
   `--max-time 20`, the tee path, `${TELEGRAM_BOT_TOKEN}` env-only reference
   and no literal token shape in the block. It is `.py`, not `.sh`, because
   the `no-glue` CI gate fails any PR that ADDS `**/*.sh` (the gate is
   mechanical and does not exempt tests). The neighbouring
   `tests/daily-digest-jev-shadow.test.sh` (the #7393 shadow-tier contract)
   stays green — the send mandate and the shadow-before-send ordering are
   unchanged.

7. **The gap found around this unit is wider than this unit — filed, not fixed
   here.** The failed unit's `OnFailure=` is empty because `9f0cba02c` (glue
   sweep, "delete escalation-tower") removed
   `systemd/service.d/10-escalate.conf`, the drop-in that wired generic
   user-unit failure to `unit-escalation@` — the same dispatcher that produced
   this very issue no longer exists. Surviving `OnFailure=` targets are only
   the named lane units (`pi-issue@`, `cursor-issue@`, `devin-issue@` →
   `pi-issue-failed@`), and the Prometheus `SystemUnitFailed` rule reads the
   system scope only. Filed with full evidence as Nishfleet/fleet-ops#8161
   (plain finding, no labels; no unit, timer, rule or config touched for it).

## Review round (the `blocked-by-judge` label)

The first push's automated judge review (github-actions[bot], 2026-09-21
23:34–23:36 IST, applied `blocked-by-judge`) raised three findings; all three
are fixed in the same run:

1. **`no-glue` FAILURE — a new `**/*.sh` cannot land.** The detector was added
   as `tests/daily-digest-send-retry.test.sh`; the gate fails any PR that adds
   `**/*.sh` (tests are not exempt). Ported to
   `tests/daily-digest-send-retry.test.py`; `no-glue` passes on the new head.
2. **`[ "$attempt" -lt 3 ] && sleep 5` was the last loop-body command, and
   `printf … | grep -q … && break` was the first.** Under `set -e` either
   failing `&&` aborts the block before the final `printf … | tee` — the
   hard-down path, the exact case the retry exists for, would have lost its
   own error output. Both are `if … then … fi` forms now (the ok-break and the
   pause), so the block is `set -e`-clean.
3. **The old `.sh` test sourced a block written to a fixed
   `/tmp/daily-digest-send-block.sh`** (collision/staleness risk). The `.py`
   port extracts into `tempfile.mkdtemp()` and removes it in `finally`.

The detector now also runs every functional case under `set -euo pipefail` and
captures the `tee` output, so finding 2's class is caught rather than read.
Proven: with the `&&` forms temporarily restored the test reports exactly
`FAIL: ok-break is an if-form, safe under set -e`, `FAIL: pause is an if-form,
safe under set -e`, `FAIL: no && conditional left to fail out of a set -e
shell` — `3 FAILURES` — and passes again once the `if` forms are back.

## Verification

- `gh issue view 7635 -R Nishfleet/fleet-ops --json title,author,labels,createdAt`
  → quoted above; `gh pr list --head claim/issue-7635 --state all` → empty (no
  prior PR; the claim branch's remote half had been force-reset to origin/main
  by the re-claim, so there was no salvage commit to cherry-pick).
- Era reads from git, not memory: `git show 334a7c9a5^:libexec/daily-digest`
  (single-attempt exec quoted above; line 361 of 361);
  `git show de9a6101a:bin/hermes` (gate shim; `REAL` rename so the raw
  `venv/bin/hermes` path fails loudly, then `exec "$REAL" send`);
  `git merge-base --is-ancestor 334a7c9a5 origin/main` → exit 0.
- Outbound gate ledger (`agent-state/lanes/outbound-gate/actions.log`):
  `2026-09-17T09:00:01+05:30 ACCEPT OK 1/3 urgent=True class=daily-digest`
  (delivered, message_id 1557) and `2026-09-18T09:00:05+05:30 ACCEPT OK 2/3
  urgent=True class=daily-digest` (accepted, then the underlying send timed
  out).
- Host probes (netcup-rs2000, 2026-09-22 ~05:3x IST, origin/main `5746e1539`):
  - `journalctl --user -u daily-digest.service --since "2026-09-20"` →
    `Starting` 09:00:00, success line with `message_id=1607` at 09:04:00,
    `Finished` (Sep 20); `Starting` 09:00:00, ``{"ok":true,"message_id":1616}`
    at 09:05:39, `Finished` (Sep 21).
  - `systemctl --user show daily-digest.service -p Type -p Result -p NRestarts
    -p OnFailure` → `Type=oneshot`, `Result=success`, `NRestarts=0`,
    `OnFailure=` empty.
  - `systemctl --user show daily-digest.timer -p LastTriggerUSec -p
    NextElapseUSecRealtime -p Persistent` → last Mon 2026-09-21 09:00 IST,
    next Tue 2026-09-22 09:00 IST, `Persistent=yes`.
  - `journalctl --user -o short-iso | head -1` → 2026-09-19T21:33:11+05:30
    (retained window; Sep 18 and Sep 19-morning rotated).
- Fix and tests (in this worktree, branch `claim/issue-7635`):
  - `python3 tests/daily-digest-send-retry.test.py` → "all
    daily-digest-send-retry cases passed" (retry contract present;
    fail-fail-ok: 3 attempts, delivered, proof printed; healthy path: one
    attempt, silent stderr; hard-down: capped at 3, no false ok; precedent
    note and single-send guard present).
  - `bash tests/daily-digest-jev-shadow.test.sh` → "all
    daily-digest-jev-shadow cases passed" (shadow precedes send; send mandate
    intact; no credential reference in the block).
  - `python3 tests/jev-merge-queue-batches.test.py` → "PASS: all checks".
  - `semgrep --config p/default --baseline-commit "$(git merge-base HEAD
    origin/main)" --quiet --metrics=off` → clean (no findings printed).
  - CI round 1 on the first push: `ci` and `Gitleaks` passed but `no-glue`
    FAILED (`##[error]Process completed with exit code 1` on
    `test -z "$(git diff --diff-filter=A --name-only origin/main...HEAD --
    'bin/**' 'scripts/**' … '**/*.sh' '**/*.mjs' …)"`) — the added
    `tests/daily-digest-send-retry.test.sh` matched `**/*.sh`. Fixed in the
    same run by porting the detector to `tests/daily-digest-send-retry.test.py`
    (functionally identical: it still executes the shipped block with stubbed
    bash functions); re-run green, as above.
- Deployment path for the fix text: the unit reads the deploy clone's
  `prompts/daily-digest.md`, and `fleet-sync.service` ("a git pull IS the
  deploy", `~/.config/systemd/user/fleet-sync.service`) fast-forwards that
  clone on its timer — so the merged retry text becomes live on the next sync
  tick with no unit-file change.

run-proof: `python3 tests/daily-digest-send-retry.test.py`,
`bash tests/daily-digest-jev-shadow.test.sh` and
`python3 tests/jev-merge-queue-batches.test.py` ran green in this session in
the worktree `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-7635`
(branch `claim/issue-7635`) after the `prompts/daily-digest.md` rewrite; the
host journal/timer/ledger probes above (netcup-rs2000, 2026-09-22) carry the
2026-09-18 failure snapshot, the 2026-09-20/21 recovered beats
(message_id 1607 / 1616), and the pending 2026-09-22 09:00 fire.

loose-ends: user-unit-escalation-gap — same-hour escalation for ordinary
user-scope units has not existed since `9f0cba02c` deleted
`systemd/service.d/10-escalate.conf` (the dispatcher that produced this
issue); filed with evidence as Nishfleet/fleet-ops#8161, not touched here.
deploy-lag — the retry text is live only after the merge's next `fleet-sync`
pull. stale-branch — a local
`fix/issue-7635-daily-digest-telegram-timeout` branch in the deploy clone is
inert residue from the 2026-09-18 attempt (no salvage commits on it);
untouched. judge-round-merge — #8162 merged 4m48s after the judge applied
`blocked-by-judge`, through the merge queue (the label has no teeth there);
this follow-up PR ships the finding-2 fixes to main, and the systemic
gap is filed with evidence as Nishfleet/fleet-ops#8163.
