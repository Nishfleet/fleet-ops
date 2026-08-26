#!/usr/bin/env bash
# tests/fleet-heartbeat-failed-notify-shape.test.sh
#
# fleet-ops#368 (blind-audit rank 2): the OnFailure Telegram page must name
# the live host at send time, not a stale migration literal like
# hostinger-kvm4. The class lock is a grep of unit/page templates plus a
# planted-literal drill so the guard cannot silently stop firing.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc="$repo_root/systemd/fleet-heartbeat-failed-notify.service"
manifest="$repo_root/MANIFEST"
stale_hosts=(hostinger-kvm4)

scan_stale() {
  local root="$1" host hits
  for host in "${stale_hosts[@]}"; do
    hits="$(grep -R --include='*.service' --include='*.timer' --include='*.path' \
      --include='*.sh' --include='*.md' -n -F "$host" \
      "$root/systemd" "$root/bin" "$root/prompts" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
      printf '%s\n' "$hits"
      return 0
    fi
  done
  return 1
}

[[ -f "$svc" ]] || fail "missing unit template: $svc"
grep -q '^\[Unit\]$' "$svc" || fail "missing [Unit]"
grep -q '^\[Service\]$' "$svc" || fail "missing [Service]"
grep -q '^Type=oneshot$' "$svc" || fail "Type=oneshot required"
grep -q 'hermes send -t telegram' "$svc" || fail "ExecStart must page via hermes telegram"
grep -qE '\$\(hostname( -s)?\)|%H' "$svc" \
  || fail "ExecStart must resolve host at runtime via \$(hostname), \$(hostname -s), or %H"
grep -q 'MONITOR_UNIT' "$svc" || fail "ExecStart must include MONITOR_UNIT"
if grep -qF 'hostinger-kvm4' "$svc"; then
  fail "notify unit still hard-codes hostinger-kvm4"
fi
ok "fleet-heartbeat-failed-notify.service shape"

grep -Fxq "systemd/fleet-heartbeat-failed-notify.service /home/nish/.config/systemd/user/fleet-heartbeat-failed-notify.service" "$manifest" \
  || fail "MANIFEST missing fleet-heartbeat-failed-notify.service entry"
ok "MANIFEST entry present"

# Repo templates (and stop-escalation / other telegram paths under bin/ and
# prompts/) must not embed known stale host literals.
if hits="$(scan_stale "$repo_root")"; then
  fail "stale host literal found in repo templates:"$'\n'"$hits"
fi
ok "no stale host literals in systemd/bin/prompts templates"

# Drill: a planted hostinger-kvm4 in a throwaway tree MUST be detected.
# If this ever goes quiet, the class is unguarded again (fleet-ops#366).
drill="$(mktemp -d)"
mkdir -p "$drill/systemd" "$drill/bin" "$drill/prompts"
printf '%s\n' 'ExecStart=/bin/sh -c "hermes send -t telegram failed on hostinger-kvm4"' \
  >"$drill/systemd/bad-page.service"
if ! hits="$(scan_stale "$drill")"; then
  rm -rf "$drill"
  fail "drill: planted hostinger-kvm4 was NOT detected — stale-host guard is broken"
fi
rm -rf "$drill"
ok "drill: planted hostinger-kvm4 is rejected"

# Live user units: the original finding lived only on disk, not in the repo.
live_dir="${HOME}/.config/systemd/user"
if [[ -d "$live_dir" ]]; then
  live_hits="$(grep -R --include='*.service' --include='*.timer' --include='*.path' \
    -n -F 'hostinger-kvm4' "$live_dir" 2>/dev/null || true)"
  if [[ -n "$live_hits" ]]; then
    fail "stale host literal in live user units:"$'\n'"$live_hits"
  fi
  ok "no stale host literals in live user units"
fi

# Execution-is-the-review: run the page body with a stub hermes so we never
# send a real Telegram. The rendered text must contain hostname -s.
scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
cat >"$scratch/hermes" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$(dirname "$0")/argv"
EOF
chmod +x "$scratch/hermes"

exec_line="$(grep '^ExecStart=' "$svc")"
payload="${exec_line#ExecStart=/bin/sh -c \'}"
payload="${payload%\'}"
payload="${payload//\/home\/nish\/.local\/bin\/hermes/$scratch/hermes}"
MONITOR_UNIT=fixture.service /bin/sh -c "$payload"
got="$(cat "$scratch/argv")"
host="$(hostname -s)"
[[ "$got" == *"$host"* ]] || fail "page must contain live hostname ($host); got: $got"
[[ "$got" != *hostinger-kvm4* ]] || fail "page still names hostinger-kvm4: $got"
[[ "$got" == *fixture.service* ]] || fail "page must include MONITOR_UNIT; got: $got"
ok "runtime page names live host $host (hermes stubbed, no send)"

echo "OK: fleet-heartbeat-failed-notify-shape (#368)"
