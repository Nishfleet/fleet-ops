# Observe-close for #7399 — stop-judge site deleted in the glue sweep; no shadow target remains

Issue #7399 (filed 2026-09-17) asked for a Jev shadow inside the Pi
`stop-judge` extension: 7 Jev booleans shadowing the regex verdict behind
an off-by-default flag, the four logged false positives as the acceptance
test, a per-turn JSONL shadow log, and `docs/jev-stop-judge-2026-09.md` as
the termination report. The binding packet constraints were posted
2026-09-18T15:26Z (plan item T8).

By the time this claim ran (2026-09-22), the site itself no longer exists.
`stop-judge.ts` was deleted in the 2026-09-18 glue sweep — three hours
after the T8 constraints landed — and its id is on the extension ban
list: "stop policy the fleet no longer wants". A banned id reappearing as
a live `.ts` or package is a gate fail. No per-turn settle/continue
judgment exists anywhere in the fleet to shadow, so the packet cannot be
implemented as specified; this report is the resolution record.

## What was found

1. **The extension is deleted and banned.** `7c2b2beac`
   ("cut(extensions): delete 2,663 lines of pi extensions; stock forks +
   systemd carry the rest", 2026-09-18 23:57 IST) removed it;
   `template/extensions/README.md` on origin/main records
   `stop-judge.ts | 404 | nothing — a stop policy the fleet no longer
   wants`. `config/pi-extensions-allowlist.json` carries it under
   `banned` (added by `ace144a83`): "deleted-20260918-glue-sweep
   (7c2b2beac): stop policy the fleet no longer wants". Both commits are
   ancestors of origin/main `b82640a98` (`git merge-base --is-ancestor`
   passes for each). Live check 2026-09-22 ~02:15 IST:
   `~/.pi/agent/extensions/` holds no `stop-judge.ts`, and
   `~/.pi/agent/settings.json` carries no `stop-judge` reference. The
   only remnant is
   `~/.local/state/vps-maintenance/pi-extensions.bak/stop-judge.ts`
   (allowlist: ".bak ... files are not live").
2. **The baseline it would shadow is gone — and was never an LLM call.**
   The issue title says "replace its per-turn LLM 'done/stuck?' call"; the
   orchestrator DEP (2026-09-17T21:55Z) already ruled the real classifier
   was deterministic at `agent_settled` with zero baseline judge tokens.
   The `.bak` copy confirms it: `classifyEnding()` is 50 regex literals
   (27 offer phrases, 7 plan phrases, 7 boundary patterns, 9 refusal
   patterns) returning settle/continue and injecting "Continue with the
   obvious next step; do not wait for approval." via `pi.sendUserMessage`
   under three circuit breakers. No model was ever invoked per turn; the
   saving the issue prices was zero tokens at baseline. Post-sweep there
   is no regex verdict left — T8's "shadow against the regex verdict" has
   no second term.
3. **No surviving organ makes the equivalent call.** `git grep` for
   `classifyEnding`/`agent_settled` over origin/main hits only docs,
   config and bench files; nothing evaluates settle-vs-continue at run
   end. A settled worker's run simply ends — the dead-man is systemd
   `RuntimeMaxSec` plus the `pi-issue@` `ExecStopPost` artifact check.
   The #7392 precedent (the advisory tier rides inside the surviving
   organ that makes the call, #8105/#8107) does not apply: here the organ
   and the policy were deleted together.
4. **The tracked-source dependency is open but moot for this site.** The
   2026-09-17 DEP parked implementation on #6887 (adopt unversioned box
   plumbing) after #7462 (inventory); both remain open. The sweep moved
   the site past "untracked" to banned — even a landed #6887 would not
   make a banned id shippable.
5. **The acceptance test's subjects are gone.** The "four logged false
   positives" live in the deleted file's own comments: fleet-ops-1081
   (refusal misread as proposal, 2026-09-07), 0509-1538 (inanimate
   "waiting for the build" + polysemous boundary tokens, 2026-09-10), the
   bare `wipe`/`purge`/`truncate` completion-report FP, and the
   boundary-on-asking false-positive storm fix. Its fail-loud channel
   (`agent-state/STOP-REASON.json`) is write-only per trip — the last
   record is `unit-escalation`, 2026-09-18T09:30:51Z — so no durable
   per-decision JSONL exists to replay.

## Reconciled against the packet

- *7 Jev booleans shadowing the regex verdict*: impossible — the regex
  verdict is deleted.
- *Flag-gated shadow, OFF by default*: nothing to gate into; the id may
  not reappear as a live extension.
- *Four named false positives resolved by Jev*: cannot run — classifier
  and log are deleted; the real FP ids are recorded above.
- *200 real shadow turns + agreement rate*: cannot be produced — no site
  emits rows.
- *Register the site with #7754*: nothing to register; #7754 scores
  shadow sites that emit JSONL rows, and this site emits none.
- *`docs/jev-stop-judge-2026-09.md`*: this report is that record, filed
  under `docs/reports/` per convention.

## Residual path

If the fleet wants a Jev settle/continue judgment, it is a NEW organ —
Nish's explicit yes is required before one is built (no-glue rule), it
cannot reuse the banned `stop-judge` id, and it would reintroduce a
continuation policy the fleet deliberately removed. Nothing here claims
that judgment is wanted; the newest authoritative act on the site is its
deletion.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention.
