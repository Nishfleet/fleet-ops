<!-- CANONICAL: standing-rules canonical source -->
<!-- Edit ONLY the regions between SECTION markers. The generator in
     bin/render-standing-rules rebuilds the marked regions in
     ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md from this file. -->

<!-- SECTION: idle-fleet-alarm -->
## Fleet live state — read before scoping work

The old `.idle-fleet-alarm.json` banner is GONE. It lived in the fleet control
plane, which was deleted on 2026-08-23 ("Everything runs through Pi, directly.
No launchers." — vault `global-standing-rules.md`). Do not look for it, and do
not trust any stale copy you find: live seat state now comes from the LiteLLM
router itself (step 4), not from a file. The `lanes/` directory also holds
operational artefacts — seats/, reports/, outbound-gate/, `.seen` markers,
logs, timestamped seats-quarantine/corpse dirs — none of which this check
reads (fleet-ops#6613).

Check live state directly instead, in this order:

1. If `~/workspaces/agent-state/FLEET-PAUSED` exists, the fleet is
   deliberately down — respect it. Stop; do not scope or launch work.
2. `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers` is the
   truth on whether fleet timers are armed. Enrolment is declared in
   fleet-ops `config/intake-repos.json`, converged by the reconciler
   (fleet-ops#32).
3. `systemctl --user list-units --state=failed` — must be EMPTY. Anything failed
   is a fault you own repairing in this turn. (Needs
   `XDG_RUNTIME_DIR=/run/user/$(id -u)` set, or it silently returns nothing.)
4. `curl -s 127.0.0.1:4000/health/readiness` — LiteLLM's own readiness
   (`{"status":"healthy","db":"connected"}`); then
   `curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state` — one
   gauge per deployment, 0 = healthy, 1 = partial outage, 2 = complete
   outage. This REPLACES `lanes/pi-seat-health.json`: its writer
   (`seat-health.ts`, 1,472 lines) was deleted on 2026-09-18, so that file is
   frozen at its last write and must not be read as live state.
5. `uptime` for load, and merged-PR counts per repo for actual throughput.

A missing or unparseable state file is itself a finding — report it, never treat
it as "no news is good news".

**Precedence (fleet-ops#5748):** this 5-step block is the single canonical
fleet live-state check. Shorter summaries on other surfaces (e.g. the Pi
`AGENTS.md` quick minimum) defer to it; edit THIS section, re-render, and any
divergence is resolved in this block's favour.
<!-- END SECTION: idle-fleet-alarm -->

<!-- SECTION: one-fleet-rule -->
## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23 — corrected 2026-08-25)

Full text: `/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/standing-rules-archive.md` → `## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23 — corrected 2026-08-25)`.
<!-- END SECTION: one-fleet-rule -->

<!-- SECTION: nish-preimplementation-contract -->
## Mandatory pre-implementation contract

Before implementation work, automatically read and follow `/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/pre-implementation-contract.md`. This is non-negotiable for every agent and subagent on this host. For non-trivial work, investigate first, present Goal, Blocking questions, Assumptions, and Plan. Then stop for Nish's approval only when the work touches a canonical reserved class (vault `global-standing-rules.md` → "Canonical reserved-classes list") or is irreversible. Everything else begins once the plan is on the record — "Engineer reversibility, don't gate" (Nish, 2026-08-24): make it revertible in under two minutes and stop asking (fleet-ops#6610).
<!-- END SECTION: nish-preimplementation-contract -->

<!-- SECTION: shared-fleet-routing -->
**Everything runs through Pi, directly. No launchers.** (Nish, 2026-08-23 — vault `_system/shared-memory/global-standing-rules.md`.) The fleet control plane AND the `implementation-worker-*` launcher layer are both DELETED. There is no dispatch wrapper for Pi work. `governed-run` and `~/.local/share/implementation-worker-routing/` are retired for Pi dispatch, NOT deleted (verified 2026-09-11: `test -x ~/.local/bin/governed-run && echo still-present`); `governed-run` remains sanctioned for non-Pi ad-hoc commands (sanction lives in `~/.codex/AGENTS.md`). The old `codex-model-routing.md` ladder at `~/workspaces/tooling/nish-vault/_system/shared-memory/codex-model-routing.md` is superseded.

Call `pi` directly, prompt on **stdin** (Pi rejects a `--` end-of-options flag):

```
pi --print --provider <provider> --model <model>
```

For work that must outlive this session, use a systemd transient unit, never a
backgrounded `pi` — the launching shell reaps the child and leaves dead-seat
EXTLOAD lines. `bin/pi-systemd-run` and `bin/pi-detached-deadman` were deleted on
2026-09-18; the two stock `systemd-run` properties below replace them exactly, and
there is no wrapper to keep in sync:

```
systemd-run --user --collect --unit <name> \
  -p RuntimeMaxSec=<seconds> \
  -E DELIVERABLE=<absolute artifact path> \
  -p 'ExecStopPost=/bin/sh -c '"'"'test -s "$DELIVERABLE" || { echo no-deliverable >&2; exit 1; }'"'"'' \
  -- sh -c 'cat /path/to/packet.md | pi --print --provider <provider> --model <model>'
```

`RuntimeMaxSec=` is the deadline: systemd kills an over-running unit into
`Result=timeout`. The `ExecStopPost=` line is the deliverable check: a stop at
exit 0 that left no artifact becomes `Result=exit-code`, i.e. `failed`, which is
what `OnFailure=` and the failed-units pass key off. Both halves were proven on
this host on 2026-09-18 (RED: no artifact -> `Result=exit-code`; GREEN: artifact
written -> `Result=success`; `RuntimeMaxSec=5` against `sleep 60` ->
`Result=timeout`).

Drop `--collect` when you want the dead unit to stay listed in
`systemctl --user list-units --state=failed`. With `--collect` systemd unloads
the unit as soon as it dies, so the failure survives only in the journal
(`journalctl --user -u <name>`).

Watch a live run with `systemctl --user status <name>.service`.

Every detached launch carries both: without `RuntimeMaxSec=` a hung run never
dies, and without the `ExecStopPost=` check a run could stop clean at exit 0 with
no artifact and the exit-0-no-deliverable FAILURE (fleet-ops#4266) could never
fire. Canonical copy-paste block: fleet-ops README (README.md "systemd by default").

For delegated work use Pi's stock `subagent` extension (`scout`, `planner`, `worker`, `reviewer`; `/implement`, `/scout-and-plan`, `/implement-and-review`):

```
echo 'Use worker to <task>' | pi --print --provider devin --model glm-5-2
```

Check the seat before routing: `curl -sL 127.0.0.1:4000/metrics | grep litellm_deployment_state` (0 = healthy, 1 = partial, 2 = complete outage).

**Before writing ANY orchestration** — dispatch, queue, scheduling, spec gates, handoff, reporting — read Pi's 79 shipped example extensions (verified 2026-09-01: `ls ~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/ | wc -l`) in `~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/` and `docs/`. The fleet hand-built ~20,000 lines of control plane that Pi already ships. A hand-built fork of a stock extension is the known failure mode.

**Compute rule:** prefer event-driven over scheduled every time. The old fleet burned money polling; a schedule now needs a named reason.

The old DeepSeek/MiniMax/Luna launcher ladder and `_system/shared-memory/codex-model-routing.md` are SUPERSEDED - history only.

Sol is retired (Nish 2026-09-07, fleet-ops#4148): do not launch `gpt-5.6-sol`, do not top up straitly for it. The remaining Codex identity is Luna via `codex-luna@`. Exact model/effort identity is fail-closed: prove host, provider, model, role and effort from runtime evidence before launch. Missing proof means no launch. No silent substitution.
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

Reaches Nish and nothing else: **the canonical reserved-classes list** in the
vault (`nish-vault/_system/shared-memory/global-standing-rules.md` → "Only
the un-fixable reaches Nish" → "Canonical reserved-classes list") wins over
any shorter surface list — that vault block is the single source of truth;
this bullet is a pointer, not a restatement (fleet-ops#5586, fleet-ops#5685).
Plus the standing exception unrelated to those classes: an unrepairable
failure must fail LOUD, never degrade silently.

**HOW an agent escalates a reserved-class finding (glue sweep 2026-09-18).**
One stock line, from any user unit or session, unauthenticated:

```
amtool alert add alertname=NishEscalation severity=nish \
  --annotation=summary='<one sentence: what, and what you need from Nish>'
```

`severity=nish` is an existing Alertmanager route straight to the Telegram
receiver at group_interval 1m. Use `--annotation=summary`, NOT a bare
`summary=`: a bare key becomes a LABEL, which (a) the telegram message
template reads `.CommonAnnotations.summary` so the message body arrives empty,
and (b) changes the alert fingerprint, so every escalation becomes a distinct
alert that never dedupes or resolves. Resolve by re-sending the same labels
with `--end` in the past once the item is closed.

This replaces appending a line to `agent-state/NISH-ESCALATIONS.md` and the
`nish-boundary-notify` path unit + `hermes` shim that watched it — all
deleted. Everything else still holds: escalate ONLY the canonical
reserved-classes list, and fix everything around it first.

Corollary: **if a human had to notice it by hand, that blind spot is the real
bug.** Fix the instance AND the detector. Canonical text:
`nish-vault/_system/shared-memory/agent-contract.md`.
<!-- END SECTION: never-relay-finding -->

<!-- SECTION: shared-memory-loop -->
## Automatic shared-memory loop

- **Failure response is #1 (Nish, 2026-08-08):** any detected fleet-infrastructure failure gets automatic, autonomous, INSTANT repair dispatch on the cheapest healthy Pi seat (pick seats via `litellm_deployment_state` on 127.0.0.1:4000/metrics), escalating to a flagship seat for broad or high-stakes repair. Never a quiet degraded mode, never 'flag for Nish'. Fail LOUD when repair is impossible.
- Non-negotiable response style: default to concise ELI5 language with plain words and the direct answer first. Add depth only when Nish explicitly asks or when essential safety or verification details cannot be omitted.
- Memory is the Pi session plus the plain markdown in `nish-vault` — the `memoryctl` recall/outcome/feedback/capture loop and its curator were deleted on 2026-09-18 (the write path had not run in 39 days and the curator compiled 0 notes in its entire live history).
<!-- END SECTION: shared-memory-loop -->
