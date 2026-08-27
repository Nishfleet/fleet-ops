#!/usr/bin/env bash
# tests/fleet-heartbeat-throughput-split.test.sh
#
# Proves the per-tick THROUGHPUT line splits merged fleet-worker PRs into
# product repos (everything except fleet-ops) and control plane (fleet-ops).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-undersaturation"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t throughput.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# intake-repos.json: 0509 (product) + fleet-ops (control plane).
intake_json="$scratch/intake-repos.json"
cat >"$intake_json" <<'JSON'
{
  "repos": [
    { "name": "0509" },
    { "name": "fleet-ops" }
  ],
  "excluded": [],
  "deferred": []
}
JSON

log_dir="$scratch/log"
triage="$scratch/triage.md"
seat_state="$scratch/pi-packet"
mkdir -p "$log_dir" "$seat_state/active-seats"

# Fake gh returns canned merged PRs for the throughput query and counts for issue list.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
# Parse enough of argv to tell issue list (with --jq length) from the
# throughput `pr list --search ... --json number,headRefName` call.
repo=""
kind=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -R) repo="$2"; shift 2 ;;
        issue) kind="issue"; shift ;;
        pr) kind="pr"; shift ;;
        *) shift ;;
    esac
done

if [[ "$kind" == "issue" ]]; then
    # count_work uses --jq 'length' over --json number; return the count.
    printf '1\n'
    exit 0
fi

if [[ "$kind" == "pr" ]]; then
    case "$repo" in
        Nishfleet/0509)
            # One product PR: 0509 remains the only product receiving supply.
            printf '[{"number":1,"headRefName":"claim/issue-100"}]\n'
            ;;
        Nishfleet/fleet-ops)
            # Two control-plane PRs: fleet-ops precedence is deliberate.
            printf '[{"number":2,"headRefName":"claim/issue-50"},{"number":3,"headRefName":"p1/ops"}]\n'
            ;;
        *)
            printf '[]\n'
            ;;
    esac
    exit 0
fi

printf '[]\n'
FAKE
chmod +x "$gh_fake"

# Fake systemctl: just enough for the healthy path (work>0, running>0).
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift
cmd="$1"; shift
case "$cmd" in
    list-units) ;;
    is-active)  echo active ;;
    *)          ;;
esac
FAKE
chmod +x "$systemctl_fake"

# Work and running both > 0 so we hit the healthy path and only the throughput line fires.
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export PI_PACKET_STATE="$seat_state"
export WORK_READY="$scratch/work_ready"
export WORK_INPROGRESS="$scratch/work_inprogress"
export RUNNING_UNITS="$scratch/running_units"
export LIVE_SEAT_UNITS="$scratch/live_seat_units"

printf '1\n' >"$WORK_READY"
printf '1\n' >"$WORK_INPROGRESS"
printf 'pi-issue@0509-1.service\n' >"$RUNNING_UNITS"
printf 'pi-issue@0509-1.service\n' >"$LIVE_SEAT_UNITS"

set +e
env_out=$(SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$bin" 2>&1)
env_rc=$?
set -e
[[ "$env_rc" == 0 ]] || fail "healthy tick must exit 0, got $env_rc ($env_out)"

# The throughput line must show product=1, control-plane=2.
grep -q 'merged_product_PRs=1' "$triage" || fail "triage missing product PR split (got: $(cat "$triage"))"
grep -q 'merged_control_plane_PRs=2' "$triage" || fail "triage missing control-plane PR split (got: $(cat "$triage"))"
grep -q 'merged_fleet_worker_PRs=3' "$triage" || fail "triage missing total split (got: $(cat "$triage"))"

# When control-plane merges exceed product merges, the canary must NOT treat
# the ratio as a fault. It must emit a deliberate-precedence line instead.
grep -q 'THROUGHPUT-PRECEDENCE-OK' "$triage" || fail "triage missing THROUGHPUT-PRECEDENCE-OK line for infra-heavy ratio (got: $(cat "$triage"))"
ok "throughput line splits product (1) vs control-plane (2) and logs precedence-ok"

ok "fleet-heartbeat throughput: product-vs-control-plane split and precedence logging correct"
