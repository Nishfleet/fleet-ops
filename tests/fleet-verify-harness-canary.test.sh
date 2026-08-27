#!/usr/bin/env bash
# tests/fleet-verify-harness-canary.test.sh
#
# Proves the per-repo verification harness canary (fleet-ops#524) offline:
#   1. Clean enrolled product with valid skill -> OK, no file.
#   2. Enrolled product missing skill -> exit 1, LOUD, auto-files.
#   3. Enrolled skill missing a required heading -> exit 1, auto-files.
#   4. Enrolled skill missing features/ map -> exit 1.
#   5. Deferred product missing skill -> exit 0, auto-files (observe-to-open).
#   6. Dedup: open issue already carrying the marker -> no second create.
#   7. Intake missing -> exit 1 WATCHER-BROKEN.
#   8. Config missing required_headings -> exit 1.
#   9. skip[] fleet-ops stays quiet even when enrolled.
#  10. Production skip names non-products and does not skip 0509.
#  11. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.
#  12. Live 0509 checkout (VPS) with FILE=0 is green.
#  13. Stale local checkout, valid harness on origin/main -> ok, no file
#      (fleet-ops#927: canary filed 7s after the harness PR merged because the
#      local HEAD was behind origin/main).
#  14. ORIGIN_FALLBACK=0 re-asserts the local-only missing path (the pre-#927
#      behavior), proving the seam is real and the fallback is opt-out.
#  18. Leftover-duplicate drain (fleet-ops#812 / #999): tinystudio-in is
#      ok via origin/main, two leftover open issues with the same marker
#      (#812 and #999) plus one unrelated issue. Both leftovers close on
#      this tick; the unrelated issue is not touched; nothing new is filed.
#  19. Still-gap: leftover open issue is NOT closed when the harness is
#      still missing.
#  20. FILE=0 skips observe-to-close (live probes must not close).
#  21. Open-list --limit 50 class (fleet-ops#999): 60 dummy issues sit
#      ahead of the marker. Dedup must still see #812 and not file a
#      second copy. The live desk had 200+ open issues; --limit 50 missed
#      #812 and filed leftover #999.
#  22. Leftover-duplicate drain for aiconverter-app (fleet-ops#997):
#      origin/main already has verify-aiconverter (Nishfleet/aiconverter-app#190)
#      with LAUNCH/DOCTOR/DRIVE/EVIDENCE/CLEANUP plus features/. Local HEAD
#      is behind. Leftover #997 (and sibling #768 from the same marker pile)
#      must close on the same tick as an unrelated issue stays open. A
#      tinystudio-in-only drain would leave #997 on the desk.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-verify-harness-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
cfg="$repo_root/config/verify-harness.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$cfg" ]] || fail "missing: $cfg"

scratch="$(mktemp -d -t verify-harness-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_VERIFY_HARNESS_REPO="Nishfleet/fleet-ops"
export FLEET_VERIFY_HARNESS_FILE=1
export FLEET_OPS_REPO="$scratch"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    limit=30
    if [[ "$*" =~ --limit[[:space:]]+([0-9]+) ]]; then
      limit="${BASH_REMATCH[1]}"
    fi
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      jq --argjson n "$limit" '.[0:$n]' "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue close"*)
    printf '%s\n' "$*" >>"${GH_CLOSED:-/dev/null}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
closed_log="$scratch/closed.log"
: >"$closed_log"
export GH_CLOSED="$closed_log"
export PATH="$scratch:$PATH"

products="$scratch/products"
mkdir -p "$products"

write_cfg() { cat >"$scratch/verify-harness.json"; }
write_intake() { cat >"$scratch/intake-repos.json"; }

base_cfg() {
  write_cfg <<'JSON'
{
  "required_headings": ["LAUNCH", "DOCTOR", "DRIVE", "EVIDENCE", "CLEANUP"],
  "skip": [
    {"name": "fleet-ops", "reason": "control plane"},
    {"name": "0509-telemetry", "reason": "sink"}
  ]
}
JSON
}

base_intake() {
  write_intake <<JSON
{
  "checkout_root": "$products",
  "repos": [{"name": "0509"}, {"name": "fleet-ops"}],
  "deferred": [{"name": "tinystudio-in"}]
}
JSON
}

commit_tree() {
  local dir="$1"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture"
}

make_valid_harness() {
  local dir="$1" app="${2:-app}"
  mkdir -p "$dir/.claude/skills/verify-${app}/features"
  cat >"$dir/.claude/skills/verify-${app}/SKILL.md" <<'EOF'
## LAUNCH
start
## DOCTOR
health
## DRIVE
click
## EVIDENCE
shot
## CLEANUP
stop
EOF
  echo "# feature" >"$dir/.claude/skills/verify-${app}/features/one.md"
  commit_tree "$dir"
}

run_canary() {
  set +e
  env_out=$(
    FLEET_VERIFY_HARNESS_JSON="$scratch/verify-harness.json" \
    FLEET_VERIFY_HARNESS_INTAKE="$scratch/intake-repos.json" \
    FLEET_VERIFY_HARNESS_CHECKOUT_ROOT="$products" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean enrolled -----------------------------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
mkdir -p "$products/fleet-ops"
git init -q -b main "$products/fleet-ops"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario1: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario1: clean enrolled harness is green, no file"

# --- 2. enrolled missing ---------------------------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
mkdir -p "$products/0509"
git init -q -b main "$products/0509"
git -C "$products/0509" config user.email t@t
git -C "$products/0509" config user.name t
echo x >"$products/0509/README"
git -C "$products/0509" add README
git -C "$products/0509" commit -q -m "no harness"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: missing enrolled must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out" || fail "scenario2: must LOUD ($env_out)"
grep -q '0509' <<<"$env_out" || fail "scenario2: must name 0509 ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file (gh=$(cat "$gh_log"))"
ok "scenario2: enrolled missing harness fails loud and auto-files"

# --- 3. enrolled incomplete headings ---------------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
mkdir -p "$products/0509/.claude/skills/verify-0509/features"
printf '%s\n' '## LAUNCH' 'start' '## DOCTOR' 'ok' >"$products/0509/.claude/skills/verify-0509/SKILL.md"
echo "# f" >"$products/0509/.claude/skills/verify-0509/features/one.md"
commit_tree "$products/0509"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: incomplete headings must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out" || fail "scenario3: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: enrolled incomplete headings fail loud"

# --- 4. enrolled missing features/ -----------------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
mkdir -p "$products/0509/.claude/skills/verify-0509"
cat >"$products/0509/.claude/skills/verify-0509/SKILL.md" <<'EOF'
## LAUNCH
## DOCTOR
## DRIVE
## EVIDENCE
## CLEANUP
EOF
commit_tree "$products/0509"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: missing features must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out" || fail "scenario4: must LOUD ($env_out)"
ok "scenario4: enrolled missing features/ map fails loud"

# --- 5. deferred missing, enrolled valid -----------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
mkdir -p "$products/tinystudio-in"
git init -q -b main "$products/tinystudio-in"
git -C "$products/tinystudio-in" config user.email t@t
git -C "$products/tinystudio-in" config user.name t
echo x >"$products/tinystudio-in/README"
git -C "$products/tinystudio-in" add README
git -C "$products/tinystudio-in" commit -q -m "no harness"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: deferred gap must stay exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario5: must log OK ($env_out)"
grep -q 'deferred gap: tinystudio-in' <<<"$env_out" || fail "scenario5: must name deferred ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario5: must auto-file deferred (gh=$(cat "$gh_log"))"
ok "scenario5: deferred missing harness auto-files and keeps the tick green"

# --- 6. dedup --------------------------------------------------------------
: >"$gh_log"; : >"$triage"
jq -n --arg b $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  '[{number: 88, body: $b}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: dedup must stay exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario6: must not create again (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario6: must log dedup ($env_out)"
if grep -q 'issue close' "$gh_log"; then
  fail "scenario6: still-gap must not observe-to-close (gh=$(cat "$gh_log"))"
fi
unset GH_OPEN_ISSUES
ok "scenario6: open marker is not filed twice"

# --- 7. intake missing -----------------------------------------------------
: >"$gh_log"; : >"$triage"
base_cfg
set +e
env_out=$(
  FLEET_VERIFY_HARNESS_JSON="$scratch/verify-harness.json" \
  FLEET_VERIFY_HARNESS_INTAKE="$scratch/no-such-intake.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
env_rc=$?
set -e
[[ "$env_rc" == "1" ]] || fail "scenario7: missing intake must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-WATCHER-BROKEN' <<<"$env_out" || fail "scenario7: must LOUD ($env_out)"
ok "scenario7: missing intake fails loud"

# --- 8. config missing required_headings -----------------------------------
: >"$gh_log"; : >"$triage"
base_intake
write_cfg <<'JSON'
{"skip": [{"name": "fleet-ops", "reason": "control plane"}]}
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario8: empty headings must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-WATCHER-BROKEN' <<<"$env_out" || fail "scenario8: must LOUD ($env_out)"
ok "scenario8: config without required_headings fails loud"

# --- 9. skip fleet-ops even when enrolled ----------------------------------
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg
write_intake <<JSON
{
  "checkout_root": "$products",
  "repos": [{"name": "fleet-ops"}],
  "deferred": []
}
JSON
# fleet-ops has no harness on purpose
mkdir -p "$products/fleet-ops"
git init -q -b main "$products/fleet-ops"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: skipped control plane must exit 0, got rc=$env_rc ($env_out)"
grep -q 'skip non-product: fleet-ops' <<<"$env_out" || fail "scenario9: must skip fleet-ops ($env_out)"
if grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out"; then
  fail "scenario9: must not violate skipped repo ($env_out)"
fi
ok "scenario9: skip[] fleet-ops is not a product gap"

# --- 10. production skip list ----------------------------------------------
jq -e '.required_headings == ["LAUNCH","DOCTOR","DRIVE","EVIDENCE","CLEANUP"]' \
  "$cfg" >/dev/null \
  || fail "scenario10: production required_headings must be the five standing-rule sections"
for name in fleet-ops 0509-telemetry egress-probe TinyStudio.io-public fleet2 siterep; do
  jq -e --arg n "$name" '.skip[] | select(.name == $n)' "$cfg" >/dev/null \
    || fail "scenario10: production skip missing $name"
done
if jq -e '.skip[] | select(.name == "0509")' "$cfg" >/dev/null; then
  fail "scenario10: production skip must not include 0509"
fi
ok "scenario10: production skip names non-products and keeps 0509 in scope"

# --- 11. heartbeat wiring --------------------------------------------------
grep -F 'fleet-verify-harness-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-verify-harness-canary"
grep -F 'verify_harness_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture verify_harness_canary_rc"
grep -F -- '_propagate_crash verify_harness_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the verify-harness gate fails loud"
grep -q 'bin/fleet-verify-harness-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-verify-harness-canary"
grep -q 'config/verify-harness.json' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install config/verify-harness.json"
ok "scenario11: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

# --- 12. live 0509 (VPS inner loop) ----------------------------------------
live_0509="/home/nish/workspaces/products/0509"
if [[ -d "$live_0509/.git" && -f "$repo_root/config/intake-repos.json" ]]; then
  set +e
  live_out=$(
    FLEET_VERIFY_HARNESS_FILE=0 \
    FLEET_OPS_REPO="$repo_root" \
    FLEET_HEARTBEAT_TRIAGE="$triage" \
    "$bin" 2>&1
  )
  live_rc=$?
  set -e
  [[ "$live_rc" == "0" ]] || fail "scenario12: live 0509 must exit 0, got rc=$live_rc ($live_out)"
  grep -q 'VERIFY-HARNESS-OK' <<<"$live_out" || fail "scenario12: must log OK ($live_out)"
  grep -q 'ok: 0509' <<<"$live_out" || fail "scenario12: must accept live 0509 ($live_out)"
  ok "scenario12: live 0509 harness is green (FILE=0)"
else
  ok "scenario12: live 0509 checkout not present — skip"
fi

# --- 13. stale local, valid harness on origin/main (fleet-ops#927) ---------
# Reproduces the #927 class: PR #190 merged the harness to origin/main, but the
# local checkout's HEAD was behind, so the canary filed a false positive 7s
# later. The fix re-checks origin's default-branch HEAD before reporting a gap.
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
# Build a bare "origin" whose default branch (main) carries a valid harness.
origin_bare="$scratch/origin-0509.git"
# fleet-ops#598: pin init.defaultBranch on the same line as `git init --bare`
# (hosted runner's global config is master, not main, so an unpinned bare
# init lands on master and the harness canary mis-fires). The class gate in
# tests/fleet-deploy-check.test.sh scans for the `-c init.defaultBranch=`
# token on the init line.
git -c init.defaultBranch=main init -q --bare "$origin_bare"
work_clone="$scratch/origin-work"
git init -q -b main "$work_clone"
git -C "$work_clone" config user.email t@t
git -C "$work_clone" config user.name t
make_valid_harness "$work_clone" 0509 2>/dev/null
git -C "$work_clone" remote add origin "$origin_bare"
git -C "$work_clone" push -q origin main
# Now create the inspected checkout: clone so origin/main exists, then reset
# HEAD to an earlier commit that has NO harness, leaving origin/main ahead.
git clone -q "$origin_bare" "$products/0509"
git -C "$products/0509" config user.email t@t
git -C "$products/0509" config user.name t
git -C "$products/0509" reset -q --hard HEAD~0  # at origin/main tip (has harness)
# Move local HEAD back to a harness-less commit while keeping origin/main.
git -C "$products/0509" checkout -q --orphan stale-local
git -C "$products/0509" rm -rf --quiet .claude 2>/dev/null || true
rm -rf "$products/0509/.claude"
echo "no harness here" >"$products/0509/README"
git -C "$products/0509" add README
git -C "$products/0509" commit -q -m "stale local HEAD without harness"
# origin/main still points at the harness commit (remote-tracking ref present).
git -C "$products/0509" rev-parse --verify --quiet origin/main >/dev/null \
  || fail "scenario13: fixture must have origin/main ref"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario13: stale-local with valid origin must exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario13: must log OK ($env_out)"
grep -q 'stale-local: 0509' <<<"$env_out" || fail "scenario13: must log stale-local ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario13: must not file when origin has the harness (gh=$(cat "$gh_log"))"
fi
ok "scenario13: stale local checkout with valid origin/main harness is ok, no file (fleet-ops#927)"

# --- 14. ORIGIN_FALLBACK=0 re-asserts the local-only missing path ----------
# Same fixture as 13, but the fallback disabled: the stale local HEAD is a
# real violation again. Proves the seam is real and the fix is opt-out.
: >"$gh_log"; : >"$triage"
set +e
env_out=$(
  FLEET_VERIFY_HARNESS_JSON="$scratch/verify-harness.json" \
  FLEET_VERIFY_HARNESS_INTAKE="$scratch/intake-repos.json" \
  FLEET_VERIFY_HARNESS_CHECKOUT_ROOT="$products" \
  FLEET_VERIFY_HARNESS_ORIGIN_FALLBACK=0 \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
env_rc=$?
set -e
[[ "$env_rc" == "1" ]] || fail "scenario14: fallback=0 + stale local must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out" || fail "scenario14: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario14: must auto-file (gh=$(cat "$gh_log"))"
ok "scenario14: ORIGIN_FALLBACK=0 re-asserts the local-only missing path"

# --- 15. stale local, valid harness on nishfleet/main (fleet-ops#961) ------
# Reproduces the #961 class: origin points at upstream (andrewyng) which
# does NOT have the harness, but a separately named `nishfleet` remote
# points at the user's fork (Nishfleet/<repo>) which DOES have the harness
# on its default branch. The fallback must walk the fallback_remotes list
# past origin and accept the nishfleet ref.
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
# Build TWO bare remotes: origin = upstream (no harness), nishfleet = fork
# (with harness). The local checkout has both remotes, but HEAD lacks the
# harness.
upstream_bare="$scratch/upstream-0509.git"
fork_bare="$scratch/fork-0509.git"
git -c init.defaultBranch=main init -q --bare "$upstream_bare"
git -c init.defaultBranch=main init -q --bare "$fork_bare"
# Seed upstream with a no-harness commit.
upstream_work="$scratch/upstream-work"
git init -q -b main "$upstream_work"
git -C "$upstream_work" config user.email t@t
git -C "$upstream_work" config user.name t
echo "no harness upstream" >"$upstream_work/README"
git -C "$upstream_work" add README
git -C "$upstream_work" commit -q -m "upstream seed"
git -C "$upstream_work" remote add origin "$upstream_bare"
git -C "$upstream_work" push -q origin main
# Seed fork (nishfleet) with a valid harness.
fork_work="$scratch/fork-work"
git init -q -b main "$fork_work"
git -C "$fork_work" config user.email t@t
git -C "$fork_work" config user.name t
make_valid_harness "$fork_work" 0509
git -C "$fork_work" remote add origin "$fork_bare"
git -C "$fork_work" push -q origin main
# Now create the inspected checkout: clone upstream so origin = upstream,
# then add a nishfleet remote pointing at fork. Reset HEAD to a harness-
# less commit so the local state is "missing".
git clone -q "$upstream_bare" "$products/0509"
git -C "$products/0509" config user.email t@t
git -C "$products/0509" config user.name t
git -C "$products/0509" remote add nishfleet "$fork_bare"
git -C "$products/0509" fetch -q nishfleet
git -C "$products/0509" rev-parse --verify --quiet nishfleet/main >/dev/null \
  || fail "scenario15: fixture must have nishfleet/main ref"
# Sanity: origin/main is the upstream (no harness) and nishfleet/main is the
# fork (with harness). local HEAD sits on the upstream main, harness-less.
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario15: stale-local + nishfleet has harness must exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario15: must log OK ($env_out)"
grep -q 'stale-local: 0509' <<<"$env_out" || fail "scenario15: must log stale-local ($env_out)"
grep -q 'nishfleet/main' <<<"$env_out" || fail "scenario15: must name nishfleet/main as the source ref ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario15: must not file when nishfleet/main has the harness (gh=$(cat "$gh_log"))"
fi
ok "scenario15: stale local checkout with valid nishfleet/main harness is ok, no file (fleet-ops#961)"

# --- 16. nishfleet fallback disabled when no nishfleet remote exists ---------
# Same shape as 13 (only origin, valid on origin/main). Proves the new
# fallback_remotes loop tolerates a missing nishfleet remote without
# breaking the existing origin path.
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
origin_bare="$scratch/origin-0509-16.git"
git -c init.defaultBranch=main init -q --bare "$origin_bare"
work_clone="$scratch/origin-work-16"
git init -q -b main "$work_clone"
git -C "$work_clone" config user.email t@t
git -C "$work_clone" config user.name t
make_valid_harness "$work_clone" 0509
git -C "$work_clone" remote add origin "$origin_bare"
git -C "$work_clone" push -q origin main
git clone -q "$origin_bare" "$products/0509"
git -C "$products/0509" config user.email t@t
git -C "$products/0509" config user.name t
# Sanity: the new clone has no `nishfleet` remote.
if git -C "$products/0509" remote get-url nishfleet >/dev/null 2>&1; then
  fail "scenario16: fixture must NOT have a nishfleet remote"
fi
git -C "$products/0509" checkout -q --orphan stale-local
git -C "$products/0509" rm -rf --quiet .claude 2>/dev/null || true
rm -rf "$products/0509/.claude"
echo "no harness here" >"$products/0509/README"
git -C "$products/0509" add README
git -C "$products/0509" commit -q -m "stale local HEAD without harness"
git -C "$products/0509" rev-parse --verify --quiet origin/main >/dev/null \
  || fail "scenario16: fixture must have origin/main ref"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario16: stale-local with origin (no nishfleet) must exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario16: must log OK ($env_out)"
grep -q 'stale-local: 0509' <<<"$env_out" || fail "scenario16: must log stale-local ($env_out)"
grep -q 'origin/main' <<<"$env_out" || fail "scenario16: must name origin/main as the source ref ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario16: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario16: missing nishfleet remote is tolerated, origin fallback still wins (fleet-ops#961)"

# --- 17. BOTH remotes empty: still a real violation ------------------------
# Same fixture as 15 (both remotes set up), but the fork's main branch is
# reset to also lack the harness. The canary must find no valid harness
# anywhere and report a real gap (this is the "fallback is not a free
# pass" guard).
: >"$gh_log"; : >"$triage"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
upstream_bare="$scratch/upstream-0509-17.git"
fork_bare="$scratch/fork-0509-17.git"
git -c init.defaultBranch=main init -q --bare "$upstream_bare"
git -c init.defaultBranch=main init -q --bare "$fork_bare"
upstream_work="$scratch/upstream-work-17"
git init -q -b main "$upstream_work"
git -C "$upstream_work" config user.email t@t
git -C "$upstream_work" config user.name t
echo "no harness upstream" >"$upstream_work/README"
git -C "$upstream_work" add README
git -C "$upstream_work" commit -q -m "upstream seed"
git -C "$upstream_work" remote add origin "$upstream_bare"
git -C "$upstream_work" push -q origin main
fork_work="$scratch/fork-work-17"
git init -q -b main "$fork_work"
git -C "$fork_work" config user.email t@t
git -C "$fork_work" config user.name t
echo "no harness fork" >"$fork_work/README"
git -C "$fork_work" add README
git -C "$fork_work" commit -q -m "fork seed"
git -C "$fork_work" remote add origin "$fork_bare"
git -C "$fork_work" push -q origin main
git clone -q "$upstream_bare" "$products/0509"
git -C "$products/0509" config user.email t@t
git -C "$products/0509" config user.name t
git -C "$products/0509" remote add nishfleet "$fork_bare"
git -C "$products/0509" fetch -q nishfleet
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario17: both remotes no-harness must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-VIOLATION' <<<"$env_out" || fail "scenario17: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario17: must auto-file (gh=$(cat "$gh_log"))"
ok "scenario17: fallback is not a free pass — both remotes no-harness is a real violation"

# --- 18. leftover-duplicate drain (fleet-ops#812 / #999) -------------------
# Live class: tinystudio-in origin/main already has the harness (PR #281)
# but local HEAD is a gate branch without it. Leftover #812 was still
# open; --limit 50 missed it and a later tick filed #999. When inspect
# returns ok via origin fallback, BOTH leftovers must close; an unrelated
# issue must stay open; nothing new is filed.
: >"$gh_log"; : >"$triage"; : >"$closed_log"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
origin_bare="$scratch/origin-tinystudio-18.git"
git -c init.defaultBranch=main init -q --bare "$origin_bare"
work_clone="$scratch/origin-tinystudio-work-18"
git init -q -b main "$work_clone"
git -C "$work_clone" config user.email t@t
git -C "$work_clone" config user.name t
make_valid_harness "$work_clone" tinystudio-in
git -C "$work_clone" remote add origin "$origin_bare"
git -C "$work_clone" push -q origin main
git clone -q "$origin_bare" "$products/tinystudio-in"
git -C "$products/tinystudio-in" config user.email t@t
git -C "$products/tinystudio-in" config user.name t
git -C "$products/tinystudio-in" checkout -q --orphan stale-local
git -C "$products/tinystudio-in" rm -rf --quiet .claude 2>/dev/null || true
rm -rf "$products/tinystudio-in/.claude"
echo "no harness here" >"$products/tinystudio-in/README"
git -C "$products/tinystudio-in" add README
git -C "$products/tinystudio-in" commit -q -m "stale local HEAD without harness"
git -C "$products/tinystudio-in" rev-parse --verify --quiet origin/main >/dev/null \
  || fail "scenario18: fixture must have origin/main ref"
jq -n \
  --arg b812 $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  --arg b999 $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  --arg b42 $'unrelated body, no verify-harness marker\n' \
  '[{number: 812, body: $b812}, {number: 999, body: $b999}, {number: 42, body: $b42}]' \
  >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18: leftover drain must stay exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario18: must log OK ($env_out)"
grep -q 'stale-local: tinystudio-in' <<<"$env_out" || fail "scenario18: must log stale-local ($env_out)"
grep -q 'OBSERVE-CLOSED tinystudio-in -> #812' <<<"$env_out" \
  || fail "scenario18: must close leftover #812 ($env_out)"
grep -q 'OBSERVE-CLOSED tinystudio-in -> #999' <<<"$env_out" \
  || fail "scenario18: must close leftover #999 ($env_out)"
if grep -q 'OBSERVE-CLOSED .* -> #42' <<<"$env_out"; then
  fail "scenario18: must not close unrelated #42 ($env_out)"
fi
if grep -q 'issue create' "$gh_log"; then
  fail "scenario18: must not file (gh=$(cat "$gh_log"))"
fi
grep -q 'issue close 812 ' "$closed_log" || fail "scenario18: gh must close 812 (closed=$(cat "$closed_log"))"
grep -q 'issue close 999 ' "$closed_log" || fail "scenario18: gh must close 999 (closed=$(cat "$closed_log"))"
if grep -q 'issue close 42 ' "$closed_log"; then
  fail "scenario18: gh must not close 42 (closed=$(cat "$closed_log"))"
fi
unset GH_OPEN_ISSUES
ok "scenario18: leftover #812 and #999 both close; unrelated #42 stays (fleet-ops#999)"

# --- 19. still-gap leftover is not closed ---------------------------------
: >"$gh_log"; : >"$triage"; : >"$closed_log"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
mkdir -p "$products/tinystudio-in"
git init -q -b main "$products/tinystudio-in"
git -C "$products/tinystudio-in" config user.email t@t
git -C "$products/tinystudio-in" config user.name t
echo x >"$products/tinystudio-in/README"
git -C "$products/tinystudio-in" add README
git -C "$products/tinystudio-in" commit -q -m "no harness"
jq -n --arg b $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  '[{number: 812, body: $b}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario19: still-gap must stay exit 0, got rc=$env_rc ($env_out)"
grep -q 'deferred gap: tinystudio-in' <<<"$env_out" || fail "scenario19: must name deferred ($env_out)"
if grep -q 'OBSERVE-CLOSED' <<<"$env_out"; then
  fail "scenario19: still-gap must not close ($env_out)"
fi
if grep -q 'issue close' "$closed_log"; then
  fail "scenario19: gh must not close (closed=$(cat "$closed_log"))"
fi
unset GH_OPEN_ISSUES
ok "scenario19: still-gap leftover is not closed"

# --- 20. FILE=0 skips observe-to-close -------------------------------------
: >"$gh_log"; : >"$triage"; : >"$closed_log"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
origin_bare="$scratch/origin-tinystudio-20.git"
git -c init.defaultBranch=main init -q --bare "$origin_bare"
work_clone="$scratch/origin-tinystudio-work-20"
git init -q -b main "$work_clone"
git -C "$work_clone" config user.email t@t
git -C "$work_clone" config user.name t
make_valid_harness "$work_clone" tinystudio-in
git -C "$work_clone" remote add origin "$origin_bare"
git -C "$work_clone" push -q origin main
git clone -q "$origin_bare" "$products/tinystudio-in"
git -C "$products/tinystudio-in" config user.email t@t
git -C "$products/tinystudio-in" config user.name t
git -C "$products/tinystudio-in" checkout -q --orphan stale-local
git -C "$products/tinystudio-in" rm -rf --quiet .claude 2>/dev/null || true
rm -rf "$products/tinystudio-in/.claude"
echo "no harness here" >"$products/tinystudio-in/README"
git -C "$products/tinystudio-in" add README
git -C "$products/tinystudio-in" commit -q -m "stale local HEAD without harness"
jq -n --arg b $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  '[{number: 999, body: $b}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
set +e
env_out=$(
  FLEET_VERIFY_HARNESS_JSON="$scratch/verify-harness.json" \
  FLEET_VERIFY_HARNESS_INTAKE="$scratch/intake-repos.json" \
  FLEET_VERIFY_HARNESS_CHECKOUT_ROOT="$products" \
  FLEET_VERIFY_HARNESS_FILE=0 \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
env_rc=$?
set -e
[[ "$env_rc" == "0" ]] || fail "scenario20: FILE=0 must stay exit 0, got rc=$env_rc ($env_out)"
if grep -q 'OBSERVE-CLOSED' <<<"$env_out"; then
  fail "scenario20: FILE=0 must not close ($env_out)"
fi
if grep -q 'issue close' "$closed_log"; then
  fail "scenario20: FILE=0 gh must not close (closed=$(cat "$closed_log"))"
fi
unset GH_OPEN_ISSUES
ok "scenario20: FILE=0 skips observe-to-close"

# --- 21. --limit 50 class: 60 dummies ahead of the marker (fleet-ops#999) -
# The live desk had 200+ open issues. file_finding used --limit 50, missed
# #812, and filed leftover #999. Dedup must walk far enough to see the
# marker sitting past index 50.
: >"$gh_log"; : >"$triage"; : >"$closed_log"
rm -rf "$products"; mkdir -p "$products"
base_cfg; base_intake
make_valid_harness "$products/0509" 0509
mkdir -p "$products/tinystudio-in"
git init -q -b main "$products/tinystudio-in"
git -C "$products/tinystudio-in" config user.email t@t
git -C "$products/tinystudio-in" config user.name t
echo x >"$products/tinystudio-in/README"
git -C "$products/tinystudio-in" add README
git -C "$products/tinystudio-in" commit -q -m "no harness"
jq -n --arg b $'body\nfleet-verify-harness-canary: missing-harness tinystudio-in\n' \
  '[range(1;61) | {number: ., body: "unrelated"}] + [{number: 812, body: $b}]' \
  >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario21: deep-list dedup must stay exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario21: must not file leftover when marker sits past index 50 (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario21: must log dedup ($env_out)"
if grep -nE '^[^#]*--limit[[:space:]]+50' "$bin"; then
  fail "scenario21: canary must not hardcode --limit 50 (fleet-ops#999 leftover filing)"
fi
unset GH_OPEN_ISSUES
ok "scenario21: marker past index 50 still dedups; --limit 50 is gone (fleet-ops#999)"

# --- 22. leftover-duplicate drain for aiconverter-app (fleet-ops#997) ------
# Live class: aiconverter-app origin/main already has the harness (PR #190)
# but local HEAD is four commits behind without it. inspect_product is ok
# via the origin fallback (fleet-ops#927). Heartbeat logged
# `ok: aiconverter-app` at 11:52Z, then #1117 landed the drain at 12:14Z,
# then freshness skipped the next tick, so leftover #997 sat. Drain must
# not be tinystudio-in-only: #997 (and sibling #768, same marker) close;
# unrelated #42 stays; nothing new is filed.
: >"$gh_log"; : >"$triage"; : >"$closed_log"
rm -rf "$products"; mkdir -p "$products"
base_cfg
write_intake <<JSON
{
  "checkout_root": "$products",
  "repos": [{"name": "0509"}, {"name": "fleet-ops"}],
  "deferred": [{"name": "aiconverter-app"}]
}
JSON
make_valid_harness "$products/0509" 0509
origin_bare="$scratch/origin-aiconverter-22.git"
git -c init.defaultBranch=main init -q --bare "$origin_bare"
work_clone="$scratch/origin-aiconverter-work-22"
git init -q -b main "$work_clone"
git -C "$work_clone" config user.email t@t
git -C "$work_clone" config user.name t
make_valid_harness "$work_clone" aiconverter
git -C "$work_clone" remote add origin "$origin_bare"
git -C "$work_clone" push -q origin main
git clone -q "$origin_bare" "$products/aiconverter-app"
git -C "$products/aiconverter-app" config user.email t@t
git -C "$products/aiconverter-app" config user.name t
git -C "$products/aiconverter-app" checkout -q --orphan stale-local
git -C "$products/aiconverter-app" rm -rf --quiet .claude 2>/dev/null || true
rm -rf "$products/aiconverter-app/.claude"
echo "no harness here" >"$products/aiconverter-app/README"
git -C "$products/aiconverter-app" add README
git -C "$products/aiconverter-app" commit -q -m "stale local HEAD without harness"
git -C "$products/aiconverter-app" rev-parse --verify --quiet origin/main >/dev/null \
  || fail "scenario22: fixture must have origin/main ref"
jq -n \
  --arg b997 $'body\nfleet-verify-harness-canary: missing-harness aiconverter-app\n' \
  --arg b768 $'body\nfleet-verify-harness-canary: missing-harness aiconverter-app\n' \
  --arg b42 $'unrelated body, no verify-harness marker\n' \
  '[{number: 997, body: $b997}, {number: 768, body: $b768}, {number: 42, body: $b42}]' \
  >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario22: leftover drain must stay exit 0, got rc=$env_rc ($env_out)"
grep -q 'VERIFY-HARNESS-OK' <<<"$env_out" || fail "scenario22: must log OK ($env_out)"
grep -q 'stale-local: aiconverter-app' <<<"$env_out" || fail "scenario22: must log stale-local ($env_out)"
grep -q 'OBSERVE-CLOSED aiconverter-app -> #997' <<<"$env_out" \
  || fail "scenario22: must close leftover #997 ($env_out)"
grep -q 'OBSERVE-CLOSED aiconverter-app -> #768' <<<"$env_out" \
  || fail "scenario22: must close leftover #768 ($env_out)"
if grep -q 'OBSERVE-CLOSED .* -> #42' <<<"$env_out"; then
  fail "scenario22: must not close unrelated #42 ($env_out)"
fi
if grep -q 'issue create' "$gh_log"; then
  fail "scenario22: must not file (gh=$(cat "$gh_log"))"
fi
grep -q 'issue close 997 ' "$closed_log" || fail "scenario22: gh must close 997 (closed=$(cat "$closed_log"))"
grep -q 'issue close 768 ' "$closed_log" || fail "scenario22: gh must close 768 (closed=$(cat "$closed_log"))"
if grep -q 'issue close 42 ' "$closed_log"; then
  fail "scenario22: gh must not close 42 (closed=$(cat "$closed_log"))"
fi
unset GH_OPEN_ISSUES
ok "scenario22: leftover #997 and #768 both close; unrelated #42 stays (fleet-ops#997)"

# Citation lock: dropping #997 from the canary is a regression even if
# the aiconverter-app drill still passes (same pin as #965 leftover piles).
grep -q 'fleet-ops#812 / #999 / #997' "$bin" \
  || fail "canary header must cite leftover #997 next to #812 / #999"
grep -q 'fleet-ops#812, fleet-ops#999, fleet-ops#997' "$bin" \
  || fail "observe-to-close comment must cite leftover fleet-ops#997"
grep -q '#812 + #999 + #997' "$bin" \
  || fail "FILE_CAP comment must cite leftover pile #997 next to #812 + #999"
ok "canary cites leftover #997 next to #812 / #999"

ok "fleet-verify-harness-canary: clean, missing, headings, features, deferred, dedup, watcher, skip, prod, wiring, live, stale-local, fallback-seam, nishfleet-remote, missing-nishfleet-remote, both-empty, leftover-drain, still-gap-no-close, file0-no-close, deep-list-dedup, aiconverter-leftover-drain"
