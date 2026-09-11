#!/usr/bin/env bash
# tests/pi-intake-trigger-enrolment.test.sh
#
# fleet-ops#5385: pi-intake-trigger must consult the live intake config and
# skip trigger files for repos absent from .repos[].name, so a queued trigger
# cannot restart intake on a deferred repo (e.g. 0509 during the rewrite
# window). Also proves the check fails closed when the config is unreadable.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/trig"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_CALLS"
EOF
chmod +x "$tmp/bin/systemctl"
cat >"$tmp/intake.json" <<'EOF'
{"repos":[{"name":"fleet-ops"}],"deferred":[{"name":"0509"}],"excluded":[]}
EOF

run_trigger() { # $1 = intake json path
  SYSTEMCTL_CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" \
    PI_INTAKE_TRIGGER_DIR="$tmp/trig" PI_INTAKE_TRIGGER_INTAKE_JSON="$1" \
    bash "$repo_root/bin/pi-intake-trigger"
}

# enrolled repo fires, deferred repo is skipped + logged, both files consumed
touch "$tmp/trig/fleet-ops" "$tmp/trig/0509"
run_trigger "$tmp/intake.json" 2>"$tmp/err.log"
grep -q 'pi-intake@fleet-ops.service' "$tmp/calls" \
  || fail "enrolled repo not started: $(cat "$tmp/calls" 2>/dev/null || echo none)"
if grep -q 'pi-intake@0509.service' "$tmp/calls"; then
  fail "deferred repo was started"; fi
grep -qi '0509.*not in .repos' "$tmp/err.log" \
  || fail "skip not logged: $(cat "$tmp/err.log")"
if [[ -f $tmp/trig/fleet-ops || -f $tmp/trig/0509 ]]; then
  fail "trigger files not consumed"; fi
ok "enrolled started, deferred skipped+logged, triggers consumed"

# missing config fails closed: nothing starts
touch "$tmp/trig/fleet-ops"
: >"$tmp/calls"
run_trigger "$tmp/missing.json" 2>"$tmp/err2.log"
if [[ -s $tmp/calls ]]; then fail "started intake despite missing config"; fi
ok "missing intake config fails closed"
