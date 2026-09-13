#!/usr/bin/env bash
# tests/fleet-who-stopped.test.sh
#
# fleet-ops#5799: the DetachedJobDied trail helper (bin/fleet-who-stopped) must
# not report "ausearch NOT INSTALLED" when the auditd package's binary exists
# but sits in /usr/sbin — a directory routinely missing from interactive and
# agent PATHs. The 2026-09-12/13 fleet-litellm-proxy incident: every dead-man
# run and every repair worker read that note while auditd was in fact
# installed and running, which is exactly the "the trail is written and simply
# absent here" trap the issue recorded. The helper must resolve ausearch from
# the known sbin locations as a fallback, keep exit 0 (a diagnostic helper
# must never fail the repair it feeds), and keep its usage contract.
#
# Hermetic: no auditd/ausearch knowledge required — the two note-branch cases
# are selected by whether an sbin ausearch actually exists on the runner, so
# exactly one of the two always runs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
whostopped="$repo_root/bin/fleet-who-stopped"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$whostopped" ]] || fail "not executable: $whostopped"
bash -n "$whostopped" || fail "syntax: $whostopped"

# --- 1. usage contract (hermetic, no ausearch needed) ------------------------
out="$("$whostopped" 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "2" ]] || fail "no-args must exit 2 (emit_usage), got rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'usage: fleet-who-stopped' \
    || fail "no-args must print the usage line: $out"
out="$("$whostopped" --last notanumber some-unit 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "2" ]] || fail "non-numeric --last must exit 2, got rc=$rc: $out"
out="$("$whostopped" --help 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "0" ]] || fail "--help must exit 0, got rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'usage: fleet-who-stopped' \
    || fail "--help must print the usage line: $out"
ok "usage contract: no-args/--last-bad exit 2 with usage, --help exits 0"

# --- 2. the note must match reality (fleet-ops#5799) -------------------------
# Exactly one of the two cases below runs, selected by whether an sbin
# ausearch exists on this runner:
#   2a. sbin ausearch EXISTS  -> run with an agent-style PATH (no /usr/sbin):
#       the "NOT INSTALLED" note must NOT fire (the sbin fallback must find
#       it), exit stays 0.
#   2b. NO ausearch anywhere  -> the note is now truthful: it must fire, and
#       exit stays 0.
if [[ -x /usr/sbin/ausearch || -x /sbin/ausearch ]]; then
    out="$(PATH="/usr/bin:/bin" "$whostopped" some-unit 2>&1)" && rc=0 || rc=$?
    [[ "$rc" == "0" ]] || fail "sbin-ausearch host: must exit 0, got rc=$rc: $out"
    printf '%s\n' "$out" | grep -q 'ausearch NOT INSTALLED' \
        && fail "sbin-ausearch host: the NOT INSTALLED note must not fire for a PATH miss: $out"
    ok "ausearch exists in sbin but not on the stripped PATH: helper finds it, note silent, exit 0"
else
    out="$(PATH="/usr/bin:/bin" "$whostopped" some-unit 2>&1)" && rc=0 || rc=$?
    [[ "$rc" == "0" ]] || fail "no-ausearch host: must still exit 0 (best-effort), got rc=$rc: $out"
    printf '%s\n' "$out" | grep -q 'ausearch NOT INSTALLED' \
        || fail "no-ausearch host: the note must fire (it is now truthful): $out"
    ok "no ausearch installed anywhere: note fires truthfully, exit 0 (best-effort)"
fi

echo "PASS: fleet-who-stopped resolution + usage contract"
