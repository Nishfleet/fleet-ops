#!/usr/bin/env bash
# tests/memoryctl-ttl-provenance.test.sh
#
# fleet-ops#1263: TTL + provenance on recorded facts. Synthesize notes at
# varying ages, assert UNVERIFIED is applied exactly when (now - observed)
# > ttl, and assert the [recall: N loaded, M UNVERIFIED] receipt.
#
# Offline. Does not touch the live vault. check-command strings are printed,
# never executed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/memoryctl-recall.py"
policy="$repo_root/lib/shared-memory/ttl-policy.md"
now="2026-08-27T18:00:00Z"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
[[ -f "$policy" ]] || fail "missing $policy"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$bin" \
  || fail "memoryctl-recall is not valid Python"
ok "script parses"

# Policy file carries every class default the issue names.
for pair in "drill-status: 5m" "seat-caps: 1h" "seat-health: 1m" \
            "decision-ledger: 7d" "evidence: 30d" "procedure: 90d"; do
  grep -qxF "$pair" "$policy" || fail "policy missing default line: $pair"
done
ok "ttl-policy.md has the six class defaults"

scratch="$(mktemp -d -t memoryctl-ttl.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
notes="$scratch/notes"
mkdir -p "$notes"

write_note() {
  local name="$1" class="$2" observed="$3" ttl="$4" check="$5" body="$6"
  {
    if [[ -n "$class$observed$ttl$check" ]]; then
      printf '%s\n' "---"
      [[ -n "$class" ]] && printf 'class: %s\n' "$class"
      [[ -n "$observed" ]] && printf 'observed: %s\n' "$observed"
      [[ -n "$ttl" ]] && printf 'ttl: %s\n' "$ttl"
      [[ -n "$check" ]] && printf 'check-command: %s\n' "$check"
      printf '%s\n' "---"
    fi
    printf '%s\n' "$body"
  } >"$notes/$name"
}

# Fresh drill-status: 4m old, default ttl 5m.
write_note drill-fresh.md drill-status "2026-08-27T17:56:00Z" "" \
  "systemctl --user is-active fleet-heartbeat.timer" \
  "heartbeat timer is active"

# Expired drill-status: 6m old, default ttl 5m.
write_note drill-stale.md drill-status "2026-08-27T17:54:00Z" "" \
  "systemctl --user is-active fleet-heartbeat.timer" \
  "heartbeat timer is active"

# Exact ttl boundary: 5m old, still fresh ((now - observed) > ttl is false).
write_note drill-boundary.md drill-status "2026-08-27T17:55:00Z" "" \
  "true" \
  "boundary still fresh"

# seat-health ttl 1m: 90s old -> expired.
write_note health-stale.md seat-health "2026-08-27T17:58:30Z" "" \
  "python3 -c 'import json,pathlib; print(pathlib.Path.home())'" \
  "deepseek-v4-flash is healthy"

# seat-caps ttl 1h: 30m old -> fresh.
write_note caps-fresh.md seat-caps "2026-08-27T17:30:00Z" "" \
  "" \
  "b.ai free seats are wired"

# decision-ledger ttl 7d: 8d old -> expired.
write_note ledger-stale.md decision-ledger "2026-08-19T18:00:00Z" "" \
  "rg -n '0509 EXCLUSIVE' /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md" \
  "0509 is exclusive supply"

# procedure ttl 90d: 10d old -> fresh.
write_note proc-fresh.md procedure "2026-08-17T18:00:00Z" "" \
  "" \
  "run install.sh --check after a MANIFEST edit"

# evidence ttl 30d: 31d old -> expired.
write_note evidence-stale.md evidence "2026-07-27T18:00:00Z" "" \
  "test -f /home/nish/workspaces/agent-state/OVERNIGHT.md" \
  "overnight handoff exists"

# Explicit ttl override: class drill-status (5m default) but ttl 1h, age 10m -> fresh.
write_note drill-override.md drill-status "2026-08-27T17:50:00Z" "1h" \
  "" \
  "override keeps this fresh"

# Not TTL-governed: no class, no ttl. Old date in body is irrelevant.
write_note ungovered.md "" "" "" "" \
  "standing rule: one fleet"

# Missing observed + class -> fail closed (UNVERIFIED).
write_note missing-observed.md drill-status "" "" \
  "date -u +%Y-%m-%dT%H:%M:%SZ" \
  "saw a green timer"

# Side-effect command must be printed, never run.
pwned="$scratch/pwned"
write_note no-exec.md seat-health "2026-08-27T17:00:00Z" "" \
  "touch $pwned" \
  "stale health"

recall() {
  python3 "$bin" --now "$now" --policy "$policy" "$notes"
}

out="$(recall)" || fail "recall exited nonzero"

printf '%s\n' "$out" >"$scratch/out.txt"

# Receipt: 12 notes, 6 UNVERIFIED
# stale: drill-stale, health-stale, ledger-stale, evidence-stale,
#        missing-observed, no-exec
# fresh: drill-fresh, drill-boundary, caps-fresh, proc-fresh,
#        drill-override, ungovered
first="$(printf '%s\n' "$out" | head -n 1)"
[[ "$first" == '[recall: 12 loaded, 6 UNVERIFIED]' ]] \
  || fail "receipt line wrong, got: $first"
ok "receipt is [recall: 12 loaded, 6 UNVERIFIED]"

assert_fresh() {
  local name="$1" needle="$2"
  printf '%s\n' "$out" | awk -v n="## $name" '
    $0 == n {p=1; next}
    p && /^## / {exit}
    p {print}
  ' | grep -qF "$needle" || fail "$name: missing fresh body '$needle'"
  printf '%s\n' "$out" | awk -v n="## $name" '
    $0 == n {p=1; next}
    p && /^## / {exit}
    p {print}
  ' | grep -q '^UNVERIFIED:' && fail "$name: marked UNVERIFIED but should be fresh"
  ok "$name is fresh"
}

assert_unverified() {
  local name="$1" body="$2" check="$3"
  local section
  section="$(printf '%s\n' "$out" | awk -v n="## $name" '
    $0 == n {p=1; next}
    p && /^## / {exit}
    p {print}
  ')"
  grep -qF "UNVERIFIED: $body" <<<"$section" \
    || fail "$name: expected 'UNVERIFIED: $body' in: $section"
  if [[ -n "$check" ]]; then
    grep -qxF "$check" <<<"$section" \
      || fail "$name: missing literal check-command '$check' in: $section"
  fi
  ok "$name is UNVERIFIED"
}

assert_fresh drill-fresh.md "heartbeat timer is active"
assert_fresh drill-boundary.md "boundary still fresh"
assert_fresh caps-fresh.md "b.ai free seats are wired"
assert_fresh proc-fresh.md "run install.sh --check after a MANIFEST edit"
assert_fresh drill-override.md "override keeps this fresh"
assert_fresh ungovered.md "standing rule: one fleet"

assert_unverified drill-stale.md "heartbeat timer is active" \
  "systemctl --user is-active fleet-heartbeat.timer"
assert_unverified health-stale.md "deepseek-v4-flash is healthy" \
  "python3 -c 'import json,pathlib; print(pathlib.Path.home())'"
assert_unverified ledger-stale.md "0509 is exclusive supply" \
  "rg -n '0509 EXCLUSIVE' /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md"
assert_unverified evidence-stale.md "overnight handoff exists" \
  "test -f /home/nish/workspaces/agent-state/OVERNIGHT.md"
assert_unverified missing-observed.md "saw a green timer" \
  "date -u +%Y-%m-%dT%H:%M:%SZ"
assert_unverified no-exec.md "stale health" "touch $pwned"

[[ ! -e "$pwned" ]] || fail "check-command was executed (created $pwned)"
ok "check-command is not executed"

# Fresh body must not carry the UNVERIFIED prefix on the first content line.
fresh_line="$(printf '%s\n' "$out" | awk '/^## drill-fresh.md$/{p=1; next} p && NF{print; exit}')"
[[ "$fresh_line" == "heartbeat timer is active" ]] \
  || fail "drill-fresh body line should be unprefixed, got: $fresh_line"
ok "fresh notes keep the original body"

# Bundled policy is the default when --policy is omitted. Pin MEMORY_VAULT
# to an empty scratch so a later live vault copy cannot change this drill.
bundled_out="$(
  MEMORY_VAULT="$scratch" MEMORYCTL_RECALL_POLICY="" \
    python3 "$bin" --now "$now" "$notes"
)" || fail "bundled-default recall exited nonzero"
bundled_first="$(printf '%s\n' "$bundled_out" | head -n 1)"
[[ "$bundled_first" == '[recall: 12 loaded, 6 UNVERIFIED]' ]] \
  || fail "bundled-default receipt wrong, got: $bundled_first"
ok "bundled ttl-policy.md is the default --policy"

echo "ALL OK: TTL applied exactly when (now - observed) > ttl; receipt matches"
