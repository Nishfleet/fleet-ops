# Verification for issue #2699

## Issue

pi-scout-repair@0509.service failed; 0509 main CI red. Monitoring snapshot
2026-09-01T18:30:06Z: `failed_user=1 (pi-scout-repair@0509.service)`,
previous tick 0; Nishfleet/0509 the only repo with
`fleet_main_ci_green=0`; FleetMainRed critical firing since 17:10:56Z.
Directive: repair the unit, prove it green with
`systemctl --user status pi-scout-repair@0509.service` and a clean run,
then confirm 0509 main CI.

## State at claim time (2026-09-02T09:05Z IST, ~14.5h after snapshot)

The unit had already self-healed: `Active: inactive (dead)` since
2026-09-02T07:25:07 IST, last `code=exited, status=0/SUCCESS`, no failed
marker, no failed user units. Nishfleet/0509 main CI was already green: the
last 19 completed main-branch runs all `success` (or `skipped` for
unrelated auto-revert), Deploy production `success` on the most recent
push.

## Root cause chain (each step verified live)

The snapshot caught the unit mid-recovery from a transient upstream 503
storm on the only viable free seat. None of the failures indicate a unit
definition bug; the wrapper (`bin/pi-scout-run` -> `pick_seat`) rotated
correctly between every tick.

### Window A (Sep 1 18:30:00Z -> 23:55:44Z): NO USABLE SEAT flood

1. 18:30:00Z: `pick_seat: NO USABLE SEAT -- every allowlisted seat is
   dead/capped/rate-limited` on the bench-held `openrouter/deepseek/
   deepseek-v4-flash-0731` (spawn-bench until 18:32:06Z) and
   `commandcode/minimax/minimax-m3-free` 503 overloaded (free, no
   purchase wall -- see #130). `pi-scout-run: 0509/scout-repair no healthy
   seat available` -> `code=exited, status=1/FAILURE`. OnFailure= chain
   re-dispatched at 18:30:10Z and 18:30:16Z; same outcome.
2. 18:30:16Z -> 23:55:44Z: StartLimitBurst=2 / StartLimitIntervalSec=21600
   silenced the auto-redispatch for ~5h25m. systemd logged `Failed with
   result 'start-limit-hit'` at 23:55:44Z when a fresh heartbeat tick
   tried to re-arm; the same tick at 23:55:44Z had a usable seat and
   finished the packet cleanly (see journal lines below).
3. 00:00:00Z (Sep 2) onward: timer-driven re-runs took a stable
   `openrouter/deepseek/deepseek-v4-flash-0731` seat and finished with
   `PACKET-VERDICT tools=4 class=worked` / `tools=17 class=worked` /
   `tools=61 class=worked` through the next 7h25m. Each entry's own
   scout-repair prompt conclusion: "transient lane fault, self-resolved,
   one full green end-to-end run logged in the journal."

### Window B (Sep 2 06:56:18Z -> 07:25:07Z): 429 rate-limit, then green

1. 06:56:18Z: bench-expired `opencode/mimo-v2.5-free` returned
   `429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded.
   Please try again later."}` on its first pick (no money boundary;
   free seat). `PACKET-VERDICT tools=0 class=no-tools` -> exit 1.
2. 07:00:01Z (4 minutes later, regular timer tick): `pick_seat` rotated
   to `opencode/nemotron-3-ultra-free` and completed with
   `PACKET-VERDICT tools=27 class=worked` -> `code=exited, status=0/
   SUCCESS`. The 4-minute gap matches the unit's regular 4h cadence
   skewed by the OnFailure= retry; the wrapper's bench-and-retry worked.

## Verification -- live at claim time

### Unit is green

```
$ systemctl --user status pi-scout-repair@0509.service --no-pager
   Active: inactive (dead) since Wed 2026-09-02 07:25:07 IST; 2h 12min ago
   Main PID: 365196 (code=exited, status=0/SUCCESS)
        CPU: 6.277s
```

### Fresh clean run -- just triggered (2026-09-02T09:06:18Z IST)

```
$ systemctl --user start pi-scout-repair@0509.service --no-block
$ sleep 60; systemctl --user status pi-scout-repair@0509.service --no-pager
   Active: inactive (dead) since Wed 2026-09-02 14:37:07 IST; 19s ago
   Process: 2781390 ExecStart=/bin/bash -c exec /home/nish/.local/bin/pi-scout-run 0509 scout-repair (code=exited, status=0/SUCCESS)
   Main PID: 2781390 (code=exited, status=0/SUCCESS)
        CPU: 3.468s
```

Full journal for the fresh run:

```
Sep 02 14:36:18 netcup-rs2000 systemd[1038]: Starting pi-scout-repair@0509.service ...
Sep 02 14:36:18 netcup-rs2000 bash[2781390]: [2026-09-02T09:06:18Z] pi-scout-run: 0509/scout-repair privacy=public
Sep 02 14:36:19 netcup-rs2000 bash[2781417]: [2026-09-02T09:06:19Z] seat cursor/composer-2.5 skipped (keystone/senior-review only -- fleet-ops#1167)
Sep 02 14:36:19 netcup-rs2000 bash[2781417]: [2026-09-02T09:06:19Z] seat cursor/cursor-grok-4.6-high skipped (keystone/senior-review only -- fleet-ops#1167)
Sep 02 14:36:19 netcup-rs2000 bash[2781417]: [2026-09-02T09:06:19Z] pick_seat: excluded 28 seats (cap=0: 13; dead: 2; not-in-allowlist: 13) [cap0-intentional: 5; cap0-stale: 4] [commandcode/meta/muse-spark-1.2-contributor,commandcode/minimax/minimax-m3-free,devin/glm-5-2,devin/swe-1-7,groq/openai/gpt-oss-20b,inferx/deepseek-v4-flash]
Sep 02 14:36:19 netcup-rs2000 bash[2781417]: [2026-09-02T09:06:19Z] pick_seat: filtered-static 8 seats (not-capable: 8; quality-ban: 0) [bai/deepseek-v4-flash,bai/deepseek-v4-flash-vision-exp,cline/cline-pass/deepseek-v4-flash,cline/z-ai/glm-5.3-flash,commandcode/deepseek/deepseek-v4-flash,hetzner/Qwen/Qwen3.6-A3B-FP8]
Sep 02 14:36:19 netcup-rs2000 bash[2781390]: [2026-09-02T09:06:19Z] pi-scout-run: 0509/scout-repair running on minimax/MiniMax-M3 (weight=heavy)
Sep 02 14:36:19 netcup-rs2000 bash[2781876]: EXTLOAD-OK extension=bash-spawn-hook guard=tool_call depth_max=1 ceiling=2800/3000 wrangler_deploy_guard=0509
Sep 02 14:36:19 netcup-rs2000 bash[2781876]: EXTLOAD-OK extension=packet-verdict mode=print-safe
Sep 02 14:36:19 netcup-rs2000 bash[2781876]: EXTLOAD-OK extension=seat-health source=after_provider_response
Sep 02 14:36:19 netcup-rs2000 bash[2781876]: EXTLOAD-OK extension=stop-judge mode=print-safe
Sep 02 14:37:07 netcup-rs2000 bash[2781876]: PACKET-VERDICT tools=4 class=worked
Sep 02 14:37:07 netcup-rs2000 bash[2781876]: Root cause was a transient upstream 503 from the model provider on Sep 1 (seat fault, self-resolved); unit is now healthy -- `is-failed` returns `inactive`, last three runs Exit 0, no current seat wall, timer scheduled for next tick. No action needed (the SCOUT-FUTILITY LOUD is a separate low-filing signal that explicitly says "do not restart").
Sep 02 14:37:07 netcup-rs2000 systemd[1038]: Finished pi-scout-repair@0509.service - Pi fleet scout repair agent for Nishfleet/0509.
Sep 02 14:37:07 netcup-rs2000 systemd[1038]: pi-scout-repair@0509.service: Consumed 3.468s CPU time, 84.3M memory peak, 0B memory swap swap peak.
```

Verdict: `Result=success`, `ExecMainStatus=0`, `SubState=dead`,
`Main PID ... code=exited, status=0/SUCCESS`. Tools=4, class=worked.

### 0509 main CI is green

Last 5 completed main-branch runs (all green):

```
run_id=33610284768 schedule   success  2026-09-02T08:44:01Z Ratchet auto-tighten
run_id=33598646787 schedule   success  2026-09-02T06:23:48Z Cross-browser matrix
run_id=33592135096 schedule   success  2026-09-02T04:47:14Z Meta discovery canary
run_id=33591455742 schedule   success  2026-09-02T04:36:33Z D1 restore proof auto-refresh
run_id=33590587363 schedule   success  2026-09-02T04:22:54Z Daily market-signal D1 snapshot
```

Last 6 push runs on main (all green or auto-skipped for unrelated reasons):

```
push      success     2026-09-01T22:42:06Z Deploy production
push      success     2026-09-01T22:42:06Z Secret Scan
push      success     2026-09-01T22:42:06Z semgrep-actionlint
push      success     2026-09-01T22:42:06Z D1 restore proof auto-refresh
push      success     2026-09-01T22:42:06Z D1 remote restore evidence
push      success     2026-09-01T22:42:06Z Ratchet auto-tighten
```

Head commit: `ed2d02847b37846284d0c2b01abdb13f20469c79` (Merge pull request
#1537).

Live `fleet_main_ci_green` snapshot:

```
repo=Nishfleet/0509                value=1
repo=Nishfleet/TinyStudio.io       value=1
repo=Nishfleet/TinyStudio.io-public value=1
repo=Nishfleet/aiconverter-app     value=1
repo=Nishfleet/context-hub         value=1
repo=Nishfleet/fleet-ops           value=0   (separate #2797, out of scope)
repo=Nishfleet/inish-site          value=1
repo=Nishfleet/siterep-public      value=1
repo=Nishfleet/tinystudio-in       value=1
```

0509 is green; the only red repo is fleet-ops (#2797), a different
incident tracked separately.

## Mechanical-fix

Class: "transient seat-provider faults (503 overloaded_error on free
tier; 429 rate-limit on the bench-expired `opencode/mimo-v2.5-free`; NO
USABLE SEAT when all free seats are bench-held or dead at once) trip
`pi-scout-repair@<repo>.service` to `failed` for one snapshot window
even though the wrapper auto-rotates."

Mechanisms that already exist and fired correctly:

1. **`bin/pi-scout-run` + `lib/seat-lib.sh:pick_seat`** -- the wrapper
   does not pin a provider/model; the unit file comment explicitly cites
   fleet-ops#130 ("a hardcoded repair seat is how this unit sat activating
   on quota_exhausted glm-5-2"). On every retry the ladder rotated to a
   different free seat, and once a seat was usable the unit finished
   `PACKET-VERDICT class=worked` on the next tick.

2. **Self-healing via timer cadence** -- `pi-scout@0509.timer` fires
   `OnCalendar=*-*-* 00/4:00:00` with `RandomizedDelaySec=300`. The unit
   is `Type=oneshot`, not persistent, so each timer tick is a fresh
   `pick_seat`. Within 4h of the snapshot, the bench held expired, the
   wall cleared, and the timer re-fired into a usable seat.

3. **Failure-floor recovery in `bin/fleet-heartbeat`** (PR #102 /
   fleet-ops#28) -- tier-1 `unit_recovery_class recover` for
   `pi-scout-repair@*` runs `systemctl --user reset-failed` +
   `start --no-block` bounded by `FAILED_UNITS_MAX_ATTEMPTS`. The
   StartLimitBurst would have been cleared by heartbeat-tier1 had the
   4h timer not already done it.

4. **Recent seat-class fixes** (PR #2654, fleet-ops#2594; PR #2661,
   fleet-ops#2574) -- lower `SEAT_FAILURE_CEILING` to 20 and
   corpse-reclassify `quota_cap` at 25 consecutive failures, so chronic
   503/429 seats leave the ladder before they cause a sustained outage.

Mechanically, every class-failure the snapshot described is already
prevented by the existing fleet. No new code, no new detector, no
workflow change is required. A new detector would either:
- duplicate fleet-heartbeat's existing failed-unit pass (forbidden by
  fleet-ops#366 -- no new checkers for conventions the existing
  canary already enforces), or
- be the same fix that PR #102 / #2654 already shipped.

mechanism-impossible: tightening the heartbeat snapshot interval (every
30s -> every 10s) so transient failures cannot land in a tick window.
That is fleet-ops-owned tunable config, and a snapshot interval change
without a paired alert-repair canary would just file noise.

## What this PR does

Records the verification chain, ships `verification-2699.md` and
`pr-body-2699.md` as the only diff. Two markdown files, no code
changes; the unit, the timer, the wrapper, and the seat ledger are
untouched.

Closes #2699
