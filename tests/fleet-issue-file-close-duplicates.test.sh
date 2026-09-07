#!/usr/bin/env bash
# tests/fleet-issue-file-close-duplicates.test.sh
#
# fleet-ops#2762: close-duplicates drains the same-problem duplicate backlog
# the filing gate (fleet-ops#1212) identifies but never closes.
#
# Proves, offline with a fake gh:
#   1. --dry-run reports the agent-ready duplicate would close, oldest kept.
#   2. FLEET_CLOSE_DUPLICATES_OK=1 closes the agent-ready duplicate via gh.
#   3. agent-in-progress / agent-blocked members get a comment, NOT a close.
#   4. OK unset (default 0) is fail-closed: no close call (noop).
#   5. --cap limits closes per run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"
bin="$repo_root/bin/fleet-issue-file"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"
"$bin" close-duplicates --help >/dev/null || fail "close-duplicates --help failed"

scratch=$(mktemp -d -t close-dups.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake gh: logs every invocation; list serves a fixture; close/comment record.
mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
log="${GH_LOG:-/dev/null}"
printf 'ARGS:%s\n' "$*" >>"$log"
case "$1" in
  issue)
    case "$2" in
      list)
        if [[ -f "${GH_OPEN_JSON:-/dev/null}" ]]; then cat "${GH_OPEN_JSON}"; else printf '[]\n'; fi
        ;;
      close)    echo "closed $3" >>"${GH_CLOSED:-/dev/null}" ;;
      comment)  echo "commented $3" >>"${GH_COMMENTED:-/dev/null}" ;;
    esac
    ;;
esac
exit 0
GH
chmod +x "$scratch/fakebin/gh"

export GH="$scratch/fakebin/gh"
export GH_LOG="$scratch/gh.log"
export GH_CLOSED="$scratch/closed"
export GH_COMMENTED="$scratch/commented"
export GH_OPEN_JSON="$scratch/gh-open.json"

: >"$scratch/closed"
: >"$scratch/commented"
: >"$scratch/gh.log"

# A 3-member duplicate cluster: #100 (oldest, agent-ready), #101 (agent-ready),
# #102 (agent-in-progress — protected). Plus one unrelated issue.
cat >"$scratch/gh-open.json" <<'JSON'
[
  {"number":100,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red since 2026-09-02T08:15Z","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u100","labels":["agent-ready"]},
  {"number":101,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red: FleetMainRed critical firing 5h","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u101","labels":["agent-ready"]},
  {"number":102,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red + alert-repair run hop stalled","body":"FleetMainRed firing. CI is red on main. alert-repair stalled.","url":"u102","labels":["agent-in-progress"]},
  {"number":200,"repository":"Nishfleet/0509","title":"Dark-mode contrast on the billing page","body":"Agency CTA contrast is 2.14:1 in dark theme.","url":"u200","labels":["agent-ready"]}
]
JSON

# --- 1. dry-run reports close of agent-ready, oldest kept -------------------
out=$(python3 "$lib" close-duplicates --dry-run --from-json "$scratch/gh-open.json" \
      --output-json "$scratch/dry.json" 2>/dev/null || true)
closed=$(jq '.closed' "$scratch/dry.json")
commented=$(jq '.commented' "$scratch/dry.json")
[[ "$closed" -eq 1 ]] || fail "dry-run must report 1 close (agent-ready dup), got closed=$closed"
[[ "$commented" -ge 1 ]] || fail "dry-run must report >=1 comment (protected member), got commented=$commented"
# Oldest (#100) must NOT appear as a close/comment target; #101 closes, #102 comments.
actions=$(jq -r '.actions[].ref' "$scratch/dry.json")
echo "$actions" | grep -q "Nishfleet/fleet-ops#101" || fail "dry-run must target #101"
echo "$actions" | grep -q "Nishfleet/fleet-ops#102" || fail "dry-run must target #102 (protected comment)"
echo "$actions" | grep -q "Nishfleet/fleet-ops#100" && fail "dry-run must NOT close the canonical #100"
ok "dry-run: closes agent-ready #101, comments protected #102, keeps #100"

# --- 2. OK=1 closes the agent-ready duplicate via gh ------------------------
: >"$scratch/closed"; : >"$scratch/commented"; : >"$scratch/gh.log"
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/live.json" 2>/dev/null || true
closed=$(jq '.closed' "$scratch/live.json")
[[ "$closed" -eq 1 ]] || fail "OK=1 must close 1 agent-ready dup, got closed=$closed"
grep -q "101" "$scratch/closed" || fail "gh issue close must be called on #101"
# Canonical #100 must never be closed.
grep -q "100" "$scratch/closed" && fail "must NOT close canonical #100"
ok "OK=1: closed agent-ready #101 via gh, kept canonical #100"

# --- 3. protected member gets a comment, not a close ------------------------
grep -q "102" "$scratch/commented" || fail "protected #102 must get a comment"
grep -q "102" "$scratch/closed" && fail "protected #102 must NOT be closed"
ok "protected agent-in-progress #102: commented, not closed"

# --- 4. OK unset (default 0) is fail-closed ---------------------------------
: >"$scratch/closed"; : >"$scratch/commented"
out=$(python3 "$lib" close-duplicates --from-json "$scratch/gh-open.json" \
      --output-json "$scratch/noop.json" 2>/dev/null || true)
closed=$(jq '.closed' "$scratch/noop.json")
[[ "$closed" -eq 0 ]] || fail "OK unset must close 0, got closed=$closed"
[[ ! -s "$scratch/closed" ]] || fail "OK unset must not call gh issue close"
ok "fail-closed: OK unset closes nothing"

# --- 5. cap limits closes ---------------------------------------------------
: >"$scratch/closed"
# 4 agent-ready duplicates of the oldest (#100).
cat >"$scratch/gh-open.json" <<'JSON'
[
  {"number":100,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red since 2026-09-02T08:15Z","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u100","labels":["agent-ready"]},
  {"number":101,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red: FleetMainRed critical firing 5h","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u101","labels":["agent-ready"]},
  {"number":103,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red: FleetMainRed critical firing 6h","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u103","labels":["agent-ready"]},
  {"number":104,"repository":"Nishfleet/fleet-ops","title":"fleet-ops main CI red: FleetMainRed critical firing 7h","body":"FleetMainRed firing. CI is red on main. alert-repair escalated.","url":"u104","labels":["agent-ready"]}
]
JSON
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --cap 2 --output-json "$scratch/cap.json" 2>/dev/null || true
closed=$(jq '.closed' "$scratch/cap.json")
[[ "$closed" -eq 2 ]] || fail "cap=2 must close exactly 2, got closed=$closed"
ok "cap=2 limits closes to 2"

echo "OK: close-duplicates drains the duplicate backlog (fleet-ops#2762)"
