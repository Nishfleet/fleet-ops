## What

fleet-ops#1380 asked to prune or re-auth the dead `credentials_bad` seats so
health counts stop reporting phantom capacity. Re-auditing the snapshot's 12
seats against live state today: most recovered (straitly/ds4-pro, ollama,
groq, cline → z-ai/glm-5.3-flash, zenmux → glm-4.7-flash-free) or were already
benched cap=0 with dated reasons (opencode deepseek-v4-flash-free /
x-preview-f-free / muse-spark, commandcode out-of-credits is tracked in
#1890). The one seat that is *currently* dead, non-recoverable (its real
credential is a Nish `grok login --device-auth`, tracked separately in #1949)
and still reported as phantom walled capacity every tick is the **grok
dead-decoy** — superseded by `xai-oauth`, which already carries grok-4.5/4.6 on
the healthy subscription-proxy path. This PR prunes it.

Changes:
- `bin/fleet-seat-live-validate`: guard the grok-ledger write. It only paints
  `grok__grok-4.6/4.5.json` when `grok` is still an enumerated seat in
  `~/.pi/agent/models.json`. Once pruned, it skips the write (log + triage +
  auto-file for the grok-CLI watch still fire), so the phantom ledger cannot be
  re-created. If models.json is absent we fail open (paint as before) so the
  dead-decoy watch is never silently dropped. If a human re-wires grok later,
  painting resumes automatically.
- `config/seat-caps.json` + `config/entitled-seats.json`: record the #1380
  prune verdict on the grok dead-decoy row (cap stays 0 `dead_decoy` for
  auditability; xai-oauth is the sole live SuperGrok seat).

This is the mechanism that prevents the phantom-capacity regression class: the
canary can no longer re-paint a pruned decoy.

## Verification

Live (this run, `~/.local/bin/fleet-seat-live-validate` with the guard):
```
grok decoy pruned from models.json (fleet-ops#1380): skipping grok__grok-* ledger write; health-count phantom not re-painted (triage/auto-file still fire)
OK grok CLI dead but xai-oauth independently validated healthy — NOT marking xai-oauth dead
```
After the prune the per-seat health ledger dropped 32 -> 30 seats and the
dead/`credentials_bad` set went from `[grok/grok-4.5, grok/grok-4.6]` to none:
```
total seats: 30 | healthy: 16 | walled: 14
dead/credentials_bad seats now: (none)
```
Primary creds file removed; stale `grok__grok-*.json` ledger entries deleted.
run-proof: `tests/fleet-seat-live-validate.test.sh` scenario 13 (new) pins the
pruned case green — no `grok__grok-*` ledger re-painted, xai-oauth still
written; full suite green. `tests/entitled-wired-canary.test.sh` green
(production inventory still matches seat-caps). `sgscan` clean. `crgate` could
not run (CodeRabbit not signed in on this host — environment, not code).

mechanism-impossible: N/A — a regression guard (canary skip-on-pruned) plus a
pinned test scenario is shipped.

Closes #1380
