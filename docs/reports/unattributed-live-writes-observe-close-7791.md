# Observe-close for #7791 — "unattributed" live-file writes of 2026-09-19 00:00–00:30 IST

Issue #7791 (filed by the 2026-09-19 00:11 IST intake tick, transcript
`~/.pi/agent/sessions/pi-intake-fleet-ops/2026-09-18T18-41-49-508Z_01a0b5d3-27c3-7415-97f7-bbc5cecf7c3f.jsonl`)
recorded five observations from a night when the glue sweep was landing and a
transient LiteLLM `Connection error` window (00:05:46–00:11:13 IST) failed
four units. Re-investigated 2026-09-22 against origin/main `674ef9b33`.

Verdict up front: **items 2 and 3 are attributed to specific fleet commits,
item 4 is verified clean end-to-end, item 5 was completed by the reporter.
Item 1's accused mechanism is disproven — and is deleted anyway.** The single
unattributable act (who removed `~/workspaces/agent-state/lanes/pi-vps/`) is
named below with why the evidence no longer exists.

## 1. The lane-packet deletion — logrotate is not the mechanism

The intake tick was told to re-read
`~/workspaces/agent-state/lanes/pi-vps/2026-09-18/processed-1.md` and found
the whole `pi-vps` tree missing at 18:42 UTC. It blamed
`pi-packet-logrotate.timer`, which had passed at 00:12:18 IST.

That attribution is wrong. The organ's entire config
(`config/logrotate.conf`, recovered from `1ae2704cc^`) was one block:

```
/home/nish/.local/state/pi-packet/watch.log {
    size 10M
    rotate 5
    missingok
    notifempty
    copytruncate
    compress
    delaycompress
}
```

One file, size-triggered, `copytruncate` — it could not have deleted
`agent-state/lanes/pi-vps/2026-09-18/` at any cadence. The timer passing at
00:12:18 was coincidence with the reporter's discovery at ~00:11.

What actually deleted the dated dir is not provable from surviving evidence:

- **The user journal does not reach the window.** `journalctl --user
  --list-boots` shows a single boot entry starting 2026-09-20 07:13 IST; the
  system journal shows the same boundary. `journalctl --user --since
  2026-09-18` returns zero entries. The incident window was vacuumed with the
  Sep-20 journald restart.
- **No `actions.log` line records it.** `agent-state/actions.log` in the
  18:30–19:00 UTC window contains only the reporter's own pi-scout-repair@
  edit (line `2026-09-18T18:48:23Z`).
- **No cleanup organ covers the path.** `systemd-tmpfiles --user
  --cat-config` lists `agent-worktrees` (3d), `.pi/agent/sessions` (7d),
  `.cursor/chats/*/` (2d), `.local/state/pi-issues` (7d) — nothing under
  `agent-state/lanes/`. No crontab exists. `fleet-gardener.timer` is weekly.
- The dated `lanes/<lane>/<date>/processed-N.md` store belonged to the
  pi-vps judge/dispatch lane whose writers were deleted across the 2026-09-18
  sweep wave (`efaa7fa57` memoryctl cut 18:02 IST, then the #7828 sweep); a
  sweep-side cleanup of the orphaned state tree is consistent with `lanes/`
  losing the `pi-vps` child before the reporter looked, but no receipt names
  the actor. Unattributable stays unattributable — declared, not smoothed.

**The ask is moot regardless.** "Logrotate needs a min-age guard or the
packet must live outside the rotated tree": the accused organ was deleted by
`1ae2704cc` (#7828, merged 2026-09-21 18:20 UTC — the commit body names the
logrotate pair a "dead logrotate organ"). Nothing on main writes or reads
`agent-state/lanes/<lane>/<date>/` anymore — `prompts/` (intake, worker,
scout, daily-digest, alert-repair, gardener) contains zero `lanes/` or
`processed-` references; worker packets now enter via the claim branch +
repo prompt files. A guard on a dead convention protects nothing.

## 2. daily-digest.service at 00:00:18 — attributed to 334a7c9a5

Commit `334a7c9a5` ("cut(digest): daily-digest becomes a Pi prompt on the
same timer", nishfleet-worker[bot], **2026-09-18 23:59:01 IST**) moved
`daily-digest.{service,timer}` from loose files in `~/.config/systemd/user/`
into `systemd/` so fleet-sync owns them. The live paths are now symlinks into
the deploy clone, and both carry mtime **Sep 19 00:00** — the relink happened
inside that run. The service starting at 00:00:18 sits inside the same
install window: a re-armed `Persistent=true` timer with no fresh last-run
stamp fires on activation, and a prove-it start is the same class of act by
the same run. Which of the two systemd-level triggers fired is not resolvable
(journal window gone); the attribution to the 334a7c9a5 install run is —
there is no other writer at 00:00 and the files' link times prove it touched
exactly these units. The service then died at 00:05:46 on the shared
LiteLLM `Connection error` window — a known transient, not a second mystery.

## 3. minimax-token-refresh units vanished — attributed to 4b6f7334d

Commit `4b6f7334d` ("cut(minimax-token-refresh): no MiniMax deployment left
for a rotated key to reach", nishfleet-worker[bot], **2026-09-19 00:09:15
IST**) deleted `bin/minimax-token-refresh`, `systemd/minimax-token-refresh
.{service,timer}` and the test; its body records "Timer and service disabled
--now and unlinked before removal." The transient timer's `Unit to trigger
vanished` at 00:09:00 is systemd noticing that run's live unlink — the
deletion is the sweep commit's own documented action, not an unattributed
writer. The reporter's `reset-failed` cleared the stale not-found record.

## 4. pi-scout-repair@ sweep completion — verified, no resurrection path

The reporter removed the dead `scout-futility-check` ExecStopPost from the
live `pi-scout-repair@.service` at 00:18 (actions.log line above) and asked
whether the repo-side template can re-introduce it. Verified today:

| Check | Result |
|---|---|
| `grep -n scout-futility-check systemd/pi-scout-repair@.service` | no match — the template carries no ExecStopPost at all |
| `systemd/pi-scout@.service` | mentions the pair only in the historical "were fleet self-monitoring… Gone" comment |
| `ls -l ~/.config/systemd/user/pi-scout-repair@.service` | symlink → `~/workspaces/tooling/fleet-ops-deploy-clone/systemd/pi-scout-repair@.service` |
| Live file content | identical to repo HEAD — no futility reference |
| `pi-scout-repair@.service.pre-scout-futility-sweep-*` backup sibling | absent from `~/.config/systemd/user/` (already cleaned) |

The deploy path that the issue worried about (`install.sh` copy) no longer
exists — `72b38e857` replaced copy-then-detect-drift with linked units: a
`git pull` IS the deploy, so the live file can only ever be what origin/main
carries. There is no copy to resurrect the dead line from.

## 5. pi-scout@ + repair chain

Re-run at 00:19:34 by the reporter and verified activating; the 04:02 timer
fire covered the next run. Nothing left to do. Confirmed healthy today:
`pi-scout@fleet-ops.timer` last passed 04:03:45 IST, next 08:00:36.

## Fresh live verification (2026-09-22 ~07:5x IST, netcup-rs2000)

| Check | Result |
|---|---|
| `systemctl --user list-units --state=failed` | EMPTY |
| `curl 127.0.0.1:4000/health/readiness` | `{"status":"healthy","db":"connected"}`; every `litellm_deployment_state` gauge 0.0 |
| `systemctl --user list-timers` | 10 timers armed; no `pi-packet-logrotate`, no `minimax-token-refresh`, `daily-digest.timer` armed 09:00 IST |
| `ls ~/.config/systemd/user` | no `pi-packet-logrotate.*`, no `minimax-*`, no `*.pre-scout-futility-sweep-*` |
| `stat ~/workspaces/agent-state/lanes` | mtime 2026-09-21 00:49 IST — `pi-vps` is one of the children swept since the incident |
| `git log -S pi-packet-logrotate` | organ deleted on main by `1ae2704cc` (#7828) |

## Residual gap, named honestly

Live-file writes outside the repo rail (state dirs, `~/.config` symlinks)
carry no machine attribution: `actions.log` is voluntary per-agent prose and
the user journal's retention proved shorter than the time between an incident
and its issue being picked up (~3 days vs ~2 days kept). The fleet's standing
rule bars new organs without Nish's explicit yes, so this record names the
gap rather than building over it. Stock levers exist if it ever becomes a
priority: journald `SystemMaxUse`/persistent storage and tmpfiles rules are
config, not organs.

encoded: prose - investigation record; no code mechanism exists to fix (the
accused organ is deleted, the convention it guarded is retired, and an
attribution organ would need Nish's explicit yes)
