#!/usr/bin/env bash
# tests/fleet-self-maintenance-split.test.sh
#
# Proves bin/fleet-self-maintenance-split.py (fleet-ops#4061) measures the
# product-vs-self merge split per repo, names the top self-maintenance
# classes, and reconciles the console shipped_24h tile against its declared
# source. All gh I/O is faked via a FLEET_SELF_SPLIT_GH seam.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/../bin/fleet-self-maintenance-split.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t selfsplit.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake gh: repo list returns 0509 (product) + fleet-ops (self); pr list
# returns canned merged titles (2 seat, 1 canary, 2 product) with the 24h
# tile spot query returning 3 merged (incl 1 revert).
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
if [[ "$sub" == "repo" ]]; then
  shift  # list
  # consume --json name,isArchived -L 200
  cat <<'JSON'
[{"name":"0509","isArchived":false},
 {"name":"fleet-ops","isArchived":false},
 {"name":"dead-arch","isArchived":true}]
JSON
  exit 0
fi
if [[ "$sub" == "pr" ]]; then
  # pr list -R ORG/REPO --state merged --search merged:>=... --json ... -L N
  repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R) repo="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$repo" in
    *fleet-ops)
      cat <<'JSON'
[{"number":1,"title":"fix(seatlib): corpse retirement","mergedAt":"2026-09-05T00:00:00Z","headRefName":"seatfix"},
 {"number":2,"title":"fix(seat-caps): bump cap","mergedAt":"2026-09-05T01:00:00Z","headRefName":"cap"},
 {"number":3,"title":"fix(canary): empty-run burst","mergedAt":"2026-09-05T02:00:00Z","headRefName":"canary"}]
JSON
      ;;
    *0509)
      cat <<'JSON'
[{"number":10,"title":"feat(search): plain buyer copy","mergedAt":"2026-09-05T00:00:00Z","headRefName":"search"},
 {"number":11,"title":"Revert \"auto-restore green main\"","mergedAt":"2026-09-05T00:10:00Z","headRefName":"revert/foo"}]
JSON
      ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
exit 1
FAKE
chmod +x "$gh_fake"

# self-maintenance config (fleet-ops = self)
cat >"$scratch/self-repos.json" <<'JSON'
{"repos": ["fleet-ops"]}
JSON

export FLEET_SELF_SPLIT_GH="$gh_fake"
export FLEET_SELF_SPLIT_ORG="Nishfleet"
export FLEET_SELF_SPLIT_DAYS="7"
export FLEET_SELF_SPLIT_SELF_JSON="$scratch/self-repos.json"
export FLEET_SELF_SPLIT_NOW="2026-09-06T00:00:00+00:00"

out="$scratch/out.txt"
python3 "$bin" --days 7 >"$out" 2>&1 || fail "split exited non-zero"

grep -q "fleet-ops" "$out" || fail "fleet-ops missing from report"
grep -q "0509" "$out" || fail "0509 missing from report"
grep -q "self merges" "$out" || fail "self total missing"
# self=3 (fleet-ops), product=2 (0509) -> ratio 3/5 = 0.6
grep -q "self/total ratio    : 0.6000" "$out" \
  || fail "ratio expected 0.6000, got: $(grep 'ratio' "$out")"
grep -qi "seat management" "$out" || fail "top-3 seat class missing"
grep -qi "canary" "$out" || fail "top class canary missing"
ok "split per-repo + ratio + top classes"

# ---- top-3 classes: seat is the largest of the 3 self merges (2 of 3)
seat=$(grep -o 'seat management[^(]*' "$out" | head -1)
echo "  class line: $seat"
grep -q "2  seat management" "$out" || fail "expected seat=2/3 top class"
ok "top class = seat management"

# ---- reconcile the tile against its declared source (exporter)
cat >"$scratch/slo.prom" <<'PROM'
# TYPE fleet_product_merged_24h gauge
fleet_product_merged_24h{repo="0509"} 2
PROM
cat >"$scratch/tile.json" <<'JSON'
{"tiles": {"shipped_24h": {"count": 2, "disputed": false, "observed_at": 1788615310.0}}}
JSON
export FLEET_SELF_SPLIT_CONSOLE="$scratch/tile.json"
export FLEET_SELF_SPLIT_PRODUCT_SLO="$scratch/slo.prom"
python3 "$bin" --reconcile-tile >"$out" 2>&1 \
  || fail "reconcile-tile exited non-zero"
grep -q "RECONCILED" "$out" || {
  echo "  reconcile output:"; cat "$out"; fail "expected RECONCILED"
}
ok "tile reconcile: tile==exporter -> RECONCILED"

# mismatch path: exporter disagrees -> MISMATCH
cat >"$scratch/slo.prom" <<'PROM'
# TYPE fleet_product_merged_24h gauge
fleet_product_merged_24h{repo="0509"} 9
PROM
python3 "$bin" --reconcile-tile >"$out" 2>&1 || true
grep -q "MISMATCH" "$out" || {
  echo "  reconcile output:"; cat "$out"; fail "expected MISMATCH when exporter differs"
}
ok "tile reconcile: tile!=exporter -> MISMATCH"

echo "ALL PASS"
