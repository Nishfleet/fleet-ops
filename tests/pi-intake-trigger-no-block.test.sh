#!/usr/bin/env bash
# tests/pi-intake-trigger-no-block.test.sh
#
# Drill for fleet-ops#4561: pi-intake-trigger is a Type=oneshot unit with
# TimeoutStartSec=30. It must start pi-intake@* with `--no-block` so it does
# not inherit the intake tick's runtime. Stub intake job sleeps 40s; the
# trigger must still exit 0 within 5s.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
trigger="$repo_root/bin/pi-intake-trigger"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$trigger" ]] || fail "not executable: $trigger"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Stub TRIGGER_DIR so we never touch the real agent-state triggers.
export PI_INTAKE_TRIGGER_DIR="$scratch/triggers"
trigger_dir="$PI_INTAKE_TRIGGER_DIR"
mkdir -p "$trigger_dir"

# Stub systemctl:
#  - with --no-block: queues the job (background sleep 40) and returns immediately
#  - without --no-block: blocks for the full 40s job, like real systemd start
#  - records every invocation for assertion
mkdir -p "$scratch/bin"
cat > "$scratch/bin/systemctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$scratch/systemctl-calls"
if [[ "\$1" == "start" && "\$2" == "--no-block" ]]; then
    sleep 40 &
    exit 0
fi
if [[ "\$1" == "start" ]]; then
    sleep 40
    exit 0
fi
exit 0
STUB
chmod +x "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"

# fleet-ops#5385: the trigger now gates on .repos[].name of the live intake
# config. Point it at a fixture so this drill stays hermetic on hosted CI.
cat > "$scratch/intake.json" <<'JSON'
{"repos":[{"name":"fleet-ops"}],"deferred":[],"excluded":[]}
JSON
export PI_INTAKE_TRIGGER_INTAKE_JSON="$scratch/intake.json"

# --- 1. trigger passes --no-block -------------------------------------------
echo fleet-ops > "$trigger_dir/fleet-ops"

start=$(date +%s)
"$trigger"
rc=$?
elapsed=$(( $(date +%s) - start ))

[[ $rc -eq 0 ]] || fail "trigger exited $rc, expected 0"
[[ $elapsed -le 5 ]] || fail "trigger took ${elapsed}s with a 40s stub intake; --no-block missing? (fleet-ops#4561)"
ok "trigger exited 0 in ${elapsed}s against a 40s stub intake"

grep -q '^--user start --no-block pi-intake@fleet-ops.service$' "$scratch/systemctl-calls" \
  || fail "trigger must call 'systemctl --user start --no-block pi-intake@<repo>.service', got: $(cat "$scratch/systemctl-calls" 2>/dev/null || echo none)"
ok "systemctl called with start --no-block"

# --- 2. trigger file still consumed -----------------------------------------
[[ ! -e "$trigger_dir/fleet-ops" ]] || fail "trigger file was not removed after processing"
ok "trigger file consumed"

# cleanup background sleeps
wait 2>/dev/null || true
pkill -f 'sleep 40' 2>/dev/null || true
exit 0
