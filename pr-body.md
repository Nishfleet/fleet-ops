## Why

The straitly ds4-pro first-draw canary (fleet-ops#546) auto-files a
meter-check ticket whenever an active `deepseek/deepseek-v4-pro` worker is
seen without a recent dated meter evidence file. Workers cannot complete
those tickets: the public Straitly API exposes no non-admin balance
endpoint — `/v1/chat/completions` returns per-call `usage.cost` only,
`/v1/admin/keys/{key_hash}/spend` is admin-scoped (403 on the wired key),
and remaining credits live behind a Firebase console login. Ticket #1248 is
the live example: a worker proved all three paths and had to stop.

The issue asks to either document a non-admin balance endpoint (none
exists) or stop auto-filing tickets the API cannot satisfy. This PR does
the second: the meter-check observe-to-open is removed from
`bin/fleet-straitly-ds4-pro-canary`. The canary keeps every fail-loud
gate (seat-caps class/caps, single-slug allowlist, no double-wire,
models.json + `pi --list-models` proof) and stays green for config/routing
violations; it just stops spawning a ticket whose only satisfier is a
human with console access.

## Scope

- `bin/fleet-straitly-ds4-pro-canary`: deleted the meter-check block 8
  (`first_draw_started_at`, `meter_check_recent_for`, the
  `STRAITLY-DS4PRO-METER-CHECK-NEEDED` loud + `file_finding "meter-check"`
  call), the `FLEET_STRAITLY_DS4PRO_METER` / `_METER_WINDOW` seams, and the
  now-dead `ACTIVE_SEATS_DIR` seam. Header comment updated.
- `config/rule-enforcement.json`: `led-straitly-ds4-pro-workers` mechanism
  text no longer claims the canary auto-files a meter-check ticket;
  notes the removal reason.
- `tests/fleet-straitly-ds4-pro-canary.test.sh`: scenario 11 replaced the
  three meter-check scenarios with a regression proving an active
  straitly/ds4-pro worker with no meter evidence exits 0, files nothing,
  and raises no METER-CHECK loud. Production/wiring scenarios renumbered.
  `test-removal-justified:` trailer on the commit names why scenarios
  11-13 were deleted and what replaces them (the auto-filing behavior they
  locked is the thing being removed; the regression scenario keeps the
  guard proved).

Out of scope: #1248 stays open (it needs a human with console access to
paste the number — the blocker lived there, not in the canary).

## Tradeoffs

- The ledger line's "meter check within minutes of first draws" intent is
  not enforced by automation anymore. It cannot be: no API path returns
  remaining credits. A human with the console can still check and the
  evidence file contract is not enforced either way; nothing in this PR
  prevents a manual check.

## Blast Radius

- `fleet-heartbeat-tier1` block 25 runs the canary and captures its exit
  code; the canary's exit semantics for the fail-loud gates are unchanged,
  so tier-1 wiring is untouched.
- The triage tag `STRAITLY-DS4PRO-METER-CHECK-NEEDED` had no consumer
  outside the canary (verified by grep). Removing it breaks nothing.
- No new unit, timer, workflow, or bin/ file; no heartbeat metric.

## Verification

- `bash tests/fleet-straitly-ds4-pro-canary.test.sh` — all 13 scenarios
  pass, including the new regression (active straitly worker, no meter
  evidence → exit 0, no `issue create`, no METER-CHECK loud).
- A/B guard proof: ran the pre-change canary from `origin/main` against
  the same fixture (active straitly seat, no meter file) — it raised
  `STRAITLY-DS4PRO-METER-CHECK-NEEDED` and attempted the file; the new
  canary on the identical fixture exits 0 with `STRAITLY-DS4PRO-OK` and no
  gh call.
- `sgscan` — no new security findings.
- `bash tests/rule-enforcement.test.sh` — the weekly-fleet-review drill
  fails on origin/main too (pre-existing 8-lens prompt drift, tracked as
  #2186); unrelated to this diff.
- gate: `fleet-exec-review-canary`, `fleet-no-agent-names-check`,
  `fleet-token-efficiency-check`, `fleet-wipe-lessons-check scan` all run
  below.

Closes #1338