#!/usr/bin/env bash
# tests/role-quality-gates.test.sh
#
# Proves fleet-ops#457 per-role gate audit:
#   live catalog against this repo is green (every named role gated)
#   (a) fixture prompt with no catalog row -> finding + auto-filed issue
#   replay: open issue with the signal key is deduped
#   contracts: heartbeat-tier1 call + MANIFEST + nested CI host
#   missing-helper drill (fleet-ops#708) is gated on the #667 fallback
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

# fleet-ops#710: pin the live-audit negative for vault-knowledge-format.
# The unit file is real (added in #699) and was red-flagged until #716
# added it to NON_ROLE_UNIT_PREFIXES. This explicit signal-key check
# makes the regression findable in the test output if it ever returns.
if echo "$live" | jq -e '.findings[] | select(.id == "unit:vault-knowledge-format.service")' >/dev/null; then
  fail "live audit re-flagged vault-knowledge-format.service (regression of #710)"
fi
ok "live audit does not flag vault-knowledge-format.service (fleet-ops#710)"

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

# fleet-ops#592 / #636 / #1180: session-reap, vault-conflict-resolver, the
# vault knowledge-format lint timer, and the fleet-metrics-export Prometheus
# textfile exporter are plumbing, not work-producing roles. Dropping any
# prefix re-reds the audit (the live catalog test is not enough if the
# unit file is also gone).
python3 - "$lib" "$repo_root" <<'PY' || fail "plumbing unit skip missing"
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("role_quality_gates", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
required = (
    "interactive-session-reap",
    "vault-knowledge-format",
    "vault-conflict",
    "fleet-metrics-export",
    "fleet-aeo",
)
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
        "fleet-metrics-export.service",
        "fleet-aeo-probe.service",
    )
    if u in units
]
if leaked:
    raise SystemExit("discover_units leaked plumbing unit: " + ", ".join(leaked))
PY
ok "plumbing skips: session-reap, vault-conflict-resolver, vault-knowledge-format, fleet-metrics-export, fleet-aeo-probe (fleet-ops#1180/#1236)"

# fleet-ops#709: behaviour-locked. Build a scratch repo with a real
# vault-knowledge-format.service on disk and prove the audit emits no
# `unit:vault-knowledge-format.service` finding. The structural-prefix
# test above would still pass if a future refactor moved the skip out
# of NON_ROLE_UNIT_PREFIXES; this behaviour test would not.
scratch709=$(mktemp -d -t role-gates-709.XXXXXX)
trap 'rm -rf "$scratch709"' EXIT INT TERM
mkdir -p "$scratch709/systemd" "$scratch709/prompts" "$scratch709/bin" "$scratch709/config" "$scratch709/tests"
cat >"$scratch709/systemd/vault-knowledge-format.service" <<'UNIT'
[Unit]
Description=vault knowledge-format lint (fixture for fleet-ops#709)
[Service]
Type=oneshot
ExecStart=/bin/true
UNIT
# Minimal catalog so the auditor can parse it.
cp "$catalog" "$scratch709/config/role-quality-gates.json"
audit709_out=$(python3 "$lib" audit --repo-root "$scratch709" --catalog "$scratch709/config/role-quality-gates.json" 2>&1) || true
echo "$audit709_out" | jq -e . >/dev/null || fail "scratch audit did not emit JSON: $audit709_out"
if echo "$audit709_out" | jq -e '.findings[] | select(.id == "unit:vault-knowledge-format.service")' >/dev/null; then
  fail "fleet-ops#709 regression: vault-knowledge-format.service leaked into ungated-role findings: $(echo "$audit709_out" | jq -c '.findings')"
fi
# Mirror the exact detail line the issue reported so future refactors see the
# exact failure mode if the skip is ever dropped.
detail_hit=$(echo "$audit709_out" | jq -e '.findings[] | select(.detail | test("vault-knowledge-format.service is not in the role-quality-gates catalog"))' >/dev/null && echo yes || echo no)
if [[ "$detail_hit" == "yes" ]]; then
  fail "fleet-ops#709 regression: exact issue symptom re-appeared: $(echo "$audit709_out" | jq -c '.findings')"
fi
ok "behaviour lock: vault-knowledge-format.service is not flagged (fleet-ops#709)"

# fleet-ops#1180: behaviour-locked. Build a scratch repo with a real
# fleet-metrics-export.service on disk (the Prometheus textfile exporter
# the auditor flagged in #1180) and prove the audit emits no
# `unit:fleet-metrics-export.service` finding. The structural-prefix
# test above would still pass if a future refactor moved the skip out
# of NON_ROLE_UNIT_PREFIXES; this behaviour test would not.
scratch1180=$(mktemp -d -t role-gates-1180.XXXXXX)
trap 'rm -rf "$scratch1180"' EXIT INT TERM
mkdir -p "$scratch1180/systemd" "$scratch1180/prompts" "$scratch1180/bin" "$scratch1180/config" "$scratch1180/tests"
cat >"$scratch1180/systemd/fleet-metrics-export.service" <<'UNIT'
[Unit]
Description=Fleet Prometheus metrics exporter (fixture for fleet-ops#1180)
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /home/nish/.local/libexec/fleet-metrics-export.py
UNIT
# Minimal catalog so the auditor can parse it.
cp "$catalog" "$scratch1180/config/role-quality-gates.json"
audit1180_out=$(python3 "$lib" audit --repo-root "$scratch1180" --catalog "$scratch1180/config/role-quality-gates.json" 2>&1) || true
echo "$audit1180_out" | jq -e . >/dev/null || fail "scratch audit did not emit JSON: $audit1180_out"
if echo "$audit1180_out" | jq -e '.findings[] | select(.id == "unit:fleet-metrics-export.service")' >/dev/null; then
  fail "fleet-ops#1180 regression: fleet-metrics-export.service leaked into ungated-role findings: $(echo "$audit1180_out" | jq -c '.findings')"
fi
# Mirror the exact detail line the issue reported so future refactors see the
# exact failure mode if the skip is ever dropped.
detail_hit=$(echo "$audit1180_out" | jq -e '.findings[] | select(.detail | test("fleet-metrics-export.service is not in the role-quality-gates catalog"))' >/dev/null && echo yes || echo no)
if [[ "$detail_hit" == "yes" ]]; then
  fail "fleet-ops#1180 regression: exact issue symptom re-appeared: $(echo "$audit1180_out" | jq -c '.findings')"
fi
ok "behaviour lock: fleet-metrics-export.service is not flagged (fleet-ops#1180)"

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

# Observe-to-close (fleet-ops#1180): a stale unit finding for the
# fleet-metrics-export Prometheus exporter is closed on a clean tick.
# This is the exact issue the prefix added in this PR opened; the
# auditor must close it once the unit is skipped.
: >"$scratch/closed.txt"
: >"$scratch/triage.md"
unset EXTRA_PROMPT || true
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'The per-role quality-gate auditor (fleet-ops#457) found a bypass.\n\nunit fleet-metrics-export.service is not in the role-quality-gates catalog\n\nsignal: role-quality-gate/unit:fleet-metrics-export.service\n' \
  '[{number: 1180, body: $b}]' >"$GH_OPEN_ISSUES"
run_audit
[[ "$env_rc" == "0" ]] || fail "observe-to-close (1180) expected rc=0, got $env_rc ($env_out)"
if grep -q create "$scratch/created.txt"; then
  fail "observe-to-close (1180) must not file: $(cat "$scratch/created.txt")"
fi
grep -q 'observe-to-close: CLOSED issue #1180' <<<"$env_out" \
  || fail "clean tick must close stale fleet-metrics-export finding (out=$env_out)"
grep -q 'issue close 1180' "$scratch/closed.txt" \
  || fail "gh issue close 1180 must be invoked (closed=$(cat "$scratch/closed.txt"))"
grep -q 'observe-to-close:' "$scratch/closed.txt" \
  || fail "close comment must name observe-to-close (closed=$(cat "$scratch/closed.txt"))"
ok "observe-to-close closes stale fleet-metrics-export finding (fleet-ops#1180)"

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

# fleet-ops#708: missing helper fails loud even when an installed
# fallback exists. A bare missing-path check is a no-op on machines
# that already have ~/.local/lib/pi-packet/role-quality-gates.py: the
# wrapper would take the fallback and exit 0. The fallback gate added
# in #667 (env var unset -> fallback) must hold — a revert of that
# gate flips this drill green for the wrong reason on a VPS install.
# Same shape as #609: plant a succeeding helper under a fake HOME,
# set the env var to a missing path, and assert exit 1 + LOUD that
# names the explicit missing path (not the installed fallback).
fake_home="$scratch/fake-home"
mkdir -p "$fake_home/.local/lib/pi-packet"
cp "$lib" "$fake_home/.local/lib/pi-packet/role-quality-gates.py"
missing_helper="$scratch/no-such-helper.py"
: >"$scratch/triage.md"
set +e
missing_helper_out=$(
  HOME="$fake_home" \
  FLEET_OPS_REPO="$scratch" \
  FLEET_ROLE_GATES_JSON="$catalog" \
  FLEET_ROLE_GATES_LIB="$missing_helper" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  FLEET_ROLE_GATES_FILE=0 \
  "$bin" 2>&1
)
missing_helper_rc=$?
set -e
[[ "$missing_helper_rc" == "1" ]] \
  || fail "missing helper expected rc=1, got $missing_helper_rc — guard did not win over installed fallback ($missing_helper_out)"
grep -q 'ROLE-GATE-AUDITOR-BROKEN' "$scratch/triage.md" \
  || fail "missing helper must be LOUD (triage=$(cat "$scratch/triage.md"))"
grep -Fq "$missing_helper" "$scratch/triage.md" \
  || fail "LOUD line must name the explicit missing helper path, not the installed fallback (triage=$(cat "$scratch/triage.md"))"
ok "missing helper fails loud even with installed fallback present (fleet-ops#708)"

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
# fleet-ops#708: installed-lib fallback must be gated on unset
# FLEET_ROLE_GATES_LIB so an explicit missing-path pin still fails
# loud. A revert of the #667 gate (or refactor of the fallback) flips
# the new drill green for the wrong reason on a VPS install.
grep -Fq '[[ -z "${FLEET_ROLE_GATES_LIB:-}" && ! -f "$LIB"' "$bin" \
  || fail "installed-lib fallback must be gated on unset FLEET_ROLE_GATES_LIB (fleet-ops#708)"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, #708 fallback gate"

ok "role-quality-gates: live catalog, bypass auto-file, dedupe, observe-to-close, fail-loud, missing-helper-drill"
