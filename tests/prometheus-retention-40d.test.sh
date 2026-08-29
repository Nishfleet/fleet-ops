#!/usr/bin/env bash
# tests/prometheus-retention-40d.test.sh
#
# fleet-ops#1235: Prometheus storageRetention was 15d, too short for the
# fleet-ops#1151 baseline-delta job (needs a trailing 4-week window ≈ 35d
# of samples). This locks the SHAPE of the repo-tracked retention override
# AND functionally exercises bin/fleet-ops-deploy's restart-vs-reload
# decision + disk-headroom guard.
#
# Why restart and not reload: --storage.tsdb.retention.time is a start-time
# flag; a HUP does not apply it. The deploy script must `systemctl restart
# prometheus` when /etc/default/prometheus (the EnvironmentFile) changed,
# and fall back to `systemctl reload prometheus` for rule_files / config
# reloads when it did not.
#
# What it proves:
#   1. config/etc-default-prometheus exists and ARGS carries
#      --storage.tsdb.retention.time=40d as a single token (>=35d + 5d
#      margin). No size cap (min(time,size) would silently shorten the
#      window). No stale 15d. Loopback bind + config path preserved.
#   2. MANIFEST declares the system-scope entry (routes through
#      install.sh --system, not the symlink path).
#   3. bin/fleet-ops-deploy has the env-file snapshot, the restart path,
#      the headroom guard, and still keeps the reload path.
#   4. FUNCTIONAL: running bin/fleet-ops-deploy with prometheus "active"
#      and a changed env file calls `restart` (not `reload`) when headroom
#      is OK, and fails loud (exit 1, no restart) when headroom is below
#      the threshold. Unchanged env file calls `reload` (not `restart`).
#
# The live end-to-end proof (real `systemctl restart prometheus` +
# /api/v1/status/runtimeinfo reporting storageRetention=40d + query_range
# over 35d) is operator-side and recorded in the PR body; CI has no
# prometheus unit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

env_file="$repo_root/config/etc-default-prometheus"
manifest="$repo_root/MANIFEST"
install="$repo_root/install.sh"
deploy="$repo_root/bin/fleet-ops-deploy"

# --- 1. config shape ---------------------------------------------------------
[[ -f "$env_file" ]] || fail "missing: $env_file"
ok "config/etc-default-prometheus exists"

# ARGS carries --storage.tsdb.retention.time=40d as a single argv token
# (whitespace boundary on both sides so IFS word-splitting keeps it whole).
if ! grep -E '^ARGS=".*--storage\.tsdb\.retention\.time=40d([[:space:]]|")' "$env_file" >/dev/null; then
  fail "ARGS must contain --storage.tsdb.retention.time=40d as a single token (got: $(grep -E '^ARGS=' "$env_file" || echo '<missing>'))"
fi
ok "ARGS carries --storage.tsdb.retention.time=40d as a single token"

# Defence-in-depth: no size cap (min(time,size) would silently shorten 40d).
if grep -E -- '--storage\.tsdb\.retention\.size' "$env_file" >/dev/null; then
  fail "must not set --storage.tsdb.retention.size (size cap would silently shorten the 40d window)"
fi
ok "no size cap: --storage.tsdb.retention.size is absent"

# Must NOT retain the stale 15d the issue is dropping.
if grep -E -- '--storage\.tsdb\.retention\.time=15d' "$env_file" >/dev/null; then
  fail "still references 15d (stale value; the issue is to drop it)"
fi
ok "no stale 15d"

# Loopback bind + config path preserved (the issue asked only to change retention).
grep -Eq -- '--web\.listen-address=127\.0\.0\.1:9090' "$env_file" \
  || fail "--web.listen-address must stay 127.0.0.1:9090 (loopback only)"
ok "loopback bind preserved: 127.0.0.1:9090"
grep -Eq -- '--config\.file=/etc/prometheus/prometheus\.yml' "$env_file" \
  || fail "--config.file must stay /etc/prometheus/prometheus.yml"
ok "config path preserved: /etc/prometheus/prometheus.yml"

# --- 2. MANIFEST entry -------------------------------------------------------
manifest_line="config/etc-default-prometheus /etc/default/prometheus"
grep -Fxq "$manifest_line" "$manifest" \
  || fail "MANIFEST missing entry: $manifest_line"
ok "MANIFEST declares the system-scope entry"

# --- 3. deploy-script shape --------------------------------------------------
bash -n "$deploy" || fail "bin/fleet-ops-deploy: bash syntax error"

# Env-file snapshot before install.sh --system (sha256sum before/after).
grep -q 'prom_env_before=' "$deploy" \
  || fail "fleet-ops-deploy must snapshot /etc/default/prometheus before install.sh --system (fleet-ops#1235)"
grep -q 'prom_env_changed=' "$deploy" \
  || fail "fleet-ops-deploy must compute prom_env_changed (fleet-ops#1235)"
ok "deploy snapshots the env file and computes prom_env_changed"

# Restart path present (start-time flag needs it).
grep -q 'systemctl restart prometheus' "$deploy" \
  || fail "fleet-ops-deploy must restart prometheus when the env file changes (fleet-ops#1235)"
ok "deploy has the restart path"

# Headroom guard present: df on the TSDB fs + threshold + loud fail.
grep -q 'PROM_RETENTION_HEADROOM_GB' "$deploy" \
  || fail "fleet-ops-deploy must honor PROM_RETENTION_HEADROOM_GB (fleet-ops#1235)"
grep -q 'PROM_TSDB_FS' "$deploy" \
  || fail "fleet-ops-deploy must honor PROM_TSDB_FS for the headroom check (fleet-ops#1235)"
grep -q 'DEPLOY-PROMETHEUS-HEADROOM' "$deploy" \
  || fail "fleet-ops-deploy must fail loud (DEPLOY-PROMETHEUS-HEADROOM) on low headroom (fleet-ops#1235)"
ok "deploy has the disk-headroom guard (threshold + loud fail)"

# Reload path still present (unchanged env file → HUP for rule_files).
grep -q 'sudo -n systemctl reload prometheus' "$deploy" \
  || fail "fleet-ops-deploy must still reload prometheus when the env file is unchanged (fleet-ops#1247)"
ok "deploy keeps the reload path for unchanged env files"

# --- 4. FUNCTIONAL: restart-vs-reload + headroom guard -----------------------
# Run the real bin/fleet-ops-deploy in a scratch env with prometheus "active",
# a controlled env file, a fake sudo (drops -n, execs the rest so `sudo -n
# systemctl ...` reaches the fake systemctl via scratch PATH), and a fake df
# returning controlled free space. install.sh --system is made to change the
# env file by adding the /etc/default/prometheus MANIFEST entry and a fake
# `install` that copies the repo file to $PROM_ENV_FILE.
scratch="$(mktemp -d -t prom-retention.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.local/state/fleet-ops" \
         "$HOME/.pi/agent/prompts"

checkout="$scratch/checkout"
mkdir -p "$checkout/bin" "$checkout/systemd" "$checkout/config" "$checkout/lib"

# Minimal checkout: install.sh, deploy, drift canary stub, intake-reconcile stub.
cp "$repo_root/install.sh" "$checkout/install.sh"
cp "$deploy" "$checkout/bin/fleet-ops-deploy"
chmod +x "$checkout/install.sh" "$checkout/bin/fleet-ops-deploy"

# drift canary stub: always clean (exit 0). Needs a shebang — the deploy
# runs it as $HOME/.local/bin/fleet-ops-drift (no .py) via the symlink.
cat >"$checkout/bin/fleet-ops-drift.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY
# intake-reconcile stub: no-op.
cat >"$checkout/bin/intake-reconcile" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "$checkout/bin/fleet-ops-drift.py" "$checkout/bin/intake-reconcile"

# Scratch MANIFEST with the /etc/default/prometheus entry (routes through
# install.sh --system) plus a user-scope bin so install.sh has work in both
# modes. The drift canary + intake-reconcile are installed as user-scope.
cat >"$checkout/MANIFEST" <<MANIFEST
config/etc-default-prometheus /etc/default/prometheus
bin/fleet-ops-drift.py $HOME/.local/bin/fleet-ops-drift
bin/intake-reconcile $HOME/.local/bin/intake-reconcile
MANIFEST
cp "$env_file" "$checkout/config/etc-default-prometheus"

# Local git repo so the deploy's git fetch/merge/status succeed.
git init -q "$checkout"
git -C "$checkout" add -A
git -C "$checkout" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$checkout" branch -M main
git -C "$checkout" remote add origin "$checkout"
git -C "$checkout" update-ref refs/remotes/origin/main HEAD

# Fake systemctl: reports prometheus active; logs reload/restart to a file.
systemctl_fake="$scratch/systemctl"
prom_calls="$scratch/prom-calls"
: >"$prom_calls"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
# Drop the leading --user if present (install.sh calls --user).
[ "${1:-}" = "--user" ] && shift
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  is-active)
    case "${1:-}" in
      prometheus) printf 'active\n'; exit 0 ;;
      *) printf 'inactive\n'; exit 3 ;;
    esac
    ;;
  is-enabled) echo "not-found"; exit 1 ;;
  daemon-reload) exit 0 ;;
  enable) exit 0 ;;
  start) exit 0 ;;
  reload)
    echo "reload ${1:-}" >> "${PROM_CALLS:-/dev/null}"
    exit 0
    ;;
  restart)
    echo "restart ${1:-}" >> "${PROM_CALLS:-/dev/null}"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$systemctl_fake"

# Fake sudo: drop -n (non-interactive), exec the rest. Routes `sudo -n
# systemctl ...` to the fake systemctl via scratch PATH, and `sudo install
# ...` to the fake install below.
sudo_fake="$scratch/sudo"
cat >"$sudo_fake" <<'FAKE'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  [ "$a" = "-n" ] && continue
  args+=("$a")
done
exec "${args[@]}"
FAKE
chmod +x "$sudo_fake"

# Fake install: when the dest is /etc/default/prometheus, copy the source to
# $PROM_ENV_FILE so the deploy's before/after sha256 differs (simulating the
# real install -D writing the new retention). Otherwise behave like install.
install_fake="$scratch/install"
cat >"$install_fake" <<'FAKE'
#!/usr/bin/env bash
# Mimic `install -D ... src dest`: last two non-flag args are src and dest.
src=""; dest=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) src="$dest"; dest="$a" ;;
  esac
done
if [ "$dest" = "/etc/default/prometheus" ] && [ -n "${PROM_ENV_FILE:-}" ]; then
  mkdir -p "$(dirname "$PROM_ENV_FILE")"
  cp "$src" "$PROM_ENV_FILE"
  exit 0
fi
# Real install fallback for any other dest.
mkdir -p "$(dirname "$dest")"
cp "$src" "$dest"
exit 0
FAKE
chmod +x "$install_fake"

# Fake df: mimic `df -P --output=avail <fs>` — a single "Avail" column header
# then the value in KB. The deploy parses it with `awk 'NR==2{print $1}'`.
df_fake="$scratch/df"
cat >"$df_fake" <<'FAKE'
#!/usr/bin/env bash
printf 'Avail\n'
printf '%s\n' "${PROM_DF_AVAIL_KB:-99999999}"
exit 0
FAKE
chmod +x "$df_fake"

prom_env_scratch="$scratch/prom-env"
mkdir -p "$prom_env_scratch"

run_deploy_prom() {
  local df_avail="$1"       # KB free on the TSDB fs
  local before_src="$2"     # file whose bytes are written to PROM_ENV_FILE before the deploy
  : >"$prom_calls"
  cp "$before_src" "$prom_env_scratch/file"
  PATH="$scratch:$PATH" \
  PROM_ENV_FILE="$prom_env_scratch/file" \
  PROM_TSDB_FS="/fake" \
  PROM_DF_AVAIL_KB="$df_avail" \
  PROM_CALLS="$prom_calls" \
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DRIFT_BIN="$HOME/.local/bin/fleet-ops-drift" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_ALLOW_NONCANONICAL=1 \
    "$checkout/bin/fleet-ops-deploy" >/tmp/prom-deploy.out 2>&1
}

# A "before" env file with the stale 15d value (differs from the repo's 40d).
before_15d="$scratch/before-15d"
cat >"$before_15d" <<'ENV'
ARGS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=15d --web.listen-address=127.0.0.1:9090"
ENV

# 4a. env file CHANGED + ample headroom (10G = 10485760 KB) → restart.
set +e
run_deploy_prom 10485760 "$before_15d"
rc=$?
set -e
[[ $rc -eq 0 ]] || { cat /tmp/prom-deploy.out; fail "4a: deploy should succeed with ample headroom (rc=$rc)"; }
grep -q '^restart prometheus$' "$prom_calls" \
  || fail "4a: changed env file + ample headroom must call 'restart prometheus' (calls=$(cat "$prom_calls"))"
grep -q '^reload ' "$prom_calls" \
  && fail "4a: changed env file must NOT call reload (calls=$(cat "$prom_calls"))" || true
ok "4a: changed env file + ample headroom → restart (not reload)"

# 4b. env file CHANGED + low headroom (1G = 1048576 KB, threshold 2G) → fail loud, no restart.
set +e
run_deploy_prom 1048576 "$before_15d"
rc=$?
set -e
[[ $rc -ne 0 ]] || { cat /tmp/prom-deploy.out; fail "4b: deploy must fail loud on low headroom (rc=$rc)"; }
grep -q '^restart prometheus$' "$prom_calls" \
  && fail "4b: low headroom must NOT call restart (calls=$(cat "$prom_calls"))" || true
grep -q 'DEPLOY-PROMETHEUS-HEADROOM' "$scratch/triage.md" 2>/dev/null \
  || { cat /tmp/prom-deploy.out; fail "4b: low headroom must write DEPLOY-PROMETHEUS-HEADROOM to triage"; }
ok "4b: changed env file + low headroom → fail loud (DEPLOY-PROMETHEUS-HEADROOM), no restart"

# 4c. env file UNCHANGED + ample headroom → reload (not restart).
# Use the repo file itself as "before"; the fake install copies the same
# file → before/after sha256 match → prom_env_changed=0 → reload path.
set +e
run_deploy_prom 10485760 "$env_file"
rc=$?
set -e
[[ $rc -eq 0 ]] || { cat /tmp/prom-deploy.out; fail "4c: deploy should succeed with unchanged env file (rc=$rc)"; }
grep -q '^reload prometheus$' "$prom_calls" \
  || fail "4c: unchanged env file must call 'reload prometheus' (calls=$(cat "$prom_calls"))"
grep -q '^restart ' "$prom_calls" \
  && fail "4c: unchanged env file must NOT call restart (calls=$(cat "$prom_calls"))" || true
ok "4c: unchanged env file → reload (not restart)"

# --- 5. install.sh routing ---------------------------------------------------
# install.sh --check --system must not produce user-scope (/home/...) diffs —
# the /etc/default/prometheus entry routes through the system handler.
check_out=$(PATH="$scratch:$PATH" "$install" --check --system 2>/dev/null || true)
if grep -q '^DIFF: /home/' <<< "$check_out"; then
  fail "install.sh --check --system leaked /home/... diffs — routing is wrong"
fi
ok "install.sh --check --system: stays on /etc/ entries"

echo "OK: prometheus retention 40d locked (shape + deploy restart/headroom functional)"

# --- Verification for fleet-ops#1414 ------------------------------------------
# This test was already wired into P14 CI by PR #1420 (commit e0969a12).
# The issue #1414 (main CI red on fleet-ops at 2026-08-27T21:10Z) was resolved
# by that fix. This verification branch confirms the fix is present and main
# is green as of the latest CI run (33232685375).
# Verification: https://github.com/Nishfleet/fleet-ops/actions/runs/33232685375
