#!/usr/bin/env bash
# tests/fleet-heartbeat-failed-notify-shape.test.sh
#
# fleet-ops#373 (blind-audit rank 2): OnFailure Telegram page must name the
# live host at runtime, not a stale migration literal like hostinger-kvm4.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc="$repo_root/systemd/fleet-heartbeat-failed-notify.service"
manifest="$repo_root/MANIFEST"

[[ -f "$svc" ]] || fail "missing unit template: $svc"
grep -q '^\[Unit\]$' "$svc" || fail "missing [Unit]"
grep -q '^\[Service\]$' "$svc" || fail "missing [Service]"
grep -q '^Type=oneshot$' "$svc" || fail "Type=oneshot required"
grep -q 'hermes send -t telegram' "$svc" || fail "ExecStart must page via hermes telegram"
grep -q 'hostname -s' "$svc" || fail "ExecStart must resolve host at runtime via hostname -s"
grep -q 'MONITOR_UNIT' "$svc" || fail "ExecStart must include MONITOR_UNIT"
ok "fleet-heartbeat-failed-notify.service shape"

grep -Fxq "systemd/fleet-heartbeat-failed-notify.service /home/nish/.config/systemd/user/fleet-heartbeat-failed-notify.service" "$manifest" \
  || fail "MANIFEST missing fleet-heartbeat-failed-notify.service entry"
ok "MANIFEST entry present"

# Repo templates must not embed known stale host literals (audit #373 scope).
stale_hosts=(hostinger-kvm4 srv1846330)
for host in "${stale_hosts[@]}"; do
  if grep -R --include='*.service' --include='*.timer' --include='*.path' -n "$host" "$repo_root/systemd" "$repo_root/bin" "$repo_root/prompts" 2>/dev/null; then
    fail "stale host literal $host found in repo templates (see grep output above)"
  fi
done
ok "no stale host literals in systemd/bin/prompts templates"

echo "OK: fleet-heartbeat-failed-notify-shape (#373)"
