#!/usr/bin/env bash
# tests/fleet-issue-file-dedupe-repo-scope.test.sh
#
# fleet-ops#5620: the `file` dedupe corpus must be scoped to the repo
# passed via --repo. A same-problem open issue in a DIFFERENT Nishfleet
# repo must never suppress or redirect a filing — previously, an
# org-wide corpus made the auto-revert halt filing comment on a
# noise-class issue in 0509 instead of creating the fleet-ops ticket.
#
# Proves:
#   1. fake gh with a same-titled open issue in repo B; `file --repo A`
#      creates the issue in A (exit 0, new number), never comments on B.
#   2. The dedupe corpus still suppresses on same-repo duplicates.
#   3. Prevention guard (fleet-ops#366): the cmd_file source must call
#      collect_open with cross_repo=False so the corpus cannot silently
#      widen back to org-wide.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"

scratch=$(mktemp -d -t issue-file-repo-scope.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
log="${GH_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
case "$1 $2" in
  "issue list")
    # Repo-scoped fake open-issue DB: one issue per repo file.
    repo_args="$*" ; repo=""
    while [[ -n "${1:-}" ]]; do
      if [[ "$1" == "-R" ]]; then repo="$2"; shift 2; fi
      shift
    done
    f="${GH_OPEN_DIR:-/dev/null}/${repo//\//__}.json"
    if [[ -f "$f" ]]; then cat "$f"; else printf '[]\n'; fi
    ;;
  "issue create")
    args=("$@") ; repo=""
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--repo" ]]; then repo="${args[$((i+1))]}"; fi
    done
    n=$(( $(cat "${GH_COUNTER:-/dev/null}" 2>/dev/null || echo 4241) + 1 ))
    echo "$n" >"${GH_COUNTER:-/tmp/issue-file-repo-scope-counter}"
    echo "https://github.com/${repo}/issues/${n}"
    echo "created ${repo}" >>"${GH_CREATED:-/dev/null}"
    ;;
  "issue comment")
    args=("$@") ; repo=""
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--repo" ]]; then repo="${args[$((i+1))]}"; fi
    done
    echo "commented ${repo}" >>"${GH_COMMENTED:-/dev/null}"
    ;;
esac
exit 0
GH
chmod +x "$scratch/fakebin/gh"

# open issue in repo B (Nishfleet/0509) with EXACTLY the same title the
# caller files into repo A (Nishfleet/fleet-ops).
mkdir -p "$scratch/opens"
cat >"$scratch/opens/Nishfleet__0509.json" <<'JSON'
[{"number":2923,"title":"AUTO-REVERT HALT: main moved after the red commit","body":"auto-revert run halted: main moved after the red commit","url":"https://github.com/Nishfleet/0509/issues/2923"}]
JSON
printf '[]\n' >"$scratch/opens/Nishfleet__fleet-ops.json"

: >"$scratch/commented"
: >"$scratch/created"
echo 4241 >"$scratch/counter"
GH_LOG="$scratch/gh.log" GH_OPEN_DIR="$scratch/opens" \
GH_CREATED="$scratch/created" GH_COMMENTED="$scratch/commented" \
GH_COUNTER="$scratch/counter" PATH="$scratch/fakebin:$PATH" \
  python3 "$lib" file --repo Nishfleet/fleet-ops \
    --title "AUTO-REVERT HALT: main moved after the red commit" \
    --body "auto-revert run halted: main moved after the red commit"
[[ $? -eq 0 ]] || fail "file must exit 0"
grep -q "created Nishfleet/fleet-ops" "$scratch/created" \
  || fail "cross-repo duplicate must NOT suppress; expected create in fleet-ops (created=$(cat "$scratch/created"))"
[[ ! -s "$scratch/commented" ]] \
  || fail "cross-repo duplicate must never comment on 0509 (commented=$(cat "$scratch/commented"))"
grep -q -- "--repo Nishfleet/fleet-ops" "$scratch/gh.log" \
  || fail "create must target the --repo repo (log=$(cat "$scratch/gh.log"))"
ok "same-titled open issue in 0509 does not avert the fleet-ops filing"

# --- 2. same-repo dedupe still works ---------------------------------------
: >"$scratch/commented"
: >"$scratch/created"
GH_LOG=/dev/null GH_OPEN_DIR="$scratch/opens" \
GH_CREATED="$scratch/created" GH_COMMENTED="$scratch/commented" \
GH_COUNTER="$scratch/counter" PATH="$scratch/fakebin:$PATH" \
  python3 "$lib" file --repo Nishfleet/0509 \
    --title "AUTO-REVERT HALT: main moved after the red commit" \
    --body "auto-revert run halted: main moved after the red commit"
[[ -s "$scratch/commented" ]] || fail "same-repo duplicate must comment"
[[ ! -s "$scratch/created" ]] || fail "same-repo duplicate must not create"
ok "same-repo duplicate still comments (dedupe intact in target repo)"

# --- 3. prevention guard: cmd_file corpus stays repo-scoped -----------------
# fleet-ops#366: cheap guard asserting the cmd_file dedupe query carries
# the target-repo scoping so the corpus cannot silently widen again.
python3 - "$lib" <<'PY' || exit 1
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
body = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "cmd_file":
        body = ast.get_source_segment(src, node)
assert body is not None, "cmd_file not found"
assert "cross_repo=False" in body, "cmd_file must pin cross_repo=False (repo-scoped corpus, fleet-ops#5620)"
assert "not args.no_cross_repo" not in body, "cmd_file must not widen the corpus via --no-cross-repo inversion"
assert "args.search_repo" not in body, "cmd_file must not add --search-repo repos to the corpus"
print("guard OK")
PY
ok "guard: cmd_file corpus is pinned repo-scoped (cross_repo=False)"

echo "ALL OK"
