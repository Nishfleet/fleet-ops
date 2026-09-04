# Pi fleet scout repair agent

difficulty: light

The scout tick unit named in the final TARGET line has FAILED. Diagnose it, fix what you safely can, PROVE the fix. You run unattended under systemd.

Steps:
1. Evidence: `journalctl --user -u pi-scout@<repo>.service -n 100 --no-pager` (unit from the TARGET line).
2. Diagnose the root cause. Common classes: gh auth expired, network/DNS outage, GitHub API outage or rate limit, malformed prompt/unit edit, pi provider outage, **pi provider seat fault** (HTTP 429, quota, "usage limit reached", "Upgrade your Token Plan", "purchase Credits", connection refused, spawn timeout).
3. Classify a provider seat fault as a **LANE FAULT, never a billing decision.** Classify on the HTTP status code and the retry semantics, NEVER on the vendor's error prose. A 429 body that says "Upgrade" or "purchase Credits" is marketing copy on a *time-based* limit; it self-resolves and is not money. The money boundary is narrow and explicit: **spending money** is Nish-reserved; **choosing which already-provisioned seat runs the work** is not. Rotating to a seat we already pay nothing for (or have already paid for) is a routing decision, not a purchase. Fail-closed still applies to model *identity* (never silently swap a model for a different one the routing policy did not approve), NOT to seat selection.
4. Fix only what is safely fixable from this box (transient outage: nothing to fix; corrupted file: restore from fleet-ops git). NEVER weaken the unit — do not remove ExecCondition, do not disable the timer, never touch credentials.
5. **Before any `systemctl start` (steps 6-7): clear a wedged unit.** A scout whose pi process hung (after a SPAWN_BLOCKED, a provider stall, or a seat-bench race) stays in `activating (start)` state — `systemctl --user start` on an already-activating unit blocks indefinitely waiting for a start job that never completes, deadlocking THIS repair unit (fleet-ops#3078). Check first:
   `state=$(systemctl --user is-active pi-scout@<repo>.service 2>/dev/null || true)`
   If `$state` is `activating`, the unit is wedged — stop it to kill the hung process:
   `systemctl --user stop pi-scout@<repo>.service`
   Then `systemctl --user reset-failed pi-scout@<repo>.service` so the failed marker clears. Only THEN proceed to the `systemctl start` in step 6 or 7. Always wrap the start in a timeout so a future wedge cannot deadlock this unit:
   `timeout 120 systemctl --user start pi-scout@<repo>.service`
6. **If the cause is a provider seat fault (429 / quota / usage-limit / outage): rotate, do not leave the unit failed.** The scout tick goes through `pi-scout-run`, which calls `pick_seat`. A recoverable 429 / rate_limited / empty_run / overload_bench bench is fail-opened onto the shortest remaining recoverable seat (fleet-ops#3324). Re-run the tick so the wrapper can pick:
   `timeout 120 systemctl --user start pi-scout@<repo>.service`
   Then `systemctl --user is-failed pi-scout@<repo>.service` must NOT print "failed" (a condition-skip counts as healthy). If start fails because pick_seat returned empty (money wall / unrecoverable), that is the genuine escalation: go to step 8. Log the rotation LOUD — print one line naming the walled seat and that the wrapper will pick again. Seat selection is not silent; only model *identity* is fail-closed. Then `systemctl --user reset-failed pi-scout@<repo>.service` so the failed marker clears.
7. If the cause is NOT a seat fault and is safely fixable: `timeout 120 systemctl --user start pi-scout@<repo>.service`; then `systemctl --user is-failed pi-scout@<repo>.service` must NOT print "failed" (a condition-skip counts as healthy).
8. **Genuine escalation — fail LOUD, not quiet.** If the cause is Nish-reserved (expired credentials, a real purchase wall that is NOT a time-based quota) OR pick_seat returned empty (money wall / unrecoverable) OR genuinely unfixable from here: leave the unit failed — that visibility is intentional — and write one short note to "/home/nish/workspaces/tooling/nish-vault/00 Inbox/agent-drop/cursor/vps/scout-fault-<YYYYMMDD>.md" with the fault signature, evidence, and the exact human action needed. A recoverable 429 / rate_limited bench is fail-opened by pick_seat (fleet-ops#3324) — that is a slightly-early retry, not this. A walled seat that self-resolves on a known reset is NOT this — record the reset time and let the ladder route around it (step 6), do not escalate. Exit nonzero.
9. Otherwise print one line: root cause + fix applied. Exit 0.
