#!/usr/bin/env bash
# tests/nish-boundary-notify-header-guard.test.sh
#
# fleet-ops#6845: ~10 orchestrator-sweep runs 2026-09-10 -> 2026-09-14 wrote
# `## ... (canonical entry lines)` headers to NISH-ESCALATIONS.md whose
# `<ts> <CLASS>` lines were absent — each claimed escalations the notifier
# had nothing to deliver, and every run was a silent green. The page channel
# to Nish read dark for 4+ days.
#
# The header-only guard in bin/nish-boundary-notify closes the gap: a `## `
# section holding neither a `^[0-9]{4}-` canonical line nor a deliverable
# prose marker (NISH ACTION / NISH DECISION NEEDED / class token) is a
# starved write — an undelivered-escalation signal that must exit 1 so
# OnFailure summons an auditor. `## DRAIN-DIGEST` pointers are the drain's
# own bookkeeping and stay exempt; a `## ` section with canonical lines or
# a prose marker is deliverable and never flags.
#
# This drill proves:
#   1. a bare `## ` header exits 1 (loud) and names the section on stderr
#   2. a `## ` header + canonical line under it delivers normally, exit 0
#   3. a `## ` header + NISH ACTION prose marker exits 0 (prose path owns it)
#   4. a `## DRAIN-DIGEST` bookkeeping header exits 0 (exempt)
#   5. a starved section alarms even when another section delivers fine
#
# Runs offline against temp files. No live state, no real Telegram send.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/nish-boundary-notify"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "missing: $script"
[[ -x "$script" ]] || fail "not executable: $script"
bash -n "$script" || fail "bash syntax error in $script"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state"
mkdir -p "$state/lanes"
seen="$state/lanes/nish-boundary-notify.seen"
escalations="$state/NISH-ESCALATIONS.md"
: > "$seen"

fake_hermes_ok="$tmp/fake-hermes-ok"
cat > "$fake_hermes_ok" <<'EOF'
#!/usr/bin/env bash
printf 'hermes-invoked\n' >> "$HERMES_LOG"
exit 0
EOF
chmod +x "$fake_hermes_ok"

# fleet-ops#4474: the notifier also reads confirmed `question` issues. Stub gh
# and the intake config so the offline drill never touches a live repo.
intake_json="$tmp/intake-repos.json"
cat > "$intake_json" <<'JSON'
{"repos":[],"excluded":[],"deferred":[]}
JSON
fake_gh="$tmp/fake-gh"
cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
exit 0
EOF
chmod +x "$fake_gh"
export BOUNDARY_NOTIFY_GH="$fake_gh"
export FLEET_INTAKE_REPOS_JSON="$intake_json"

run_notify() {
    local log="$1"
    set +e
    UNIT_ESCALATION_AGENT_STATE="$state" \
    BOUNDARY_NOTIFY_HERMES="$fake_hermes_ok" \
    BOUNDARY_NOTIFY_BACKOFF="0 0" \
    HERMES_LOG="$log" \
        bash "$script" > "$tmp/out" 2> "$tmp/err"
    local rc=$?
    set -e
    echo "$rc"
}

# --- scenario 1: bare `## ` header -> exit 1, names the starved section ----
echo "--- scenario 1: header-only section exits 1 (loud) ---"
cat > "$escalations" <<'EOS'
# Nish escalations

## Orchestrator decision sweep 2026-09-14T00:00:00Z — canonical entry lines

EOS
: > "$seen"
hermes_log="$tmp/h1.log"; : > "$hermes_log"
rc=$(run_notify "$hermes_log")
echo "exit: $rc"
[[ "$rc" -eq 1 ]] || fail "header-only section must exit 1 (loud); got $rc"
ok "header-only section exits 1"
grep -q "UNDELIVERED-ESCALATION" "$tmp/err" \
    || fail "stderr must name the starved section; got: $(cat "$tmp/err")"
grep -q "Orchestrator decision sweep 2026-09-14T00:00:00Z" "$tmp/err" \
    || fail "stderr must quote the bare header; got: $(cat "$tmp/err")"
ok "stderr names the starved section"
[[ "$(wc -l < "$hermes_log")" -eq 0 ]] \
    || fail "a starved section is an auditor signal, not a page — hermes must not fire"
ok "no hermes call (auditor signal, not a page)"

# --- scenario 2: `## ` header + canonical line -> delivered, exit 0 --------
echo "--- scenario 2: populated section delivers normally, exit 0 ---"
cat > "$escalations" <<'EOS'
# Nish escalations

## Orchestrator decision sweep 2026-09-14T00:00:00Z — canonical entry lines
2026-09-14T00:00:01Z CREDENTIAL-BOUNDARY issue-fleet-ops-6845 — drill entry — recommended: yes
  SUMMARY: drill canonical line under a populated header.
EOS
: > "$seen"
hermes_log="$tmp/h2.log"; : > "$hermes_log"
rc=$(run_notify "$hermes_log")
echo "exit: $rc"
[[ "$rc" -eq 0 ]] || fail "populated section must exit 0; got $rc; err: $(cat "$tmp/err")"
grep -q "delivered (hermes, attempt 1)" "$tmp/out" \
    || fail "canonical line under a `## ` header must be delivered; out: $(cat "$tmp/out")"
ok "populated section delivers + exits 0 (guard not tripped)"

# --- scenario 3: `## ` header + NISH ACTION prose marker -> exit 0 ---------
echo "--- scenario 3: prose-marker section is deliverable, exit 0 ---"
cat > "$escalations" <<'EOS'
# Nish escalations

## 2026-09-14 — drill prose ask (fleet-ops#6845)
- **NISH ACTION (drill):** the prose scan owns this — the guard must not flag it.
EOS
: > "$seen"
hermes_log="$tmp/h3.log"; : > "$hermes_log"
rc=$(run_notify "$hermes_log")
echo "exit: $rc"
[[ "$rc" -eq 0 ]] || fail "prose-marker section must exit 0 (prose path owns it); got $rc; err: $(cat "$tmp/err")"
grep -q "delivered (hermes, attempt 1)" "$tmp/out" \
    || fail "prose marker must deliver via the prose path; out: $(cat "$tmp/out")"
ok "prose-marker section delivered by prose scan, guard not tripped"

# --- scenario 4: `## DRAIN-DIGEST` bookkeeping header -> exit 0 ------------
echo "--- scenario 4: DRAIN-DIGEST pointer is exempt, exit 0 ---"
cat > "$escalations" <<'EOS'
# Nish escalations

## DRAIN-DIGEST 2026-09-14T00:00:00Z — 3 stale entries moved to /tmp/digest-2026-09-14.md (fleet-ops#5624 bound-breach)
EOS
: > "$seen"
hermes_log="$tmp/h4.log"; : > "$hermes_log"
rc=$(run_notify "$hermes_log")
echo "exit: $rc"
[[ "$rc" -eq 0 ]] || fail "DRAIN-DIGEST pointer must exit 0 (drain bookkeeping); got $rc; err: $(cat "$tmp/err")"
ok "DRAIN-DIGEST pointer exempt"

# --- scenario 5: starved section alarms alongside a real delivery ----------
# The live failure shape: one section delivered fine while a second sat
# bare. The guard must still fail the run — a green run must never silently
# carry a starved section.
echo "--- scenario 5: starved section alarms even when another delivers ---"
cat > "$escalations" <<'EOS'
# Nish escalations

## Orchestrator decision sweep 2026-09-14T00:00:00Z — canonical entry lines
2026-09-14T00:00:01Z CREDENTIAL-BOUNDARY issue-fleet-ops-6845 — drill entry — recommended: yes

## Orchestrator decision sweep 2026-09-14T01:00:00Z — canonical entry lines

EOS
: > "$seen"
hermes_log="$tmp/h5.log"; : > "$hermes_log"
rc=$(run_notify "$hermes_log")
echo "exit: $rc"
[[ "$rc" -eq 1 ]] || fail "a bare section must fail the run even when a sibling delivered; got $rc"
grep -q "UNDELIVERED-ESCALATION" "$tmp/err" \
    || fail "stderr must name the starved section; got: $(cat "$tmp/err")"
grep -q "delivered (hermes, attempt 1)" "$tmp/out" \
    || fail "the populated section must still deliver; out: $(cat "$tmp/out")"
ok "starved section loud alongside a real delivery"

echo ""
echo "OK: nish-boundary-notify header-only guard drill (fleet-ops#6845) — 5/5 scenarios pass"
