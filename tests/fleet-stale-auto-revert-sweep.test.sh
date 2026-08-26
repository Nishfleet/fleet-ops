#!/usr/bin/env bash
# tests/fleet-stale-auto-revert-sweep.test.sh
#
# Proves fleet-ops#349: an auto-revert PR whose reverted commit is no
# longer main HEAD must be drafted and closed before heartbeat's queue
# pass can arm auto-merge. #246 sat OPEN+MERGEABLE after main moved;
# merging it would have stripped blind-audit CI wiring.
#
#   - --decide: stale / fresh / ignore, no network
#   - stale auto-restore PR -> draft + close with do-not-merge comment
#   - fresh auto-restore PR (main still that SHA) -> leave open
#   - human revert/ title -> ignore
#   - hands-off repo -> no mutation
#   - dry-run -> no mutation
#   - overlapping flock no-op
#   - contracts: tier1 runs the sweep BEFORE the queue pass + MANIFEST
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-stale-auto-revert-sweep"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- decide (offline, no gh) ----------------------------------------------
got=$("$bin" --decide "revert/deadd76" "revert: auto-restore green main (reverts deadd76)" "abcdef0123456789")
[[ "$got" == "stale" ]] || fail "moved main should be stale, got: $got"
ok "main moved past reverted SHA -> stale"

got=$("$bin" --decide "revert/deadd76" "revert: auto-restore green main (reverts deadd76)" "deadd76aaaaaaaaaaa")
[[ "$got" == "fresh" ]] || fail "matching prefix should be fresh, got: $got"
ok "main HEAD still the reverted SHA -> fresh"

got=$("$bin" --decide "revert/DEADD76" "revert: auto-restore green main (reverts deadd76)" "deadd76bbbbbbbbbbb")
[[ "$got" == "fresh" ]] || fail "SHA compare must be case-insensitive, got: $got"
ok "mixed-case short SHA still matches main"

got=$("$bin" --decide "revert/deadd76" "revert: undo the last merge by hand" "abcdef0123456789")
[[ "$got" == "ignore" ]] || fail "human revert title should be ignore, got: $got"
ok "non auto-restore title on revert/ -> ignore"

got=$("$bin" --decide "claim/issue-349" "fix: something" "abcdef0123456789")
[[ "$got" == "ignore" ]] || fail "claim branch should be ignore, got: $got"
ok "non-revert head -> ignore"

got=$("$bin" --decide "revert/deadd76" "revert: auto-restore green main (reverts deadd76)" "")
[[ "$got" == "ignore" ]] || fail "empty main sha should be ignore, got: $got"
ok "unknown main SHA -> ignore (do not close blind)"

# --- live sweep with mocked gh --------------------------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  pr)
    case "$2" in
      list)
        cat "$FAKE_DIR/list.json"
        exit 0
        ;;
      ready)
        printf '%s\n' "$*" >>"$FAKE_DIR/ready.log"
        exit 0
        ;;
      close)
        printf '%s\n' "$*" >>"$FAKE_DIR/close.log"
        exit 0
        ;;
      *) echo "unexpected gh pr $*" >&2; exit 1 ;;
    esac
    ;;
  api)
    if [[ "${2:-}" == repos/*/commits/main ]]; then
      cat "$FAKE_DIR/main.sha"
      exit 0
    fi
    echo "unexpected gh api $*" >&2
    exit 1
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
export FLEET_STALE_REVERT_LOCKDIR="$scratch/lock"
export FLEET_STALE_REVERT_REPOS="Nishfleet/fleet-ops"
unset FLEET_STALE_REVERT_HANDS_OFF || true
unset FLEET_STALE_REVERT_DRY_RUN || true

# Case 1: stale auto-revert (#246 shape) -> draft + close
cat >"$scratch/list.json" <<'JSON'
[{"number":246,"title":"revert: auto-restore green main (reverts deadd76)","headRefName":"revert/deadd76","isDraft":false}]
JSON
printf 'fb5ca17aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$scratch/main.sha"
: >"$scratch/ready.log"
: >"$scratch/close.log"

out=$("$bin" 2>"$scratch/err1.txt")
grep -q 'closed=1' <<<"$out" || fail "stale close count: $out / $(cat "$scratch/err1.txt")"
grep -q 'pr ready 246' "$scratch/ready.log" \
  || fail "stale must convert to draft: $(cat "$scratch/ready.log")"
grep -q -- '--undo' "$scratch/ready.log" \
  || fail "draft conversion must use --undo: $(cat "$scratch/ready.log")"
grep -q 'pr close 246' "$scratch/close.log" \
  || fail "stale must close: $(cat "$scratch/close.log")"
grep -q 'Do not merge' "$scratch/close.log" \
  || fail "close comment must say do not merge: $(cat "$scratch/close.log")"
ok "stale auto-restore PR -> draft + close"

# Case 2: fresh auto-revert (main still that commit) -> leave open
cat >"$scratch/list.json" <<'JSON'
[{"number":99,"title":"revert: auto-restore green main (reverts deadd76)","headRefName":"revert/deadd76","isDraft":false}]
JSON
printf 'deadd76aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$scratch/main.sha"
: >"$scratch/ready.log"
: >"$scratch/close.log"

out=$("$bin" 2>"$scratch/err2.txt")
grep -q 'closed=0' <<<"$out" || fail "fresh must not close: $out / $(cat "$scratch/err2.txt")"
[[ -s "$scratch/close.log" ]] && fail "fresh must not call pr close: $(cat "$scratch/close.log")"
ok "fresh auto-restore PR stays open"

# Case 3: human revert/ title -> ignore
cat >"$scratch/list.json" <<'JSON'
[{"number":12,"title":"revert: undo the last merge by hand","headRefName":"revert/abc1234","isDraft":false}]
JSON
printf 'ffffffffffffffffffffffffffffffffffffffff\n' >"$scratch/main.sha"
: >"$scratch/close.log"

out=$("$bin" 2>"$scratch/err3.txt")
grep -q 'closed=0' <<<"$out" || fail "human revert must not close: $out"
[[ -s "$scratch/close.log" ]] && fail "human revert closed: $(cat "$scratch/close.log")"
ok "human revert/ title is left alone"

# Case 4: hands-off repo -> no mutation
export FLEET_STALE_REVERT_HANDS_OFF="Nishfleet/fleet-ops"
cat >"$scratch/list.json" <<'JSON'
[{"number":246,"title":"revert: auto-restore green main (reverts deadd76)","headRefName":"revert/deadd76","isDraft":false}]
JSON
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$scratch/main.sha"
: >"$scratch/close.log"
: >"$scratch/gh.log"

out=$("$bin" 2>"$scratch/err4.txt")
grep -q 'closed=0' <<<"$out" || fail "hands-off close count: $out"
if grep -q 'pr list' "$scratch/gh.log"; then
  fail "hands-off must not list PRs: $(cat "$scratch/gh.log")"
fi
ok "hands-off repo is skipped"
unset FLEET_STALE_REVERT_HANDS_OFF

# Case 5: dry-run -> no mutation
export FLEET_STALE_REVERT_DRY_RUN=1
cat >"$scratch/list.json" <<'JSON'
[{"number":246,"title":"revert: auto-restore green main (reverts deadd76)","headRefName":"revert/deadd76","isDraft":false}]
JSON
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$scratch/main.sha"
: >"$scratch/ready.log"
: >"$scratch/close.log"

out=$("$bin" 2>"$scratch/err5.txt")
grep -q 'closed=1' <<<"$out" || fail "dry-run still counts the close: $out"
[[ -s "$scratch/close.log" ]] && fail "dry-run must not close: $(cat "$scratch/close.log")"
[[ -s "$scratch/ready.log" ]] && fail "dry-run must not draft: $(cat "$scratch/ready.log")"
ok "dry-run reports the close without mutating"
unset FLEET_STALE_REVERT_DRY_RUN

# Case 6: overlapping flock no-op
mkdir -p "$scratch/lock"
exec 9>"$scratch/lock/sweep.lock"
flock -n 9 || fail "test could not hold the lock"
out=$("$bin" 2>"$scratch/err6.txt")
exec 9>&-
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"
ok "overlapping sweep is a no-op"

# Case 7: contracts
grep -q 'fleet-stale-auto-revert-sweep' "$tier1" \
  || fail "tier1 must call fleet-stale-auto-revert-sweep"
python3 - "$tier1" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
sweep = text.find("fleet-stale-auto-revert-sweep")
queue = text.find("2. queue pass starting")
if sweep < 0:
    raise SystemExit("sweep name missing from tier1")
if queue < 0:
    raise SystemExit("queue pass marker missing from tier1")
if sweep > queue:
    raise SystemExit("sweep must run BEFORE the queue pass (heartbeat auto-merges revert/ heads)")
PY
grep -q 'bin/fleet-stale-auto-revert-sweep' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-stale-auto-revert-sweep"
ok "contracts: sweep before queue pass + MANIFEST entry"

echo "all fleet-stale-auto-revert-sweep cases passed"
