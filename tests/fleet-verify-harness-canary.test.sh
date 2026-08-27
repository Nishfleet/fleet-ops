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
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
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
grep -F -- 'exit "$verify_harness_canary_rc"' "$tier1" >/dev/null \
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

ok "fleet-verify-harness-canary: clean, missing, headings, features, deferred, dedup, watcher, skip, prod, wiring, live, stale-local, fallback-seam"
