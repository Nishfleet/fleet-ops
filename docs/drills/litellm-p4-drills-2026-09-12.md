# LiteLLM P4 — proxy-down and Postgres-down drills (fleet-ops #4264, #4130 programme)

Both drills ran live on netcup-rs2000 on **2026-09-12 (all timestamps IST)**.
Operator: pi-issue-fleet-ops-4264. The drill scripts are bounded and
self-restoring (hard restore step at the end, timeout-gated); no data was
dropped — the pg_dump restore proof runs against a throwaway scratch cluster.

Baseline at T0 (23:25:03 IST): `curl 127.0.0.1:4000/health/readiness` →
`{"status":"healthy","db":"connected"}`, health canary green every 60s
(census 13/13, groups=5, pg_up=1, redis_up=1).

## Drill 1 — proxy down (23:25:03–23:28:18 IST, 195s total)

| IST | event |
|---|---|
| 23:25:03 | T0: readiness healthy/connected |
| 23:25:04–23:25:22 | 6× `systemctl --user kill -s SIGKILL fleet-litellm-proxy.service` (Restart=on-failure, RestartSec=2s) |
| 23:25:04–23:25:16 | `unit-escalation@fleet-litellm-proxy.service` fired **5×** — one per failure; OnFailure escalation is live for the proxy unit |
| 23:25:24 | unit: `active=failed result=signal nrestarts=6` — StartLimitIntervalSec=60s/Burst=5 hit; **readiness = connection-refused** |
| 23:25:38 (T+35s) | consumer probe `pi --print --provider litellm --model judge`: **no reply** (connection refused; the call fails in ~14s incl. pi startup — well under the 60s bound). The pi-issue-run pick fails the same way via `litellm_ready` (3s curl) → exit 1 → OnFailure — the #5093 walled-fleet gate. |
| 23:26:00 (T+57s) | canary: `proxy unreachable ... (dead 0s < 60s tolerance ... holding)` — 1st tick held by design |
| 23:26:23 | `pi-intake@fleet-ops` triggered mid-outage |
| 23:27:00 (T+117s) | canary: `proxy unreachable ... for 60s >= 60s (organ dead)` → **exit 1 → FAILED → "Triggering OnFailure= dependencies"** |
| 23:27:33 | failed-unit list: BOTH `fleet-litellm-proxy.service` and `fleet-litellm-health-canary.service` in `--state=failed` |
| 23:28:13 (T+190s) | RESTORED: `systemctl --user reset-failed` + `start` → readiness **200** (3.2 min ≪ 10-min bound) |
| 23:28:18 | same consumer call: **`ok`** — green again |
| 23:29:00 | canary self-heals on its next tick: `proxy_up=1 status=200 census=13 ... pg_up=1 redis_up=1`, failed state cleared on the successful start |

Escalation proof: `unit-escalation@fleet-litellm-proxy.service` ran 23:25:04 → 23:25:16 (one per SIGKILL failure), and the canary's OnFailure dependency fired at 23:27:00. Proxy stayed down the rest of the minute (StartLimitIntervalSec=60s, Burst=5) — the unit-file contract from P1 is real.

**Direct-seat restore path (proven):** workers never need the proxy to run:
`pi --print --provider devin --model glm-5-2 "reply ok"` → reply in 6s at
23:40-ish IST, 200-class, routing straight to `api.devin.ai` (the
`models.json` direct-provider form; never touches 127.0.0.1:4000). The
same invocation is the documented manager-mode worker pattern. Restore =
either wait ~2–3 min for `Restart=on-failure` (auto), or
`systemctl --user reset-failed fleet-litellm-proxy.service &&
systemctl --user start fleet-litellm-proxy.service` (proven idempotent,
readiness 200 at T+190s). Both ≪ the 10-minute bound.

## Drill 2 — Postgres down (23:36:56, 164s)

Baseline: 72 LiteLLM_* tables, 3 VerificationToken rows, readiness healthy.
Restore input prepared first: **plane E of the restore drill** (this branch)
dumped the control plane at 23:29:40 IST and proved the dump loads into a
scratch cluster — 72 LiteLLM_* tables in 16s, within the 180s bound
(`litellm-20260912T175940Z.sql.gz`, 11 MB). A failing pg_dump is exit-1
LOUD (test scenario M); an organ-not-installed host skips the plane (N)
instead of lying green.

| IST | event |
|---|---|
| 23:36:57 | `systemctl --user stop fleet-litellm-postgres.service` → proxy pulled down by `Requires=` within seconds |
| 23:37:00 | canary tick: `proxy unreachable ... (dead 0s < 60s tolerance — holding)` |
| 23:37:16 (T+20s) | readiness **000 connection-refused**; pg auto-restarts (NRestarts=1, Restart=on-failure) |
| 23:37:31 (T+35s) | consumer probe on the worker-cheap group: **no reply** (fail loud) |
| 23:37:37 | direct-seat probe (`devin/glm-5-2`) during the outage: rc=0, path bypasses the proxy by construction (baseUrl=api.devin.ai) |
| ~23:38:01 (T+65s) | organ pair **self-healed**: pg NRestarts=1, proxy back, canary `proxy_up=1 status=200 pg_up=1` — the Requires=+Restart chain heals itself |
| 23:39:27 (T+151s) | documented restore re-run for proof: `start fleet-litellm-postgres` → `pg_isready` "accepting connections" → `start fleet-litellm-proxy` → readiness **200** (idempotent no-op vs the self-heal) |
| integrity | 72 tables + 3 keys before == after; **zero data loss** |

Fail-loud on Postgres-down: consumers fail in seconds (no-reply vs `ok`), readiness 000, canary holds the fault at T+4s and would trip on the second unresolved tick (the full trip + OnFailure escalation was proven end-to-end in drill 1 — same organ, same `service.d/10-escalate.conf` drop-in). The **restore** contract is proven at both layers: the distro unit (`fleet-litellm-postgres.service` running the distro postgres-16 binary) re-accepts connections in seconds, and plane E's recurring pg_dump + scratch-restore proves the control plane is RECOVERABLE — 72 LiteLLM_* tables reload from the 23:29:40Z dump within the 180s bound, restored into a throwaway cluster (non-destructive; no live clobber).

## Mechanism shipped this PR (plane E, `bin/fleet-restore-drill`)

The restore contract needs "the backup job's pg_dump" to EXIST. Plane E
makes the existing 6-hour `fleet-restore-drill` take it: pg_dump the
litellm database over the user-owned socket into
`agent-state/backups/litellm-<stamp>.sql.gz` (keep 14), then initdb a
throwaway cluster on port 5433 and load the dump (ON_ERROR_STOP, bounded
180s), asserting ≥1 LiteLLM_* table. Marker now carries
`litellm-pg dump+scratch-restore proven` when E ran. Absent cluster →
SKIP (the health canary owns organ liveness, not this drill); dead
cluster or failed dump → exit 1 LOUD, no dangling dump. Proven live:
16s plane-E run at 17:59:40–17:59:56Z (23:29:40–23:29:56 IST),
"`E. - OK: dumped litellm -> litellm-20260912T175940Z.sql.gz +
scratch-restore proven (72 LiteLLM_* tables, bound 180s)`", drill RC=0,
marker rewritten at 17:59:56Z.

## Re-armed canary (bullet 5)

Premise of the issue: the canary was stopped 2026-09-07. Live state found:
it was re-armed by the #4221 fail-open fix and has been firing every 60s;
during this turn it censused 13/13 deployments with pg/redis up. The timer
endures deploy-check (no action needed — verified, not assumed). It
failed loud during drill 1 (23:27:00) and self-healed at 23:29:00
(`proxy_up=1 census=13`).

## Deleted-unit list

Unit/timer FILES already deleted in earlier LiteLLM phases (verified live
2026-09-12: no unit files remain under `~/.config/systemd/user/`, no
MANIFEST rows, not in `systemd/` on main):

- `fleet-aimd-meter-canary` — AIMD is gone (design verdict: DELETE)
- `fleet-entitled-wired-canary` (unit) — design verdict REWRITE to /model/info
- `fleet-prepaid-util-canary` (unit) — design verdict: DELETE
- `fleet-seat-live-validate` (unit) — design verdict: DELETE
- `fleet-seat-bench/corpse` timers of the old picker

Still-not-deleted RESIDUAL (design verdicts executed only partially; the
proxy's health checks are the authority, but these still exist as
tier1-embedded invocations): tier1 blocks 15/30/37/38 still run
`fleet-entitled-wired-canary`, `fleet-seat-live-validate`,
`fleet-aimd-meter-canary`, `fleet-prepaid-util-canary` on every 5-min
tick; the 4 bins remain installed (~/.local/bin), with their test hosts
(escalation-coverage-canary.test.sh) and MANIFEST rows. Follow-up issue
files this turn: the remaining cull (REWRITE entitled-wired to /model/info,
delete live-validate + the two 9-line residue meters + MANIFEST rows +
prom/ledger leftovers).

## Vault ledger line

`00 Inbox/agent-drop/pi/vps/2026-09-12-litellm-p4-drills.md` (this drop
records the drill outcomes + the deleted-unit list per the vault contract).
