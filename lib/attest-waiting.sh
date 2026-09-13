# fleet-ops#5870: the attest-waiting detector.
# shellcheck shell=bash
#
# A worker that hits a gate-owned path refuses to self-attest correctly, but
# three instances (0509#3068, 0509#3144, fleet-ops#5760) then parked the issue
# as kind=nish-decision and it sat for hours until a judge read it by hand.
# The classifier (bin/blocked-reconcile) now routes those to
# orchestrator-attest; THIS detector is the observer that catches any straggler
# in the agent-ready/agent-blocked queue: an issue whose latest blocked-status
# comment mentions an attestation and that has had no orchestrator comment for
# more than 2h. Zero is the normal value; any non-zero line is judge-visible
# (`attest-waiting: <n> [#a #b]` in the measure.sh header).
#
# Contract (testable in isolation):
#   attest_waiting_line <repo...>     prints exactly one line on stdout:
#     attest-waiting: <n> [#a #b ...] — waiting issues found
#     attest-waiting: 0               — the normal value
#     attest-waiting: UNAVAILABLE:<why> — gh failure, never a fabricated 0
# Env: ATTEST_WAITING_NOW=<iso8601>     freeze "now" (tests)
#      ATTEST_WAITING_STALE_S=<secs>    staleness threshold (default 7200)

attest_waiting_line() {
    [[ $# -gt 0 ]] || return 0
    if ! { command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1; }; then
        echo "attest-waiting: UNAVAILABLE:missing-tool"
        return 0
    fi

    local now_iso="${ATTEST_WAITING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local stale_s="${ATTEST_WAITING_STALE_S:-7200}"
    local repos_json fail=0
    repos_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)

    local payload
    payload=$(python3 - "$now_iso" "$stale_s" "$repos_json" <<'PY' 2>/dev/null
import json, os, subprocess, sys

now_iso, stale_s, repos_json = sys.argv[1], sys.argv[2], sys.argv[3]
repos = json.loads(repos_json)

def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200] or "gh failed")
    return r.stdout

from datetime import datetime, timezone
try:
    now = datetime.strptime(now_iso.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")
except ValueError:
    now = datetime.now(timezone.utc)

REST_RE = ("gate-integrity-attest", "verifier-attest", "attest-requested")

problems = []
for repo in repos:
    out = gh("issue", "list", "-R", repo, "--state", "open",
             "--json", "number,labels", "--limit", "200")
    labels_by_num = {i["number"]: [l["name"] for l in i.get("labels") or []]
                     for i in json.loads(out)}
    candidates = sorted(n for n, ls in labels_by_num.items()
                        if "agent-ready" in ls or "agent-blocked" in ls)
    for num in candidates:
        try:
            raw = gh("api", f"repos/{repo}/issues/{num}/comments",
                     "-q", '[.[] | {at:.created_at, who:.user.login, '
                           'assoc:.author_association, body:.body}]')
        except RuntimeError:
            raise
        comments = json.loads(raw) or []
        attest_ts = None
        orch_ts = None
        for c in sorted(comments, key=lambda x: x["at"]):
            body = c.get("body") or ""
            low = body.lower()
            if any(k in low for k in REST_RE) or "attest" in low:
                attest_ts = c["at"]
            if (c.get("assoc") == "OWNER" or c.get("who") == "nish3451"
                    or body.lstrip().lower().startswith(
                        ("gate-integrity-attest:", "verifier-attest:"))):
                orch_ts = c["at"]
        if attest_ts is None:
            continue
        # The latest attest mention is newer than any orchestrator response.
        if orch_ts is not None and orch_ts >= attest_ts:
            continue
        base = orch_ts or attest_ts
        try:
            base_dt = datetime.strptime(base.replace("Z", "+0000"),
                                        "%Y-%m-%dT%H:%M:%S%z")
        except ValueError:
            continue
        age_s = (now - base_dt).total_seconds()
        if age_s > int(stale_s):
            problems.append(f"#{num}")
    if not candidates:
        continue

if problems:
    shown = " ".join(p for p in problems[:6])
    more = "" if len(problems) <= 6 else f" +{len(problems) - 6} more"
    print(f"attest-waiting: {len(problems)} [{shown}{more}]")
else:
    print("attest-waiting: 0")
PY
    ) || fail=1

    if [ "$fail" -eq 1 ] || [ -z "${payload:-}" ]; then
        echo "attest-waiting: UNAVAILABLE:gh-error"
        return 0
    fi
    printf '%s\n' "$payload"
}
