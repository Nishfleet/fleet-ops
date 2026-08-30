<!-- CANONICAL: standing-rules canonical source -->
<!-- Edit ONLY the regions between SECTION markers. The generator in
     bin/render-standing-rules rebuilds the marked regions in
     ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md from this file. -->

<!-- SECTION: idle-fleet-alarm -->
## Fleet live state — read before scoping work

The old `.idle-fleet-alarm.json` banner is GONE. It lived in the fleet control
plane, which was deleted on 2026-08-23 ("Everything runs through Pi, directly.
No launchers." — vault `global-standing-rules.md`). Do not look for it, and do
not trust any stale copy you find: `agent-state/lanes/` now holds only
`pi-seat-health.json`.

Check live state directly instead, in this order:

1. `systemctl --user list-units --state=failed` — must be EMPTY. Anything failed
   is a fault you own repairing in this turn. (Needs
   `XDG_RUNTIME_DIR=/run/user/$(id -u)` set, or it silently returns nothing.)
2. `cat /home/nish/workspaces/agent-state/lanes/pi-seat-health.json` — the Pi
   seat's last observed provider/model, HTTP status and `health_class`. Check
   `observed_at` is recent before believing it.
3. `uptime` for load, and merged-PR counts per repo for actual throughput.

A missing or unparseable state file is itself a finding — report it, never treat
it as "no news is good news".
<!-- END SECTION: idle-fleet-alarm -->

<!-- SECTION: one-fleet-rule -->
## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23)

**No second dispatcher, ever.** A second fleet spends its effort on itself
(fleet2 hit 64% self-maintenance while fleet1 landed 452 product items in the
same window). Success metric stays: merged product PRs/day (baseline 133 on
2026-08-14).

The fleet1 machinery this rule named — `agent-state/lanes` lane-manager, idle
alarm, stall watchdogs, improvement loops — was DELETED on 2026-08-23 and
replaced by Pi (see routing below). The principle stands; the implementation is
gone. Do not rebuild a dispatcher. Full history: vault
`_system/shared-memory/global-standing-rules.md` -> "One fleet" and
"Everything runs through Pi".
<!-- END SECTION: one-fleet-rule -->

<!-- SECTION: nish-preimplementation-contract -->
## Mandatory pre-implementation contract

Before implementation work, automatically read and follow `/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/pre-implementation-contract.md`. This is non-negotiable for {{SURFACE_PREIMPLEMENT_PHRASE}}. For non-trivial work, investigate first, present Goal, Blocking questions, Assumptions, and Plan, then stop for Nish's approval. Only the contract's tiny obvious-change proportionality exception permits immediate implementation.
<!-- END SECTION: nish-preimplementation-contract -->

<!-- SECTION: shared-fleet-routing -->
**Everything runs through Pi, directly. No launchers.** (Nish, 2026-08-23 — vault `_system/shared-memory/global-standing-rules.md`.) The fleet control plane AND the `implementation-worker-*` launcher layer are both DELETED. There is no dispatch wrapper. `governed-run` and `~/.local/share/implementation-worker-routing/` are gone with them; the old `codex-model-routing.md` ladder is superseded.

Call `pi` directly, prompt on **stdin** (Pi rejects a `--` end-of-options flag):

```
pi --print --provider <provider> --model <model>
```

For work that must outlive this session, use `pi-systemd-run`, never `nohup pi ... &` — the launching shell reaps a nohup'd child and leaves dead-seat EXTLOAD lines. `pi-systemd-run --unit <name> --stdin <packet.md> -- pi --print --provider <provider> --model <model>` (a thin `systemd-run --user --collect --no-block` wrapper; not a dispatcher — no retry, no queue). Canonical wording: fleet-ops README and `prompts/heartbeat.md`.

For delegated work use Pi's stock `subagent` extension (`scout`, `planner`, `worker`, `reviewer`; `/implement`, `/scout-and-plan`, `/implement-and-review`):

```
echo 'Use worker to <task>' | pi --print --provider devin --model glm-5-2
```

Check the seat before routing: `agent-state/lanes/pi-seat-health.json` {{SEAT_CHECK_PHRASE}}

**Before writing ANY orchestration** — dispatch, queue, scheduling, spec gates, handoff, reporting — read Pi's 74 shipped example extensions in `~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/` and `docs/`. The fleet hand-built ~20,000 lines of control plane that Pi already ships. A hand-built fork of a stock extension is the known failure mode.

**Compute rule:** prefer event-driven over scheduled every time. The old fleet burned money polling; a schedule now needs a named reason.{{OLD_LAUNCHER_BLOCK}}
{{SOL_IDENTITY_BLOCK}}
<!-- END SECTION: shared-fleet-routing -->

<!-- SECTION: never-relay-finding -->
## Never relay a finding you could act on (Nish, 2026-08-09)

**"Why come to me when you know the answer?"** An agent that finds a problem,
diagnoses it, then hands the diagnosis to Nish has done the hard 90% and stopped
at the part that costs him attention. A finding is a WORK ITEM, not a message.
Find it, fix it, verify it, log it - then report the result.

- **Audit/review output belongs to whoever commissioned it.** Sol, Grok,
  CodeRabbit, Greptile, any sub-agent: their findings land in your queue, never
  in Nish's inbox. "Sol found 3 blockers" is not a deliverable; "Sol found 3
  blockers, here is the fix and the proof" is.
- A sub-agent's failure is escalated by fixing or re-routing it, not forwarding it.
- If a later shift could do it, this shift could have done it.
- Close with a result, never an offer.

Reaches Nish and nothing else: money, pricing, legal, brand, product direction,
customer-data deletion, and authority he has explicitly reserved - plus the
standing exception that an unrepairable failure must fail LOUD, never degrade
silently.

Corollary: **if a human had to notice it by hand, that blind spot is the real
bug.** Fix the instance AND the detector. Canonical text:
`nish-vault/_system/shared-memory/agent-contract.md`.
<!-- END SECTION: never-relay-finding -->

<!-- SECTION: shared-memory-loop -->
## Automatic shared-memory loop

{{FAILURE_RESPONSE_BLOCK}}- Non-negotiable response style: default to concise ELI5 language with plain words and the direct answer first. Add depth only when Nish explicitly asks or when essential safety or verification details cannot be omitted.
- Before meaningful work, run `/home/nish/.local/bin/memoryctl-recall context --agent {{SURFACE_AGENT}} --query "<task in one sentence>" --repo "$PWD"` and use only the relevant returned notes. Notes it marks `UNVERIFIED:` are stale until their check-command proves fresh — treat them as unconfirmed. Re-verify live state before acting.
- After meaningful work, run `/home/nish/.local/bin/memoryctl outcome --agent {{SURFACE_AGENT}} --goal "<goal>" --result "<result>" --repo "$PWD" --proof "Command: <exact replay/inspection command>; observed: <what it printed>; observed-at: <UTC ISO8601>" --source "<vault path, credential-free URL, or git:repo@sha reference>" --verified-by "{{SURFACE_AGENT}}"`. Project scope is derived from `--repo`. Add `--promote` only for reusable, evidence-backed knowledge. The promotion gate hard-rejects any proof that does not start with `Command:` — prose proofs never compile (101 denials accumulated by 2026-08-28 from this mistake). For a VERIFIED outcome, additionally mint an execution receipt first — `memoryctl proof-run --for-memory-id <id> --for-goal <goal> -- <argv...>` — then pass the SAME id via `--memory-id` plus `--proof-receipt <printed path>`; without a receipt the outcome is stored but marked unverified.
- If a retrieved memory materially helped or harmed the task, run `/home/nish/.local/bin/memoryctl feedback --agent {{SURFACE_AGENT}} --context-id "<packet context receipt>" --target-ref "<exact packet feedback ref>" --effect helped|harmed --proof "<observable effect>" --source "<portable evidence>" --verified-by "{{SURFACE_AGENT}}"`. Feedback must bind to the exact packet receipt and memory digest; do not rate unused memories.
- To remember a reusable fact Nish confirmed, use `/home/nish/.local/bin/memoryctl capture` with a stable `--memory-id`, portable evidence `--source`, `--verified-by user-confirmed`, and `--promote`. `--verified-by user-confirmed` is REJECTED unless Nish mints a live consent receipt via `memoryctl confirm` (interactive TTY) and you pass it with `--consent-receipt`; without one, use your own agent identity as verifier. The exact digest must also pass the local acceptance workflow before compilation.
- The deterministic VPS curator may update only compiled memory and promotion proposals. It never edits durable decisions or playbooks.
<!-- END SECTION: shared-memory-loop -->
