# Observe-close for #6845 — NISH-ESCALATIONS.md header-only starvation; every required-fix subject has since been deleted

Issue #6845 recorded a real outage of the reserved-class page channel:
between 2026-09-10 and 2026-09-14, ~10 orchestrator decision-sweep runs
wrote `## <date>` section headers into `agent-state/NISH-ESCALATIONS.md`
claiming "landed AND verified" canonical lines, while
`grep -cE '^[0-9]{4}-'` on the file returned 0. `bin/nish-boundary-notify`'s
parser had nothing to deliver, so five open reserved-class waits never
reached Nish's phone despite ten runs believing they had escalated.

Every subject named in the issue's required fix was deleted in the
2026-09-18 glue sweep, so the acceptance items are moot as written:

| issue requirement | subject | fate |
|---|---|---|
| 1. sweep appends MUST be header+lines in one write, verified by pre/post grep counts | `prompts/orchestrator-decision-sweep.md` + `agent-cron-orchestrator-decision-sweep.service` | deleted by `a437f7be6` "chore(second-cut-B)", ancestor of `origin/main` — no sweep writes this file at all |
| 2. notifier header-only guard (exit 1 on a `##` section with no canonical line) | `bin/nish-boundary-notify` (513 lines) + `nish-boundary-notify.path` | deleted by `6fdd20ed1` "cut(escalation): one stock amtool line replaces the 1,181-line notify tower", ancestor of `origin/main` |
| 3. name the seat approval gate if it strips line-appends | — | moot: the live path traverses no seat. `amtool alert add` POSTs straight into alertmanager; there is no model call between the agent's line and the phone |
| termination: two consecutive sweeps carrying pre/post counts + header-only drill exits 1 via the notifier | the sweep and the notifier | both deleted; substituted by the live drill of the replacement rail below |

Live state re-verified on this host, 2026-09-20T06:2xZ:

- `agent-state/NISH-ESCALATIONS.md` does not exist (only
  `nish-escalations-archive/` and a `.res-drill-boundary/` fixture remain).
- `systemctl --user list-unit-files --type=path` → only
  `pi-intake-trigger.path`; nothing watches an escalation file.
- `bin/nish-boundary-notify`, `bin/fleet-escalation-drain`,
  `bin/money-boundary-raise`, `bin/hermes` are absent from `origin/main`
  and from `~/.local/bin`; `fleet-escalation-drain` went with the
  escalation-tower cut `9f0cba02c` (Jev 0.87).
- Nothing on `main` instructs an append to the file: the remaining
  `NISH-ESCALATIONS` references (`docs/standing-rules.md`,
  `prompts/daily-digest.md`, `config/alertmanager.yml` comments) all
  document the replacement, not the file.

## Why the failure class cannot recur in this shape

The starvation was a parser-miss: a header without canonical lines was a
state that existed in a file and was invisible to the reader. The
replacement rail has no intermediate document —
`amtool alert add alertname=NishEscalation severity=nish --annotation=summary='...'`
is a synchronous POST: either alertmanager stores the alert or amtool
exits nonzero in the caller's hands. The alert list itself is the receipt
(`amtool alert query severity=nish`; `prompts/daily-digest.md` step 8 runs
it every morning), so "claimed but absent" is checkable by anyone, not
only by a dedicated parser.

## Live drill, 2026-09-20

```
06:24:59Z  amtool alert add alertname=NishEscalation severity=nish \
             --annotation=summary='DRILL fleet-ops#6845 observe-close: ...' → exit 0
~06:26Z    alertmanager_notifications_total{integration="telegram"}: 16 → 17
           alertmanager_notifications_failed_total{integration="telegram"}: 0 for every reason
06:26Z     re-sent same labels with --end in the past → resolved
06:28Z     telegram counter 17 → 18 (send_resolved:true delivered the
           resolution too); `amtool alert query severity=nish` → 0 active
```

Same proof pattern as `6fdd20ed1` (counter 6→8) and
`docs/reports/nish-boundary-notify-observe-close-6800.md`.

## The one surviving gap, closed by this PR

The file rail is gone but the last hop could still fail silently: a dead
telegram bot token or a down alertmanager would leave severity=nish
escalations accepted-but-undelivered — the same dark-channel class — and
Prometheus did not scrape alertmanager at all
(`{__name__=~"alertmanager_.+"}` → empty, verified 2026-09-20T06:2xZ).

This PR therefore adds:

- `config/prometheus.yml`: the `alertmanager` scrape job
  (127.0.0.1:9093, stock `/metrics`).
- `config/fleet_rules.yml`: `FleetNishPageRailDown` in the
  `fleet_watchdog` group — fires when
  `alertmanager_notifications_failed_total{integration="telegram"}`
  rises or `up{job="alertmanager"}` is 0/absent. severity=critical →
  repair-dispatch (an auditor), never the phone: telegram is the thing
  that is broken, and paging through it would be the starvation bug
  wearing a new hat.

## Provenance

- Salvage chain `5cf2d1eba` → `8f736f38b` → `d812587d4` (PR #7538, closed
  unmerged 2026-09-18T05:48:27Z when its claim branch reset) patched the
  notifier/drain/sweep-prompt files. Re-landing them on current `main`
  would resurrect organs removed by Jev-approved deletions, so the patch
  is deliberately not carried forward.
- The 2026-09-17 `decision-resolved:` comment ("resume preserved
  notifier/drain patch … original acceptance stays") predates the cuts;
  the acceptance subjects no longer exist, so it cannot be executed as
  written. This record is the substitute evidence.
- Related: #6800 observe-close (`f1d52dc0f`, same subject organ), #7486
  (coderabbit sign-in, closed).
