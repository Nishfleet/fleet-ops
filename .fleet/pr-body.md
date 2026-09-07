## What changed

The 0509 scout usage block (fleet-ops#3149) treats Cloudflare Zone Analytics as
one best-effort source. The sanctioned CF token lacks `zone.analytics.read`
for the 0509 zone, so the GraphQL call returns a 403 authz error and the
source drops. Per the judge opus-5 decision (2026-09-07), this issue makes
that source explicitly OPTIONAL and grounds the scout on the three working
sources instead of waiting on a token re-scope.

### 1. CF analytics source is optional (fleet-ops#3172)

`lib/packet-assembly.sh` `packet_cf_analytics_usage` now detects the 403
`zone.analytics.read` authz error and logs a one-line
`usage-source: cloudflare-analytics UNAVAILABLE (token scope)` marker, then
DROPS (returns 1). A missing optional source never fails the scout run or
drops the whole usage block — the other sources (lp_run_audit, /search query
log, inbound email) still assemble around it.

### 2. TODO(fleet-ops#3172) at the CF call site

A `TODO(fleet-ops#3172)` comment sits at the GraphQL call site. Once the
sanctioned token is re-scoped with Zone Analytics Read, the call returns data
instead of the authz error, the UNAVAILABLE branch stops matching, and the
block prints normally — no code change needed.

### 3. Reader path for the working sources (verified + tested)

The reader path for `lp_run_audit`, the /search query log, and inbound email
already exists (`packet_local_usage` / `packet_inbound_email_usage`). This PR
adds tests proving the reader path reads dump dirs into the usage block and
that a missing dump dir DROPS with a marker instead of failing. The dump side
(populating `$PACKET_LP_AUDIT_DIR` / `$PACKET_SEARCH_LOG_DIR`) is a 0509-app
concern and is tracked as a follow-up.

## Verification

- Live probe of `packet_cf_analytics_usage 0509.io 7` against the real
  sanctioned CF token (VPS, token value never printed):
  ```
  usage-source: cloudflare-analytics UNAVAILABLE (token scope)
  ### Cloudflare analytics (0509.io, 7 days): Actor 'com.cloudflare.api.token...' does not have permission 'com.cloudflare.api.account.zone.analytics.read'
  exit=1
  ```
  The source logs the availability line and DROPS (exit 1), non-fatal.
- Integrated `packet_usage_block` with a real lp_run_audit + /search query
  log dump dir: CF source drops with the UNAVAILABLE marker, lp_run_audit and
  /search query log are read into the block, and the whole block assembles
  with exit 0 (never fails the scout run).
- `bash tests/pi-scout-packet-assembly.test.sh` -> green (exit 0), including
  the two new sections: CF 403 logs `usage-source: cloudflare-analytics
  UNAVAILABLE (token scope)` and drops; reader path reads lp_run_audit and
  /search query log dumps.
- `bash tests/cf-token-canary.test.sh` -> green (exit 0).
- `bash tests/pi-scout-seat-rotation.test.sh`, `sr-token-efficiency-debt`,
  `failure-mechanism-gate`, `fleet-failed-command-flagged` -> green.
- `bash -n lib/packet-assembly.sh` -> OK. `sgscan --base origin/main` -> no
  new security findings.

run-proof: live `packet_cf_analytics_usage 0509.io 7` against the real
sanctioned CF token returned exit 1 with the `usage-source:
cloudflare-analytics UNAVAILABLE (token scope)` line and the authz drop
marker; integrated `packet_usage_block` with real lp_run_audit + /search
query log dump dirs assembled the full usage block with exit 0; the
pi-scout-packet-assembly test (including the two new sections) and the
cf-token-canary test both ran green.

net-positive-because: the +68 lines are the CF-optional branch (log line +
TODO + doc) and two test sections proving the optional-source and reader-path
behaviour; the net-positive is the durable fix that grounds the scout on the
three working sources and makes the fourth non-fatal, per the judge opus-5
decision.

organ-heartbeat: lib/packet-assembly.sh not-an-organ: a sourced helper lib
invoked only from inside the existing scout run; no new unit, timer, workflow,
exporter, guard, or canary.

loose-ends: dump path for lp_run_audit / /search query log / inbound email
(populating $PACKET_LP_AUDIT_DIR / $PACKET_SEARCH_LOG_DIR) is a 0509-app
concern and is filed as a follow-up; the reader path is shipped and tested
here.

Closes #3172
