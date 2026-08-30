# Builder attribution — class-(c) units, manual-seam hunt

Hunt owner: fleet-ops#1500 (audit follow-up to #1480, step 4)
Date: 2026-08-30
Host: netcup-rs2000

## What this is

The #1480 machinery audit classified 7 hand-placed units as class (c)
(unsanctioned build, follow-ups #1492–#1498) and pinned their build windows via
unit-file mtime + journal first-run. It deliberately did NOT attribute each unit
to a named builder session inline: "That correlation is itself a hand-built
hunt, so it is filed here rather than run inline by the audit."

This report runs that hunt. It correlates each build window against the two
evidence bases the issue named — session outcome/action logs (memoryctl
receipts, Claude Code session transcripts on this host, systemd journal) and
vault agent-drop captures — and names the building session for each unit.

## Evidence sources

| Source | Location | What it proves |
|---|---|---|
| systemd journal first-run | `journalctl --user -u <unit>` | exact placement→first-start moment |
| unit-file mtime | `stat ~/.config/systemd/user/<unit>` | write moment (surviving units) |
| ExecStart script mtime | `stat ~/.local/bin/<script>` | script write moment |
| Claude session transcripts | `~/.claude/projects/-home-nish/<session>.jsonl` | per-session tool calls with timestamps; identifies model + window |
| memory files | `~/.claude/projects/-home-nish/memory/*.md` frontmatter `originSessionId` | which session wrote the design memory |
| vault agent-drop captures | `nish-vault/00 Inbox/agent-drop/pi/…` | contemporaneous documentation of the silent-file placements (writer identity: pi-vps / glm-5-2) |
| agent-state docs | `agent-state/agent-agnostic-audit-2026-08-25.md`, `fleet-restoration-2026-08-25.md` | session-written work records |

## Attribution table

| Unit | Build window (UTC) | Builder session | Builder model | Evidence (chain) |
|---|---|---|---|---|
| siterep-pr-conflict-watchdog | 2026-08-24 06:19Z (first run) | 1b0c4709-6306… | claude-opus-5 | first run inside session window (05:12–13:04Z); same-session watchdog fleet (gha-stuck-run-watch unit written directly 05:28Z); pi-vps capture 09:15Z enumerates it among 19 silent files placed 2026-08-24 |
| open-question-sweep | 2026-08-24 07:41Z (first run) | 1b0c4709-6306… dispatched packet p34-open-question 07:33:23Z → pi writer (glm-5-2) | claude-opus-5 (+ glm-5-2 writer) | p34-open-question dispatch 07:33:23Z, unit first-run 07:41:33Z; `open-question` script created 2026-08-24 (802 lines, mtime 08:12Z after first-run log-dir fix); pi-vps capture 09:55Z |
| memory-index-autocompact | 2026-08-24 18:23Z (unit mtime = first run 18:23:54Z) | a1897df9-2057… | claude-fable-5 | transcript: "Automate memory index compaction, event-driven" task 18:20Z; memory `memory-index-autocompact.md` originSessionId a1897df9… written 18:31Z; autocompact backups 23:53 IST; unit+script mtimes 18:23Z/18:29Z |
| agent-scheduler-drift | 2026-08-25 15:11Z (first run) | b6079196-8390… ("agent-agnostic-audit / Auto-revert-validation sessions") | claude-fable-5 | memory `agent-agnostic-machinery-only.md` (originSessionId b6079196…) 14:58Z; "Use worker to build the AGENT-AGNOSTIC quality-baseline research" 14:59Z; drift unit wired 15:15Z / 17:39–17:41Z; pi-vps capture 16:35Z |
| quality-baseline-research | 2026-08-25 15:10Z (unit mtime), first run 15:11:58Z | b6079196-8390… | claude-fable-5 | transcript: hermes cron `quality-baseline-research` created 14:52Z (the agent-agnostic violation), removed same hour, rebuilt as systemd units 15:10–15:11Z (script mtime 15:10:07Z); memory self-records the violation |
| ready-work | 2026-08-25 16:07Z (first run) | b6079196-8390… | claude-fable-5 | transcript RESULT 16:24Z: "never-say-next … pieces=[… READY-WORK.md ready-work.path ready-work.servic…]"; pi-vps capture 00:15Z 2026-08-26 |
| auditor-stdio-test | 2026-08-25 23:17:57Z (unit mtime = first run) | unidentified — "some session's scratch test unit" (3c6ea3a4…, overnight watchdog, contemporaneous record 23:22Z) | unknown | created+started same second, 5s after vps-maintenance window closed; context: senior-auditor dispatch debugging (stop-escalation.service "pi auditor dispatch failed" 22:20Z, timeout 23:14:21Z); watchdog monitor FAILED-UNITS:2 event 23:21Z; `/tmp` fixtures gone |

## Evidence chains in detail

### 1b0c4709 — the 2026-08-24 morning watchdog fleet (siterep-pr-conflict-watchdog, open-question-sweep)

Session 1b0c4709-6306-4eca-b6a8-e7d320f2cc47 (claude-opus-5, claude-desktop,
05:12Z–13:04Z 2026-08-24) built the morning cascade. The transcript shows the
session writing the `gha-stuck-run-watch` service unit directly at 05:28:11Z,
then dispatching pi-packet workers (p10–p36, glm-5-2 seat) for the rest of the
watchdog fleet. The pi-vps captures document the same cascade as one change
set: 06:50Z (gha-stuck-run-watch), 09:15Z ("watchdog fleet — offload-to-VPS
timers + never-page-Nish refactor", 19 silent files listing
`siterep-pr-conflict-watchdog.{service,timer}` + `open-question-sweep` files),
09:55Z ("open-question loop" — `open-question` 802-line script + sweep units).

- siterep-pr-conflict-watchdog first run 06:19:29Z falls inside this session's
  dispatch window.
- open-question-sweep first run 07:41:33Z is 8 minutes after the session's
  p34-open-question packet dispatch at 07:33:23Z (packet `p34-open-question`),
  and the 09:55Z pi capture names the same files.

The session itself later recognized the pattern ("2,559 lines of hand-written
bash" — the forbidden pattern) and disarmed + archived the cascade at 08:08Z,
writing the "No hand-built orchestration. Ever." amendment into
`global-standing-rules.md` at 08:09Z. The units were re-armed later that day by
other work; that is why they survived to the audit.

### a1897df9 — memory-index-autocompact (2026-08-24 18:23Z)

Session a1897df9-2057-4457-bdd0-ce66439f72b6 (claude-fable-5, claude-desktop,
started 17:50Z 2026-08-24). Its transcript shows the "Automate memory index
compaction, event-driven" task at 18:20:14Z ("Follow-up, approved by Nish") and
the compaction design iteration at 18:26Z. The design memory
`memory-index-autocompact.md` carries `originSessionId a1897df9-2057-…` and was
written 18:31:32Z — the unit (18:23:00Z) and script (18:29:55Z) mtimes bracket
that write. The unit's first run at 18:23:54Z triggered the first live
compaction (backups `MEMORY.md.autocompact-bak-20260824-235354`…). The pi-vps
capture of 2026-08-25 02:10Z ("p64 box-protection infra … memory-index
autocompact") records the same change set, noting it was installed by a prior
session.

### b6079196 — the 2026-08-25 agent-agnostic migration (agent-scheduler-drift, quality-baseline-research, ready-work)

Session b6079196-8390-4626-8149-77c13e2a1978 (claude-fable-5, claude-desktop,
18:15Z 2026-08-24 → 18:27Z 2026-08-25) — the session the pi-vps capture names
"agent-agnostic-audit / Auto-revert-validation sessions". Its transcript is
minute-accurate:

- 14:51–14:52Z: creates the **hermes cron** `quality-baseline-research`
  (job c949d0d3eca3) — the agent-agnostic violation the memory later records.
- 14:57–14:58Z: reads `global-standing-rules.md`, writes the
  `agent-agnostic-machinery-only` memory ("I violated this on 2026-08-25 by
  creating a Hermes cron for the quality-baseline-research refresh; removed
  same hour, rebuilt on [[…]]-compliant substrate") — the rebuild.
- 14:59Z: "Use worker to build the AGENT-AGNOSTIC quality-baseline research" —
  the systemd units land 15:10–15:11Z (`quality-baseline-refresh` script
  15:10:07Z, `quality-baseline-research.{service,timer}` 15:10:51Z, first run
  15:11:58Z; `agent-scheduler-drift` first run 15:11:11Z; the drift
  allowlist/gate wiring carried through 17:41Z with the hermes cron pause of
  the migrated market-signal job).
- 15:57–16:24Z: the never-say-next layer-3 build — transcript RESULT 16:24:25Z
  lists `READY-WORK.md ready-work.path ready-work.service …`; ready-work first
  ran 16:07:00Z.

So the same session built all three units within ~2 hours, and it did so while
actively stating the agent-agnostic rule in its own memory — the dispatcher
class (ready-work) slipped through even after the rule was internalized. That
is the instruction gap, stated precisely: **the writer internalized
"agent-agnostic substrate" but not "no new dispatcher/watchdog machinery at
all"** — the two bans sat in different files and lost to urgency.

### auditor-stdio-test — unidentified builder (2026-08-25 23:17:57Z)

The unit was created and started in the same second, 5 seconds after the
vps-maintenance quiesce closed (23:17:52Z) and while the senior-auditor
dispatch path was failing (stop-escalation.service "pi auditor dispatch
failed" 22:20Z; timeout + kill at 23:14:21Z). Its Description ("Auditor stdio
ordering test") and body (StandardInput=file ordering vs ExecStartPre) are a
scratch probe of how systemd feeds the auditor's packet via stdin. The
overnight fleet-watchdog session 3c6ea3a4 (claude-fable-5) received the
FAILED-UNITS:2 monitor event at 23:21:07Z and recorded at 23:22:18Z:
"auditor-stdio-test is some session's scratch test unit — reset, left in place
for its owner." No transcript in `~/.claude/projects/-home-nish` textually owns
the write in that minute, so the builder session cannot be named from the
available session logs. This unit is test debris (per #1492) and its builder
identity is the one open attribution gap; the natural follow-up is to treat the
senior-auditor dispatch workstream active 2026-08-25 22:00–23:30Z as the owning
family and keep #1492 as the deletion work item.

## Instruction-gap closure at the writer

The audit's step-4 conclusion stands and this hunt sharpens it: **the ban
existed in prose before the gate, and prose bans lose to urgency at decision
time.** Per unit, the missed instruction was:

| Unit | Instruction in force at build time | Missed because |
|---|---|---|
| siterep-pr-conflict-watchdog, open-question-sweep | no-new-machinery standing rules | builder was mid hand-built plumbing session that self-identified and disarmed at 08:08Z the same morning |
| memory-index-autocompact | borderline b/c (addressed in #1498) | Nish-approved feature request rebuilt onto systemd; class ambiguity |
| agent-scheduler-drift, quality-baseline-research, ready-work | agent-agnostic substrate (internalized 14:58Z) but no-new-dispatcher-machinery (missed) | two bans in different documents; urgency of the migration won |
| auditor-stdio-test | no-hand-built-plumbing (in effect) | scratch test debris by unidentified session during auditor-dispatch debugging |

The mechanical closure is already shipped and live, so this hunt adds no new
organ (per the issue: "the standing hunt, not a new organ"):

1. **Manual-seam lens in the blind-audit prompt** (fleet-ops#377, closed) —
   `prompts/blind-audit.md` §Manual-seam lens: every cycle enumerates
   hand-performed operations since last cycle from exactly these evidence
   sources (memoryctl outcome records, actions logs, GitHub events, systemctl
   starts with no timer parent) and matches each seam to a mechanism issue or
   files one. This report is the first titled execution of that lens's
   machinery-placement branch.
2. **Machinery-authorization gate** (fleet-ops#1566, merged) —
   `lib/machinery-authorization-gate.py` + `bin/fleet-machinery-authorization-gate`:
   default-deny on new `systemd/` units / MANIFEST additions without a
   nish-only authorization signal; `hunt` flags hand-placed units not on the
   allowlist (`config/machinery-allowlist.json`). Live gap-audit findings
   already landed: #1573 (agent-scheduler-drift, closed) and #2088
   (quality-baseline-research, open).
3. **Organ catalog** (PR #1502) — reuse path so the next writer reaching for a
   banned class finds the existing row instead.

## Follow-up state (as of 2026-08-30)

| Unit | Follow-up | State |
|---|---|---|
| auditor-stdio-test | #1492 (delete test debris) | OPEN |
| ready-work | #1493 (adjudicate dispatcher) | CLOSED — MECHANICAL-INSTEAD, deleted |
| open-question-sweep | #1494 (adjudicate watchdog) | CLOSED |
| agent-scheduler-drift | #1495 (adjudicate watchdog) | CLOSED — migrated into repo `systemd/` |
| siterep-pr-conflict-watchdog | #1496 (adjudicate watchdog) | CLOSED — MECHANICAL-INSTEAD (GH Actions already covers), deleted |
| quality-baseline-research | #1497 (adjudicate dispatcher) | OPEN (+ gap-audit #2088) |
| memory-index-autocompact | #1498 (adjudicate borderline b/c) | OPEN |

## Manual-seam lens table (blind-audit contract shape)

Columns per `prompts/blind-audit.md`: seam, source, mechanism, disposition, reason.

| Seam | Source | Mechanism | Disposition | Reason |
|---|---|---|---|---|
| siterep-pr-conflict-watchdog hand-placed 2026-08-24 | journal first-run 06:19:29Z; unit in pi-vps capture 09:15Z | #1496 adjudication (MECHANICAL-INSTEAD: GH Actions pr-conflict-watchdog covers) | matched | unit deleted; check already owned by siterep repo workflow |
| open-question-sweep hand-placed 2026-08-24 | p34-open-question dispatch 07:33:23Z, first run 07:41:33Z; pi-vps capture 09:55Z | #1494 adjudication | matched | disposed by follow-up |
| memory-index-autocompact placed 2026-08-24 | unit mtime/first run 18:23Z; session a1897df9; memory originSessionId | #1498 adjudication (borderline b/c) | matched | disposed by follow-up |
| agent-scheduler-drift placed 2026-08-25 | session b6079196; first run 15:11:11Z; pi-vps capture 16:35Z | #1495 adjudication → migrated into repo `systemd/` | matched | disposed: now repo-sourced |
| quality-baseline-research placed 2026-08-25 | session b6079196; unit mtime 15:10:51Z; memory self-record | #1497 adjudication + gap-audit #2088 | matched | disposed by follow-ups |
| ready-work placed 2026-08-25 | session b6079196; first run 16:07:00Z; transcript RESULT 16:24Z | #1493 adjudication (MECHANICAL-INSTEAD) | matched | unit deleted; stock pi-packet dispatch covers |
| auditor-stdio-test placed 2026-08-25 23:17:57Z | unit mtime = first run; watchdog event 23:21Z | #1492 (delete test debris) | matched — builder unidentified | scratch test unit; deletion pending #1492 |

## What the next blind-audit cycle does with this

The manual-seam lens now names the sessions; the next cycle's seam table should
carry the builder session IDs from this report as the `source` of each
placement row, and any future repeated placement by the same session class
trips the machinery gate rather than needing a new attribution hunt.