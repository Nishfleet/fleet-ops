# Silent-stderr evidence-path mechanism match for #6499

Issue #6499 was filed after the 2026-09-14 ~00:20 IST incident:
`fleet-litellm-proxy.service` hung, was SIGKILLed, and the ~47 s restart
window made `pi` exit 1 with nothing on stdout or stderr. Inside
`bin/pi-scout-run`, `run_seated_pi` captured stderr to a mktemp and emitted
`[pi-seated-err]` lines only when the capture was non-empty, so the empty
case reached the journal as a bare exit 1 and `scout-futility-check`
misclassified a provider-wall crash as "not green, not provider-wall". The
issue asked for:

- (a) silent-stderr variant: on `rc != 0` with empty stderr, lift the newest
  session jsonl's last `errorMessage`/`stopReason` into the journal through
  `[pi-seated-err]`;
- (b) worked-run variant: a successful run whose top-level session stamped
  `PACKET-VERDICT tools=0 class=no-tools` — the stamp should reflect real
  tool count or name the working session;
- (c) regression: keep the non-empty-stderr emit path.

The match is the 2026-09-18 sweep: every organ the fix would touch is
deleted. No new code is needed — the failure mode cannot reproduce in the
form described.

## Mechanism

- `bin/pi-scout-run` (197 lines; `run_seated_pi` ran
  `"$PI_BIN" --print ... 2> "$err_tmp"` and emitted
  `tail -n 5 "$err_tmp" | sed 's/^/[pi-seated-err] /'` only under
  `[[ -s "$err_tmp" ]]` — the exact empty-stderr hole) — deleted by
  ca33faa96 `refactor(rail): the unit IS the worker — collapse
  intake/worker/scout to pi --print`, merged 2026-09-18.
  `systemd/pi-scout@.service` now pipes `prompts/scout.md` into
  `pi --print` directly; pi's stdout and stderr both reach the journal
  unfiltered.
- `bin/scout-futility-check` (1,042 lines — the journal-grep classifier the
  `[pi-seated-err]` channel existed to feed) — deleted by fa2f27bf9
  `chore(second-cut-A): delete the fleet self-watching organs`, merged
  2026-09-18. `systemd/pi-scout-repair@.service` records it: "No on-exit
  futility classifier remains."
- `packet-verdict.ts` (89 lines — the `tools=0 class=no-tools` stamper of
  accept-b) and `stop-judge.ts` — deleted by 7c2b2beac `cut(extensions):
  delete 2,663 lines of pi extensions`. `config/pi-extensions-allowlist.json`
  carries both under `banned` (`deleted-20260918-glue-sweep`);
  `~/.pi/agent/extensions/` on the live host holds neither. Verdict parsing
  was replaced by the ExecStopPost artifact check in `pi-issue@.service`
  (claim/issue-<N> branch or a PR from it must exist), which judges a
  artifact, not a tool count.
- `lib/guard_pi_packet.py` — deleted by 6fee069b6 `cut(no-glue 3)`; only
  stale-directory copies and a `__pycache__` .pyc remain.

## Why the failure mode cannot reproduce

- **(a) silent-stderr:** there is no wrapper left to swallow stderr — pi's
  own streams go straight to the journal. Post-cut proof: `pi-scout@0509`
  exited 1 at 2026-09-19 08:06 IST and the journal carries pi's printed
  `429: {"message":"No deployments available for selected model, ...
  cooldown_list=[...]","code":"429"}` — the exact provider-wall signature
  the old channel existed to deliver. When pi prints nothing, the session
  jsonl under `--session-dir` (`~/.pi/agent/sessions/pi-scout-%i/`) still
  records every error turn — verified in
  `2026-09-19T14-31-51-740Z_01a0ba14-aabb-76bd-bf0d-7a0c4d8a0378.jsonl` (7
  assistant turns with `stopReason=error`, `errorMessage=429: {...}`). The
  consumer that misclassified empty-journal exits is gone with the wrapper;
  the OnFailure hop (`pi-scout-repair@%i`) is a full pi agent that can read
  the session dir itself, not a signature grep.
- **(b) worked-run tools=0:** the extension that stamped the bad verdict is
  deleted. Nothing stamps `PACKET-VERDICT` on pi runs anymore; worker
  success is judged by the artifact check, which cannot misread a worked
  run as no-tools. The three 2026-09-20 `pi-scout@0509` ticks (08:16 /
  12:01 / 16:03 IST) all exited 0 with full run summaries in the journal —
  filed Nishfleet/0509#3802, #3803, #3814, #3815 — observable directly.
- **(c) regression:** the `[pi-seated-err]` channel is gone with the
  wrapper; there is no partial-emit path left to regress.

## Prior work on this issue

Claimed 5x between 2026-09-13 and 2026-09-20; every prior claim released
with no PR (StartLimitBurst on the already-cut surfaces, then parked
`awaiting-runtime-gate` by fleet-ops#5048 on 2026-09-14). No
`wip(salvage)` commits exist for this issue
(`git log --all --grep='wip(salvage)'` shows none for 6499);
`origin/claim/issue-6499` was reset to `origin/main` on the
2026-09-20T12:03:46Z re-claim.

## Verification

On 2026-09-20, at `origin/main` 1e74a467f:

- `git merge-base --is-ancestor` confirms ca33faa96, fa2f27bf9, 7c2b2beac
  and 6fee069b6 are ancestors of `origin/main`.
- `git grep 'pi-seated-err\|run_seated_pi\|scout-futility\|guard_pi_packet'
  origin/main -- bin lib systemd config prompts template` returns only
  deletion-recording comments and `banned` allowlist rows; the one stale
  attribution line in `template/cursor-rules/fleet-packet-verdict.mdc` is
  corrected in this PR.
- Live host: `~/.local/bin/pi-scout-run` absent; live
  `~/.config/systemd/user/pi-scout@.service` identical to the repo file;
  `~/.pi/agent/extensions/` holds no packet-verdict or stop-judge.
- Journal: the three 2026-09-20 `pi-scout@0509` ticks above, plus the
  2026-09-19 08:06 failure carrying the 429 body.
- Live-state caveat observed this run (outside this issue's scope):
  `cursor-issue@0509-3786` and `cursor-issue@fleet-ops-6793` sit failed on
  `ActionRequiredError: You're out of usage` — Cursor-lane quota
  exhaustion, a seat/billing wall, not a code defect.

## Disposition

Match #6499 to the sweep deletions ca33faa96 / fa2f27bf9 / 7c2b2beac /
6fee069b6. The spec-gate `termination` was written 2026-09-13, before the
sweep, and names a PR touching `bin/pi-scout-run` — that file no longer
exists; the intent (the silent-stderr evidence gap durably closed) is met
because the gap lived only inside the deleted wrapper-plus-classifier
pair. The `metric` names `class=worked` verdict stamps that no longer
exist on any lane; the observable it protected — whether a scout tick did
real work — is read straight from the journal, which now carries pi's
full output. This report supplies the resolution record, not a repair.
