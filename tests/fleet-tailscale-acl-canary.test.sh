#!/usr/bin/env bash
# tests/fleet-tailscale-acl-canary.test.sh
#
# Proves the VPS→Mac Tailscale lockdown canary (fleet-ops#544) offline:
#   1. Clean: PacketFilter is Mac→VPS only -> OK, no file.
#   2. Self→Mac allow -> exit 1, LOUD, auto-files.
#   3. Self→0.0.0.0/0 -> exit 1 (covers the Mac).
#   4. Missing Mac peer -> exit 1, watcher-broken.
#   5. Missing netmap fetch -> exit 1, watcher-broken.
#   6. Dedup: open issue already carrying the marker -> no second create.
#   7. Matrix row is enforced; heartbeat-tier1 wires the canary; MANIFEST
#      installs it. Nested CI host so this token does not edit workflows.
#   8. Live VPS netmap (when sudo tailscale works) must pass.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-tailscale-acl-canary"
lib="$repo_root/lib/tailscale-acl-lockdown.py"
cfg="$repo_root/config/tailscale-acl-lockdown.json"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing: $lib"
[[ -f "$cfg" ]] || fail "missing: $cfg"
[[ -f "$tier1" ]] || fail "missing: $tier1"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"
bash -n "$bin" || fail "bash syntax error in canary"

scratch="$(mktemp -d -t tailscale-acl-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_TAILSCALE_ACL_REPO="Nishfleet/fleet-ops"
export FLEET_TAILSCALE_ACL_FILE=1
export FLEET_TAILSCALE_ACL_LIB="$lib"
export FLEET_TAILSCALE_ACL_CONFIG="$cfg"
export FLEET_OPS_REPO="$repo_root"

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

write_netmap() { cat >"$scratch/netmap.json"; }

clean_netmap() {
  write_netmap <<'JSON'
{
  "SelfNode": {
    "Name": "netcup-rs2000.example.ts.net.",
    "ComputedName": "netcup-rs2000",
    "Addresses": ["100.108.184.97/32"]
  },
  "Peers": [
    {
      "Name": "nishants-macbook-air.example.ts.net.",
      "ComputedName": "nishants-macbook-air",
      "Addresses": ["100.120.128.16/32"]
    }
  ],
  "PacketFilter": [
    {
      "Srcs": ["100.120.128.16/32"],
      "Dsts": [{"Net": "100.108.184.97/32", "Ports": {"First": 0, "Last": 65535}}]
    }
  ],
  "PacketFilterRules": [
    {"SrcIPs": ["100.120.128.16"], "DstPorts": [{"IP": "100.108.184.97", "Ports": {"First": 0, "Last": 65535}}]}
  ]
}
JSON
}

run_canary() {
  FLEET_TAILSCALE_NETMAP="$scratch/netmap.json" "$bin" 2>&1
}

# --- 1. clean Mac→VPS only ------------------------------------------------
: >"$gh_log"; : >"$triage"
clean_netmap
out=$(run_canary) || fail "scenario1: clean filter must exit 0 ($out)"
grep -q 'TAILSCALE-ACL-LOCKDOWN-OK\|OK: compiled PacketFilter' <<<"$out" \
  || fail "scenario1: must log OK ($out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file ($gh_log)"
fi
ok "scenario1: Mac→VPS-only PacketFilter is green"

# --- 2. Self→Mac allow ----------------------------------------------------
: >"$gh_log"; : >"$triage"
write_netmap <<'JSON'
{
  "SelfNode": {
    "Name": "netcup-rs2000.example.ts.net.",
    "ComputedName": "netcup-rs2000",
    "Addresses": ["100.108.184.97/32"]
  },
  "Peers": [
    {
      "Name": "nishants-macbook-air.example.ts.net.",
      "ComputedName": "nishants-macbook-air",
      "Addresses": ["100.120.128.16/32"]
    }
  ],
  "PacketFilter": [
    {
      "Srcs": ["100.108.184.97/32"],
      "Dsts": [{"Net": "100.120.128.16/32", "Ports": {"First": 22, "Last": 22}}]
    }
  ]
}
JSON
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario2: self→mac must exit 1 (rc=$rc out=$out)"
grep -q 'LOCKDOWN-BROKEN' <<<"$out" || fail "scenario2: must LOUD lockdown-broken ($out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file ($gh_log)"
ok "scenario2: self→mac PacketFilter is rejected and filed"

# --- 3. Self→0.0.0.0/0 ----------------------------------------------------
: >"$gh_log"; : >"$triage"
write_netmap <<'JSON'
{
  "SelfNode": {
    "Name": "netcup-rs2000.example.ts.net.",
    "ComputedName": "netcup-rs2000",
    "Addresses": ["100.108.184.97/32"]
  },
  "Peers": [
    {
      "Name": "nishants-macbook-air.example.ts.net.",
      "ComputedName": "nishants-macbook-air",
      "Addresses": ["100.120.128.16/32"]
    }
  ],
  "PacketFilter": [
    {
      "Srcs": ["100.108.184.97/32"],
      "Dsts": [{"Net": "0.0.0.0/0", "Ports": {"First": 0, "Last": 65535}}]
    }
  ]
}
JSON
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario3: wildcard dst must exit 1 (rc=$rc out=$out)"
grep -q 'LOCKDOWN-BROKEN' <<<"$out" || fail "scenario3: must LOUD lockdown-broken ($out)"
ok "scenario3: self→0.0.0.0/0 is rejected"

# --- 4. missing Mac peer --------------------------------------------------
: >"$gh_log"; : >"$triage"
write_netmap <<'JSON'
{
  "SelfNode": {
    "Name": "netcup-rs2000.example.ts.net.",
    "ComputedName": "netcup-rs2000",
    "Addresses": ["100.108.184.97/32"]
  },
  "Peers": [
    {
      "Name": "hostinger-kvm4.example.ts.net.",
      "ComputedName": "hostinger-kvm4",
      "Addresses": ["100.82.230.76/32"]
    }
  ],
  "PacketFilter": []
}
JSON
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario4: missing mac peer must exit 1 (rc=$rc out=$out)"
grep -q 'WATCHER-BROKEN' <<<"$out" || fail "scenario4: must LOUD watcher-broken ($out)"
ok "scenario4: missing Mac peer fails closed"

# --- 5. broken netmap fetch -----------------------------------------------
: >"$gh_log"; : >"$triage"
set +e
out=$(
  unset FLEET_TAILSCALE_NETMAP
  TAILSCALE_NETMAP_CMD="false" \
  "$bin" 2>&1
)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario5: failed fetch must exit 1 (rc=$rc out=$out)"
grep -q 'WATCHER-BROKEN' <<<"$out" || fail "scenario5: must LOUD watcher-broken ($out)"
ok "scenario5: dead netmap fetch fails closed"

# --- 6. dedup -------------------------------------------------------------
: >"$gh_log"; : >"$triage"
jq -n --arg b $'body\ntailscale-acl-canary: lockdown-broken\n' \
  '[{"number": 544, "body": $b}]' >"$scratch/open.json"
write_netmap <<'JSON'
{
  "SelfNode": {
    "Name": "netcup-rs2000.example.ts.net.",
    "ComputedName": "netcup-rs2000",
    "Addresses": ["100.108.184.97/32"]
  },
  "Peers": [
    {
      "Name": "nishants-macbook-air.example.ts.net.",
      "ComputedName": "nishants-macbook-air",
      "Addresses": ["100.120.128.16/32"]
    }
  ],
  "PacketFilter": [
    {
      "Srcs": ["100.108.184.97/32"],
      "Dsts": [{"Net": "100.120.128.16/32", "Ports": {"First": 22, "Last": 22}}]
    }
  ]
}
JSON
set +e
out=$(
  GH_OPEN_ISSUES="$scratch/open.json" \
  FLEET_TAILSCALE_NETMAP="$scratch/netmap.json" \
  "$bin" 2>&1
)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario6: still exit 1 (rc=$rc out=$out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario6: must not create a second issue (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$out" || fail "scenario6: must log dedup ($out)"
ok "scenario6: open marker is not filed twice"
unset GH_OPEN_ISSUES

# --- 7. contracts ---------------------------------------------------------
jq -e '.rules[] | select(.id == "led-tailscale" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-tailscale must be status=enforced in the matrix"
grep -F 'fleet-tailscale-acl-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-tailscale-acl-canary"
grep -F 'tailscale_acl_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture tailscale_acl_canary_rc"
grep -F -- 'exit "$tailscale_acl_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the Tailscale ACL gate fails loud"
grep -q 'bin/fleet-tailscale-acl-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-tailscale-acl-canary"
grep -Fq 'bash "$here/fleet-tailscale-acl-canary.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "scenario7: matrix enforced, heartbeat wired, MANIFEST, nested CI host"

# --- 8. live VPS netmap (inner loop) --------------------------------------
if sudo -n tailscale debug netmap >/dev/null 2>&1; then
  live_map="$scratch/live-netmap.json"
  sudo -n tailscale debug netmap >"$live_map"
  live_out=$(python3 "$lib" verify --netmap "$live_map" --config "$cfg" 2>&1) \
    || fail "scenario8: live PacketFilter must pass lockdown ($live_out)"
  grep -q 'TAILSCALE-ACL-LOCKDOWN-OK' <<<"$live_out" \
    || fail "scenario8: live verify must print OK ($live_out)"
  ok "scenario8: live VPS PacketFilter has no VPS→Mac allow"
else
  ok "scenario8: live tailscale netmap not readable (hosted CI) — skip"
fi

ok "fleet-tailscale-acl-canary: clean, self→mac, wildcard, missing peer, dead fetch, dedup, contracts, live"
