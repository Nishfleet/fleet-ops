#!/usr/bin/env bash
# tests/nish-boundary-notify-questions.test.sh
#
# fleet-ops#4474 (part 1: one store). Proves nish-boundary-notify now reads the
# CONFIRMED `question`-issue store instead of relying only on NISH-ESCALATIONS.md:
#   1. a `question` issue labelled nish-reserved (the conference gate confirmed
#      it truly needs Nish) is delivered to Nish's phone via hermes.
#   2. delivery is deduped by issue URL ($SEEN) — a second run re-sends nothing.
#   3. an undecided question (label `question`, no nish-reserved) is NOT
#      delivered — no question text reaches Telegram before the gate.
#   4. a hermes delivery failure is loud (exit 1) so an auditor is summoned.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/nish-boundary-notify"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$script" ]] && [[ -x "$script" ]] || fail "missing/not executable: $script"
command -v jq >/dev/null 2>&1 || fail "jq missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
state="$tmp/state"; mkdir -p "$state/lanes"
seen="$state/lanes/nish-boundary-notify.seen"; : >"$seen"

# Fake gh: returns a fixture question-list JSON from $Q_FIXTURE; logs every call.
qlog="$tmp/gh.log"
fake_gh="$tmp/gh"
cat >"$fake_gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QLOG"
cat "$Q_FIXTURE"
exit 0
EOF
chmod +x "$fake_gh"

intake="$tmp/intake.json"
cat >"$intake" <<'JSON'
{"repos":[{"name":"demo"}],"excluded":[],"deferred":[]}
JSON

# Fake hermes success/failure (logs per invocation; exit code via $HERMES_RC).
fake_hermes="$tmp/hermes"
cat >"$fake_hermes" <<'EOF'
#!/usr/bin/env bash
printf 'hermes-invoked\n' >> "$HERMES_LOG"
printf '%s\n' "$*" >> "$HERMES_LOG"
printf '\n--\n' >> "$HERMES_LOG"
exit "${HERMES_RC:-0}"
EOF
chmod +x "$fake_hermes"

hermes_log="$tmp/hermes.log"
export QLOG="$qlog"
export HERMES_LOG="$hermes_log"

# body with the canonical store shape (question:/options: on their own lines)
cat >"$tmp/body.md" <<'MD'
context line

question: should we top up straitly?
options: a | b | c

blocked-on: nish-decision (money: top up straitly)
MD

# =============================================================================
# 1. confirmed (nish-reserved) question -> delivered via hermes
# =============================================================================
: >"$hermes_log"; : >"$qlog"
export Q_FIXTURE="$tmp/q1.json"
cat >"$Q_FIXTURE" <<'J'
[{"number":901,"title":"top up straitly?","body":"question: should we top up straitly?\noptions: a | b | c\nblocked-on: nish-decision (money)"}]
J
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" >"$tmp/o1" 2>"$tmp/e1"
grep -q "delivered (hermes" "$tmp/o1" || { cat "$tmp/e1"; fail "confirmed question not delivered"; }
grep -q "top up straitly" "$hermes_log" || fail "hermes message missing the question text"
grep -q "should we top up straitly" "$hermes_log" || fail "hermes message missing the question line"
grep -q "OPTIONS\|Options" "$hermes_log" || fail "hermes message missing options"
ok "confirmed nish-reserved question delivered via hermes"

# =============================================================================
# 2. dedupe: second run with the same confirmed question sends nothing new
# =============================================================================
: >"$hermes_log"
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" >"$tmp/o2" 2>"$tmp/e2"
[[ -s "$hermes_log" ]] && { echo "--- hermes_log ---"; cat "$hermes_log"; fail "confirmed question re-delivered on second run"; }
ok "confirmed question deduped by the seen-mark (second run silent)"

# =============================================================================
# 3. undecided question (no nish-reserved) -> NOT delivered: the gh query only
#    matches confirmed questions (-l nish-reserved,conference-approved), so an
#    undecided question never appears in the results. Prove the query carries
#    the confirmed-label filter.
# =============================================================================
: >"$hermes_log"; : >"$qlog"
# gh returns the empty list for this query = no confirmed question to deliver
export Q_FIXTURE="$tmp/q3.json"
printf '[]\n' >"$Q_FIXTURE"
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" >"$tmp/o3" 2>"$tmp/e3"
grep -q 'nish-reserved,conference-approved' "$qlog" \
  || { echo "--- qlog ---"; cat "$qlog"; fail "confirmed-question query must filter by nish-reserved/conference-approved"; }
[[ -s "$hermes_log" ]] && fail "undecided question reached hermes before the gate"
ok "undecided question (no nish-reserved) never reaches hermes — query filters confirmed only"

# =============================================================================
# 4. hermes failure on a confirmed question -> loud exit 1
# =============================================================================
# reset seen so scenario 4 has a fresh undelivered question
: >"$seen"
export Q_FIXTURE="$tmp/q4.json"
cat >"$Q_FIXTURE" <<'J'
[{"number":903,"title":"ask nish","body":"question: money call?\noptions: a | b\nblocked-on: nish-decision (money)"}]
J
set +e
UNIT_ESCALATION_AGENT_STATE="$state" HERMES_RC=1 \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" >"$tmp/o4" 2>"$tmp/e4"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "hermes failure on a confirmed question must exit 1 (loud), got rc=$rc"
grep -q "DELIVERY FAILED" "$tmp/e4" || fail "hermes failure not reported loud"
ok "hermes failure on a confirmed question is loud (exit 1)"


# =============================================================================
# 5. fleet-ops#4476: the delivered body carries the Q:<repo>#<n> handle so a
#    Telegram reply can name it back.
# =============================================================================
: >"$seen"
export Q_FIXTURE="$tmp/q5.json"
cat >"$Q_FIXTURE" <<'J'
[{"number":905,"title":"top 5","body":"question: should we buy a seat?\noptions: a | b\nblocked-on: nish-decision (money)","createdAt":"2026-09-08T00:00:00Z"}]
J
: >"$hermes_log"
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" >"$tmp/o5" 2>"$tmp/e5"
grep -q 'Q:demo#905' "$hermes_log" \
  || { echo "--- hermes_log ---"; cat "$hermes_log"; fail "confirmed-question message lacks the Q:<repo>#<n> handle (fleet-ops#4476)"; }
ok "confirmed-question Telegram line carries the Q:demo#905 handle"

# =============================================================================
# 6. fleet-ops#4476: --dry-run lists only gate-confirmed questions and never
#    touches hermes (no send).
# =============================================================================
: >"$hermes_log"; : >"$qlog"
export Q_FIXTURE="$tmp/q6.json"
cat >"$Q_FIXTURE" <<'J'
[{"number":906,"title":"q6","body":"question: confirm the senior gate?\noptions: y|n","createdAt":"2026-09-08T01:00:00Z"}]
J
: >"$seen"
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" --dry-run >"$tmp/o6" 2>"$tmp/e6"
[[ -s "$hermes_log" ]] && fail "--dry-run must never send to hermes"
grep -q 'DRY-RUN Q:demo#906' "$tmp/o6" \
  || { cat "$tmp/e6"; fail "--dry-run must list the gate-confirmed question with its Q: handle; got: $(cat "$tmp/o6")"; }
ok "nish-boundary-notify --dry-run lists only gate-confirmed questions (no send)"

# =============================================================================
# 7. fleet-ops#4476: --digest sends ONE summary line and throttles to 1/6h.
# =============================================================================
: >"$hermes_log"
export Q_FIXTURE="$tmp/q7.json"
cat >"$Q_FIXTURE" <<'J'
[{"number":907,"title":"q7","body":"question: still needed?\noptions: a|b","createdAt":"2026-09-06T00:00:00Z"}]
J
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" --digest >"$tmp/o7a" 2>"$tmp/e7a"
grep -q 'digest: delivered' "$tmp/o7a" || { cat "$tmp/e7a"; fail "--digest did not deliver a summary line"; }
[[ -s "$hermes_log" ]] || fail "--digest sent no Telegram summary"
ok "--digest emits one summary line for unanswered confirmed questions"
# second call within 6h must be throttled (no second send)
: >"$hermes_log"
UNIT_ESCALATION_AGENT_STATE="$state" \
  BOUNDARY_NOTIFY_HERMES="$fake_hermes" BOUNDARY_NOTIFY_BACKOFF="0 0" \
  BOUNDARY_NOTIFY_GH="$fake_gh" FLEET_INTAKE_REPOS_JSON="$intake" \
  bash "$script" --digest >"$tmp/o7b" 2>"$tmp/e7b"
grep -q 'throttled' "$tmp/o7b" || fail "--digest second call within 6h must be throttled; got: $(cat "$tmp/o7b")"
[[ -s "$hermes_log" ]] && fail "throttled --digest must not send again"
ok "--digest throttles to 1 per 6h"

echo "PASS: tests/nish-boundary-notify-questions.test.sh"
