# fleet-ops#5870: the attest-waiting detector. fleet-ops#6257: newest-state.
# shellcheck shell=bash
#
# A worker that hits a gate-owned path refuses to self-attest correctly, but
# three instances (0509#3068, 0509#3144, fleet-ops#5760) then parked the issue
# as kind=nish-decision and it sat for hours until a judge read it by hand.
# bin/blocked-reconcile used to classify those as orchestrator-attest; it was
# deleted in the 2026-09-18 glue sweep. THIS detector is the remaining
# observer: an issue whose LATEST state still requests an attestation and
# that has had no orchestrator comment for more than 2h. Historical attest
# comments are suppressed by a later decision-resolved: line, by a live
# non-orchestrator blocked-on: as the last blocked-on form, or by an
# attest-referenced PR head that is already merged (fleet-ops#6257). A
# thread whose latest comment still asks for an admin attest still waits.
# That is #5870's real-time path. Zero is the normal value; any non-zero
# line is judge-visible (`attest-waiting: <n> [#a #b]` in the measure.sh
# header).
#
# Contract (testable in isolation):
#   attest_waiting_line <repo...>     prints exactly one line on stdout:
#     attest-waiting: <n> [#a #b ...] — waiting issues found
#     attest-waiting: 0               — the normal value
#     attest-waiting: UNAVAILABLE:<why> — gh failure, never a fabricated 0
# Env: ATTEST_WAITING_NOW=<iso8601>     freeze "now" (tests)
#      ATTEST_WAITING_STALE_S=<secs>    staleness threshold (default 7200)
#      ATTEST_WAITING_BUDGET_S=<secs>   total wall-clock budget (default 60)

attest_waiting_line() {
    # measure.sh runs under set -e. A failure inside this function is NOT
    # covered by the caller's `|| echo` (inner commands are not part of that
    # OR-list) and would abort the judge feed before the findings: line
    # (tests/findings-measure-line.test.sh).
    set +e
    [[ $# -gt 0 ]] || return 0
    if ! { command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; }; then
        echo "attest-waiting: UNAVAILABLE:missing-tool"
        return 0
    fi

    local now_iso="${ATTEST_WAITING_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local stale_s="${ATTEST_WAITING_STALE_S:-7200}"
    local repos_json fail=0
    repos_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)

    # fleet-ops#5870: each gh call already carries timeout=120, but the loop
    # below is one gh call PER open agent-ready/agent-blocked issue across
    # every repo, so the TOTAL had no bound — a large queue wedged measure.sh
    # and, through it, the 5-min fleet-metrics-export tick. An overall budget
    # degrades to UNAVAILABLE (never a fabricated 0) instead of hanging.
    local budget_s="${ATTEST_WAITING_BUDGET_S:-60}"
    local payload
    payload=$(timeout "$budget_s" python3 - "$now_iso" "$stale_s" "$repos_json" <<'PY' 2>/dev/null
import json, re, subprocess, sys
from datetime import datetime, timezone

now_iso, stale_s, repos_json = sys.argv[1], sys.argv[2], sys.argv[3]
repos = json.loads(repos_json)

def gh(*args, wait=120):
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True,
                           timeout=wait)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"gh timeout after {wait}s") from e
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200] or "gh failed")
    return r.stdout

try:
    now = datetime.strptime(now_iso.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")
except ValueError:
    now = datetime.now(timezone.utc)

REST_RE = ("gate-integrity-attest", "verifier-attest", "attest-requested")
SKIP_COMMENT = re.compile(
    r"(?i)^(claimed by |claim branch released|blocked-checked:)"
)
STRUCK_LINE = re.compile(r"^\s*(?:[-*]\s+)?~~.+~~\s*$")
BLOCKED_ON = re.compile(r"(?im)^blocked-on:\s*(.+?)\s*$")
DECISION_RESOLVED = re.compile(r"(?im)^decision-resolved:\s*")
ATTEST_SHA = re.compile(
    r"(?im)^(?:gate-integrity-attest|verifier-attest|attest-requested)"
    r":\s*([0-9a-f]{40})\b"
)
ATTEST_MENTION = re.compile(
    r"(?i)\battest|gate[\s-]*integrity\s*attest|attest-requested"
)
ATTEST_ADMIN = re.compile(
    r"(?i)\badmin\b|gate[\s-]*integrity\s*attest|attest-requested|"
    r"verifier[\s-]*attest"
)
NAMED_NOT_DEP = {
    "orchestrator", "nish-decision", "infra", "senior-review",
    "split", "senior-conference",
}
URL = re.compile(
    r"^https://github\.com/([\w.-]+)/([\w.-]+)/(issues|pull)/(\d+)/?$"
)
OWNED = re.compile(r"^([\w.-]+)/([\w.-]+)#(\d+)$")
HASH = re.compile(r"^#(\d+)$")


def live_text(text):
    lines = []
    for line in (text or "").splitlines():
        if STRUCK_LINE.match(line):
            continue
        lines.append(line)
    return "\n".join(lines)


def is_attest_blocker(text):
    t = text or ""
    if any(k in t.lower() for k in REST_RE):
        return True
    return bool(ATTEST_MENTION.search(t) and ATTEST_ADMIN.search(t))


def is_dep_form(raw):
    raw = (raw or "").strip().rstrip(".,;")
    if raw.lower() in NAMED_NOT_DEP:
        return False
    return bool(URL.match(raw) or OWNED.match(raw) or HASH.match(raw))


def sha_merged(repo, sha):
    # Fail closed: unproven merge keeps the live attest request waiting.
    try:
        raw = gh("api", f"repos/{repo}/commits/{sha}/pulls", wait=8)
    except RuntimeError:
        return False
    try:
        pulls = json.loads(raw or "[]")
    except json.JSONDecodeError:
        return False
    if not isinstance(pulls, list):
        return False
    return any(isinstance(p, dict) and p.get("merged_at") for p in pulls)


def newest_state(comments):
    usable = []
    for c in sorted(comments, key=lambda x: x["at"]):
        body = c.get("body") or ""
        if SKIP_COMMENT.match(body.lstrip()):
            continue
        usable.append({
            "at": c["at"],
            "who": c.get("who"),
            "assoc": c.get("assoc"),
            "live": live_text(body),
            "raw": body,
        })
    last_blocked = None
    last_attest_ts = None
    last_resolved_ts = None
    orch_ts = None
    shas = []
    for c in usable:
        live = c["live"]
        for m in BLOCKED_ON.finditer(live):
            last_blocked = m.group(1).strip()
        if DECISION_RESOLVED.search(live) and not BLOCKED_ON.search(live):
            last_resolved_ts = c["at"]
        if is_attest_blocker(live):
            last_attest_ts = c["at"]
            for m in ATTEST_SHA.finditer(live):
                shas.append(m.group(1).lower())
        raw = c["raw"]
        if (c.get("assoc") == "OWNER" or c.get("who") == "nish3451"
                or raw.lstrip().lower().startswith(
                    ("gate-integrity-attest:", "verifier-attest:"))):
            orch_ts = c["at"]
    latest_requests = bool(usable) and is_attest_blocker(usable[-1]["live"])
    suppress = False
    if last_attest_ts:
        if last_resolved_ts and last_resolved_ts >= last_attest_ts:
            suppress = True
        if last_blocked and is_dep_form(last_blocked):
            suppress = True
        # Real-time path: a thread whose latest comment still asks for an
        # admin attest still waits (fleet-ops#6257 must-not).
        if latest_requests:
            suppress = False
    return last_attest_ts, orch_ts, suppress, latest_requests, shas


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
        attest_ts, orch_ts, suppress, latest_requests, shas = newest_state(
            comments)
        if attest_ts is None:
            continue
        if orch_ts is not None and orch_ts >= attest_ts:
            continue
        if suppress and not latest_requests:
            continue
        # Merged-head suppression applies even when the latest comment still
        # asks for attest. That request can never be actionable.
        if shas and all(sha_merged(repo, sha) for sha in shas):
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
        echo "attest-waiting: UNAVAILABLE:gh-error-or-budget"
        return 0
    fi
    printf '%s\n' "$payload"
}
