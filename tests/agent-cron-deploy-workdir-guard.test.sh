#!/usr/bin/env bash
# tests/agent-cron-deploy-workdir-guard.test.sh
#
# fleet-ops#6252 (live DEPLOY-BLOCKED evidence 2026-09-13T01:40Z): agent-cron
# units pointed WORKDIR/WorkingDirectory at fleet-ops deploy checkouts. The
# weekly fleet review wrote config/model-candidates.json into the live deploy
# clone, fleet-deploy-check went fail-closed (DEPLOY-BLOCKED) and merge-to-live
# was blocked for the whole 42-min review. Class fix, locked here:
#   - no unit file in systemd/ may set WorkingDirectory= or Environment=
#     WORKDIR= at a path inside a fleet-ops deploy checkout,
#   - agent-cron-run must refuse to start with such a WORKDIR (before any pi
#     spawn), for the clone and the non-clone deploy dir alike,
#   - the match must NOT over-block lookalike names (fleet-ops-deploy-mirror
#     is a legitimate workdir).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

DEPLOY_RE='(^|/)fleet-ops-deploy(-clone)?(/|$)'

# --- scenario 1: no unit points WorkingDirectory/WORKDIR at a deploy checkout
while IFS= read -r -d '' unit; do
    while IFS= read -r directive; do
        value="${directive#*=}"
        if [[ "$value" =~ $DEPLOY_RE ]]; then
            fail "scenario 1: $unit sets a deploy-checkout cwd (fleet-ops#6252): $directive"
        fi
    done < <(grep -E '^(WorkingDirectory=|Environment=WORKDIR=)' "$unit" || true)
done < <(find "$repo_root/systemd" -maxdepth 1 -name '*.service' -print0)
ok "scenario 1: no systemd unit sets WorkingDirectory/WORKDIR inside a deploy checkout"

# --- scenarios 2-5: agent-cron-run refuses a deploy-checkout WORKDIR --------
scratch="$(mktemp -d -t agent-cron-deploy-wd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seatlib so the guard scenarios never reach seat picking.
stub_lib="$scratch/seatlib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
litellm_seat() { printf 'cursor\tcomposer-2.5\n'; return 0; }
EOF

# Fake pi that records invocation — the guard must stop pi from ever running.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$PI_RECORD_ARGS"
printf 'ran\nDIGEST:: deploy-workdir-guard\n'
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
rm -f "$record_args"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"
printf '# deploy-workdir-guard prompt\nbody\n' >"$prompts_dir/deploy-workdir-guard-slug.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export PI_RECORD_ARGS="$record_args"
export ATTEMPTS_DIR="$scratch/attempts"
mkdir -p "$ATTEMPTS_DIR"

# --- scenario 2: WORKDIR nested inside fleet-ops-deploy-clone -> FATAL ------
deploy_sub="$scratch/fleet-ops-deploy-clone/sub"
mkdir -p "$deploy_sub"
rm -f "$record_args"
set +e
WORKDIR="$deploy_sub" "$bin" deploy-workdir-guard-slug >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 2: WORKDIR inside the deploy clone must exit 1, got $rc (stderr: $(cat "$scratch/run2.err"))"
grep -q 'FATAL' "$scratch/run2.err" \
  || fail "scenario 2: must fail loud with FATAL, got: $(cat "$scratch/run2.err")"
grep -q 'fleet-ops#6252' "$scratch/run2.err" \
  || fail "scenario 2: refusal must cite fleet-ops#6252, got: $(cat "$scratch/run2.err")"
grep -q 'deploy-workdir-guard-slug' "$scratch/run2.err" \
  || fail "scenario 2: FATAL must name the slug, got: $(cat "$scratch/run2.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 2: pi must NOT be invoked, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 2: WORKDIR nested in fleet-ops-deploy-clone -> FATAL exit 1, pi never invoked"

# --- scenario 3: the clone root itself -> FATAL ------------------------------
deploy_clone_root="$scratch/fleet-ops-deploy-clone"
mkdir -p "$deploy_clone_root"
rm -f "$record_args"
set +e
WORKDIR="$deploy_clone_root" "$bin" deploy-workdir-guard-slug >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 3: WORKDIR = deploy clone root must exit 1, got $rc"
grep -q 'FATAL' "$scratch/run3.err" \
  || fail "scenario 3: must fail loud with FATAL, got: $(cat "$scratch/run3.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 3: pi must NOT be invoked, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 3: WORKDIR = fleet-ops-deploy-clone root -> FATAL exit 1"

# --- scenario 4: the non-clone deploy dir -> FATAL ---------------------------
deploy_dir="$scratch/fleet-ops-deploy"
mkdir -p "$deploy_dir"
rm -f "$record_args"
set +e
WORKDIR="$deploy_dir" "$bin" deploy-workdir-guard-slug >"$scratch/run4.out" 2>"$scratch/run4.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 4: WORKDIR = fleet-ops-deploy must exit 1, got $rc"
grep -q 'FATAL' "$scratch/run4.err" \
  || fail "scenario 4: must fail loud with FATAL, got: $(cat "$scratch/run4.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 4: pi must NOT be invoked, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 4: WORKDIR = fleet-ops-deploy (non-clone) -> FATAL exit 1"

# --- scenario 5: a lookalike name is NOT over-blocked ------------------------
lookalike="$scratch/fleet-ops-deploy-mirror"
mkdir -p "$lookalike"
rm -f "$record_args"
set +e
WORKDIR="$lookalike" "$bin" deploy-workdir-guard-slug >"$scratch/run5.out" 2>"$scratch/run5.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 5: lookalike workdir must run, got $rc (stderr: $(cat "$scratch/run5.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 5: pi must be invoked for a lookalike workdir, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 5: lookalike (fleet-ops-deploy-mirror) still runs — no over-blocking"

ok "agent-cron deploy-workdir guard: units clean, runner refuses deploy checkouts, lookalikes unaffected"
