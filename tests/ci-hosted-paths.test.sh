#!/usr/bin/env bash
# tests/ci-hosted-paths.test.sh
#
# fleet-ops#926: P14 tests that feed git a `main...feature` (or `main..feature`)
# rev range die on hosted GitHub Actions runners whose `init.defaultBranch`
# is still `master`. The no-agent-names drill did this after an unpinned
# `git init -q`, and CI failed with:
#
#   fatal: ambiguous argument 'main...feature': unknown revision
#
# This file is the class lock. It (1) reproduces the hosted-runner failure
# and the CI-safe replacement range, and (2) scans every tests/*.test.sh
# so a future drill cannot re-introduce an unpinned `main..` / `main...`
# range. A file that pins `git init -q -b main` (or `init.defaultBranch=main`)
# on a non-comment line is allowed: that is how Phase E of
# fleet-no-agent-names.test.sh names `main` on purpose.
#
# Hosted by tests/rule-enforcement.test.sh so P14 runs this without a
# workflow-file edit (worker tokens cannot push .github/workflows/**).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t ci-hosted-paths.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Non-comment line pins the default branch to `main`.
file_pins_main() {
  local f="$1" line stripped
  while IFS= read -r line || [[ -n "$line" ]]; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    if [[ "$stripped" == *"git init -q -b main"* ]] \
      || [[ "$stripped" == *"init.defaultBranch=main"* ]]; then
      return 0
    fi
  done <"$f"
  return 1
}

# Non-comment line feeds git a `main..` / `main...` rev range.
# `origin/main..` is a different ref (the `/` excludes it).
line_has_main_range() {
  local stripped="$1"
  [[ "$stripped" =~ (^|[^[:alnum:]/_])main\.\. ]] || return 1
  if [[ "$stripped" == *"--commit-range"* ]]; then
    return 0
  fi
  if [[ "$stripped" == git* ]] && [[ "$stripped" == *" log "* || "$stripped" == *" log'"* ]]; then
    return 0
  fi
  return 1
}

# Print "basename:lineno:line" for each unsafe range in $1.
scan_unsafe_ranges() {
  local f="$1" lineno=0 line stripped base
  base="$(basename "$f")"
  file_pins_main "$f" && return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    if line_has_main_range "$stripped"; then
      printf '%s:%s:%s\n' "$base" "$lineno" "$stripped"
    fi
  done <"$f"
}

configure_git() {
  local dir="$1"
  git -C "$dir" config user.email "agent@example.com"
  git -C "$dir" config user.name "Test Agent"
}

seed_linear_feature() {
  local dir="$1"
  printf 'initial\n' >"$dir/file"
  git -C "$dir" add file
  git -C "$dir" commit -qm "initial"
  git -C "$dir" checkout -qb feature
  printf 'change\n' >"$dir/file"
  git -C "$dir" add file
  git -C "$dir" commit -qm "feat"
}

# --- 1. Live repro: hosted-runner defaultBranch makes main...feature die ----
unpinned="$scratch/unpinned"
mkdir -p "$unpinned"
git -c init.defaultBranch=master init -q "$unpinned"
configure_git "$unpinned"
seed_linear_feature "$unpinned"

set +e
git -C "$unpinned" rev-parse --verify main >/dev/null 2>&1
main_rc=$?
git -C "$unpinned" log --oneline main...feature >/dev/null 2>"$scratch/unpinned.err"
log_rc=$?
set -e
[[ "$main_rc" != 0 ]] || fail "unpinned init with defaultBranch=master must not create a main ref"
[[ "$log_rc" != 0 ]] || fail "unpinned init: git log main...feature must fail (got rc=0)"
grep -Eq 'unknown revision|ambiguous argument' "$scratch/unpinned.err" \
  || fail "unpinned init: git log main...feature must name unknown/ambiguous revision, got: $(cat "$scratch/unpinned.err")"
ok "live: unpinned git init (defaultBranch=master) makes main...feature an unknown revision"

git -C "$unpinned" log --oneline 'feature~1..feature' >/dev/null \
  || fail "unpinned init: git log feature~1..feature must resolve (got rc=$?)"
ok "live: feature~1..feature resolves without a main ref (CI-safe range)"

# --- 2. Live repro: git init -q -b main makes main...feature resolvable -----
pinned="$scratch/pinned"
mkdir -p "$pinned"
git init -q -b main "$pinned"
configure_git "$pinned"
seed_linear_feature "$pinned"
git -C "$pinned" log --oneline main...feature >/dev/null \
  || fail "pinned init -b main: git log main...feature must resolve"
ok "live: git init -q -b main makes main...feature resolvable"

# --- 3. Class gate rejects an unpinned fixture ------------------------------
unsafe_demo="$scratch/unsafe-demo.sh"
cat >"$unsafe_demo" <<'FAKE'
#!/usr/bin/env bash
out=$("$bin" --commit-range main...feature 2>&1)
FAKE
unsafe_hits="$(scan_unsafe_ranges "$unsafe_demo")"
[[ -n "$unsafe_hits" ]] || fail "class gate must reject unpinned --commit-range main...feature"
ok "class gate rejects unpinned main...feature"

# --- 4. Class gate allows the same range when the file pins main ------------
safe_demo="$scratch/safe-demo.sh"
cat >"$safe_demo" <<'FAKE'
#!/usr/bin/env bash
git init -q -b main
out=$("$bin" --commit-range main...feature 2>&1)
FAKE
safe_hits="$(scan_unsafe_ranges "$safe_demo")"
[[ -z "$safe_hits" ]] || fail "class gate must allow pinned main...feature, got: $safe_hits"
ok "class gate allows main...feature when the file pins git init -q -b main"

# --- 5. Live repo: no P14 test repeats the unpinned class -------------------
violations=""
for f in "$here"/*.test.sh; do
  [[ "$(basename "$f")" == "ci-hosted-paths.test.sh" ]] && continue
  hits="$(scan_unsafe_ranges "$f")"
  if [[ -n "$hits" ]]; then
    violations+="$hits"$'\n'
  fi
done
[[ -z "$violations" ]] || fail "P14 tests use an unpinned main.. / main... rev range (fleet-ops#926):"$'\n'"$violations"
ok "live: no P14 test uses an unpinned main.. / main... rev range"

# --- 6. This lock is actually reached from a P14-listed test ----------------
grep -Fq 'bash "$here/ci-hosted-paths.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must invoke this file (P14 host, fleet-ops#926)"
ok "lock is wired through tests/rule-enforcement.test.sh (already in P14)"

echo "OK: ci-hosted-paths.test.sh: hosted-runner rev-range class is locked"
