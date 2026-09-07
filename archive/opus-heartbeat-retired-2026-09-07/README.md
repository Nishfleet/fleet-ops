# opus-heartbeat family — retired 2026-09-07 (fleet-ops#4141)

One-time archive of the 5 live scripts that lived in `~/.local/libexec/`
(outside any git worktree, per their own headers). Archived here so git
IS the backup before the live copies + 6 `.bak` copies were `rm`'d.

Retired because they re-derived fleet state Prometheus already held. The
hourly fleet judge (`fable-fleet-check.service`, packet
`agent-state/fleet-landing-watch/fable-check.md`) is the single judge;
recording rules in `config/fleet_rules.yml` hold the derived numbers.

Files (frozen at retirement time, do not edit):
- `opus-heartbeat` — wrapper: gather + judge + allowlisted actions + prom writer
- `opus-heartbeat-gather` — 1,749-line snapshot gatherer
- `opus-heartbeat-run` — runner helper
- `opus-heartbeat-fallback` — Pi fallback when Claude auth/quota wall hit
- `heartbeat-audit` — audit helper

See: fleet-ops#4141, vault `_system/shared-memory/retired-mechanisms.md`.
