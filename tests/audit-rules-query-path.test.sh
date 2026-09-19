#!/usr/bin/env bash
# tests/audit-rules-query-path.test.sh
#
# fleet-ops#5918 class lock: the audit-trail query hints must name a command
# that actually resolves in the environment the trail is read from.
#
# Root cause (#5918, live-proven on the bug host): ausearch ships at
# /usr/sbin/ausearch, but ExecStopPost and the systemd user manager run with
# PATH=/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin — no /usr/sbin. A
# bare `ausearch` query hint therefore fails with "no audit trail" on a host
# where auditd is active and the trail exists. #4733 fixed exactly this inside
# bin/fleet-escalation-canary (AUSEARCH_SBIN_PATHS); that helper and
# bin/fleet-who-stopped were later deleted in the 2026-09-18 glue sweeps, so
# this lock now guards the surviving surface: the prose a human follows.
#
# The lock is deliberately file-shaped, not run-shaped, so hosted CI (no
# auditd, no /usr/sbin/ausearch) still runs it; the live probe at the end
# SKIPs when ausearch is genuinely absent.
#
# Hosted by the #5889 auto-host in tests/p14-test-listing-gate.test.sh, so a
# worker PR that adds this file runs it in P14 without a ci.yml edit (the
# nishfleet-worker App has no Workflows scope).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

rules="$repo_root/config/audit/rules.d/30-fleet-unit-stop.rules"
[[ -f "$rules" ]] || fail "audit rules file not found: $rules"

# --- 1. the -w rules themselves are untouched --------------------------------
# This lock is about the query hints. A change to the audited rules is a
# different review (and a root reload), so pin the shape: six watch lines.
rule_lines="$(grep -c '^-w ' "$rules")"
[[ "$rule_lines" -eq 6 ]] \
  || fail "expected 6 '-w ' audit rules, found $rule_lines (rule changes need a root reload, not a comment edit)"

[[ "$(tail -c 1 "$rules" | xxd -p)" == "0a" ]] \
  || fail "audit rules file must end with a newline (a missing trailing newline trips the augenrules load)"
ok "audit rules file keeps its six '-w ' lines and its trailing newline"

# --- 2. every ausearch *invocation* names the absolute path -------------------
# The bug is a relative resolution of a binary that lives in /usr/sbin. The
# precise class is a hint that tells the reader to RUN a command: an
# `ausearch` token followed by its `-k <key>` selector on the same line. Prose
# that explains the bug may name the bare token in backticks; a runnable line
# may not.
#
# bare_invocations FILE — print each line invoking ausearch without a dir.
bare_invocations() {
  local f="$1" line tok
  while IFS= read -r line; do
    read -r -a toks <<<"$line"
    local seen_bare=0
    for tok in "${toks[@]:-}"; do
      case "$tok" in
        '`ausearch`'|"ausearch") seen_bare=1 ;;
        -k) if [[ "$seen_bare" -eq 1 ]]; then printf '%s\n' "$line"; break; fi ;;
      esac
    done
  done < <(grep 'ausearch' "$f" || true)
}

# Negative drill: the gate must actually catch the #5918 fault. A fixture with
# the original bare hint must produce a hit; the corrected line must not.
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
printf '%s\n' '# Query: ausearch -k fleet-unit-stop -ts yesterday -i' >"$td/bare.rules"
printf '%s\n' '# Query: /usr/sbin/ausearch -k fleet-unit-stop -ts yesterday -i' >"$td/abs.rules"
[[ -n "$(bare_invocations "$td/bare.rules")" ]] \
  || fail "negative drill broken: a bare-invocation fixture produced no hit"
[[ -z "$(bare_invocations "$td/abs.rules")" ]] \
  || fail "negative drill broken: the absolute-path fixture produced a hit"
ok "negative drill: bare invocation is caught, absolute path is not"

bad_lines="$(bare_invocations "$rules")"
if [[ -n "$bad_lines" ]]; then
  echo "FAIL: audit rules invoke ausearch without the /usr/sbin absolute path:" >&2
  printf '  %s\n' "$bad_lines" >&2
  fail "a bare 'ausearch' does not resolve on the systemd-user PATH (fleet-ops#5918)"
fi
ok "every ausearch invocation in the rules file uses an absolute path"

# Both surviving trails must carry a runnable hint, so the fix cannot be
# satisfied by deleting the query lines instead of correcting them.
for key in fleet-unit-stop fleet-unit-run; do
  grep -Eq "^# */(usr/)?sbin/ausearch +-k +$key" "$rules" \
    || fail "no absolute-path query hint for -k $key in the rules file (fleet-ops#5918)"
done
ok "both audit keys carry an absolute-path query hint"

# --- 3. the deleted helper is not advertised as a live query command ---------
# bin/fleet-who-stopped was deleted 2026-09-18. Naming it as the way to read
# the trail sends the reader to a command that does not exist.
if grep -n 'fleet-who-stopped' "$rules" | grep -vq 'deleted'; then
  grep -n 'fleet-who-stopped' "$rules" | grep -v 'deleted' >&2
  fail "audit rules name bin/fleet-who-stopped as a live command; it was deleted 2026-09-18"
fi
ok "the deleted who-stopped helper is only referenced as deleted"

# --- 4. live probe (VPS only) -------------------------------------------------
systemd_path='/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin'
if [[ ! -x /usr/sbin/ausearch ]]; then
  echo "SKIP: /usr/sbin/ausearch not installed (hosted runner); file-shape locks above still applied"
  echo "OK: audit-rules-query-path: prose lock passed, live probe skipped"
  exit 0
fi

# Precondition: the blind spot is real on this host — prove it, do not assume.
if env PATH="$systemd_path" bash -c 'command -v ausearch' >/dev/null 2>&1; then
  echo "SKIP: bare ausearch lookup resolves on the systemd-user PATH on this host; #5918's premise does not apply here"
  echo "OK: audit-rules-query-path: prose lock passed, live probe skipped (premise absent)"
  exit 0
fi
ok "precondition: bare 'ausearch' does not resolve on the systemd-user PATH (the #5918 blind spot)"

env PATH="$systemd_path" bash -c '/usr/sbin/ausearch --version' >/dev/null 2>&1 \
  || fail "the absolute /usr/sbin/ausearch path does not run under the systemd-user PATH"
ok "the absolute /usr/sbin/ausearch path runs under the systemd-user PATH"

# The hint as written in the file must itself be executable: extract the first
# absolute ausearch path the file offers and run it.
hint_bin="$(grep -oE '/(usr/)?sbin/ausearch' "$rules" | head -n 1)"
[[ -n "$hint_bin" ]] || fail "rules file carries no absolute ausearch path to verify"
[[ -x "$hint_bin" ]] || fail "query hint names a non-executable path: $hint_bin"
ok "the query hint's absolute path ($hint_bin) is executable"

echo "OK: audit-rules-query-path: query hints resolve in the systemd-user environment (fleet-ops#5918)"
