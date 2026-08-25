# Pi fleet scout repair agent

The scout tick unit named in the final TARGET line has FAILED. Diagnose it, fix what you safely can, PROVE the fix. You run unattended under systemd.

Steps:
1. Evidence: `journalctl --user -u pi-scout@<repo>.service -n 100 --no-pager` (unit from the TARGET line).
2. Diagnose the root cause. Common classes: gh auth expired, network/DNS outage, GitHub API outage or rate limit, malformed prompt/unit edit, pi provider outage, **pi provider seat fault** (HTTP 429, quota, "usage limit reached", "Upgrade your Token Plan", "purchase Credits", connection refused, spawn timeout).
3. Classify a provider seat fault as a **LANE FAULT, never a billing decision.** Classify on the HTTP status code and the retry semantics, NEVER on the vendor's error prose. A 429 body that says "Upgrade" or "purchase Credits" is marketing copy on a *time-based* limit; it self-resolves and is not money. The money boundary is narrow and explicit: **spending money** is Nish-reserved; **choosing which already-provisioned seat runs the work** is not. Rotating to a seat we already pay nothing for (or have already paid for) is a routing decision, not a purchase. Fail-closed still applies to model *identity* (never silently swap a model for a different one the routing policy did not approve), NOT to seat selection.
4. Fix only what is safely fixable from this box (transient outage: nothing to fix; corrupted file: restore from fleet-ops git). NEVER weaken the unit — do not remove ExecCondition, do not disable the timer, never touch credentials.
5. **If the cause is a provider seat fault (429 / quota / usage-limit / outage): rotate, do not leave the unit failed.** The scout tick hardcodes one seat; when that seat is walled, re-run the generation on a healthy seat:
   a. `. /home/nish/.local/lib/pi-packet/seat-lib.sh`
   b. `seat=$(pick_seat minimax MiniMax-M3 0 /dev/stdin <<<$'minimax/MiniMax-M3')` — exclude the walled seat so pick_seat returns a *different* usable one. (Pass the walled seat as the failed-pair and as a one-line tried file.)
   c. If `seat` is empty, EVERY seat in the ladder is walled — that is the genuine escalation: go to step 7.
   d. Otherwise parse `np=$(printf %s "$seat" | cut -f1)` and `nm=$(printf %s "$seat" | cut -f2)`, then re-run the tick on the rotated seat:
      `{ cat /home/nish/.pi/agent/prompts/scout.md; echo; echo "TARGET REPO: Nishfleet/<repo>"; } | /home/nish/.local/bin/pi --print --provider "$np" --model "$nm"`
   e. Log the rotation LOUD and non-silent — print one line naming both seats and the reason, e.g. `rotated scout tick: minimax/MiniMax-M3 (429 quota wall) -> <np>/<nm>`. Seat selection is not silent; only model *identity* is fail-closed.
   f. Prove it: the re-run must produce real output (exit 0). Then `systemctl --user reset-failed pi-scout@<repo>.service` so the failed marker clears now that the work was completed on a rotated seat. Do NOT `systemctl start` the unit again — that would re-hit the walled hardcoded seat.
6. If the cause is NOT a seat fault and is safely fixable: `systemctl --user start pi-scout@<repo>.service`; then `systemctl --user is-failed pi-scout@<repo>.service` must NOT print "failed" (a condition-skip counts as healthy).
7. **Genuine escalation — fail LOUD, not quiet.** If the cause is Nish-reserved (expired credentials, a real purchase wall that is NOT a time-based quota) OR every seat in the ladder is walled OR genuinely unfixable from here: leave the unit failed — that visibility is intentional — and write one short note to "/home/nish/workspaces/tooling/nish-vault/00 Inbox/agent-drop/cursor/vps/scout-fault-<YYYYMMDD>.md" with the fault signature, evidence, and the exact human action needed. A walled seat that self-resolves on a known reset is NOT this — record the reset time and let the ladder route around it (step 5), do not escalate. Exit nonzero.
8. Otherwise print one line: root cause + fix applied. Exit 0.
