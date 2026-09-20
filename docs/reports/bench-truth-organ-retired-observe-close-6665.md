# Observe-close for #6665 — fleet-seat-bench-truth hot loop: trigger fix landed in #7559, then the whole organ retired in the glue sweep

fleet-ops#6665 (filed 2026-09-14) asked for the diagnosis and repair of a
hot loop in `fleet-seat-bench-truth`: the measure.sh unit-churn line
recorded 449 and 411 starts/h in two consecutive judge runs against a
200/h threshold, with the `.path` trigger on the seats-ledger directory
as the prime suspect. The accept bullets were: identify why the trigger
re-fires, fix the trigger class, pin a regression test under 200
starts/h, and quote a post-deploy `journalctl --since -1h | grep -c
Started` under 200.

By the time this claim ran, the loop had already been resolved on main
twice over — first by the trigger fix, then by the retirement of the
entire organ. No code change remains; this report is the resolution
record, matching the established observe-close pattern (the #6799
record, PR #7968; the #6499 record, PR #7965).

## What was found

1. **The trigger diagnosis and fix landed in PR #7559** (merged
   2026-09-17T21:04:37Z, squash merge commit `83cfad1c`,
   `git merge-base --is-ancestor` verified against origin/main
   `4a41ff5f8` and the deploy clone's installed HEAD). The diagnosis:
   `PathChanged` on the seats-ledger dir re-fired on the probe's own
   sweep writes; the bin-level 60s debounce bounded sweep *work* but not
   service *starts*. The fix added `ExecStartPost=/bin/sleep 30` to the
   oneshot, holding the unit activating after every sweep so path events
   coalesce — a hard bound of 121 starts/h, under the 200/h line. The
   storm-drill test was updated in the same PR to pin that bound and to
   make the live layer a read-only post-deploy proof.
2. **The organ was then deliberately retired on main.** `571bf2098`
   ("chore(glue-sweep): delete seat-comeback / bench-truth (3008 lines)",
   2026-09-18, ancestor of origin/main) deleted
   `bin/fleet-seat-comeback-release`, `systemd/fleet-seat-bench-truth.path`,
   `systemd/fleet-seat-bench-truth.service`,
   `systemd/fleet-seat-comeback-release.{service,timer}` and
   `systemd/fleet-seat-recovery.{path,service}` — replaced by LiteLLM's
   own router config (`cooldown_time`, `allowed_fails`, per-group
   fallbacks in `~/.config/fleet-ops/litellm-proxy.yaml`). The drill
   test `tests/fleet-seat-bench-truth-path-storm-drill.test.sh` was
   deleted separately by `9f0cba02c` ("chore(glue-sweep): delete
   escalation-tower", same sweep, ancestor of origin/main).
   `git ls-files` on main matches nothing for `bench-truth` or
   `comeback-release`.
3. **Installed version confirmed — the retirement is live, not just
   merged.** Deploy-clone HEAD `4a41ff5f8` contains both `83cfad1c` and
   `571bf2098`. On the live box at 2026-09-20 ~14:20 UTC:
   `systemctl --user cat fleet-seat-bench-truth.{service,path,timer}`
   reports "No files found"; `list-units --all 'fleet-seat-bench*'`
   loads 0 units; `journalctl --user -u fleet-seat-bench-truth.service
   --since -1h` has no entries at all; `~/.local/bin/
   fleet-seat-comeback-release` and `~/.config/systemd/user/` bench /
   comeback unit files are absent; `list-units --state=failed` is
   empty. The last live start attempt recorded in
   `agent-state/STOP-REASON.json` failed exit 127 at
   2026-09-18T09:30:51Z because the installed bin was already gone; the
   on-main deletion commit `571bf2098` carries committer time
   10:03:51Z.
4. **The literal proof bullet reads 0 — and is not claimed as the
   hold's effect.** `grep -c Started` over the unit's last hour is 0
   because the unit no longer exists. The retired test's own live layer
   said "never accept a zero count ... or an absent/inactive probe as a
   fix", and the judge's continuation ruled "never count a vanished
   unit as a fix". What makes this a resolution rather than a vanish:
   the absence is a deliberate, reviewed, on-main deletion with the
   replacement mechanism named in the commit (LiteLLM router cooldowns/
   retries), verified installed — not a crashed or silently dropped
   unit. The >200/h churn class is dead permanently because the
   triggering `.path` unit, the oneshot it fired, and the bin it ran
   are all gone by design. For the record, the in-life fix bound was
   121 starts/h (#7559) and the storm had already subsided before the
   merge — the PR's own comment recorded an 11 Starting-records/h
   pre-change baseline at 2026-09-17T20:45:12Z, versus the judge's
   223/h measurement at 2026-09-14T10:54Z.
5. **Why the issue kept being re-claimed.** PR #7559 carried a
   `Relates to` trailer — a MENTION under the fleet-ops#3231 delivery
   rules — so observe-to-close posted comment-only and the issue stayed
   open; fleet-ops#5045 recorded 17 re-claims since the merge and
   parked it under `awaiting-runtime-gate`. This PR's `Closes #6665`
   trailer performs the close through the merged-PR path — the same
   close path the 2026-09-18/19 cuts adopted once the observe-to-close
   sweep was retired (fleet-ops#7828).
6. **No live residue on main.** A repo-wide grep at `4a41ff5f8` for
   `bench-truth` / `seat-comeback` matches only historical records
   (`.pr-body-2415.md`, `archive/`, `config/seat-caps.json` comments,
   `docs/design/`, `reports/`) — no systemd unit, manifest entry, bin
   target, or test references the organ.

## Verification

- `gh pr view 7559 --json state,mergedAt,mergeCommit` → MERGED
  2026-09-17T21:04:37Z, mergeCommit `83cfad1c`.
- `git merge-base --is-ancestor 83cfad1c origin/main` → yes;
  `--is-ancestor 83cfad1c HEAD` on the deploy clone (`4a41ff5f8`) →
  yes (installed).
- `git merge-base --is-ancestor 571bf2098 origin/main` → yes;
  `9f0cba02c` → yes.
- `git ls-files | grep -E 'bench-truth|comeback-release'` on main →
  empty; `git show 571bf2098 --stat` → the unit/bin paths deleted;
  `git log --diff-filter=D -- tests/fleet-seat-bench-truth-path-storm-
  drill.test.sh` → `9f0cba02c`.
- Live, `XDG_RUNTIME_DIR=/run/user/1000` on netcup-rs2000 at
  2026-09-20 ~14:20 UTC: `systemctl --user cat fleet-seat-bench-
  truth.service` → "No files found"; `list-units --all
  'fleet-seat-bench*'` → 0 loaded; `journalctl --user -u fleet-seat-
  bench-truth.service --since -1h | grep -c Started` → 0 (journal for
  the unit holds no entries); `ls ~/.local/bin/fleet-seat-comeback-
  release` → absent; `ls ~/.config/systemd/user/` → no bench/comeback
  units; `systemctl --user list-units --state=failed` → empty.
- `STOP-REASON.json` → last unit failure exit 127 (bin missing) at
  2026-09-18T09:30:51Z, before the retirement commit's 10:03:51Z
  committer timestamp.

run-proof: probes above ran live on netcup-rs2000 2026-09-20 ~14:20 UTC
against origin/main `4a41ff5f8`; commit ancestry via `git merge-base
--is-ancestor`; PR state via `gh pr view 7559`; live unit state via
`systemctl --user` / `journalctl --user`; docs-only record — no unit,
timer, workflow or script path touched.

loose-ends: none — docs-only resolution record for work already landed
and retired on main; nothing half-done.
