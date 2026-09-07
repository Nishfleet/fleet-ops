#!/usr/bin/env bash
# tests/fleet-issue-file-close-duplicates-regression-3161.test.sh
#
# fleet-ops#3161 regression: the primary-signal floor + cross-repo canonical
# once closed 18 issues incl. two Nish-endorsed critical-path packets
# (fleet-ops#3140 manager loop, fleet-ops#3146 dead-man ping) as score=1.00
# duplicates of an UNRELATED 0509 CI issue (0509#1220). Root cause: any
# shared PRIMARY signal (the seat-crisis detector fires on a bare "seat" +
# "dead" mention, which 0509#1220's CI diff body carries) floors the pair
# to PRIMARY_SIGNAL_FLOOR=0.70 >= DUP_THRESHOLD=0.65 regardless of token
# overlap, clusters chain transitively, and the canonical is "oldest open
# in cluster" even across repos.
#
# Required fix (this PR):
#   - a CLOSE needs pairwise token overlap max(t,b) >= DUP_THRESHOLD on its
#     own; signal floors may only produce a possible-duplicate COMMENT.
#   - canonical must be in the SAME repo; cross-repo similarity is
#     comment-only.
#   - PROTECTED_LABELS += critical-path; owner-authored (nish3451) issues
#     are never auto-closed — comment only.
#   - a close cites the pairwise score to the canonical, not a transitive
#     cluster score; clusters larger than 4 are comment-only and file one
#     dup-cluster review line.
#
# This test replays the 18-close shape from the journal: with the fix, 0 of
# them close, all get possible-duplicate comments; the #3140/#3146 pair with
# 0509#1220 scores < 0.3 on token overlap. Hermetic (fake gh, no network).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"

scratch=$(mktemp -d -t close-dups-3161.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake gh: logs close/comment calls; list serves a fixture.
mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
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
export GH_CLOSED="$scratch/closed"
export GH_COMMENTED="$scratch/commented"
export GH_OPEN_JSON="$scratch/gh-open.json"

: >"$scratch/closed"
: >"$scratch/commented"

# --- Fixture: the 2026-09-04 18-close shape -------------------------------
# Two Nish-endorsed critical-path packets in fleet-ops (#3140 manager loop,
# #3146 dead-man ping), one unrelated 0509 CI issue (#1220) whose diff body
# mentions "seat" + "dead-man ping" (triggers _has_seat_crisis), and 15
# fleet-ops alert issues that each share the seat-crisis primary signal.
# Pre-fix: all 18 non-canonical members closed as score=1.00 dups of the
# oldest (0509#1220, cross-repo canonical). Post-fix: 0 close, all comment.
python3 - "$scratch/gh-open.json" <<'PY'
import json, sys
path = sys.argv[1]
issues = []

def add(repo, n, title, body, labels, author="nishfleet-worker[bot]"):
    issues.append({
        "number": n, "repository": repo, "title": title, "body": body,
        "url": f"https://github.com/{repo}/issues/{n}",
        "labels": labels, "author": {"login": author},
    })

# The unrelated 0509 CI issue — oldest in the cluster, so pre-fix it became
# the cross-repo canonical. Its body mentions "seat" + "dead-man ping" so
# _has_seat_crisis fires (the bug).
add("Nishfleet/0509", 1220,
    "[fleet-ops#87] CI: add tests/heartbeat-watchman.test.sh to P14 verify-command list",
    "The fleet-ops worker token cannot push .github/workflows/**. This is the CI "
    "wiring for fleet-ops#87. Same change as fleet-ops#200. Apply this patch to "
    ".github/workflows/ci.yml: bash tests/heartbeat-watchman.test.sh, failed-unit "
    "paging, seat-health freshness. A dead-man ping, failed-unit page, or "
    "seat-health regression can merge green.",
    ["agent-ready"], author="app/nishfleet-worker")

# The two Nish-endorsed critical-path packets (owner-authored, critical-path).
add("Nishfleet/fleet-ops", 3140,
    "Manager loop for heavy/keystone issues: worker plans phases, spawns a fresh implementer per phase with handoff, reviewer per phase; replaces the never-used phases: manifest (Nish 2026-09-04)",
    "Decision (Nish, 2026-09-04) after the Manager Loop write-up. Facts: the "
    "fleet-ops#1383 phases manifest has been written into 0 packets ever. Shape: "
    "packet_difficulty heavy|keystone -> the pi-issue worker runs as MANAGER. "
    "Every seat was dead during the 33h outage; this is the recovery plan.",
    ["agent-blocked", "critical-path"], author="nish3451")

add("Nishfleet/fleet-ops", 3146,
    "Dead-man pings 'healthy' unconditionally: fleet-hc-ping.sh curls on every exporter tick, so the 33h outage looked alive; ping only on real product outcome",
    "Found 2026-09-04 while reviewing why nobody was paged during the 33h outage "
    "(0 merged PRs, every seat dead). ~/.local/libexec/fleet-hc-ping.sh line 11 "
    "curls the healthchecks URL unconditionally; the metrics exporter ran fine.",
    ["agent-blocked", "critical-path"], author="nish3451")

# 15 fleet-ops alert issues — each shares the seat-crisis primary signal
# (mentions "seat" + "dead"/"corpse") so pre-fix they joined the cluster and
# closed as dups of 0509#1220. None has real token overlap with 0509#1220.
for i in range(15):
    n = 4000 + i
    add("Nishfleet/fleet-ops", n,
        f"FleetSeatCorpse alert: seat dead, credentials bad, manual repair needed (alert {i})",
        f"alert-repair fired. health_class=corpse, seat_dead=true, credentials_bad. "
        f"Seat is dead and must be repaired. alert {i} of the 2026-09-04 outage.",
        ["agent-ready"], author="app/nishfleet-worker")

with open(path, "w") as fh:
    json.dump(issues, fh)
print(f"wrote {len(issues)} issues")
PY

# --- 1. With the fix, 0 issues close (all 18 get possible-duplicate comments)
export FLEET_CLOSE_DUPLICATES_REVIEW_LOG="$scratch/review.log"
: >"$scratch/review.log"
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/run.json" 2>/dev/null || true

closed=$(jq '.closed' "$scratch/run.json")
commented=$(jq '.commented' "$scratch/run.json")
[[ "$closed" -eq 0 ]] || fail "regression: must close 0, got closed=$closed (the 18-close bug)"
# 18 issues across 2 repos -> 2 per-repo canonicals -> 16 non-canonical
# members get possible-duplicate comments. Pre-fix all 16 non-canonical
# members closed as score=1.00 dups of the single cross-repo canonical.
[[ "$commented" -eq 16 ]] || fail "regression: must comment 16 (all non-canonical members), got commented=$commented"
ok "fix: 0 closes, $commented possible-duplicate comments (was 16 wrong closes)"

# No close comment may cite a cross-repo canonical. With the fix there are 0
# closes, so 0 close comments. Verify via the actions JSON: every action is a
# comment (not a close), and every comment's canonical is in the SAME repo as
# its ref (cross-repo canonicals are forbidden in close comments; comment-only
# comments also use the per-repo canonical).
python3 - "$scratch/run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
actions = d["actions"]
assert actions, "expected comment actions"
for a in actions:
    assert a["action"] == "comment", f"no close actions allowed, got {a['action']}"
    ref_repo = a["ref"].rsplit("#", 1)[0]
    canon_repo = a["canonical"].rsplit("#", 1)[0]
    assert ref_repo == canon_repo, (
        f"canonical must be same-repo: {a['ref']} -> {a['canonical']} (cross-repo)"
    )
print(f"OK: {len(actions)} comment actions, all same-repo canonical, 0 close actions")
PY
ok "no close comment cites a cross-repo canonical"

# --- 2. The Nish-endorsed critical-path packets are not closed ------------
# #3140 is the fleet-ops canonical (oldest, lowest number) so it is kept;
# #3146 is non-canonical and owner-authored + critical-path -> comment only.
# Neither is closed. (Pre-fix both closed as dups of cross-repo 0509#1220.)
grep -q "3140" "$scratch/closed" && fail "#3140 must NOT be closed (owner + critical-path canonical)"
grep -q "3146" "$scratch/closed" && fail "#3146 must NOT be closed (owner + critical-path)"
grep -q "3146" "$scratch/commented" || fail "#3146 must get a comment (owner + critical-path, non-canonical)"
ok "Nish-endorsed critical-path #3140/#3146: not closed (#3146 commented, #3140 kept as canonical)"

# --- 3. Pairwise token overlap #3140/#3146 vs 0509#1220 is < 0.3 -----------
python3 - "$lib" "$scratch/gh-open.json" <<'PY'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("issue_file", sys.argv[1])
I = importlib.util.module_from_spec(spec); spec.loader.exec_module(I)
issues = {(i["repository"], i["number"]): i for i in json.load(open(sys.argv[2]))}
def pair(a, b):
    d = I.score_pair(a["title"], a["body"], b["title"], b["body"])
    return d["token_overlap_max"], d["score"]
for (ra, na), (rb, nb) in [
    (("Nishfleet/fleet-ops", 3140), ("Nishfleet/0509", 1220)),
    (("Nishfleet/fleet-ops", 3146), ("Nishfleet/0509", 1220)),
]:
    tok, score = pair(issues[(ra, na)], issues[(rb, nb)])
    assert tok < 0.3, f"{ra}#{na} vs {rb}#{nb} token overlap {tok} must be < 0.3"
    # The signal floor still raises the cluster score to >= 0.7 — that is the
    # bug's mechanism, and the fix is that the floor can no longer authorise
    # a close, only a comment.
    assert score >= 0.7, f"{ra}#{na} vs {rb}#{nb} cluster score {score} still floored (the bug mechanism)"
    print(f"OK: {ra}#{na} vs {rb}#{nb} token_overlap={tok} < 0.3, cluster score={score} (floor only)")
PY
ok "pairwise token overlap #3140/#3146 vs 0509#1220 < 0.3"

# --- 4. Cluster > 4 is comment-only and files a dup-cluster review line ----
# The 18-member cluster is > CLUSTER_CLOSE_MAX (4), so every member is
# comment-only AND one review line is filed in the review log.
review_lines=$(wc -l < "$scratch/review.log")
[[ "$review_lines" -ge 1 ]] || fail "cluster > 4 must file >=1 dup-cluster review line, got $review_lines"
grep -q "dup-cluster review" "$scratch/review.log" || fail "review log must contain a dup-cluster review line"
ok "cluster > 4: comment-only + dup-cluster review line filed"

# --- 5. closes_by_label metric: cross_repo and protected stay 0 ------------
python3 - "$scratch/run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cbl = d["closes_by_label"]
assert cbl["cross_repo=true,protected=true"] == 0, cbl
assert cbl["cross_repo=true,protected=false"] == 0, cbl
assert cbl["cross_repo=false,protected=true"] == 0, cbl
assert cbl["cross_repo=false,protected=false"] == 0, cbl
print("OK: closes_by_label all zero (no closes this run)")
PY
ok "closes_by_label{cross_repo,protected} all zero"

# --- 6. A genuine same-repo high-overlap duplicate STILL closes ------------
# The fix must not break the legitimate path: two agent-ready issues in the
# same repo with real token overlap >= DUP_THRESHOLD close (oldest kept).
: >"$scratch/closed"; : >"$scratch/commented"; : >"$scratch/review.log"
python3 - "$scratch/gh-open.json" <<'PY'
import json, sys
path = sys.argv[1]
issues = [
  {"number":100,"repository":"Nishfleet/fleet-ops",
   "title":"fleet-ops main CI red since 2026-09-02T08:15Z FleetMainRed firing",
   "body":"FleetMainRed firing. CI is red on main. alert-repair escalated.",
   "url":"u100","labels":["agent-ready"],"author":{"login":"app/nishfleet-worker"}},
  {"number":101,"repository":"Nishfleet/fleet-ops",
   "title":"fleet-ops main CI red: FleetMainRed critical firing 5h",
   "body":"FleetMainRed firing. CI is red on main. alert-repair escalated.",
   "url":"u101","labels":["agent-ready"],"author":{"login":"app/nishfleet-worker"}},
]
with open(path, "w") as fh:
    json.dump(issues, fh)
PY
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/legit.json" 2>/dev/null || true
closed=$(jq '.closed' "$scratch/legit.json")
[[ "$closed" -eq 1 ]] || fail "legit same-repo high-overlap dup must close 1, got closed=$closed"
grep -q "101" "$scratch/closed" || fail "legit dup #101 must be closed via gh"
grep -q "100" "$scratch/closed" && fail "legit canonical #100 must NOT be closed"
python3 - "$scratch/legit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cbl = d["closes_by_label"]
assert cbl["cross_repo=false,protected=false"] == 1, cbl
assert cbl["cross_repo=true,protected=false"] == 0, cbl
assert cbl["cross_repo=false,protected=true"] == 0, cbl
print("OK: legit close counted as cross_repo=false,protected=false")
PY
ok "legit same-repo high-overlap dup still closes (oldest kept), metric counts it"

echo "OK: close-duplicates regression for fleet-ops#3161 (primary-signal floor + cross-repo canonical)"
