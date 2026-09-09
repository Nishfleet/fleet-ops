#!/usr/bin/env bash
# tests/standards-drift-dedupe.test.sh
#
# fleet-ops#4591: the filing gate's same-problem dedupe must key standards-drift
# signals on the missing FILE (signal: standards-drift/<repo>/<file>), not on
# the shared "standards drift: <repo> missing <X>" title prefix / boilerplate.
#
# Before this fix, two drift signals differing only in file (secret-scan.yml vs
# semgrep.yml) scored 1.00 because their bodies are template-identical, so the
# second was suppressed as a "possible duplicate" of the first — one closed
# secret-scan.yml issue silently swallowed every other missing gate.
#
# Proves, offline (via the `score` subcommand, no gh / network):
#   1. Two standards-drift signals differing ONLY in file are BOTH filed
#      (the second resolves to `new`, not `duplicate`).
#   2. A true duplicate pair (same file) is still suppressed (resolves to
#      `duplicate`).
#
# Hosted by tests/issue-file.test.sh so the P14 test-listing gate (fleet-ops#566)
# reaches it transitively through ci-standards-audit.test.sh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"

scratch=$(mktemp -d -t standards-drift-dedupe.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

score() {
  python3 "$lib" score --title "$1" --body "$2" --against-json "$3"
}

# The exact bodies the fleet-escalation-canary standards-drift block files
# (bin/fleet-escalation-canary block 13): template-identical except for the
# `signal:` key and the workflow filename.
drift_body() {
  local file="$1"
  printf 'signal: standards-drift/Nishfleet/fleet-ops/%s\n\n' "$file"
  printf 'Repo Nishfleet/fleet-ops is intake-enrolled but missing the standard gate workflow `%s`.\n' "$file"
  printf 'The portable standard (P11-B) requires every enrolled repo to carry the\n'
  printf 'standard thin-caller workflows. This issue was auto-filed by the\n'
  printf 'fleet-escalation-canary standards-drift block.\n\n'
  printf 'Fix: add the thin-caller workflow (or apply the standard via\n'
  printf 'repo-standards-apply.mjs).\n'
}

drift_title() {
  printf 'standards drift: Nishfleet/fleet-ops missing %s' "$1"
}

# --- 1. distinct file -> BOTH filed ----------------------------------------
# Open issue covers secret-scan.yml; the candidate is semgrep.yml. Same repo,
# same template, DIFFERENT missing file -> must NOT be suppressed as a
# duplicate (fleet-ops#4591).
cat >"$scratch/open-secret-scan.json" <<'JSON'
[
  {
    "number": 4587,
    "repository": "Nishfleet/fleet-ops",
    "title": "standards drift: Nishfleet/fleet-ops missing secret-scan.yml",
    "body": "signal: standards-drift/Nishfleet/fleet-ops/secret-scan.yml\n\nRepo Nishfleet/fleet-ops is intake-enrolled but missing the standard gate workflow `secret-scan.yml`.\nThe portable standard (P11-B) requires every enrolled repo to carry the\nstandard thin-caller workflows. This issue was auto-filed by the\nfleet-escalation-canary standards-drift block.\n\nFix: add the thin-caller workflow (or apply the standard via\nrepo-standards-apply.mjs)."
  }
]
JSON

out=$(score "$(drift_title semgrep.yml)" "$(drift_body semgrep.yml)" "$scratch/open-secret-scan.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "new" ]] || fail "semgrep.yml must file as new against secret-scan.yml, got $out"
[[ "$sc" < "0.40" ]] || fail "semgrep.yml score must stay below borderline, got $sc"
ok "distinct-file standards-drift files as new (semgrep vs secret-scan, score=$sc)"

# The reverse direction must also hold (symmetry): open semgrep.yml,
# candidate secret-scan.yml.
cat >"$scratch/open-semgrep.json" <<'JSON'
[
  {
    "number": 4588,
    "repository": "Nishfleet/fleet-ops",
    "title": "standards drift: Nishfleet/fleet-ops missing semgrep.yml",
    "body": "signal: standards-drift/Nishfleet/fleet-ops/semgrep.yml\n\nRepo Nishfleet/fleet-ops is intake-enrolled but missing the standard gate workflow `semgrep.yml`.\nThe portable standard (P11-B) requires every enrolled repo to carry the\nstandard thin-caller workflows. This issue was auto-filed by the\nfleet-escalation-canary standards-drift block.\n\nFix: add the thin-caller workflow (or apply the standard via\nrepo-standards-apply.mjs)."
  }
]
JSON
out=$(score "$(drift_title secret-scan.yml)" "$(drift_body secret-scan.yml)" "$scratch/open-semgrep.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "new" ]] || fail "secret-scan.yml must file as new against semgrep.yml, got $out"
ok "distinct-file standards-drift files as new (secret-scan vs semgrep, score=$sc)"

# --- 2. same file -> suppression still fires --------------------------------
# A true duplicate (same repo, same file) must still be suppressed so the gate
# does not spam a second issue for an already-open drift alarm.
out=$(score "$(drift_title secret-scan.yml)" "$(drift_body secret-scan.yml)" "$scratch/open-secret-scan.json")
kind=$(jq -r .kind <<<"$out")
sc=$(jq -r .score <<<"$out")
[[ "$kind" == "duplicate" ]] || fail "same-file standards-drift must still suppress, got $out"
ok "same-file standards-drift still suppressed as duplicate (score=$sc)"

echo "OK: standards-drift dedupe keys on the missing file (fleet-ops#4591)"