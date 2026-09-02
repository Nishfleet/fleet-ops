Sweep of the latent dispatch-ledger fixture rows left by the alert-repair class-park drill (blind audit 2026-09-01 finding #6, FINDINGS-QUEUE.md "Still open — three follow-ups" #2). PR #2660 stopped the class-park test spawning real repair workers; the ledger rows it left behind stayed `status:"open"` — a recurrence vector for the phantom-alert amplification loop if the ledger is ever re-scanned raw.

## What changed

- `bin/dispatch-ledger-fixture-sweep` (one-shot): marks EVERY dispatch-ledger row carrying a fixture alertname (`NoClassParkAlert|ClassExpiredAlert|NoParkKeyAlert` — the fixture names live in the `unit`/`packet_path` fields, e.g. `alert-repair-NoClassParkAlert-<ts>`; the ledger has no separate `alertname` key) as `terminal=true` with `terminal_reason="fixture_alertname_no_prometheus_rule"` (+ `terminal_ts`). Open AND already-closed rows are marked, so the raw-line count of `terminal != true` for these alertnames drops to zero.
  - Pre-sweep `cp` backup (rollback = restore the copy, per the issue's rollback section).
  - In-place rewrite, no appended lines — the completion-canary's `load_dispatch_latest` keeps the last line per id, so appending terminal lines would make the (still `status:"open"`) terminal record the latest and could itself trigger re-dispatch.
  - `status` is untouched (terminal marks done; pairing/intent unchanged).
  - Idempotent: a re-run marks nothing new and exits 0. Malformed lines survive untouched.
- `tests/dispatch-ledger-fixture-sweep.test.sh` (hermetic, fully offline): before sweep 3+ open fixture rows exist; after sweep zero open fixture rows for those alertnames; every fixture row carries terminal + reason + ts; non-fixture rows byte-identical; `status` untouched; pre-sweep backup present; idempotent re-run marks nothing; a malformed line survives and the ledger is not truncated.

mechanism: regression drill `tests/dispatch-ledger-fixture-sweep.test.sh` proves the guard fires (before ≥3 open fixture rows → after 0), and the one-shot sweep is re-runnable whenever the leak class reappears. Discovered adjacent gap (filed, not fixed here — out of this issue's scope): the completion-canary dispatch plane filters open rows on `status == "open"` only and ignores `terminal`, so an unpaired future fixture row would still be re-dispatched — Nishfleet/fleet-ops#2872.

## Verification

Hermetic test:
```
bash tests/dispatch-ledger-fixture-sweep.test.sh
ALL PASS
```
(expect: before open-fixture=5 status-open=4; after open-fixture(terminal!=true)=0; idempotent re-run marked=0; malformed line survives.)

Adjacent suites (unchanged code, proving no blast radius on the ledger readers):
```
bash tests/fleet-completion-canary.test.sh        # OK
bash tests/pi-systemd-run.test.sh                 # OK
bash tests/fleet-worktree-reaper.test.sh          # OK
bash tests/pi-salvage-worktree.test.sh            # OK
bash tests/alert-repair-class-park-skip.test.sh   # 4/4 OK
```

Live sweep (real ledger, pre-sweep cp backup at `dispatch-ledger.jsonl.sweep-backup-20260902T173849Z`):
```
$ bash bin/dispatch-ledger-fixture-sweep
backup: /home/nish/workspaces/agent-state/dispatch-ledger.jsonl.sweep-backup-20260902T173849Z
fixture_rows=220 marked=220 already_terminal=0 malformed_skipped=0
```
issue metric before/after (adapted to the real schema — the issue's literal jq used a non-existent `.alertname` key; the fixture names live in `unit`/`packet_path`):
```
before: jq -c 'select((.unit // .packet_path // "") | test("alert-repair-(NoClassParkAlert|ClassExpiredAlert|NoParkKeyAlert)-")) | select(.terminal != true)' dispatch-ledger.jsonl | wc -l   # 220
after:  # 0
```
Ledger intact: 745 lines before and after. Canary-visible open rows unchanged (1 real `alert-repair-FleetDeadCredentialSeats-*` dispatch; zero fixture rows). Idempotent re-run: `marked=0 already_terminal=220`.

run-proof: transcript above — live one-shot sweep on `/home/nish/workspaces/agent-state/dispatch-ledger.jsonl` (220 fixture rows marked, 745 lines preserved), hermetic test ALL PASS, adjacent suites green.

research: last30days — last-30-days git log + `gh issue search` sweep of this repo for prior dispatch-ledger sweep/terminal tooling (PR #2660, #2694/#2796, the class-park drill lineage) plus a live read of the ledger shape, the completion-canary's `load_dispatch_latest`/`classify_dispatch`/`close_dispatch_entry` and actions.log receipts — compared (a) in-place row rewrite via jq (would mangle key order / duplicate-terminal tracking across 745 lines; the ledger's own writers use compact python json), (b) an appended terminal line per row (rejected: would change the canary's last-per-id resolution and could itself trigger re-dispatch), (c) the existing `fleet-completion-canary` dispatch-plane close path (rejects: it classifies/redispatch-closes live rows, not marks fixture rows terminal; and the canary ignores terminal entirely, filed as #2872). Adopted (a)-style in-place rewrite implemented in python3 matching the ledger's own compact `json.dumps(separators=(",", ":"))` format; no new machinery — one-shot cleanup script + regression test.

help-first: read `jq --help` (v1.7) and the completion-canary's `load_dispatch_latest`/`close_dispatch_entry`/`classify_dispatch` — jq can filter but has no in-place JSONL row rewrite primitive, and no existing bin/ marks terminal on dispatch-ledger rows; hand-built the 50-line bash+python3 wrapper because nothing existing does this specific in-place terminal marking.

organ-heartbeat: bin/dispatch-ledger-fixture-sweep not-an-organ: one-shot cleanup script (no timer, no metric export, no guard loop — run explicitly or from the termination cue; no heartbeat to export). No organ registry/rules changes.

Note: the new test is standalone; it is not added to the CI verify-command list because `.github/workflows/**` is a gate-owned path this worker token cannot touch (separate concern; the test is run here and by any future sweep).

Closes #2768