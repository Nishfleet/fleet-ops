#!/usr/bin/env bash
# tests/role-quality-gates.test.sh
#
# Proves fleet-ops#457 per-role gate audit:
#   live catalog against this repo is green (every named role gated)
#   (a) fixture prompt with no catalog row -> finding + auto-filed issue
#   replay: open issue with the signal key is deduped
#   contracts: heartbeat-tier1 call + MANIFEST + nested CI host
#
# Offline. Live gh is stubbed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-role-gate-audit"
lib="$repo_root/lib/role-quality-gates.py"
catalog="$repo_root/config/role-quality-gates.json"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$catalog" ]] || fail "missing $catalog"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# Live catalog against this checkout must be clean. A new prompt/unit
# without a row is the bug this audit exists to catch.
set +e
live=$(python3 "$lib" audit --repo-root "$repo_root" --catalog "$catalog" 2>&1)
live_rc=$?
set -e
echo "$live" | jq -e . >/dev/null || fail "live audit did not emit JSON: $live"
[[ "$live_rc" == "0" ]] || fail "live catalog has findings: $(echo "$live" | jq -c '.findings')"
ok "live catalog: every named role is gated ($(echo "$live" | jq -r .role_count) roles)"

# fleet-ops#592: researcher is a standing role — dropping the catalog row
# must fail even if the live scan happens to be empty for other reasons.
python3 - "$catalog" <<'PY' || fail "researcher catalog row missing or incomplete"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = next((r for r in data["roles"] if r.get("id") == "researcher"), None)
if row is None:
    raise SystemExit("researcher role missing")
if "researcher.md" not in (row.get("prompts") or []):
    raise SystemExit("researcher prompts must include researcher.md")
if "fleet-researcher.service" not in (row.get("units") or []):
    raise SystemExit("researcher units must include fleet-researcher.service")
if "researcher_delta_contract" not in (row.get("bypass_checks") or []):
    raise SystemExit("researcher must name researcher_delta_contract")
PY
ok "catalog: researcher role is gated (fleet-ops#592)"

# fleet-ops#592 / #636: session-reap, vault-conflict-resolver, and the
# vault knowledge-format lint timer are plumbing, not work-producing roles.
# Dropping any prefix re-reds the audit (the live catalog test is not enough
# if the unit file is also gone).
python3 - "$lib" "$repo_root" <<'PY' || fail "plumbing unit skip missing"
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("role_quality_gates", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
required = ("interactive-session-reap", "vault-knowledge-format", "vault-conflict")
missing = [p for p in required if p not in mod.NON_ROLE_UNIT_PREFIXES]
if missing:
    raise SystemExit("NON_ROLE_UNIT_PREFIXES missing " + ", ".join(missing))
repo = Path(sys.argv[2])
units = mod.discover_units(repo)
leaked = [
    u
    for u in (
        "interactive-session-reap.service",
        "vault-knowledge-format.service",
        "vault-conflict-resolver.service",
    )
    if u in units
]
if leaked:
    raise SystemExit("discover_units leaked plumbing unit: " + ", ".join(leaked))
PY
ok "plumbing skips: session-reap, vault-conflict-resolver, vault-knowledge-format (fleet-ops#636)"

scratch=$(mktemp -d -t role-gates.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/fakebin"
: >"$scratch/triage.md"
: >"$scratch/gh.log"
: >"$scratch/created.txt"

cat >"$scratch/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "${1:-}" in
  issue)
    case "${2:-}" in
      list)
        if [[ -n "${GH_OPEN_ISSUES:-}" && -f "$GH_OPEN_ISSUES" ]]; then
          cat "$GH_OPEN_ISSUES"
        else
          printf '[]\n'
        fi
        ;;
      create)
        echo "https://github.com/Nishfleet/fleet-ops/issues/4571"
        echo create >>"${GH_CREATED:-/dev/null}"
        ;;
      close)
        echo "$*" >>"${GH_CLOSED:-/dev/null}"
        ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$scratch/fakebin/gh"

run_audit() {
  set +e
  env_out=$(
    HOME="$scratch/home" \
    PATH="$scratch/fakebin:$PATH" \
    GH="$scratch/fakebin/gh" \
    FLEET_OPS_REPO="$repo_root" \
    FLEET_ROLE_GATES_JSON="$catalog" \
    FLEET_ROLE_GATES_LIB="$lib" \
    FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    FLEET_ROLE_GATES_FILE=1 \
    FLEET_ROLE_GATES_REPO="Nishfleet/fleet-ops" \
    FLEET_ROLE_GATES_EXTRA_PROMPT="${EXTRA_PROMPT:-}" \
    GH_LOG="$scratch/gh.log" \
    GH_CREATED="$scratch/created.txt" \
    GH_CLOSED="$scratch/closed.txt" \
    GH_OPEN_ISSUES="${GH_OPEN_ISSUES:-}" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# Clean run (no extra prompt): exit 0, no issue filed.
: >"$scratch/created.txt"
: >"$scratch/closed.txt"
: >"$scratch/triage.md"
unset EXTRA_PROMPT || true
unset GH_OPEN_ISSUES || true
run_audit
[[ "$env_rc" == "0" ]] || fail "clean audit expected rc=0, got $env_rc ($env_out)"
if grep -q create "$scratch/created.txt"; then
  fail "clean audit must not file: $(cat "$scratch/created.txt")"
fi
ok "clean audit exits 0 and files nothing"

# (a) fixture ungated prompt -> auto-file
: >"$scratch/created.txt"
: >"$scratch/triage.md"
: >"$scratch/gh.log"
export EXTRA_PROMPT="planner-v2.md"
run_audit
[[ "$env_rc" == "0" ]] || fail "(a) auditor itself must stay rc=0, got $env_rc ($env_out)"
grep -q 'ROLE-GATE-BYPASS' "$scratch/triage.md" \
  || fail "(a) triage must name the bypass: $(cat "$scratch/triage.md")"
grep -q 'planner-v2.md' "$scratch/triage.md" \
  || fail "(a) triage must name the fixture prompt"
grep -q create "$scratch/created.txt" \
  || fail "(a) must auto-file a finding: $(cat "$scratch/gh.log")"
grep -q 'role-quality-gate/prompt:planner-v2.md' "$scratch/gh.log" \
  || fail "(a) filed body must carry the signal key: $(cat "$scratch/gh.log")"
ok "(a) fixture ungated prompt auto-files a finding"

# Replay: open issue with the signal -> no second file
: >"$scratch/created.txt"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nsignal: role-quality-gate/prompt:planner-v2.md\n' \
  '[{number: 77, body: $b}]' >"$GH_OPEN_ISSUES"
run_audit
[[ "$env_rc" == "0" ]] || fail "dedupe expected rc=0, got $env_rc"
if grep -q create "$scratch/created.txt"; then
  fail "dedupe must not file a second issue"
fi
grep -q 'dedup' <<<"$env_out" || fail "dedupe must log dedup (out=$env_out)"
ok "replay: open issue with signal key is deduped"

# Observe-to-close (fleet-ops#636): a stale unit finding is closed on a
# clean tick. This is the class that left #636 open after #667 skipped the
# unit: the auditor filed, never closed.
: >"$scratch/created.txt"
: >"$scratch/closed.txt"
: >"$scratch/triage.md"
unset EXTRA_PROMPT || true
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'The per-role quality-gate auditor (fleet-ops#457) found a bypass.\n\nunit vault-conflict-resolver.service is not in the role-quality-gates catalog\n\nsignal: role-quality-gate/unit:vault-conflict-resolver.service\n' \
  '[{number: 636, body: $b}]' >"$GH_OPEN_ISSUES"
run_audit
[[ "$env_rc" == "0" ]] || fail "observe-to-close expected rc=0, got $env_rc ($env_out)"
if grep -q create "$scratch/created.txt"; then
  fail "observe-to-close must not file: $(cat "$scratch/created.txt")"
fi
grep -q 'observe-to-close: CLOSED issue #636' <<<"$env_out" \
  || fail "clean tick must close stale unit finding (out=$env_out)"
grep -q 'issue close 636' "$scratch/closed.txt" \
  || fail "gh issue close 636 must be invoked (closed=$(cat "$scratch/closed.txt"))"
grep -q 'observe-to-close:' "$scratch/closed.txt" \
  || fail "close comment must name observe-to-close (closed=$(cat "$scratch/closed.txt"))"
ok "observe-to-close closes stale vault-conflict-resolver finding (fleet-ops#636)"

# Observe-to-close leaves an active finding open
: >"$scratch/closed.txt"
export EXTRA_PROMPT="planner-v2.md"
jq -n --arg b $'body\nsignal: role-quality-gate/prompt:planner-v2.md\n' \
  '[{number: 77, body: $b}]' >"$GH_OPEN_ISSUES"
run_audit
[[ "$env_rc" == "0" ]] || fail "active finding expected rc=0, got $env_rc ($env_out)"
if grep -q 'issue close 77' "$scratch/closed.txt"; then
  fail "active finding must stay open (closed=$(cat "$scratch/closed.txt"))"
fi
ok "observe-to-close leaves an active finding open"
unset EXTRA_PROMPT || true
unset GH_OPEN_ISSUES || true

# Broken auditor (missing catalog) fails loud
set +e
broken_out=$(
  FLEET_OPS_REPO="$scratch" \
  FLEET_ROLE_GATES_JSON="$scratch/no-such.json" \
  FLEET_ROLE_GATES_LIB="$lib" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  FLEET_ROLE_GATES_FILE=0 \
  "$bin" 2>&1
)
broken_rc=$?
set -e
[[ "$broken_rc" == "1" ]] || fail "missing catalog expected rc=1, got $broken_rc ($broken_out)"
grep -q 'ROLE-GATE-AUDITOR-BROKEN' "$scratch/triage.md" \
  || fail "missing catalog must be LOUD"
ok "auditor broken (missing catalog) fails loud"

# Contracts
grep -F 'fleet-role-gate-audit' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-role-gate-audit"
grep -F 'role_gate_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture role_gate_rc"
grep -F -- 'exit "$role_gate_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the auditor is broken"
grep -q 'bin/fleet-role-gate-audit' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-role-gate-audit"
grep -F 'observe-to-close' "$bin" >/dev/null \
  || fail "auditor must observe-to-close auto-filed findings (fleet-ops#636)"
grep -Fq 'bash "$here/role-quality-gates.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host"

ok "role-quality-gates: live catalog, bypass auto-file, dedupe, observe-to-close, fail-loud"
