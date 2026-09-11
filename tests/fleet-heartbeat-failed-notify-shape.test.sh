#!/usr/bin/env bash
# tests/fleet-heartbeat-failed-notify-shape.test.sh
#
# fleet-ops#368: stale-host-literal guard for the Telegram page. If the
# message is ever hand-rolled with a literal hostname, the page will fire with
# the wrong host after the next migration. Never print a bare machine name.
# fleet-ops#373: blind-audit rank 2 found the installed page hard-coded
# 'hostinger-kvm4' while the live host is netcup-rs2000. The repo templates
# must resolve the hostname at runtime and the guard must sweep systemd,
# bin, lib and prompts for any known stale machine literal.
# fleet-ops#1399: the unit now delegates to lib/fleet-heartbeat-failed-notify.py,
# which keeps per-unit state and pages only after N consecutive failures.
# fleet-ops#5462: the gap-audit re-filed the already-fixed #373 finding. Its
# residual ask — "do the same audit on stop-escalation and any other Telegram
# path" — is mechanized here: every file that can put text on a Telegram page
# (all unit templates, every `hermes send` caller, the stop-escalation
# dispatcher) must carry NO bare machine-name literal — neither a known-stale
# host NOR the current host, resolved at test runtime. A literal is wrong the
# moment the fleet migrates; pages must resolve the hostname at runtime.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc="$repo_root/systemd/fleet-heartbeat-failed-notify.service"
helper="$repo_root/lib/fleet-heartbeat-failed-notify.py"
manifest="$repo_root/MANIFEST"
stale_hosts=(hostinger-kvm4 srv1846330)

[[ -f "$svc" ]] || fail "missing unit template: $svc"
grep -q '^\[Unit\]$' "$svc" || fail "missing [Unit]"
grep -q '^\[Service\]$' "$svc" || fail "missing [Service]"
grep -q '^Type=oneshot$' "$svc" || fail "Type=oneshot required"
grep -q '^ExecStart=' "$svc" || fail "ExecStart required"
grep -q 'MONITOR_UNIT' "$svc" || fail "unit must document MONITOR_UNIT"
grep -q 'fleet-heartbeat-failed-notify.py' "$svc" || fail "ExecStart must call fleet-heartbeat-failed-notify.py"
grep -q 'FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD' "$svc" || fail "threshold must be configured"
grep -q 'HERMES_URGENT' "$svc" || fail "pages must be marked urgent"
ok "fleet-heartbeat-failed-notify.service shape"

[[ -f "$helper" ]] || fail "missing helper: $svc"
python3 -m py_compile "$helper" >/dev/null 2>&1 || fail "helper does not compile"
ok "helper exists and compiles"

grep -Fxq "lib/fleet-heartbeat-failed-notify.py /home/nish/.local/lib/pi-packet/fleet-heartbeat-failed-notify.py" "$manifest" \
  || fail "MANIFEST missing lib/fleet-heartbeat-failed-notify.py"
grep -Fxq "systemd/fleet-heartbeat-failed-notify.service /home/nish/.config/systemd/user/fleet-heartbeat-failed-notify.service" "$manifest" \
  || fail "MANIFEST missing fleet-heartbeat-failed-notify.service"
ok "MANIFEST entries present"

# --- stale-host literal guard -----------------------------------------------
# Any literal machine name in the page text is a migration hazard. The helper
# resolves the hostname at runtime; no unit, script, helper or prompt may
# carry a known stale host literal.
scan_stale() {
  local root="$1" host hits
  for host in "${stale_hosts[@]}"; do
    hits="$(grep -R --include='*.service' --include='*.timer' --include='*.path' \
      --include='*.sh' --include='*.py' --include='*.md' -n -F "$host" \
      "$root/systemd" "$root/bin" "$root/lib" "$root/prompts" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
      printf '%s\n' "$hits"
      return 0
    fi
  done
  return 1
}

# Real scan (must be clean).
if hits="$(scan_stale "$repo_root")"; then
  fail "stale host literal found in repo templates:"$'\n'"$hits"
fi
ok "stale-host literal guard is clean"

# Drill: a planted stale host in a throwaway tree MUST be detected.
# If this ever goes quiet, the class is unguarded again (fleet-ops#366, #373).
drill="$(mktemp -d)"
trap 'rm -rf "$drill"' EXIT INT TERM
mkdir -p "$drill/systemd"
for bad_host in "${stale_hosts[@]}"; do
  printf '%s\n' "ExecStart=/bin/sh -c \"hermes send -t telegram failed on $bad_host\"" \
    >"$drill/systemd/$bad_host.page.service"
  if ! hits="$(scan_stale "$drill")"; then
    fail "drill: planted $bad_host was NOT detected — stale-host guard is broken"
  fi
  ok "drill: planted $bad_host is rejected"
  rm -f "$drill/systemd/$bad_host.page.service"
done

# --- page-sender host-literal guard (fleet-ops#5462) -------------------------
# The same audit on stop-escalation and every other Telegram path, mechanized.
# A page-sender file is: any unit template under systemd/, any file under
# bin/lib/prompts that invokes `hermes send`, and the stop-escalation
# dispatcher (it feeds the escalation page pipeline even though it does not
# call hermes directly). None of them may carry a bare machine-name literal —
# known-stale OR current. The current host is resolved at test runtime so the
# guard follows the fleet to the next machine without a list update.
page_sender_files() {
  local root="$1"
  {
    grep -R -l -F "hermes send" "$root/systemd" "$root/bin" "$root/lib" "$root/prompts" 2>/dev/null || true
    printf '%s\n' "$root/bin/stop-escalation-dispatch"
    find "$root/systemd" -type f 2>/dev/null || true
  } | sort -u
}

current_hosts() {
  {
    hostname -s 2>/dev/null || true
    hostname 2>/dev/null || true
    hostname -f 2>/dev/null || true
  } | while IFS= read -r h; do [[ -n "$h" ]] && printf '%s\n' "$h"; done | sort -u
}

scan_page_senders() {
  local root="$1" file host hits all_hits=""
  local forbidden=("${stale_hosts[@]}")
  while IFS= read -r h; do
    forbidden+=("$h")
  done < <(current_hosts)
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    for host in "${forbidden[@]}"; do
      hits="$(grep -n -F "$host" "$file" 2>/dev/null || true)"
      if [[ -n "$hits" ]]; then
        all_hits+="$file: literal [$host]"$'\n'"$hits"$'\n'
      fi
    done
  done < <(page_sender_files "$root")
  if [[ -n "$all_hits" ]]; then
    printf '%s' "$all_hits"
    return 0
  fi
  return 1
}

# Real scan (must be clean).
if hits="$(scan_page_senders "$repo_root")"; then
  fail "machine-name literal found in a Telegram page sender:"$'\n'"$hits"
fi
ok "page-sender host-literal guard is clean (stale + current host, all page paths)"

# Runtime-resolution pin: the page text must come from a runtime hostname, so
# the helper must actually call socket.gethostname (fleet-ops#5462 fix path).
grep -q "socket.gethostname" "$helper" \
  || fail "failed-notify helper must resolve the hostname at runtime (socket.gethostname), never a literal"
ok "failed-notify page resolves the hostname at runtime"

# Drill: a planted CURRENT-host literal in a fake page sender MUST be detected.
cur_host="$(hostname -s 2>/dev/null || true)"
if [[ -n "$cur_host" ]]; then
  printf '%s\n' "ExecStart=/bin/sh -c \"hermes send -t telegram failed on $cur_host\"" \
    >"$drill/systemd/current-host.page.service"
  if ! hits="$(scan_page_senders "$drill")"; then
    fail "drill: planted current-host literal ($cur_host) was NOT detected — page-sender guard is broken"
  fi
  grep -qF "$cur_host" <<<"$hits" \
    || fail "drill: detection output does not name the planted host $cur_host"
  ok "drill: planted current-host literal ($cur_host) is rejected"
  rm -f "$drill/systemd/current-host.page.service"
fi

# --- threshold behaviour ----------------------------------------------------
bash "$here/fleet-heartbeat-failed-notify-threshold.test.sh" \
  || fail "threshold test failed"
ok "threshold test passed"

echo "OK: fleet-heartbeat-failed-notify-shape"
