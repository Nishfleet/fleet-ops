# Observe-close for #7029 — comeback-rebench record stranded by the organ's own deletion; replayed to the canonical terminal state by hand

fleet-ops#7029 is the unit-death dispatch for
`alert-repair-FleetSeatComebackNeverReleased-20260915T123645Z.service`,
which died on a connection error 14 s after start (tools=0, hop=2
exhausted) and never ran its job. The job it carried: resolve the seat
record(s) the `FleetSeatComebackNeverReleased` alert counted as owing a
comeback that never got released. Duplicate dispatches #7060 and #7087
died identically; gap-audit #7077 flagged the same class. The 2026-09-17
orchestrator sweeps held the issue open with "require a real release or
reasoned terminal record; no invented cooldowns, credit purchase or new
machinery" and assigned the older two-seat history check (#3101).

By the time this claim ran, the whole organ was retired and the record
it stranded was the only live residue. This run performed the terminal
transition by hand against the organ's own canonical record shapes; this
report is the resolution record, matching the established observe-close
pattern (the #6665 record, PR #7959; the #6799 record, PR #7968).

## What was found

1. **The stranded record was `cursor__kimi-k3-max`, stuck mid-rebench.**
   Live `lanes/seats/cursor__kimi-k3-max.json` before this run, verbatim:
   `{"health_class":"transient_fault","seat_dead":false,"observed_at":
   "2026-09-18T09:30:51Z","source":"comeback_release_rebench",
   "failure_mode":"comeback_rebench","usable_at":"2026-09-18T09:45:51Z",
   "bench_until":"2026-09-18T09:45:51Z","bench_window_s":900,
   "consecutive_failure_count":1,"writer":"rebench_seat"}`. It was the
   only record in the ledger carrying a `comeback_*` failure mode — the
   `never_released_total=1` the 2026-09-17 sweep saw.
2. **The mechanism that resolves a rebench was deleted while this record
   was in flight.** `571bf2098` ("chore(glue-sweep): delete seat-comeback
   / bench-truth (3008 lines)", ancestor of origin/main) deleted
   `bin/fleet-seat-comeback-release`, its service/timer, and the
   `FleetSeatComebackNeverReleased` alert rule. The organ's last action —
   this rebench write at 2026-09-18T09:30:51Z — is the same second
   `fleet-seat-bench-truth.service` failed exit 127 on the already-missing
   bin (`agent-state/STOP-REASON.json`, timestamp identical). The 15-min
   bench window expired 09:45:51Z; nothing was left to probe it.
3. **Every other piece of the lane is gone too, so a "real release" is
   impossible by architecture, not by seat health.**
   `seat-health.ts` (the ledger writer, `source=after_provider_response`)
   is no longer installed under `~/.pi/agent/extensions/` — it survives
   only in `~/.local/state/vps-maintenance/pi-extensions.bak/` and its
   README entry marks it replaced by LiteLLM's own
   `/health/readiness` + `litellm_deployment_state`. The reader
   (`lib/litellm-seat.sh`, `seat_usable`) was deleted in `9853ec72c`
   ("the router already does all of it"). The `cursor` provider is absent
   from `~/.pi/agent/models.json` and `models-store.json` (present in the
   2026-09-07 backup `models.json.pre-4234-...`, gone by
   `models.json.bak-ctx-20260919`), and `kimi-k3-max` was never a catalog
   model under it even when the provider existed — only `composer-2.5`
   and `cursor-grok-4.6-high` were. `litellm_deployment_state` exposes no
   cursor deployment. There is no fleet path left that could probe or
   serve this seat.
4. **The record was replayed to the organ's canonical terminal state by
   hand** (2026-09-20T19:19:02Z), preserving the organ's exact two-stage
   lifecycle that ~90 sibling records show:
   - corpse stage archived to
     `lanes/seats-corpse-retired-2026-09-20T19:19:02Z/cursor__kimi-k3-max.json`:
     `health_class=corpse`, `seat_dead=true`,
     `failure_mode=comeback_never_released` (the mode named for exactly
     this condition, fleet-ops#3156), `source=comeback_release_corpse`,
     `writer=corpse_seat`, `corpse_threshold=25`;
   - live ledger now carries the never-re-offer tombstone:
     `health_class=parked`, `failure_mode=corpse_retired`,
     `source=corpse_retirement`, `usable_at`/`bench_until` =
     2036-09-19T19:19:02Z (+3652 d, the sibling convention),
     `writer=write_parked_ledger`, `bench_reason` naming the strand cause
     and this issue.
   A post-write scan of `lanes/seats/*.json` finds **0** records in a
   `comeback_*`/`rebench` failure mode. No money/quota wall record was
   touched: the `quota_bench`/`quota_exhausted`/`money_boundary` and
   prior `corpse_retired` rows are unchanged.
5. **The older two-seat history (#3101, re-flagged by #7077) is verified
   closed.** `minimax__MiniMax-M3` (`comeback_never_released` corpse,
   c=25, 2026-09-03T10:30:53Z) was physically retired into
   `seats-corpse-retired-2026-09-03T16:45:53Z/` inside the 6 h grace;
   `opencode__nemotron-3-ultra-free` (c=25→26) was retired into
   `seats-corpse-retired-2026-09-03T19:30:36Z/` and again
   `2026-09-04T06:45:38Z/` after re-registration. Both later re-entered
   through real provider probes and sit `healthy` today (M3 http 200 at
   2026-09-14T11:12:29Z; nemotron-3-ultra-free http 200 at
   2026-09-12T02:11:12Z) — the release/corpse path worked end to end for
   them while the organ lived.
6. **The detector gap (#7077) is closed by the retirement itself.** The
   blind-audit "manual seam" existed because a live ledger could silently
   strand a `comeback_rebench` record with nothing watching. That class
   cannot recur: the only writer of rebench records is deleted, the
   ledger is dead state (no reader), and
   `tests/fleet-seat-comeback-release-retired.test.sh` (#7903) pins the
   organ's absence on main. A new detector would require reviving the
   machinery the sweep deliberately removed —
   `mechanism-impossible: the comeback-rebench writer, the ledger reader,
   and the alert rule are all retired on main; a stranded record can no
   longer be produced, and no hermetic test may read the live ledger
   (pinned by the #6264 tombstone).`
7. **Loose end observed, not touched:** `config/seat-caps.json` still
   carries `providers/cursor` (cap 2, `kimi-k3-max`/`kimi-k3-high` model
   caps) for a provider absent from the pi catalog — capacity accounting
   is a money-adjacent surface and out of this issue's scope; noted for
   the next roster pass.

## Verification

- `gh issue view 7029/7060/7087/7077/3101 -R Nishfleet/fleet-ops` →
  dispatch bodies, orchestrator hold, and the two named seats.
- Stranded record pre-state quoted above; post-state re-read from disk:
  `cat lanes/seats/cursor__kimi-k3-max.json` → `parked`/`corpse_retired`;
  `cat lanes/seats-corpse-retired-2026-09-20T19:19:02Z/cursor__kimi-k3-max.json`
  → `corpse`/`comeback_never_released`.
- Live-ledger scan (python over `lanes/seats/*.json`, this run) → 0
  records with `failure_mode` in `comeback_*` or `writer=rebench_seat`.
- `git merge-base --is-ancestor 571bf2098 origin/main` → yes (organ +
  alert rule deleted on main); `git ls-files | grep comeback` →
  historical records only; `git log -S FleetSeatComebackNeverReleased`
  → deleted in `571bf2098`.
- `ls ~/.local/bin/fleet-seat-comeback-release` → absent;
  `~/.config/systemd/user/` → no bench/comeback/recovery units;
  `systemctl --user list-units --state=failed` → empty;
  `systemctl --user list-timers` → no seat/comeback/bench timers.
- `~/.pi/agent/models.json` + `models-store.json` grep `cursor` → 0;
  `pi --list-models` provider column → no `cursor`; LiteLLM
  `litellm_deployment_state` → no cursor deployment.
- `cat ~/.local/state/fleet-seat-comeback-release.json` → organ journal
  frozen at `last_sweep=1789723831` (2026-09-18T09:30:31Z) with
  `cursor__kimi-k3-max.json` last_probe=1789723851 — its final write.

run-proof: host probes above ran live on netcup-rs2000
2026-09-20 ~19:19 UTC against origin/main `b20776708`; ledger edits are
the two record files named (verified by re-read); commit ancestry via
`git merge-base --is-ancestor`; unit/timer state via `systemctl --user`;
docs-only record — no unit, timer, workflow or script path touched.

loose-ends: seat-caps-cursor-roster — `config/seat-caps.json` still
rosters `providers/cursor` caps for a provider absent from the pi
catalog; money-adjacent, intentionally untouched, left for a roster pass.
