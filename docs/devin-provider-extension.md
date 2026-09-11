# Devin provider extension — flags, why, date

The `devin-provider` Pi extension (`~/.pi/agent/extensions/devin-provider/index.ts`)
routes Devin Pro through the Devin CLI. This doc records the current invocation
flags, why they are what they are, and when they changed (fleet-ops#4780).

## Current invocation (2026-09-09)

```
devin --print --prompt-file <prompt> --model <model> \
      --respect-workspace-trust false \
      --permission-mode dangerous
```

- **`--permission-mode dangerous`** — Devin may write files and run commands.
- **No `--sandbox`** — the sandbox is deliberately off.
- **`--respect-workspace-trust false`** — the CLI must not refuse an untrusted
  workspace (fleet-ops#4825).

## Why (2026-09-09)

`--sandbox` forces Devin's "autonomous" permission mode. Since 2026-09-08 the
CLI rejects every file write non-interactively under that mode with the literal
`rejected a tool call that requires confirmation`, so **100% of runs ended empty
at the first edit** (30+ empty runs on 2026-09-09). Probe: no sandbox +
`--permission-mode dangerous` writes and runs; sandbox with any mode does not.

Devin now runs unsandboxed on the VPS like every other seat — standing VPS
write autonomy (Nish, 2026-08-05).

## Safety net

`lib/seat-lib.sh` classifies the `rejected a tool call that requires
confirmation` literal as `devin-writes-rejected` (matcher
`is_devin_writes_rejected`, writer `mark_seat_devin_writes_rejected_bench`).
If a future Devin CLI update restores writable sandboxing, re-probe with the
two commands in the issue before restoring `--sandbox`; until then it stays
off. The classifier benches the seat with a named reason instead of a day of
empty runs, and never retires it (a CLI/flag config fault is infrastructure,
not seat yield).

## Rate-limit resume (2026-09-11)

A Devin "Reached overall message rate limit ... reset in N minutes" no longer ends the
pi session. `rate-limit.ts` parses the advertised reset, the provider waits it out
(min 30s, max 20 min, +15s slack) and re-runs the same packet with a RESUME NOTE, up to
3 attempts, only while enough of pi-issue-run's watchdog budget (`PI_HANG_TIMEOUT_S`,
now exported) remains for a real run. The seat ledger still records the wall (other
workers skip the seat); a successful resume rewrites it healthy. Knobs:
`PI_DEVIN_RATE_LIMIT_{MAX_ATTEMPTS,MIN_WAIT_S,MAX_WAIT_S,MIN_RUN_S}`.
Test: `tests/devin-provider-rate-limit-retry.test.sh`.
