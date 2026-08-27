#!/usr/bin/env bash
# tests/vault-lint.test.sh
#
# fleet-ops#1264: vault snapshot lint. A note that asserts live state
# (unit status, seat caps, red/green on main, PR merged/open, lane
# counts) without a check-command and a fresh observed timestamp fails.
# Pointers and procedures with no live-state claim pass.
#
# Fixtures (8+):
#   1. clean pointer                          PASS
#   2. live-state + check-command + fresh     PASS
#   3. live-state without check-command       FAIL
#   4. live-state with stale observed         FAIL
#   5. live-state missing observed            FAIL
#   6. seat-cap claim without check-command   FAIL
#   7. red on main without check-command      FAIL
#   8. live-state only inside a fence         PASS
# plus edge cases: PR MERGED, lanes active, ttl override, unknown class,
# --report stays exit 0, --pre-write refuses (exit 2) and does not leave
# a dirty capture in place.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lint="$repo_root/lib/vault-lint.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lint" ]] || fail "missing $lint"
python3 -m py_compile "$lint" || fail "vault-lint.py failed py_compile"
ok "1: vault-lint.py compiles"

python3 "$lint" --help >/dev/null \
  || fail "vault-lint --help must exit 0"
ok "2: --help exits 0"

scratch="$(mktemp -d -t vault-lint.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
notes="$scratch/notes"
mkdir -p "$notes"

NOW="2026-08-27T18:00:00Z"
run() { python3 "$lint" --now "$NOW" "$@"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
cat >"$notes/01-clean-pointer.md" <<'EOF'
---
class: procedure
ttl: 90d
---
To see whether the unit is up, run:

`systemctl --user is-active fleet-heartbeat.timer`

Do not record the result in this note. Point at the check instead.
EOF

cat >"$notes/02-live-state-with-check.md" <<'EOF'
---
class: seat-caps
check-command: jq '.providers' /home/nish/.local/state/pi-packet/seat-caps.json
observed: 2026-08-27T17:30:00Z
---
Current seat cap is 4 on the free pool. Re-run the check-command before treating this as live.
EOF

cat >"$notes/03-live-state-without-check.md" <<'EOF'
---
class: drill-status
observed: 2026-08-27T17:59:00Z
---
fleet-heartbeat.service Active: active (running) right now.
EOF

cat >"$notes/04-live-state-stale-observed.md" <<'EOF'
---
class: seat-caps
check-command: jq '.providers' /home/nish/.local/state/pi-packet/seat-caps.json
observed: 2026-08-27T16:00:00Z
---
seat cap is 4
EOF

cat >"$notes/05-live-state-missing-observed.md" <<'EOF'
---
class: seat-health
check-command: systemctl --user is-active pi-intake@fleet-ops.service
---
pi-intake@fleet-ops.service Active: failed
EOF

cat >"$notes/06-seat-cap-no-check.md" <<'EOF'
---
class: seat-caps
observed: 2026-08-27T17:50:00Z
---
The seats cap is 2 after the last rotation.
EOF

cat >"$notes/07-red-on-main.md" <<'EOF'
---
class: drill-status
observed: 2026-08-27T17:59:00Z
---
We are red on main as of this morning.
EOF

cat >"$notes/08-fenced-example.md" <<'EOF'
---
class: procedure
ttl: 90d
---
Example `systemctl` output looks like this. It is a format sample, not a claim:

```
fleet-heartbeat.service Active: active (running)
```

Run the check yourself; do not copy the sample into a status note.
EOF

cat >"$notes/09-pr-merged.md" <<'EOF'
---
class: evidence
observed: 2026-08-27T17:00:00Z
---
PR 1276 MERGED an hour ago.
EOF

cat >"$notes/10-lanes-active.md" <<'EOF'
---
class: drill-status
observed: 2026-08-27T17:59:00Z
---
16 lanes active and merged 3 PRs/24h.
EOF

cat >"$notes/11-ttl-override-fresh.md" <<'EOF'
---
class: seat-caps
ttl: 4h
check-command: jq '.providers' /home/nish/.local/state/pi-packet/seat-caps.json
observed: 2026-08-27T16:00:00Z
---
seat cap is 4
EOF

cat >"$notes/12-unknown-class.md" <<'EOF'
---
class: vibes
check-command: true
observed: 2026-08-27T17:59:00Z
---
green on main
EOF

# ---------------------------------------------------------------------------
# 3-4: clean pointer and proven live-state pass
# ---------------------------------------------------------------------------
out="$(run --check "$notes/01-clean-pointer.md")" || fail "clean pointer must exit 0, got output: $out"
printf '%s\n' "$out" | grep -q '0 violation' || fail "clean pointer report: $out"
ok "3: clean pointer passes"

out="$(run --check "$notes/02-live-state-with-check.md")" \
  || fail "live-state with check-command + fresh observed must exit 0: $out"
ok "4: live-state with check-command and fresh observed passes"

# ---------------------------------------------------------------------------
# 5-8: required fail fixtures
# ---------------------------------------------------------------------------
set +e
out="$(run --check "$notes/03-live-state-without-check.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing check-command must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'missing check-command' \
  || fail "missing check-command must be named: $out"
printf '%s\n' "$out" | grep -q 'unit-status' \
  || fail "unit-status kind must be named: $out"
ok "5: live-state without check-command fails"

set +e
out="$(run --check "$notes/04-live-state-stale-observed.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "stale observed must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'older than class TTL' \
  || fail "stale observed must name TTL: $out"
ok "6: live-state with stale observed fails"

set +e
out="$(run --check "$notes/05-live-state-missing-observed.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing observed must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'missing observed' \
  || fail "missing observed must be named: $out"
ok "7: live-state missing observed fails"

set +e
out="$(run --check "$notes/06-seat-cap-no-check.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "seat-cap without check-command must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'seat-cap' || fail "seat-cap kind: $out"
ok "8: seat-cap claim without check-command fails"

set +e
out="$(run --check "$notes/07-red-on-main.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "red on main without check-command must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -qi 'red on main' || fail "red on main excerpt: $out"
ok "9: red on main without check-command fails"

# ---------------------------------------------------------------------------
# 9: fenced example is a procedure sample, not a claim
# ---------------------------------------------------------------------------
out="$(run --check "$notes/08-fenced-example.md")" \
  || fail "fenced example must pass (procedure sample, not a claim): $out"
ok "10: live-state only inside a fence passes"

# ---------------------------------------------------------------------------
# Extra live-state kinds
# ---------------------------------------------------------------------------
set +e
out="$(run --check "$notes/09-pr-merged.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "PR MERGED without check-command must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'pr-merged' || fail "pr-merged kind: $out"
ok "11: PR N MERGED without check-command fails"

set +e
out="$(run --check "$notes/10-lanes-active.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "lanes active without check-command must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'lanes-active' || fail "lanes-active kind: $out"
printf '%s\n' "$out" | grep -q 'merged-prs-24h' || fail "merged-prs-24h kind: $out"
ok "12: lanes active and merged PRs/24h without check-command fail"

out="$(run --check "$notes/11-ttl-override-fresh.md")" \
  || fail "explicit ttl: 4h must keep a 2h-old seat-caps note passing: $out"
ok "13: explicit ttl override still inside the window passes"

set +e
out="$(run --check "$notes/12-unknown-class.md" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "unknown class must exit 1, got $rc: $out"
printf '%s\n' "$out" | grep -q 'unknown class' || fail "unknown class named: $out"
ok "14: unknown class fails"

# ---------------------------------------------------------------------------
# Directory scan + --report (heartbeat) stays exit 0
# ---------------------------------------------------------------------------
set +e
out="$(run --check "$notes" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "directory --check must exit 1 on mixed fixtures, got $rc"
printf '%s\n' "$out" | grep -q '03-live-state-without-check.md' \
  || fail "directory report must name the dirty note: $out"
ok "15: directory --check fails and names dirty notes"

set +e
out="$(run --report "$notes" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--report must exit 0 even with violations, got $rc: $out"
printf '%s\n' "$out" | grep -q '^# Vault snapshot lint' \
  || fail "--report must be Markdown: $out"
printf '%s\n' "$out" | grep -q 'violation' || fail "--report must count violations: $out"
ok "16: --report prints Markdown and exits 0 with violations"

# ---------------------------------------------------------------------------
# Capture wrapper refuse path (--pre-write)
# ---------------------------------------------------------------------------
dirty="$scratch/capture-dirty.md"
cp "$notes/03-live-state-without-check.md" "$dirty"
set +e
out="$(run --pre-write "$dirty" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "--pre-write dirty note must exit 2, got $rc: $out"
printf '%s\n' "$out" | grep -q 'missing check-command' \
  || fail "--pre-write must return the violation report: $out"
ok "17: --pre-write dirty note exits 2 with the report"

# Simulated siterep-vault-capture: write then lint; on refuse, drop the file.
# `|| cap_rc=$?` keeps set -e from aborting; do not toggle set -e here.
capture() {
  local dest="$1" cap_rc=0
  cat >"$dest"
  python3 "$lint" --now "$NOW" --pre-write "$dest" >/dev/null || cap_rc=$?
  if [[ "$cap_rc" -ne 0 ]]; then
    rm -f "$dest"
    return 2
  fi
  return 0
}

dropped="$scratch/dropped.md"
set +e
capture "$dropped" <"$notes/03-live-state-without-check.md"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "capture wrapper must refuse dirty notes, got $rc"
[[ ! -e "$dropped" ]] || fail "capture wrapper must not leave a refused note on disk"
ok "18: capture wrapper refuses a dirty note and does not leave the file"

kept="$scratch/kept.md"
set +e
capture "$kept" <"$notes/02-live-state-with-check.md"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "capture wrapper must accept a proven note, got $rc"
[[ -f "$kept" ]] || fail "capture wrapper must keep a proven note"
ok "19: capture wrapper keeps a note that passes the lint"

echo "OK: vault-lint.test.sh: 12 fixtures + check/report/pre-write wrapper lock"
