#!/usr/bin/env bash
# tests/workflow-action-pin-guard.test.sh
#
# fleet-ops#1296: a one-character typo in a pinned `actions/checkout@<sha>`
# (3d3d... vs the canonical 3d3c...) made GitHub Actions return
# "Unable to resolve action ... unable to find version <sha>" at run time.
# The failing scheduled workflow ran on main's HEAD, so its check run dragged
# the default-branch statusCheckRollup to FAILURE and fired FleetMainRed.
#
# This test is the mechanical prevention for that class. It is OFFLINE (no
# GitHub API call) so it runs in the P14 test suite on hosted runners that
# have no GH_TOKEN. Two checks:
#
#   1. Canonical registry: every `uses: <repo>@<sha>` pin in
#      .github/workflows/** must match a known-good SHA in the registry below.
#      A typo (3d3d... / ...10b...) is a different 40-hex string and is
#      rejected. New actions or bumped SHAs are added to the registry in the
#      same PR that introduces them.
#
#   2. intra-repo consistency: the same `<repo>` must not carry two different
#      SHA pins. A second SHA for the same action is almost always a typo or a
#      half-bumped pin; if a bump is intentional, every caller moves together
#      and the registry is updated in the same PR.
#
# Why a registry and not a live `gh api .../git/commits/<sha>` probe: the test
# suite runs on hosted runners with no GH_TOKEN, and a network probe makes the
# gate flaky on rate limits. The registry is the set of SHAs already proven
# resolvable on main; a pin not in it is the failure mode this gate exists for.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- Canonical action-pin registry -----------------------------------------
# Each line: "<action-repo>@<40-hex-sha>". Add a line in the same PR that
# introduces or bumps a pin. SHAs are commit SHAs (git/commits), not tag SHAs.
read -r -d '' REGISTRY <<'REG' || true
actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
actions/setup-python@42375524e23c412d93fb67b49958b491fce71c38
actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
actions/create-github-app-token@fee1f7d63c2ff003460e3d139729b119787bc349
BetaHuhn/repo-file-sync-action@8b92be3375cf1d1b0cd579af488a9255572e4619
Nishfleet/fleet-ops/.github/workflows/red-on-main-detector.yml@2970807d23df3578b5a76b40580e022084a7bffd
Nishfleet/fleet-ops/.github/workflows/stop-the-line-detector.yml@2970807d23df3578b5a76b40580e022084a7bffd
REG

# --- Collect every pinned `uses:` in .github/workflows/** ------------------
mapfile -t pins < <(
  grep -rhoE 'uses: [A-Za-z0-9._/-]+@[a-f0-9]{40}' "$repo_root"/.github/workflows/ \
    | sed 's/^uses: //' \
    | sort -u
)
[[ "${#pins[@]}" -gt 0 ]] || fail "no pinned uses: actions found under .github/workflows/"

# 1. registry check
bad=0
for pin in "${pins[@]}"; do
  if ! grep -qxF "$pin" <<<"$REGISTRY"; then
    echo "FAIL: pin not in canonical registry: $pin" >&2
    bad=$((bad+1))
  fi
done
[[ "$bad" -eq 0 ]] \
  || fail "$bad pinned action(s) are not in the canonical registry. \
A typo (one wrong hex char) or an unbumped pin produces a SHA not listed. \
Add the SHA to the registry in tests/workflow-action-pin-guard.test.sh in \
the same PR, or fix the pin to match an existing entry."
ok "all pinned actions match the canonical registry"

# 2. intra-repo consistency: one SHA per action repo
declare -A seen=()
dupes=0
for pin in "${pins[@]}"; do
  repo="${pin%@*}"
  sha="${pin##*@}"
  if [[ -n "${seen[$repo]:-}" && "${seen[$repo]}" != "$sha" ]]; then
    echo "FAIL: $repo pinned to two SHAs: ${seen[$repo]} and $sha" >&2
    dupes=$((dupes+1))
  fi
  seen[$repo]="$sha"
done
[[ "$dupes" -eq 0 ]] \
  || fail "$dupes action(s) pinned to more than one SHA. A second SHA for the \
same action is almost always a typo or a half-bumped pin; bump every caller \
together and update the registry in the same PR."
ok "each action is pinned to a single SHA across all workflows"

echo "OK: workflow action pins are canonical and consistent (fleet-ops#1296)"
exit 0
