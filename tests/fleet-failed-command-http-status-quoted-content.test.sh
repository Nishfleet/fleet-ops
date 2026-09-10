#!/usr/bin/env bash
# tests/fleet-failed-command-http-status-quoted-content.test.sh
#
# fleet-ops#5032: a `HTTP 4xx/5xx` token QUOTED as data must not veto the
# grep/rg no-match exemption in `lib/failed-command-flagged.py`.
#
# Live #5032: the alert-repair worker ran the compound probe
#   curl -s 127.0.0.1:9090/api/v1/alerts 2>/dev/null | head -c 2000;
#   echo; echo "---TIMERS---";
#   XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers 2>/dev/null |
#     grep -i cpu-sampler
# The terminal `grep -i cpu-sampler` matched nothing, so bash exited 1 —
# a POSIX no-match probe, which the standing rules say is NOT a failure.
# But the Prometheus alerts payload the earlier (successful) `curl` stage
# printed quotes the provider quota wall in an annotation
# (`... a provider has >=2 seats reporting HTTP 402/health_class=quota_exhausted
# within the last 1h ...`), the bare `HTTP\s*[45]\d\d` alternative in
# REAL_ERR_RE matched that quoted string, and `is_benign_no_match`
# returned False before the BENIGN_STAGE_RE exemption could apply. The
# session was filed as FAILED-COMMAND-SWALLOWED (issue #5032) for a probe
# that was never a failure.
#
# The fix: the HTTP alternative in REAL_ERR_RE is envelope-anchored
# (`gh:` / `curl:` / `wget:` followed on the same line by `HTTP 4xx/5xx`),
# because a bare token anywhere in a toolResult blob is content — a
# Prometheus alert annotation, a seat-caps reason string, docs, source
# code. That is the same doctrine the isError=false guard already
# encodes: successful output quoting error strings is content. The other
# alternatives (`Not Found`, `Permission denied`, `error TS<N>`,
# `API rate limit`) keep their bare-token behaviour — they are the live
# #698 / #1061 / #1185 / #1253 signals and a `gh api` 404 still only
# ever reaches a probe through a `gh:` envelope anyway.
#
# Scenarios:
#   1. live #5032 shape: benign terminal grep no-match over a fetched
#      payload that quotes `HTTP 402` -> clean (0 findings). This is the
#      regression the fix exists for; a refactor that re-broadens the
#      HTTP alternative to a bare token turns this red.
#   2. cross-check: `gh: HTTP 502 (curl exit code 22)` as the terminal
#      line of the SAME benign grep chain -> still a finding (1). This is
#      the HTTP-only signal the envelope form must keep catching; a
#      refactor that drops the HTTP alternative entirely turns this red.
#   3. cross-check: `gh: Not Found (HTTP 404)` on a benign grep chain ->
#      still a finding (1). The non-HTTP alternatives are unchanged.
#   4. cross-check: the seat-caps reason shape (a bare `HTTP 402` /
#      `HTTP503` quoted inside a config file being searched) -> clean
#      (0 findings). Same false-positive class reached through `rg`
#      instead of the alerts payload.
#
# No `bin/` change: the detector and its library already exist; this
# file pins the classifier contract.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-http-status-quoted-content.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T21:00:00Z"
}

# write_session <name> <command> <toolResult text> [<assistant follow-up text>]
# Builds the JSONL with python3 so the payload text can be pasted
# verbatim (the live shapes are full of quotes and JSON escapes).
write_session() {
  local name="$1" cmd="$2" text="$3" follow="${4:-Moving on to the next check.}"
  python3 - "$sessions/$name.jsonl" "$cmd" "$text" "$follow" <<'PY'
import json, sys
out, cmd, text, follow = sys.argv[1:5]
lines = [
    {"type": "message", "message": {"role": "assistant", "content": [
        {"type": "toolCall", "id": "call_1", "name": "bash",
         "arguments": {"command": cmd}}]}},
    {"type": "message", "message": {"role": "toolResult", "toolCallId": "call_1",
                                    "toolName": "bash", "isError": True,
                                    "content": [{"type": "text", "text": text}]}},
    {"type": "message", "message": {"role": "assistant", "content": [
        {"type": "text", "text": follow}]}},
]
with open(out, "w", encoding="utf-8") as fh:
    for line in lines:
        fh.write(json.dumps(line) + "\n")
PY
  touch -d "2026-09-10T20:00:00Z" "$sessions/$name.jsonl"
}

# --- 1. live #5032: quoted HTTP 402 in a fetched payload is not a failure ---
# The toolResult text is the live shape: the Prometheus /api/v1/alerts
# JSON (the annotation quotes `HTTP 402/health_class=quota_exhausted`),
# the `---TIMERS---` marker, and the grep no-match exit 1.
write_session "quoted-http-402-probe" \
  'curl -s 127.0.0.1:9090/api/v1/alerts 2>/dev/null | head -c 2000; echo; echo "---TIMERS---"; XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers 2>/dev/null | grep -i cpu-sampler' \
  '{"status":"success","data":{"alerts":[{"labels":{"alertname":"Watchdog","severity":"none"},"annotations":{"description":"Always firing. If this disappears, Prometheus or Alertmanager is dead.","summary":"Watchdog heartbeat for the alerting pipeline"},"state":"firing","activeAt":"2026-08-29T22:06:04.453034516Z","value":"1e+00"},{"labels":{"alertname":"FleetProviderQuotaExhausted","instance":"127.0.0.1:9100","job":"node","service":"fleet","severity":"warning"},"annotations":{"description":"fleet-ops#2712: a provider has >=2 seats reporting HTTP 402/health_class=quota_exhausted within the last 1h. The per-provider fleet_provider_quota_exhausted{provider=\"...\"} series names the affected provider and its seat count; the seat-health ledger at /home/nish/workspaces/agent-state/lanes/seats lists each seat. This is ONE account-level billing wall, not N independent seat faults — triage the provider quota/billing, not each seat separately.","summary":"Provider quota exhausted"},"state":"firing","activeAt":"2026-09-09T20:20:34.453034516Z","value":"1e+00"}]}}
---TIMERS---

Command exited with code 1'

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "live #5032 quoted HTTP 402 with a terminal grep no-match must be clean (got $count) $report"
ok "live #5032: quoted HTTP 402 in a fetched payload + grep no-match is not a swallowed failure"
rm -f "$sessions/quoted-http-402-probe.jsonl"

# --- 2. cross-check: a gh HTTP-error envelope still vetoes the exemption ----
# Same benign grep chain, but the text carries gh's own error line. The
# envelope form of the HTTP alternative must catch this.
write_session "gh-envelope-http-502" \
  'gh api repos/Nishfleet/fleet-ops/actions/runs 2>&1 | grep -c conclusion' \
  'gh: HTTP 502 (curl exit code 22)
Command exited with code 1'

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh: HTTP 502 envelope on a grep chain must stay a finding (got $count) $report"
grep -q 'HTTP 502' <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "finding snippet should mention HTTP 502 (got $(jq -r '.findings[0].snippet' <<<"$report"))"
ok "gh: HTTP 502 (curl exit code 22) envelope is still flagged"
rm -f "$sessions/gh-envelope-http-502.jsonl"

# --- 3. cross-check: the non-HTTP alternatives are unchanged ----------------
# `Not Found` has no envelope requirement and must keep vetoing the
# grep/rg no-match exemption (live #698 class).
write_session "gh-envelope-not-found" \
  'gh api repos/Nishfleet/fleet-ops/contents/AGENTS.md 2>&1 | grep -i name' \
  '{
  "message": "Not Found",
  "documentation_url": "https://docs.github.com/rest",
  "status": "404"
}gh: Not Found (HTTP 404)
Command exited with code 1'

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh Not Found on a grep chain must stay a finding (got $count) $report"
ok "Not Found still vetoes the grep no-match exemption (live #698 class)"
rm -f "$sessions/gh-envelope-not-found.jsonl"

# --- 4. cross-check: the seat-caps reason shape is also content -------------
# The same false-positive class reached through `rg`: a bare `HTTP 402`
# (and the `HTTP503` no-space form) quoted inside a config file being
# searched, with no envelope line anywhere.
write_session "quoted-http-seat-caps" \
  'cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && rg -n "openrouter|opencode-go" config/seat-caps.json 2>/dev/null' \
  '      "cap": 0,
      "reason": "2026-08-27, n=3, HTTP 402, request id, ledger path (quota_exhausted)"
      "reason": "2026-09-10, n=149 straight HTTP503 / upstream unavailable"
Command exited with code 1'

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "quoted HTTP 402/HTTP503 seat-caps reasons with an rg no-match must be clean (got $count) $report"
ok "quoted HTTP 402/HTTP503 in searched config content is not a swallowed failure"
rm -f "$sessions/quoted-http-seat-caps.jsonl"

echo "OK: fleet-failed-command-http-status-quoted-content: live #5032 + envelope contrasts"
