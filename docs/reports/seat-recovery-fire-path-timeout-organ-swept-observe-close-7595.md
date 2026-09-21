# Observe-close for #7595 — fleet-seat-recovery.service died inside its own fire path; the organ is deleted on main and uninstalled on the host

fleet-ops#7595 is the unit-death dispatch (fleet-ops#5456 A(ii)) for
`fleet-seat-recovery.service`, which died `Result=timeout` at
2026-09-18T04:21:49+05:30 — SIGTERM at `TimeoutStartSec=60`, exactly 60 s
after logging its one real action. The dispatch asks the claim to "diagnose
from the journal, redo the work, and land it". This run diagnosed the death
from the deleted organ's own source, verified the organ's removal is the
durable fix, and records why nothing remains to redo. Same convention as the
#7029 and #7553 observe-closes.

## What was found

1. **The unit died doing the one thing it existed for.** The dispatch body's
   captured journal (the 2026-09-18 window is vacuumed locally — two
   `journalctl --since` probes return no entries — so the issue body is the
   surviving record):

   ```
   04:20:49 [fleet-seat-recovery] ledger verdict: last=no-usable cur=usable
   04:20:49 [fleet-seat-recovery] SEAT-RECOVERY: NO-USABLE-SEAT -> usable — firing intake instantly
   04:21:49 fleet-seat-recovery.service: start operation timed out. Terminating.
   04:21:49 fleet-seat-recovery.service: Main process exited, code=killed, status=15/TERM
   04:21:49 fleet-seat-recovery.service: Failed with result 'timeout'.
   04:21:49 fleet-seat-recovery.service: Triggering OnFailure= dependencies.
   ```

   Exactly 60 s from the fire line to the kill — `TimeoutStartSec=60`, not a
   stall in detection. The verdict, persist (`printf > $STATE`, line 167 of
   the deleted bin) and edge detection all completed; the kill landed inside
   the fire.

2. **The hang was structural — the fire path was synchronous.**
   `bin/fleet-seat-recovery` (deleted copy read from `571bf2098^`) fired with:

   ```bash
   if "$SYSTEMCTL" --user start "pi-intake@$repo.service" 2>/dev/null; then
   ```

   `systemctl start` on a `Type=oneshot` unit blocks until that unit's
   ExecStart finishes, and `pi-intake@<repo>.service` is a whole Pi intake
   session — minutes, against this unit's 60 s start budget. The first
   `enrolled_repos` entry alone (0509 per `config/intake-repos.json`) was
   guaranteed to outlive it. Every earlier defence guarded the *watch* path —
   the StartLimit wedge (#617), the 2478-starts/h trigger storm and debounce
   (#5024), the sentinel-only trigger (#5093), ledger write suppression
   (#5096), the .path trigger-limit trap (#5106) — while the fire path kept
   a blocking `systemctl start` under a 60 s ceiling. The non-fire runs in
   the same journal exited in milliseconds (`debounce: ... skip scan`,
   `nothing to fire`); the unit was only ever killed when it had real work.

3. **The organ was deleted ~11 h after the death, on purpose.**
   `571bf2098` ("chore(glue-sweep): delete seat-comeback / bench-truth (3008
   lines, Jev 0.79)", verified `git merge-base --is-ancestor 571bf2098
   origin/main` this run) removed `bin/fleet-seat-recovery` (199 lines),
   `systemd/fleet-seat-recovery.service` + `.path`, the comeback-release
   bin/service/timer, the bench-truth path/service, six meta-alerts and the
   exporter gauges that existed only to grade the organ. Its stated
   replacement is LiteLLM's own router: live
   `~/.config/fleet-ops/litellm-proxy.yaml` carries `cooldown_time: 60`,
   `allowed_fails: 1`, `num_retries: 0`, `allowed_fails_policy:` and
   per-group `fallbacks:` — a NO-USABLE-SEAT window is now absorbed and
   recovered inside the proxy, not by a shell bin racing a start timeout.

4. **The host is verified clean.** `systemctl --user cat
   fleet-seat-recovery.service` → "No files found"; `systemctl --user
   list-unit-files | grep -i 'seat|recovery'` → zero rows;
   `ls ~/.local/bin/fleet-seat-recovery` → absent; `systemctl --user
   list-timers` → no seat/recovery entries. There is no unit to start, so
   this death cannot recur.

5. **The residue is inert dead state, not a live trigger.**
   `agent-state/lanes/seats/.no-usable-seat` (7 B, content `usable`, mtime
   2026-09-18 16:22 IST) is a sentinel nothing watches — the `.path` unit is
   deleted and its writer `bin/pi-issue-run` is gone too (`git ls-files
   bin/` on this branch: only am-executor-claim, fleet-claim-release,
   fleet-litellm-key, fleet-silent-pr-close-check, pi-intake-trigger).
   `/run/user/1000/fleet-seat-recovery.state` reads `usable 1789715296`
   (2026-09-18T07:08:16Z = 12:38 IST) — a write *after* the 04:21 death,
   i.e. the unit ran once more cleanly before the sweep removed it,
   confirming the verdict path was healthy and only the fire path was
   lethal.

6. **"Redo the work" is already satisfied by the surviving cadence.** The
   dying run's payload was an instant `pi-intake` start on a recovery edge —
   a few minutes' head start on a tick that runs on its own ~5-min timer
   plus the `pi-intake-trigger.path` file trigger. This run observed 66
   `Starting pi-intake` lines in today's journal alone, the router readiness
   endpoint reports `{"status":"healthy","db":"connected"}`, and every raw
   `litellm_deployment_state` row is `0.0` (the `2.0` rows are the
   `worker-cheap`/`worker-capable`/`senior` synthetic-alias gauges that flip
   with each 60 s cooldown — their `model_id` fields name the aliased
   group). The fleet has had four days of healthy intake ticks since the
   lost fire; there is no stranded work to replay.

7. **No new detector is shipped — the mechanism is the deletion.** The
   mechanical-fix bar is met by the sweep itself: the failure class (this
   unit's blocking fire under `TimeoutStartSec`) no longer exists on main or
   on the host, and the unit-death dispatcher (fleet-ops#5456 A(ii)) already
   demonstrated detection by producing this issue. A regression test for "a
   deleted unit cannot hang" would re-create machinery the sweep
   deliberately removed — `mechanism-impossible: the organ, its trigger,
   its writer and its watchers are all deleted on main and uninstalled on
   the host; the surviving intake timers own the work the fire existed to
   accelerate`.

8. **Loose end observed, not touched:** `systemd/pi-intake-trigger.service:4`
   still comments "seat-recovery already fires pi-intake directly" — a stale
   reference to the deleted organ, same family as the #7885 catalog drift.
   A comment-only edit to a deployed unit file was not worth fleet-sync
   drift inside this docs record.

## Verification

- `gh issue view 7595 -R Nishfleet/fleet-ops --comments` → dispatch body with
  the captured journal quoted above; ~10 prior claim/release cycles by
  `pi-issue-fleet-ops-7595`, each released "no live worker, no open PR".
- `git show 571bf2098^:bin/fleet-seat-recovery` → the synchronous
  `systemctl --user start "pi-intake@$repo.service"` fire line quoted above;
  `git show 571bf2098^:systemd/fleet-seat-recovery.service` →
  `Type=oneshot`, `TimeoutStartSec=60`.
- `git merge-base --is-ancestor 571bf2098 origin/main` → exit 0 (organ
  deleted on main); `git ls-files | grep seat-recovery` → no live paths.
- Host probes this run (2026-09-22 ~04:3x IST, netcup-rs2000):
  `systemctl --user cat fleet-seat-recovery.service` → "No files found";
  `list-unit-files | grep seat|recovery` → empty; `list-timers` → none;
  `ls ~/.local/bin/fleet-seat-recovery` → ENOENT.
- Router: `curl -s 127.0.0.1:4000/health/readiness` → healthy;
  `litellm_deployment_state` raw-model rows all `0.0`; live
  `litellm-proxy.yaml` grep → `cooldown_time: 60`, `allowed_fails: 1`,
  `num_retries: 0`, `fallbacks:` present.
- Intake cadence: `journalctl --user -u 'pi-intake@*' --since today |
  grep -c 'Starting pi-intake'` → 66; timers list shows
  `pi-intake@fleet-ops` last ran 04:11 IST and `pi-intake@0509` armed.

run-proof: host probes above ran live on netcup-rs2000 2026-09-22 against
origin/main `7a72e3488`; the deleted organ's source was read from git
(`571bf2098^`), never from memory; docs-only record — no unit, timer,
workflow or script path touched.

loose-ends: pi-intake-trigger-comment — `systemd/pi-intake-trigger.service:4`
still credits the deleted seat-recovery organ with firing intake (stale
comment, #7885 family); dead state files `lanes/seats/.no-usable-seat` and
`$XDG_RUNTIME_DIR/fleet-seat-recovery.state` left in place as the evidence
this record cites.
