#!/usr/bin/env bash
# tests/fleet-ops-drift-metrics-dropin.test.sh
#
# fleet-ops#2920: a MANIFEST-listed fleet-metrics-export drop-in missing
# from the live merged unit must fail the drift canary loud and auto-file,
# even while the deploy-clone is on a non-main branch (the root cause that
# makes check_live_matches_origin_main unreachable — check_checkout exits
# on DRIFT-OFF-MAIN first). check_metrics_export_dropins reads MANIFEST
# from the origin/main blob and asserts each fleet-metrics-export.service.d
#/*.conf is loaded into the live merged unit (`systemctl --user cat`).
#
# Scenarios, offline (FLEET_OPS_SKIP_FETCH=1, stub gh + systemctl):
#   1. Missing drop-in  -> rc=1, DRIFT-METRICS-DROPIN, auto-file (gh create).
#   2. Present drop-in  -> check passes (no DRIFT-METRICS-DROPIN, no file).
#   3. Dedup            -> an open issue carrying the marker is not re-filed.
#
# Overlay FLEET_OPS_WORKSPACES_ROOT so this never touches the live box.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$repo_root/bin/fleet-ops-drift.py" ]] || fail "missing bin/fleet-ops-drift.py"
grep -q 'check_metrics_export_dropins' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must define check_metrics_export_dropins (fleet-ops#2920)"
grep -q 'DRIFT-METRICS-DROPIN' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must emit DRIFT-METRICS-DROPIN"
grep -q 'metrics-export-dropin-missing: fleet-ops#2920' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must carry the metrics-export-dropin marker"

scratch="$(mktemp -d -t drift-metrics-dropin.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.config/systemd/user"

ws="$scratch/workspaces"
canon="$ws/tooling/fleet-ops-deploy-clone"
mkdir -p "$canon/systemd/fleet-metrics-export.service.d" "$canon/bin"

# A MANIFEST listing one metrics-export drop-in, plus the drop-in source file.
dropin_src="$canon/systemd/fleet-metrics-export.service.d/scout-effectiveness.conf"
dropin_dest="$HOME/.config/systemd/user/fleet-metrics-export.service.d/scout-effectiveness.conf"
cat >"$dropin_src" <<'CONF'
[Service]
ExecStart=-/bin/bash -c 'exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/scout-effectiveness.py'
CONF
cat >"$canon/MANIFEST" <<MANIFEST
systemd/fleet-metrics-export.service.d/scout-effectiveness.conf $dropin_dest
MANIFEST

# Make canon a git repo on main with origin/main == HEAD so
# `git show origin/main:MANIFEST` resolves and check_checkout's branch/HEAD
# gates pass. FLEET_OPS_SKIP_FETCH=1 means no fetch is attempted.
git -C "$canon" init -q -b main
git -C "$canon" config user.email "test@example.com"
git -C "$canon" config user.name "test"
git -C "$canon" add -A
git -C "$canon" commit -q -m "scratch canon"
git -C "$canon" update-ref refs/remotes/origin/main "$(git -C "$canon" rev-parse HEAD)"

# Stub gh: log every invocation, serve an open-issues JSON, fake-create.
gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
: >"$gh_log"
echo '[]' >"$scratch/open.json"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/2999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"

# Stub systemctl. `--user cat fleet-metrics-export.service` returns the
# merged-unit text; the drop-in path appears as a `# <path>` comment line.
# CAT_STATE controls whether the drop-in path is included (present vs missing).
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
args=("$@")
if [[ "${args[0]:-}" == "--user" ]]; then shift; fi
case "${1:-}" in
  cat)
    if [[ "${2:-}" == "fleet-metrics-export.service" ]]; then
      if [[ "${CAT_MISSING:-0}" == "1" ]]; then
        printf -- '# /home/nish/.config/systemd/user/fleet-metrics-export.service\nExecStart=/usr/bin/python3 /home/nish/.local/libexec/fleet-metrics-export.py\n'
      else
        printf -- '# /home/nish/.config/systemd/user/fleet-metrics-export.service\nExecStart=/usr/bin/python3 /home/nish/.local/libexec/fleet-metrics-export.py\n# %s\nExecStart=-/bin/bash -c exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/scout-effectiveness.py\n' "${CAT_DROPIN_DEST:-}"
      fi
      exit 0
    fi
    exit 0
    ;;
  daemon-reload|enable|start|is-enabled) exit 0 ;;
  list-unit-files) printf 'fleet-metrics-export.timer enabled\n'; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$systemctl_fake"

export FLEET_OPS_WORKSPACES_ROOT="$ws"
export FLEET_OPS_CANONICAL_CHECKOUT="$canon"
export PATH="$scratch:$PATH"

run_canary() {
  set +e
  canary_out=$(
    HOME="$HOME" \
    FLEET_OPS_CHECKOUT="$canon" \
    FLEET_OPS_WORKSPACES_ROOT="$ws" \
    FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
    FLEET_OPS_SKIP_FETCH=1 \
    FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
    FLEET_OPS_TRIAGE="$scratch/triage.md" \
    FLEET_OPS_AUDIT_LOG="$scratch/audit.log" \
    FLEET_OPS_DRIFT_FILE=1 \
    FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    FLEET_OPS_DRIFT_CLOSE=0 \
    GH="$gh_fake" \
    GH_LOG="$gh_log" \
    GH_OPEN_ISSUES="$scratch/open.json" \
    CAT_MISSING="${CAT_MISSING:-0}" \
    CAT_DROPIN_DEST="$dropin_dest" \
    python3 "$repo_root/bin/fleet-ops-drift.py" 2>&1
  )
  canary_rc=$?
  set -e
}

# --- 1. missing drop-in -> DRIFT-METRICS-DROPIN + auto-file -----------------
: >"$gh_log"
: >"$scratch/triage.md"
CAT_MISSING=1 run_canary
[[ "$canary_rc" -eq 1 ]] || fail "scenario1: canary should rc=1, got $canary_rc out=$canary_out"
[[ "$canary_out" == *"DRIFT-METRICS-DROPIN"* ]] \
    || fail "scenario1: expected DRIFT-METRICS-DROPIN, got: $canary_out"
[[ "$canary_out" == *"scout-effectiveness.conf"* ]] \
    || fail "scenario1: finding must name the missing drop-in, got: $canary_out"
grep -q 'issue create' "$gh_log" \
    || fail "scenario1: must auto-file (log=$(cat "$gh_log"))"
grep -q 'fix(metrics-export): MANIFEST-listed drop-in missing from live unit' "$gh_log" \
    || fail "scenario1: filed issue must use the metrics-dropin title (log=$(cat "$gh_log"))"
ok "scenario1: missing drop-in fails loud and auto-files"

# --- 2. present drop-in -> check passes (no DRIFT-METRICS-DROPIN) -----------
: >"$gh_log"
: >"$scratch/triage.md"
CAT_MISSING=0 run_canary
[[ "$canary_out" == *"all 1 fleet-metrics-export drop-ins present in live unit"* ]] \
    || fail "scenario2: expected the present-dropin log line, got: $canary_out"
[[ "$canary_out" != *"DRIFT-METRICS-DROPIN"* ]] \
    || fail "scenario2: must not fire DRIFT-METRICS-DROPIN when present, got: $canary_out"
! grep -q 'fix(metrics-export): MANIFEST-listed drop-in missing from live unit' "$gh_log" \
    || fail "scenario2: must not auto-file when present (log=$(cat "$gh_log"))"
ok "scenario2: present drop-in passes the check (no false fire)"

# --- 3. dedup: open issue carrying the marker is not re-filed ---------------
: >"$gh_log"
: >"$scratch/triage.md"
jq -n --arg b $'body\nmetrics-export-dropin-missing: fleet-ops#2920\n' \
  '[{number: 2920, body: $b}]' >"$scratch/open.json"
CAT_MISSING=1 run_canary
[[ "$canary_rc" -eq 1 ]] || fail "scenario3: canary should still rc=1 on dedup, got $canary_rc"
[[ "$canary_out" == *"dedup:"* ]] \
    || fail "scenario3: expected dedup log, got: $canary_out"
! grep -q 'issue create' "$gh_log" \
    || fail "scenario3: must not file a duplicate (log=$(cat "$gh_log"))"
ok "scenario3: open issue with the marker is not filed twice"

echo "PASS: fleet-ops-drift-metrics-dropin (fleet-ops#2920)"
