#!/usr/bin/env bash
# tests/install-enabled-but-inactive-timer.test.sh
#
# fleet-ops#2089: a .timer unit can land in an enabled-but-inactive state
# (is-enabled=enabled, is-active=inactive) — e.g. a prior `systemctl --user
# enable` without `--now`, or a start that was lost. install.sh's generic
# [Install] loop used to guard `enable --now` on `is_unit_enabled` alone, so
# an already-enabled timer was skipped forever and never scheduled
# (NextElapseUSecRealtime empty, NextElapseUSecMonotonic=infinity). The
# staleness canary sat dead in exactly this state.
#
# This test proves the generic loop now self-heals the whole
# enabled-but-inactive class: when a timer is enabled but not active,
# install.sh calls `enable --now` (which starts an already-enabled unit).
# It also locks the precision: an enabled-AND-active timer is NOT re-started.
#
# Nested from tests/rule-enforcement.test.sh so CI covers it without a
# workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

# --- 1. Static lock: the self-heal branch exists in install.sh --------------
# A future refactor that drops the enabled-but-inactive start re-reds CI here.
grep -q 'is-active --quiet' "$install_src" \
  || fail "install.sh must check is-active --quiet to self-heal enabled-but-inactive timers"
grep -q 'was enabled but inactive' "$install_src" \
  || fail "install.sh must log the self-heal start for enabled-but-inactive timers"
ok "install.sh has the enabled-but-inactive self-heal branch (fleet-ops#2089)"

# --- 2. Build a scratch install environment ----------------------------------
scratch="$(mktemp -d -t install-inactive.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

mkdir -p "$scratch/systemd" "$scratch/home/nish/.config/systemd/user"

# A minimal [Install]-carrying timer, the shape is_installable_unit accepts.
cat >"$scratch/systemd/example-weekly.timer" <<'EOF'
[Unit]
Description=Example weekly timer

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# MANIFEST: timer src -> user-scope dest (not /etc, so user install path).
cat >"$scratch/MANIFEST" <<MANIFEST
systemd/example-weekly.timer $scratch/home/nish/.config/systemd/user/example-weekly.timer
MANIFEST

# --- 3. Scenario A: enabled BUT inactive -> install.sh MUST start it --------
# This is the fleet-ops#2089 state. The stub reports is-enabled=enabled yet
# is-active=inactive. The self-heal must call `enable --now` (which starts an
# already-enabled unit), recording it to a log we assert on.
calls_a="$scratch/calls-a.log"
: >"$calls_a"
cat >"$scratch/stub-inactive.sh" <<EOF
#!/usr/bin/env bash
# Records every argv so we can assert the self-heal fired.
echo "\$*" >>"$calls_a"
case "\$*" in
  *"is-enabled"*) echo "enabled"; exit 0 ;;
  *"is-active --quiet"*) exit 1 ;;   # INACTIVE -> triggers self-heal
  *"enable --now"*) exit 0 ;;
  *"daemon-reload"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$scratch/stub-inactive.sh"

cd "$scratch"
out_a=$(SYSTEMCTL="$scratch/stub-inactive.sh" "$install" 2>&1 || true)

# The self-heal path must have called enable --now on the timer.
grep -q -- '--user enable --now example-weekly.timer' "$calls_a" \
  || fail "enabled-but-inactive timer was not started; calls: $(cat "$calls_a"); out: $out_a"
grep -q 'was enabled but inactive' <<<"$out_a" \
  || fail "install.sh did not log the self-heal start; out: $out_a"
ok "scenario A: enabled-but-inactive timer is started (self-heal fires)"

# --- 4. Scenario B: enabled AND active -> install.sh must NOT re-start ------
# Precision lock: an already-running timer must not be spuriously restarted.
calls_b="$scratch/calls-b.log"
: >"$calls_b"
cat >"$scratch/stub-active.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$calls_b"
case "\$*" in
  *"is-enabled"*) echo "enabled"; exit 0 ;;
  *"is-active --quiet"*) exit 0 ;;   # ACTIVE -> self-heal must NOT fire
  *"enable --now"*) exit 0 ;;
  *"daemon-reload"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$scratch/stub-active.sh"

out_b=$(SYSTEMCTL="$scratch/stub-active.sh" "$install" 2>&1 || true)

if grep -q -- '--user enable --now example-weekly.timer' "$calls_b"; then
  fail "enabled-AND-active timer was spuriously re-started; calls: $(cat "$calls_b")"
fi
ok "scenario B: enabled-and-active timer is not re-started (precision)"

echo "OK: install.sh self-heals enabled-but-inactive timers (fleet-ops#2089)"
