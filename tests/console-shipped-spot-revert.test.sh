#!/usr/bin/env bash
# tests/console-shipped-spot-revert.test.sh
#
# Fleet-ops#4061: the console `shipped_24h` tile counts NON-revert merges
# (fleet_product_merged_24h). The verify spot-cross-check used to count ALL
# merged PRs, so on any day with a revert the spot disagreed and the tile was
# chronically false-DISPUTED. Proves run_shipped_gh_spot now excludes revert
# PRs so the spot agrees with the tile's definition.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
ver="$repo_root/libexec/fleet-console-pi/verify.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$ver" ]] || fail "missing $ver"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t shippedspot.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake gh: search/issues returns titles (incl a GitHub auto-revert + a
# fleet auto-revert) so the raw count would be 6 but non-revert is 3.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
# gh api search/issues -X GET -f q=... --paginate --jq '.items[]?.title'
if [[ "$1" == "api" && "$2" == "search/issues" ]]; then
  cat <<'OUT'
fix(seatlib): corpse retirement
Revert "fix(seatlib): corpse retirement"
feat(search): plain buyer copy
auto-revert: auto-restore green main
revert: auto-restore green main (reverts b498b90)
fix(canary): empty-run burst
OUT
  exit 0
fi
exit 1
FAKE
chmod +x "$gh_fake"

python3 - "$ver" "$gh_fake" <<'PY' || fail "verify spot logic failed"
import importlib.util, sys
ver_path, gh = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("console_verify", ver_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.GH = gh
m.SKIP_GH = False

count = m._gh_search_nonrevert_count("repo:Nishfleet/0509 is:merged merged:>=2026-09-05T00:00:00+00:00")
assert count == 3, f"expected 3 non-revert of 6 titles, got {count}"
print(f"OK: raw 6 titles -> non-revert count = {count} (reverts excluded)")

# _is_revert_title unit cases — must mirror fleet-product-slo's is_revert,
# incl the auto-restore bot's lowercase `revert: ...` (ConsoleLying live
# case: head-revert branches titled `revert: auto-restore green main
# (reverts <sha>)` were counted, over-flagging the tile).
assert m._is_revert_title("Revert \"fix\"") is True
assert m._is_revert_title("auto-revert: auto-restore green main") is True
assert m._is_revert_title("revert: auto-restore green main (reverts b498b90)") is True
assert m._is_revert_title("revert/3a1d316") is False  # head-ref form is not a title; fine, title covers the bot
assert m._is_revert_title("feat(search): plain copy") is False
assert m._is_revert_title("fix(seatlib): corpse retirement") is False
print("OK: _is_revert_title matches fleet-product-slo revert conventions")

# gh skip still skips, never disputes (existing safety)
m.SKIP_GH = True
try:
    m._gh_search_nonrevert_count("repo:x")
    raise AssertionError("expected VerifyError when gh skipped")
except m.VerifyError:
    print("OK: SKIP_GH still skips cleanly")

# A revert-only day yields 0, not a dispute
m.SKIP_GH = False
def bad_titles(q):
    raise AssertionError("should not need gh for a pure revert title")
count_r = sum(0 if m._is_revert_title(t) else 1
              for t in ["Revert \"a\"", "auto-revert: b"])
assert count_r == 0, ("expected 0 non-revert", count_r)
print("OK: revert-only window counts as 0")
print("ALL PASS")
PY
