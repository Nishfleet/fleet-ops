#!/usr/bin/env bash
# hand-written because no platform feature installs from an explicit manifest; GNU stow rejected: directory-sweep semantics conflict with the allowlist requirement.
#
# Modes (fleet-ops#71):
#   (default)            — symlink every MANIFEST entry whose destination is in
#                          the user scope (~/.config, ~/.local, ~/.pi), then
#                          systemctl --user daemon-reload. SKIPS any entry whose
#                          destination is /etc/... — those require --system.
#   --check              — dry-run. Drift = symlink target differs OR
#                          destination is missing OR destination is a regular
#                          file whose content differs from the repo file.
#                          Treats both symlinks AND byte-equal copies as OK
#                          (system-scope drop-ins are installed as copies,
#                          not symlinks, because they cross privilege
#                          boundaries — install -D, not ln -s).
#   --system             — install entries whose destination is under /etc/...
#                          using `sudo install -D -m 0644 -o root -g root`.
#                          Skips non-system entries. Requires `sudo -n true`
#                          to succeed (non-interactive). After install, runs
#                          `sudo systemctl daemon-reload` so systemd
#                          re-reads the drop-ins. --system takes no part in
#                          daemon-reload for the user instance — call without
#                          --system first for that.
#                          A changed config/fleet_rules.yml also gets
#                          `sudo systemctl reload prometheus` (ExecReload is
#                          kill -HUP), and every group in the installed file
#                          is proven present in GET /api/v1/rules
#                          (fleet-ops#1307); the reload is skipped when the
#                          file bytes did not change.
#   --check --system     — drift detection for system-scope entries only.
#                          Useful for "is this box up to date?" without
#                          changing anything.
#
# fleet-ops#3277: a MANIFEST src of `npm-pin:<rel>` is not a repo file. It
# pins dest as a symlink at $PI_PACKAGE_EXAMPLES/<rel> (the installed pi
# package examples/). Used for the stock subagent agents.ts + workflow
# prompts so a pi reinstall cannot silently drop delegation.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; rc=0
manifest="$here/MANIFEST"
# Tests inject a stub via SYSTEMCTL= (fleet-ops#290). Live installs leave this unset.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

mode=""
check_system=0
user_unit_changed=0
system_unit_changed=0
system_rules_changed=0
system_audit_changed=0
declare -a to_enable=()
for arg in "$@"; do
  case "$arg" in
    --check)      mode="--" ;;           # distinct from empty so we can
                                       # detect "did the user pass --check"
                                       # even together with --system.
    --system)     check_system=1 ;;
    *) echo "install.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

do_user_install=0
do_user_check=0
do_system_install=0
do_system_check=0
if [ "$check_system" = 1 ]; then
  if [ "$mode" = "--" ]; then
    do_system_check=1
  else
    do_system_install=1
  fi
elif [ "$mode" = "--" ]; then
  do_user_check=1
else
  do_user_install=1
fi

# fleet-ops#176: a hand-run of install.sh from a hotfix / issue worktree /
# worktree-parent retargets every live symlink at a tree that can diverge
# or be deleted. Refuse mutating installs from any path under
# FLEET_OPS_WORKSPACES_ROOT that is not the canonical deploy checkout.
# --check never refuses (auditors still need to see DIFF). Tests live under
# /tmp, which is outside the workspaces root, so they stay allowed.
# FLEET_OPS_ALLOW_NONCANONICAL=1 is the explicit operator override.
refuse_noncanonical_install() {
  [ "${FLEET_OPS_ALLOW_NONCANONICAL:-}" = 1 ] && return 0
  local ws_root canon got want root
  ws_root="${FLEET_OPS_WORKSPACES_ROOT:-/home/nish/workspaces}"
  canon="${FLEET_OPS_CANONICAL_CHECKOUT:-$ws_root/tooling/fleet-ops-deploy-clone}"
  got=$(readlink -f "$here")
  want=$(readlink -f "$canon" 2>/dev/null || printf '%s\n' "$canon")
  root=$(readlink -f "$ws_root" 2>/dev/null || printf '%s\n' "$ws_root")
  [ "$got" = "$want" ] && return 0
  case "$got" in
    "$root"|"$root"/*)
      echo "install.sh: REFUSE: refusing to install from non-canonical checkout $got" >&2
      echo "install.sh: canonical checkout is $want (fleet-ops#176)" >&2
      echo "install.sh: set FLEET_OPS_ALLOW_NONCANONICAL=1 to override" >&2
      exit 1
      ;;
  esac
}

# fleet-ops#5459: --check never refuses (auditors need the DIFFs), but a
# --check run from a non-canonical workspaces checkout must SAY its DIFFs are
# measured against this tree — a stale clone's DIFF count reads exactly like
# live drift and has been filed as a critical gap-audit finding.
warn_noncanonical_check() {
  [ "${FLEET_OPS_ALLOW_NONCANONICAL:-}" = 1 ] && return 0
  local ws_root canon got want root
  ws_root="${FLEET_OPS_WORKSPACES_ROOT:-/home/nish/workspaces}"
  canon="${FLEET_OPS_CANONICAL_CHECKOUT:-$ws_root/tooling/fleet-ops-deploy-clone}"
  got=$(readlink -f "$here")
  want=$(readlink -f "$canon" 2>/dev/null || printf '%s\n' "$canon")
  root=$(readlink -f "$ws_root" 2>/dev/null || printf '%s\n' "$ws_root")
  [ "$got" = "$want" ] && return 0
  case "$got" in
    "$root"|"$root"/*)
      echo "install.sh: NONCANONICAL-CHECKOUT: $got is not the live install source; DIFF lines compare installed files against THIS checkout, not live drift" >&2
      echo "install.sh: canonical checkout is $want (fleet-ops#5459)" >&2
      ;;
  esac
}

if [ "$mode" != "--" ]; then
  refuse_noncanonical_install
else
  warn_noncanonical_check
fi

# Returns 0 if the destination is under /etc/, 1 otherwise. Used to route
# each MANIFEST line to the user/system handler.
dest_is_system() { case "$1" in /etc/*) return 0;; *) return 1;; esac; }

# Returns 0 if the source path is a systemd unit/drop-in that requires a
# daemon-reload when changed.
is_unit_src() { case "$1" in systemd/*) return 0;; *) return 1;; esac; }

# Returns 0 if the source path is a user-scope installable unit (not a
# template, has [Install]) and should be enabled by install.sh.
is_installable_unit() {
    local src=$1
    case "$src" in
        systemd/*.service|systemd/*.timer|systemd/*.path)
            case "$src" in *@*) return 1;; esac
            case "$src" in systemd/system/*) return 1;; esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

unit_has_install() { grep -qE '^\[Install\]$' "$1" 2>/dev/null; }

# Returns 0 if systemd reports the unit as enabled. Do not trust the exit
# code alone: a stub that exits 0 without printing "enabled" would make
# install.sh skip enable --now and leave [Install] units unstarted
# (fleet-ops#236, fleet-ops#290).
is_unit_enabled() {
    local unit=$1 state
    state=$("$SYSTEMCTL" --user is-enabled "$unit" 2>/dev/null) || true
    case "$state" in
        enabled|enabled-runtime) return 0 ;;
        *) return 1 ;;
    esac
}

# Returns 0 if the installed destination already matches the repo file.
# Treats a symlink to the repo file OR a byte-identical regular file as OK.
unit_file_matches() {
    local dest=$1 repo=$2
    if [ -L "$dest" ]; then
        [ "$(readlink -f "$dest" 2>/dev/null)" = "$repo" ] && return 0
    elif [ -f "$dest" ] && cmp -s "$dest" "$repo" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Resolve dest to the live file (follow one symlink). Empty if dest is missing.
live_target_file() {
    local dest=$1
    if [ -L "$dest" ]; then
        readlink -f "$dest" 2>/dev/null || true
    elif [ -f "$dest" ]; then
        printf '%s\n' "$dest"
    fi
}

# Returns 0 if $1 resolves under FLEET_OPS_WORKSPACES_ROOT but not under
# the canonical deploy checkout. That class is a hijacked install source
# (issue worktree, worktree-parent, leftover hotfix) — not a hot-patch.
# The mtime guard must not block retargeting these, or a leftover worktree
# symlink (e.g. fleet-failed-command-flagged pointing at issue-1136) stays
# live forever (fleet-ops#1189).
live_target_is_noncanonical() {
  local live=$1
  local ws_root canon live_r want root
  ws_root="${FLEET_OPS_WORKSPACES_ROOT:-/home/nish/workspaces}"
  canon="${FLEET_OPS_CANONICAL_CHECKOUT:-$ws_root/tooling/fleet-ops-deploy-clone}"
  live_r=$(readlink -f "$live" 2>/dev/null || printf '%s\n' "$live")
  want=$(readlink -f "$canon" 2>/dev/null || printf '%s\n' "$canon")
  root=$(readlink -f "$ws_root" 2>/dev/null || printf '%s\n' "$ws_root")
  case "$live_r" in
    "$want"|"$want"/*) return 1 ;;
    "$root"|"$root"/*) return 0 ;;
  esac
  return 1
}

# Returns 0 if two files are content-equivalent. Byte-equal passes; otherwise
# fall back to semantically equal JSON (fleet-ops#4894). The live file is
# rewritten by an EXTERNAL python json.dump without ensure_ascii=False that
# re-escapes non-ASCII to \uXXXX — same JSON content, different bytes — so a
# byte-only compare refuses forever. jq -S normalises key order and JSON
# escaping. Non-JSON files and missing jq degrade to byte-compare (safe); real
# structural diffs still reflect and refuse.
content_equivalent() {
    local a=$1 b=$2 norm_a norm_b
    if cmp -s "$a" "$b" 2>/dev/null; then return 0; fi
    command -v jq >/dev/null 2>&1 || return 1
    norm_a=$(jq -S . "$a" 2>/dev/null) || return 1
    norm_b=$(jq -S . "$b" 2>/dev/null) || return 1
    [ "$norm_a" = "$norm_b" ]
}

# Returns 0 if dest exists and its live target is a different file whose
# mtime is newer than the repo copy AND whose content differs from the repo
# copy. A newer, byte-identical file is not a hot-patch; it is only newer
# because it has already been installed (#463). Re-sync its mtime so the
# guard does not re-check, then allow the normal install to proceed.
# A dest whose live target is in a non-canonical workspaces tree is a
# hijacked symlink (issue worktree, worktree-parent, leftover hotfix), not
# a hot-patch: retarget it to the canonical repo instead of refusing
# (fleet-ops#1189).
live_newer_than_repo() {
    local dest=$1 repo=$2
    local live live_m repo_m
    live=$(live_target_file "$dest")
    [ -n "$live" ] && [ -e "$live" ] || return 1
    [ "$live" = "$repo" ] && return 1
    if live_target_is_noncanonical "$live"; then
        return 1
    fi
    live_m=$(stat -c %Y "$live" 2>/dev/null || echo 0)
    repo_m=$(stat -c %Y "$repo" 2>/dev/null || echo 0)
    [ "$live_m" -gt "$repo_m" ] || return 1
    if content_equivalent "$live" "$repo"; then
        # Content-equivalent (byte-identical or semantically equal JSON):
        # re-sync mtime to the repo copy and do not refuse.
        # For a regular file at $dest this makes the guard cheap next time;
        # for a symlink the install below will replace it with the repo link.
        if [ -f "$dest" ] && [ ! -L "$dest" ]; then
            touch -r "$repo" "$dest" 2>/dev/null || true
        fi
        return 1
    fi
    return 0
}

# fleet-ops#463: auto-file a ticket when the install is refused because a live
# file is newer AND different from the repo copy (a genuine hot-patch). The
# diff is attached to the issue body. The helper lives in the deploy canary
# so we reuse the same GH wiring, DRIFT_REPO, and dedup logic.
file_install_refuse() {
    local dest=$1 repo=$2
    local live diff_file py
    live=$(live_target_file "$dest")
    diff_file=$(mktemp)
    if [ -n "$live" ] && [ -e "$live" ]; then
        diff -u "$repo" "$live" > "$diff_file" 2>/dev/null || true
    fi
    py="$here/bin/fleet-ops-drift.py"
    if [ -f "$py" ]; then
        GH="${GH:-gh}" \
        FLEET_OPS_DRIFT_REPO="${FLEET_OPS_DRIFT_REPO:-Nishfleet/fleet-ops}" \
          python3 "$py" --file-install-refuse "$dest" "$repo" "$diff_file" || true
    fi
    rm -f "$diff_file"
}

# True when $1 is byte-identical to origin/main:config/seat-caps.json.
# A merged cap drop on origin/main is intentional (fleet-ops-deploy).
seat_caps_is_origin_main_blob() {
    local repo=$1
    git -C "$here" show origin/main:config/seat-caps.json 2>/dev/null | cmp -s "$repo" -
}

# Returns 0 if installing repo seat-caps.json would lower any live provider
# or model cap. git checkout refreshes mtime, so live_newer_than_repo misses
# a stale clone of the pre-#331 snapshot (fleet-ops#371: live devin 4 / ollama
# 4 overwritten to 0 / 2). Prints the drops on stdout for the REFUSE line.
# Unparseable JSON is not this class — return 1 and let mtime decide.
seat_caps_would_downgrade() {
    local dest=$1 repo=$2
    local live
    [ "${FLEET_OPS_ALLOW_SEAT_CAPS_OVERWRITE:-}" = 1 ] && return 1
    live=$(live_target_file "$dest")
    [ -n "$live" ] && [ -e "$live" ] || return 1
    [ "$live" = "$repo" ] && return 1
    python3 - "$live" "$repo" <<'PY'
import json, sys

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, UnicodeError):
        sys.exit(1)
    if not isinstance(data, dict):
        sys.exit(1)
    providers = data.get("providers")
    if not isinstance(providers, dict):
        sys.exit(1)
    return providers

live, repo = load(sys.argv[1]), load(sys.argv[2])
hits = []
for name, lprov in live.items():
    if not isinstance(lprov, dict):
        continue
    rprov = repo.get(name)
    lc = lprov.get("cap")
    if isinstance(lc, int) and lc > 0:
        if not isinstance(rprov, dict):
            hits.append(f"{name}:{lc}->missing")
        else:
            rc = rprov.get("cap")
            if isinstance(rc, int) and rc < lc:
                hits.append(f"{name}:{lc}->{rc}")
    if not isinstance(rprov, dict):
        continue
    lmodels = lprov.get("models") if isinstance(lprov.get("models"), dict) else {}
    rmodels = rprov.get("models") if isinstance(rprov.get("models"), dict) else {}
    for model, lm in lmodels.items():
        if not isinstance(lm, int) or lm <= 0:
            continue
        rm = rmodels.get(model)
        if not isinstance(rm, int):
            hits.append(f"{name}/{model}:{lm}->missing")
        elif rm < lm:
            hits.append(f"{name}/{model}:{lm}->{rm}")
if hits:
    print(" ".join(hits))
    sys.exit(0)
sys.exit(1)
PY
}

# fleet-ops#4205: the live seat-caps.json state file is a regular file COPY
# (fleet-ops#2910) that install.sh overwrites from config/seat-caps.json on
# every deploy. A hand-added provider row in the live file (e.g. a newly
# wired seat like runinfra/<retired-V4-flash>) was silently dropped by that
# overwrite. Merge unknown provider rows from the live file into the repo
# copy before installing: every provider the repo does NOT declare is
# preserved, so a hand-wired seat survives a deploy. The repo remains the
# source of truth for every provider it knows about (a repo row always wins
# over the live row for the same provider). This only ADDS rows the repo
# lacks — it never lowers a cap — so it is compatible with the #371
# cap-downgrade guard above. Writes the merged JSON to stdout; on any
# unparseable input it falls back to the repo copy unchanged.
seat_caps_merge_unknown_providers() {
    local dest=$1 repo=$2
    local live
    live=$(live_target_file "$dest")
    [ -n "$live" ] && [ -e "$live" ] || { cat "$repo"; return 0; }
    [ "$live" = "$repo" ] && { cat "$repo"; return 0; }
    python3 - "$live" "$repo" <<'PY'
import json, sys

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None

live = load(sys.argv[1])
repo = load(sys.argv[2])
if not isinstance(live, dict) or not isinstance(repo, dict):
    sys.stdout.write(open(sys.argv[2], encoding="utf-8").read())
    sys.exit(0)
lp = live.get("providers")
rp = repo.get("providers")
if not isinstance(lp, dict) or not isinstance(rp, dict):
    sys.stdout.write(open(sys.argv[2], encoding="utf-8").read())
    sys.exit(0)
merged = json.loads(json.dumps(repo))
for name, prov in lp.items():
    if name not in rp:
        merged["providers"][name] = prov
json.dump(merged, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
}

# fleet-ops#372: the hand-built heartbeat drop-in pointed FLEET_OPS_DRIFT_BIN
# at a GC-able worktree and made the canary self-compare. Canonical checkout
# is now pinned on fleet-heartbeat.service; remove the paper-over if present.
# Only touch the drop-in when this MANIFEST actually installs into
# $HOME/.config/systemd/user — scratch tests that use a fake dest tree
# (and the real HOME) must not delete the live drop-in.
remove_papered_heartbeat_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin="${user_systemd}/fleet-heartbeat.service.d/10-deploy-checkout.conf"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -e "$dropin" ] || [ -L "$dropin" ]; then
        rm -f "$dropin"
        echo "removed paper-over drop-in: $dropin"
        user_unit_changed=1
    fi
}

# fleet-ops#2924: live bandage for FleetScoutStale (chmod 0644 + drop 0-valued
# series) written 2026-08-28 "until PR #1395 deploys". #1395 merged
# 2026-08-27T20:05:29Z (write fleet-scout.prom mode 0644). The drop-in is
# leftover and still rewrites the prom file on every scout. Only touch it
# when this MANIFEST installs into the live user unit dir.
# fleet-ops#4906: bridge drop-ins written by hand on 2026-09-10 (RuntimeMaxSec=13min,
# MemoryMax=2500M on the three judge units) while deploy was blocked. The caps
# now live in the unit files; remove the bridge so the repo unit is the only
# source. Only touch it when this MANIFEST installs into the live user unit dir.
remove_judge_budget_dropins() {
    local user_systemd="${HOME}/.config/systemd/user"
    local u dropin
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    for u in fable-fleet-check fable-fleet-check-kimi fable-fleet-check-opus; do
        dropin="${user_systemd}/${u}.service.d/20-judge-budget.conf"
        if [ -e "$dropin" ] || [ -L "$dropin" ]; then
            rm -f "$dropin"
            echo "removed bridge judge-budget drop-in: $dropin (fleet-ops#4906)"
            user_unit_changed=1
        fi
    done
}

# fleet-ops#5203: bridge drop-ins written by hand on 2026-09-11
# (TimeoutStartSec=120 on the two network canaries) while #5200 was in
# flight. The value now lives in the unit files; remove the bridge so the
# repo unit is the only source (two sources for one value is the #5095
# silent-contradiction bug). Remove only the 20-start-timeout.conf file,
# never the whole dir: the repo-sourced 10-pg-socket.conf symlink in
# fleet-litellm-health-canary.service.d must stay. Only touch it when this
# MANIFEST installs into the live user unit dir.
remove_canary_start_timeout_dropins() {
    local user_systemd="${HOME}/.config/systemd/user"
    local u dropin
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    for u in fleet-litellm-health-canary gh-webhook-canary; do
        dropin="${user_systemd}/${u}.service.d/20-start-timeout.conf"
        if [ -e "$dropin" ] || [ -L "$dropin" ]; then
            rm -f "$dropin"
            echo "removed bridge start-timeout drop-in: $dropin (fleet-ops#5203)"
            user_unit_changed=1
        fi
    done
}

remove_stale_scout_prom_mode_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin="${user_systemd}/pi-scout@.service.d/20-prom-mode.conf"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -e "$dropin" ] || [ -L "$dropin" ]; then
        rm -f "$dropin"
        echo "removed stale scout prom-mode drop-in: $dropin (fleet-ops#2924)"
        user_unit_changed=1
    fi
}

# fleet-ops#4112: the fleet-auto-deploy unit was deleted as stale machinery
# (WFR 2026-08-30, reports/machinery-deletion-review-2026-08-30.md). Its
# hand-placed drop-in dir ~/.config/systemd/user/fleet-auto-deploy.timer.d/
# survived the deletion and is invisible to a unit-name-only hunt
# (fleet-ops#2924 / #1548) because the unit no longer exists. The override
# only rewrote [Timer] OnCalendar — no ExecStart/ExecStartPre, not new
# machinery — so absorb-into-repo is wrong (there is no unit to source it).
# Remove the orphaned dir; only touch it when this MANIFEST installs into
# the live user unit dir.
remove_orphaned_fleet_auto_deploy_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-auto-deploy.timer.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-auto-deploy.timer.d drop-in dir: $dropin_dir (fleet-ops#4112)"
        user_unit_changed=1
    fi
}

# fleet-ops#4114: the fleet-auto-ship unit was deleted as stale machinery
# (WFR 2026-08-30, reports/machinery-deletion-review-2026-08-30.md). Its
# hand-placed drop-in dir ~/.config/systemd/user/fleet-auto-ship.service.d/
# survived the deletion and is invisible to a unit-name-only hunt
# (fleet-ops#2924 / #1548) because the unit no longer exists. The dir also
# carries .bak files (override.conf.bak-audit-timeout-20260811,
# zz-gate-retry.conf.bak-time-audit-20260812). Not new machinery — there is
# no unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_auto_ship_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-auto-ship.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-auto-ship.service.d drop-in dir: $dropin_dir (fleet-ops#4114)"
        user_unit_changed=1
    fi
}

# fleet-ops#4126: the fleet-cheap-triage unit lived in the control plane,
# which was deleted on 2026-08-23 ("Everything runs through Pi, directly.
# No launchers." — vault global-standing-rules.md). The live unit file,
# timer, the cheap-triage.py lane script, and the gate/fleet-gate binary it
# called are all gone; only the hand-placed drop-in dir
# ~/.config/systemd/user/fleet-cheap-triage.service.d/ survived the deletion
# and is invisible to a unit-name-only hunt (fleet-ops#2924 / #1548) because
# the unit no longer exists. The dir also carries .bak files
# (override.conf.bak-pulse-c51af7b13e-20260811,
# override.conf.bak-time-audit-20260812). Not new machinery — there is no
# unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_cheap_triage_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-cheap-triage.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-cheap-triage.service.d drop-in dir: $dropin_dir (fleet-ops#4126)"
        user_unit_changed=1
    fi
}

# fleet-ops#4151: the fleet-e2e-heartbeat unit was an end-to-end proof that
# the fleet ships (control-plane lane fleet-e2e-heartbeat.py). The live unit
# file, timer, the lane script, and the gate/fleet-gate binary it called are
# all gone; only the hand-placed drop-in dir
# ~/.config/systemd/user/fleet-e2e-heartbeat.service.d/ survived the deletion
# and is invisible to a unit-name-only hunt (fleet-ops#2924 / #1548) because
# the unit no longer exists. The dir also carries .bak files
# (override.conf.bak-pulse-a69537d453-20260811,
# override.conf.bak-time-audit-20260812,
# override.conf.bak-unit-fix-20260811T130719Z). Not new machinery — there is
# no unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_e2e_heartbeat_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-e2e-heartbeat.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-e2e-heartbeat.service.d drop-in dir: $dropin_dir (fleet-ops#4151)"
        user_unit_changed=1
    fi
}

# fleet-ops#4430: the fleet-hourly-audit unit lived in the control-plane
# repo (systemd/fleet-hourly-audit.service), whose machinery was deleted
# 2026-08-23 ("Everything runs through Pi, directly. No launchers." — vault
# global-standing-rules.md). Its live unit, timer, the hourly-audit.py lane
# script, the gate/fleet-gate binary it called, and the gate-retry.sh
# wrapper are all gone; only the hand-placed drop-in dir
# ~/.config/systemd/user/fleet-hourly-audit.service.d/ survived the deletion
# and is invisible to a unit-name-only hunt (fleet-ops#2924 / #1548) because
# the unit no longer exists. The drop-in set ExecStart/ExecStartPre/override
# for a unit that cannot resolve, carrying .bak files too
# (override.conf.bak-timer-sweep-20260811,
# zz-gate-retry.conf.bak-time-audit-20260812). Not new machinery — there is
# no unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_hourly_audit_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-hourly-audit.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-hourly-audit.service.d drop-in dir: $dropin_dir (fleet-ops#4430)"
        user_unit_changed=1
    fi
}

# fleet-ops#4435: the fleet-idea-intake unit was hand-placed control-plane
# machinery (never in the repo systemd/ tree or git history). Its live unit
# file, timer, the idea-intake/run-intake.py + run-bootstrap.py lane scripts,
# the campaigns/campaignlib.py payload, the gate/fleet-gate binary it called,
# and the gate-retry.sh wrapper are all gone; only the hand-placed drop-in
# dir ~/.config/systemd/user/fleet-idea-intake.service.d/ survived and is
# invisible to a unit-name-only hunt (fleet-ops#2924 / #1548) because the unit
# no longer exists. The drop-in set ExecStart/ExecStartPre/override for a
# unit that cannot resolve, carrying .bak files too
# (override.conf.bak-audit-timeout-20260811,
# override.conf.bak-timer-sweep-20260811,
# zz-gate-retry.conf.bak-time-audit-20260812). Not new machinery — there is
# no unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_idea_intake_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-idea-intake.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-idea-intake.service.d drop-in dir: $dropin_dir (fleet-ops#4435)"
        user_unit_changed=1
    fi
}

# fleet-ops#4502: the fleet-loop@ unit was hand-placed control-plane
# machinery (never in the repo systemd/ tree or git history; the sealed-packet
# 2026-08-11 gate-wrapper iteration, superseded by the repo-sourced pi-scout@ /
# pi-intake@ units). Its live unit file, any timer, the gate/fleet-gate binary,
# the fleet-scout-run runner, and the gate-retry.sh wrapper are all gone; only
# the hand-placed drop-in dir ~/.config/systemd/user/fleet-loop@.service.d/
# survived and is invisible to a unit-name-only hunt (fleet-ops#2924 / #1548)
# because the unit no longer exists. The drop-in set
# ExecStart/TimeoutStartSec/SuccessExitStatus for a unit that cannot resolve,
# carrying .bak files too
# (override.conf.bak-pulse-9e531dac8c-20260811,
# override.conf.bak-scouts-loops-pass3-20260811,
# override.conf.bak-loop-scout-backstop-gate-retry-composition-20260813,
# zz-gate-retry.conf.bak-time-audit-20260812). Not new machinery — there is
# no unit to source it — so absorb-into-repo is wrong. Remove the orphaned
# dir; only touch it when this MANIFEST installs into the live user unit dir.
remove_orphaned_fleet_loop_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin_dir="${user_systemd}/fleet-loop@.service.d"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -d "$dropin_dir" ]; then
        rm -rf "$dropin_dir"
        echo "removed orphaned fleet-loop@.service.d drop-in dir: $dropin_dir (fleet-ops#4502)"
        user_unit_changed=1
    fi
}

# fleet-ops#4470: the fleet-litellm-proxy drop-in override.conf was a
# hand-placed real file (not a symlink into the repo systemd/ tree) created
# during the fleet-ops#4181 live install. Its ExecStart clears+re-sets the
# exact wrapper path the base unit now carries (systemd/fleet-litellm-proxy
# #4401), so that half is fully superseded; the only other directive,
# EnvironmentFile=...litellm-master-key.env, is folded into the base unit
# (fleet-ops#4470) so the repo unit is the single source of truth and this
# stray override (invisible to a unit-name-only hunt, fleet-ops#2924 / #1548)
# is deleted. Not new machinery — just a redundant leftover. Remove only the
# override.conf file, never the whole dir: the repo-sourced debug.conf
# symlink must stay. Only touch it when this MANIFEST installs into the
# live user unit dir.
remove_superseded_litellm_proxy_override_dropin() {
    local user_systemd="${HOME}/.config/systemd/user"
    local dropin="${user_systemd}/fleet-litellm-proxy.service.d/override.conf"
    grep -q " ${user_systemd}/" "$manifest" 2>/dev/null || return 0
    if [ -e "$dropin" ] || [ -L "$dropin" ]; then
        rm -f "$dropin"
        echo "removed superseded fleet-litellm-proxy override.conf drop-in: $dropin (fleet-ops#4470)"
        user_unit_changed=1
    fi
}

# fleet-ops#4146: retire the three dead-man canaries (gh-webhook-canary-
# deadman, fleet-completion-canary, fleet-loose-ends-canary). Their units
# and timers are gone from MANIFEST; stop+disable any live leftovers and
# remove the prom files they wrote so the node-exporter textfile dir does
# not keep serving retired series. The gh-webhook-canary producer stays
# (its dead-man is now the FleetGhWebhookCanaryAbsent absent() rule + a
# healthchecks.io ping-on-success).
remove_retired_canaries() {
    local unit p
    for unit in \
        gh-webhook-canary-deadman.service gh-webhook-canary-deadman.timer \
        fleet-completion-canary.service fleet-completion-canary.timer \
        fleet-loose-ends-canary.service fleet-loose-ends-canary.timer
    do
        p="${HOME}/.config/systemd/user/$unit"
        # `-f` is false for a dangling symlink (its target is gone), so the
        # #4182 retire left the unit symlinks on disk: they pointed at
        # systemd/ files deleted from the deploy clone, `-f` skipped them,
        # and the live timers stayed, reddening the timer-manifest drill
        # (fleet-ops#4199). `-e || -L` catches both real files and dangling
        # symlinks.
        if [ -e "$p" ] || [ -L "$p" ]; then
            "$SYSTEMCTL" --user stop "$unit" 2>/dev/null || true
            "$SYSTEMCTL" --user disable "$unit" 2>/dev/null || true
            rm -f "$p"
            echo "retired unit removed: $unit (fleet-ops#4146)"
            user_unit_changed=1
        fi
        # `systemctl --user disable` cannot resolve a dangling unit, so it
        # leaves the timers.target.wants symlink behind. Remove it explicitly
        # so the timer-manifest live check stops seeing the retired timer.
        p="${HOME}/.config/systemd/user/timers.target.wants/$unit"
        if [ -e "$p" ] || [ -L "$p" ]; then
            rm -f "$p"
            echo "retired wants symlink removed: $unit (fleet-ops#4146)"
            user_unit_changed=1
        fi
    done
    # Remove the prom files the retired canaries wrote (deadman metric,
    # fleet_chain_* family). The gh-webhook-canary prom file stays.
    rm -f /var/lib/prometheus/node-exporter/fleet-chains.prom
    # Strip the deadman block from the gh-webhook-canary prom file if a
    # stale copy still carries it.
    if [ -f /var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom ]; then
        sed -i '/fleet_gh_webhook_canary_deadman_paged_total/d; /fleet_gh_webhook_canary_deadman_last_status/d' \
            /var/lib/prometheus/node-exporter/fleet-gh-webhook-canary.prom 2>/dev/null || true
    fi
}

remove_retired_staleness_timer() {
    local unit p
    # fleet-ops#4149: the hand-built weekly truth-staleness timer + its
    # issue-filing service are retired — the TruthStalenessMismatch alert
    # rule (config/fleet_rules.yml) replaced them. Stop/disable/remove the
    # live units on any box that still has them.
    for unit in fleet-truth-staleness-check.timer fleet-truth-staleness-check.service
    do
        p="${HOME}/.config/systemd/user/$unit"
        # `-e || -L` catches real files AND dangling symlinks (fleet-ops#4199).
        if [ -e "$p" ] || [ -L "$p" ]; then
            "$SYSTEMCTL" --user stop "$unit" 2>/dev/null || true
            "$SYSTEMCTL" --user disable "$unit" 2>/dev/null || true
            rm -f "$p"
            echo "retired unit removed: $unit (fleet-ops#4149)"
            user_unit_changed=1
        fi
        p="${HOME}/.config/systemd/user/timers.target.wants/$unit"
        if [ -e "$p" ] || [ -L "$p" ]; then
            rm -f "$p"
            echo "retired wants symlink removed: $unit (fleet-ops#4149)"
            user_unit_changed=1
        fi
    done
    # Wipe backup/retired unit files parked in the user systemd dir
    # (fleet-ops#4149 acceptance: backups are rm'd, not parked). systemd
    # ignores files with unknown suffixes, so any *.bak* / *.retired* at
    # the top level is inert cruft from a retired or mutated mechanism —
    # never a live unit. These are NOT tracked in MANIFEST — they only
    # ever exist on a live box, so a repo grep cannot prove them gone;
    # this function does.
    rm -f "${HOME}"/.config/systemd/user/*.bak* "${HOME}"/.config/systemd/user/*.retired*
}

# fleet-ops#3126 revert: the provider-shim prompt scan landed by #4356 is
# retired. template/extensions/** install as COPIES (fleet-ops#3263) and this
# installer has no generic prune for a copy dropped from MANIFEST, so the live
# module would linger in ~/.pi/agent/extensions after the revert and
# fleet-pi-extensions-canary would scream unproven-wired on every heartbeat
# (already filed once: fleet-ops#4372). Remove it explicitly, same idiom as
# the retired units above.
remove_retired_provider_spawn_guard() {
    local p="${HOME}/.pi/agent/extensions/provider-spawn-guard.ts"
    # `-e || -L` catches real files and dangling symlinks (fleet-ops#4199).
    if [ -e "$p" ] || [ -L "$p" ]; then
        rm -f "$p"
        echo "retired pi extension removed: provider-spawn-guard.ts (fleet-ops#3126 revert)"
    fi
}

# fleet-ops#4825: pin the Devin CLI workspace-trust key in the managed config.
# The vendor error message tells you to set `respect_workspace_trust: false`,
# but the CONFIG field the CLI actually reads is `skip_workspace_trust`. The
# fleet carried the wrong key, so it was silently ignored and the CLI refused
# every workspace ("Refusing to run in an untrusted workspace"), walling the
# devin prepaid seat for ~28h. This merges the CORRECT key into the live
# ~/.config/devin/config.json on every deploy so a devin auto-update that
# re-writes the config (with the misleading key) cannot silently re-break the
# seat. A merge, never an overwrite: the live config carries account fields
# (devin.org_id) the repo must not clobber. Also drops the misleading
# respect_workspace_trust key if present so a future reader is not misled.
ensure_devin_config_trust() {
    local overlay="$here/template/devin-config.json"
    local cfg_dir="${HOME}/.config/devin"
    local cfg="$cfg_dir/config.json"
    [ -f "$overlay" ] || { echo "install.sh: devin config overlay missing: $overlay" >&2; return 0; }
    command -v jq >/dev/null 2>&1 || { echo "install.sh: jq unavailable — devin trust key not pinned (fleet-ops#4825)" >&2; return 0; }
    mkdir -p "$cfg_dir" 2>/dev/null || true
    if [ ! -f "$cfg" ]; then
        # Fresh box: seed with the overlay. devin adds its own fields on run.
        install -D -m 0644 "$overlay" "$cfg" 2>/dev/null \
            && echo "devin config seeded: $cfg (skip_workspace_trust=true, fleet-ops#4825)"
        return 0
    fi
    # Merge the overlay key in and drop the misleading key. Preserve every
    # existing field (deep merge via `*`). A failed jq leaves the live file
    # untouched (tmp + mv).
    local tmp="$cfg.trust.$$.$RANDOM.tmp"
    if jq '. * ($overlay[0]) | del(.respect_workspace_trust)' --slurpfile overlay "$overlay" "$cfg" >"$tmp" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            chmod 0644 "$tmp" 2>/dev/null || true
            if mv -f "$tmp" "$cfg" 2>/dev/null; then
                echo "devin config pinned: skip_workspace_trust=true (fleet-ops#4825)"
            else
                rm -f "$tmp" 2>/dev/null || true
            fi
        else
            rm -f "$tmp" 2>/dev/null || true
        fi
    else
        rm -f "$tmp" 2>/dev/null || true
        echo "install.sh: devin config merge FAILED — live config untouched (fleet-ops#4825)" >&2
    fi
}

# Drift-or-install one entry. `_skip=1` means skip — out of scope for the
# current mode. `_install_user` defaults to ln -s; `install_system` defaults
# to sudo install -D.
#
# fleet-ops#1307: after a prometheus HUP, prove every group in the installed
# fleet_rules.yml is actually loaded via GET /api/v1/rules (PM_RULES_URL;
# file:// allowed for tests). A parse error in one group silently drops it
# from the API while prometheus keeps serving the old rules — the class of
# gap that left a merged alert rule unloaded. Reads the installed file
# (PM_RULES_FILE). Exit 0 = every file group is loaded; exit 1 = proof
# failed, and install.sh --system must be loud.
prove_rules_loaded() {
    local rules_file=$1 url=$2
    python3 - "$rules_file" "$url" <<'PY'
import json, re, sys, urllib.request

rules_file, url = sys.argv[1], sys.argv[2]
try:
    with open(rules_file, encoding="utf-8") as f:
        text = f.read()
except OSError as exc:
    sys.stderr.write(f"install.sh rules-proof: cannot read {rules_file}: {exc}\n")
    sys.exit(1)
expected = sorted(set(g.strip(chr(34) + chr(39)) for g in re.findall(r"(?m)^\s*-\s*name:\s*(\S+)", text)))
if not expected:
    sys.stdout.write(f"install.sh rules-proof: {rules_file} defines no groups; nothing to prove\n")
    sys.exit(0)
try:
    payload = urllib.request.urlopen(url, timeout=5).read().decode("utf-8")
except Exception as exc:
    sys.stderr.write(f"install.sh rules-proof: cannot fetch {url}: {exc}\n")
    sys.exit(1)
try:
    loaded = sorted(set(g["name"] for g in json.loads(payload)["data"]["groups"]))
except (KeyError, TypeError, ValueError) as exc:
    sys.stderr.write(f"install.sh rules-proof: unexpected {url} payload: {exc}\n")
    sys.exit(1)
missing = [g for g in expected if g not in loaded]
if missing:
    sys.stderr.write(f"install.sh rules-proof: FAIL groups not loaded: {missing} (fleet-ops#1307)\n")
    sys.exit(1)
sys.stdout.write(f"install.sh rules-proof: {len(expected)} group(s) loaded: {' '.join(expected)}\n")
sys.exit(0)
PY
}

# Comment-junk check (fleet-ops#156 finding 11): the old MANIFEST parser
# created symlinks named after the second token of a comment line (e.g.
# `# P14: ...` became a symlink called `P14: ...`). This scans the MANIFEST
# for any such line and proves no filesystem entry with that name exists.
check_comment_junk() {
  local src dest check_path
  while read -r src dest || [ -n "$src" ]; do
    [ -z "$src" ] && continue
    # Only whole-line comments (first token starts with '#').
    case "$src" in
      '#'*)
        [ -n "$dest" ] || continue
        if [[ "$dest" == /* ]]; then
          check_path="$dest"
        else
          check_path="$PWD/$dest"
        fi
        if [ -e "$check_path" ] || [ -L "$check_path" ]; then
          echo "DIFF: $check_path (MANIFEST comment line produced a filesystem entry)"
          rc=1
        fi
        ;;
    esac
  done < "$manifest"
}

# fleet-ops#3273: config sprawl. A .bak next to a managed MANIFEST file is a
# leftover copy, not loaded, and it confuses every grep. The manifest check
# must fail if any such .bak (or .bak-*) exists in the same directory.
check_bak_sprawl() {
  local src dest dir base entry
  while read -r src dest || [ -n "$src" ]; do
    [ -z "$src" ] && continue
    # Skip whole-line comments and entries with no destination.
    case "$src" in '#'*) continue ;; esac
    [ -n "$dest" ] || continue

    # Skip system files (under /etc/) since we cannot clean them without sudo
    # and they are managed by the system package manager / admin process.
    case "$dest" in /etc/*) continue ;; esac

    if [[ "$dest" == /* ]]; then
      dir=$(dirname "$dest")
      base=$(basename "$dest")
    else
      dir=$(dirname "$PWD/$dest")
      base=$(basename "$dest")
    fi

    # Look for any file or directory whose name starts with the managed
    # file's basename followed by '.bak'. A glob that matches nothing still
    # yields the literal pattern; the existence test filters it out.
    for entry in "$dir/$base.bak"*; do
      if [ -e "$entry" ] || [ -L "$entry" ]; then
        echo "DIFF: $entry (.bak next to managed MANIFEST file $dest)"
        rc=1
      fi
    done
  done < "$manifest"
}

# fleet-ops#5059: helper symlinks under ~/.local/bin and
# ~/.local/lib/pi-packet whose target no longer exists are dead entries on
# PATH. Live 2026-09-10T21:46-23:50Z: the deploy clone was reset to another
# repo's tree (fleet-ops#5016), every helper symlink into it dangled, and
# ~/.local/bin/unit-escalation-write stayed 127 for ~7.5h — every OnFailure
# escalation (unit-escalation@*.service) died silently because the escalation
# helper itself was the dangling link, so nothing paged the fleet's own
# fail-loud path. The MANIFEST loop above cannot see this class: a retired
# helper is gone from MANIFEST, so no entry names it. --check flags it (so
# fleet-ops-drift's DRIFT-INSTALL louds and auto-files every heartbeat tick)
# and an install removes it, so a retired helper cannot leave a live link
# behind. Same detect->repair loop as the retired-unit sweeps above.
helper_symlink_dirs() {
  if [[ -n "${FLEET_HELPER_SYMLINK_DIRS:-}" ]]; then
    printf '%s\n' "${FLEET_HELPER_SYMLINK_DIRS//:/$'\n'}"
  else
    printf '%s\n' "$HOME/.local/bin" "$HOME/.local/lib/pi-packet"
  fi
}

# A dangling helper symlink: the link does not resolve AND its target path
# names a fleet-ops checkout. Links pointing outside the fleet tree (a vendor
# CLI version link, for example) are out of scope — this class is the link a
# checkout that no longer carries the helper left behind.
dangling_helper_symlinks() {
  local d f link
  while read -r d; do
    case "$d" in '') continue ;; esac
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -L "$f" ] || continue
      [ -e "$f" ] && continue
      link=$(readlink "$f" 2>/dev/null) || continue
      case "$link" in
        *fleet-ops*) printf '%s\n' "$f" ;;
      esac
    done
  done < <(helper_symlink_dirs)
}

check_helper_symlinks() {
  local f link
  while read -r f; do
    case "$f" in '') continue ;; esac
    link=$(readlink "$f" 2>/dev/null || printf '<missing>')
    echo "DIFF: $f -> $link (dangling helper symlink; the checkout that held it is gone, fleet-ops#5059)"
    rc=1
  done < <(dangling_helper_symlinks)
}

remove_dangling_helper_symlinks() {
  local f
  while read -r f; do
    case "$f" in '') continue ;; esac
    rm -f "$f"
    echo "removed dangling helper symlink: $f (fleet-ops#5059)"
  done < <(dangling_helper_symlinks)
}

# fleet-ops#3263: Pi provider extensions (template/extensions/**) are
# installed as file COPIES, not symlinks. A symlink into the deploy-clone
# working tree resolves their relative import `../seat-health.ts` against the
# repo tree, where that sibling does not live -> runtime import failure on
# every extension load (proven: Bun and Node both resolve relative imports
# against the symlink's real path). A copy keeps resolution on the live
# extensions dir, where seat-health.ts lives. Same decoupling the
# seat-caps.json copy gets (fleet-ops#2910).
is_extension_src() { case $1 in template/extensions/*) return 0;; *) return 1;; esac; }

# fleet-ops#3277: resolve npm-pin:<rel> against the installed pi examples dir.
PI_PACKAGE_EXAMPLES="${PI_PACKAGE_EXAMPLES:-/home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples}"

process_entry() {
  local src=$1 dest=$2 skip=$3
  local repo why="" npm_pin=0
  if [[ "$src" == npm-pin:* ]]; then
    npm_pin=1
    local pin_rel="${src#npm-pin:}"
    repo=$(readlink -f "$PI_PACKAGE_EXAMPLES/$pin_rel" 2>/dev/null || true)
    if [[ -z "$repo" || ! -e "$repo" ]]; then
      echo "DIFF: $dest (npm-pin missing: $PI_PACKAGE_EXAMPLES/$pin_rel)"
      rc=1
      return 0
    fi
  else
    repo=$(readlink -f "$here/$src")
  fi

  if [ "$skip" = 1 ]; then return 0; fi

  # fleet-ops#3322: model-candidates.json is a committed seed config (seeded
  # from the Last30Days best-value research doc). Skip both drift and install
  # when the source does not exist yet (fresh checkout, CI) so a missing seed
  # never fails install.sh or drift checks — the audition lane is fail-open.
  if [[ "$src" == config/model-candidates.json && ! -f "$repo" ]]; then
    return 0
  fi

  if [ "$mode" = "--" ]; then
    # Drift detection: symlink to repo OR byte-identical regular file = OK.
    if [ -L "$dest" ]; then
      if [ "$(readlink -f "$dest" 2>/dev/null)" = "$repo" ]; then return 0; fi
    elif [ -f "$dest" ] && content_equivalent "$dest" "$repo" 2>/dev/null; then
      # fleet-ops#4948: accept byte-equal OR semantically-equal JSON for a
      # regular-file copy-install dest. The JSON config files (seat-caps.json,
      # pi-models.json, model-candidates.json) are legitimately re-serialized
      # on the live box (jq merge in seat_caps_merge_unknown_providers / an
      # external writer), so a byte-only compare reports false DRIFT-INSTALL
      # forever even when the semantic config matches the repo. content_
      # equivalent is byte-equal OR jq -S equal; a real structural diff, a
      # non-JSON file, or missing jq still reflect and refuse. Same pattern as
      # the live_newer_than_repo guard (fleet-ops#4894).
      return 0
    fi
    local link
    link=$(readlink -f "$dest" 2>/dev/null || echo '<missing>')
    echo "DIFF: $dest -> $link (want $repo)"
    rc=1
    return 0
  fi

  # Install mode.
  if dest_is_system "$dest"; then
    # System scope: copy via sudo install -D. Symlinks across privilege
    # boundaries are fragile and pointless here — daemon-reload will read
    # the contents directly. install -D creates missing parent dirs.
    if ! sudo -n true 2>/dev/null; then
      echo "install.sh: --system needs passwordless sudo. Run as root, or invoke manually:" >&2
      echo "  sudo install -D -m 0644 -o root -g root $repo $dest" >&2
      rc=1
      return 0
    fi
    if [[ "$src" == systemd/system/* ]] && ! unit_file_matches "$dest" "$repo"; then
        system_unit_changed=1
    fi
    # fleet-ops#1307: prometheus re-reads fleet_rules.yml only on HUP
    # (systemctl reload; ExecReload is kill -HUP), so a changed copy needs a
    # reload + proof, not just the systemd daemon-reload below. Byte-compare
    # BEFORE install: a diff or a first install sets the flag; a
    # byte-identical re-install skips the reload. PM_RULES_FILE overrides
    # the live file path for tests.
    if [[ "$src" == config/fleet_rules.yml ]] && ! cmp -s "${PM_RULES_FILE:-$dest}" "$repo" 2>/dev/null; then
        system_rules_changed=1
    fi
    # fleet-ops#4266: audit rules are loaded at boot by auditd from
    # /etc/audit/rules.d/; apply a change to the RUNNING daemon via
    # augenrules --load (idempotent — regenerates audit.rules + reloads
    # auditd). Only when auditd is actually installed on this box.
    if [[ "$src" == config/audit/rules.d/* ]] && ! cmp -s "$dest" "$repo" 2>/dev/null; then
        system_audit_changed=1
    fi
    sudo install -D -m 0644 -o root -g root "$repo" "$dest"
    echo "installed (system): $dest"
  else
    # User scope: symlink, idempotent. mkdir -p so nested drop-in dirs
    # (e.g. vps-weekly-update.service.d/) exist on first install.
    # seat-caps.json: a stale checkout whose files were just git-checked-out
    # has a *newer* mtime than live, so the #372 mtime guard misses it.
    # Refuse a cap drop unless this file is origin/main's blob (merged
    # reduction via fleet-ops-deploy) or the operator override is set.
    if [[ "$src" == config/seat-caps.json ]]; then
        if seat_caps_is_origin_main_blob "$repo"; then
            :
        elif why=$(seat_caps_would_downgrade "$dest" "$repo"); then
            echo "NONFATAL REFUSE: $dest would lower live seat caps ($why) from $repo (fleet-ops#371)"
            rc=1
            return 0
        elif live_newer_than_repo "$dest" "$repo"; then
            echo "NONFATAL REFUSE: $dest is newer than repo copy $repo and the content differs (will not overwrite live config)"
            file_install_refuse "$dest" "$repo"
            rc=1
            return 0
        fi
    elif [[ "$npm_pin" = 1 ]]; then
        : # dest is a pin to the installed package; always retarget
    elif live_newer_than_repo "$dest" "$repo"; then
        echo "NONFATAL REFUSE: $dest is newer than repo copy $repo and the content differs (will not overwrite live config)"
        file_install_refuse "$dest" "$repo"
        rc=1
        return 0
    fi
    if is_unit_src "$src" && ! unit_file_matches "$dest" "$repo"; then
        user_unit_changed=1
    fi
    if [ "$do_user_install" = 1 ] && is_installable_unit "$src" && unit_has_install "$repo"; then
        to_enable+=("$(basename "$src")")
    fi
    mkdir -p "$(dirname "$dest")"
    # fleet-ops#2910: seat-caps.json is a regular file COPY, not a symlink.
    # A symlink into the deploy-clone working tree means every
    # `git reset --hard origin/main` silently rewrites the live config (the
    # auditor re-applied the hot-patch 34+ times). A copy decouples the live
    # config from the git working tree so only this install step — with its
    # cap-downgrade guard above — can update it. rm -f first so a prior
    # symlink dest is replaced by the copy, not written through.
    # template/extensions/** get the same copy semantics (fleet-ops#3263):
    # the providers import ../seat-health.ts relative to their own file, and
    # a repo-tree symlink would resolve that against a nonexistent sibling.
    # config/pi-models.json is copy-installed too (fleet-ops#3722): live pi
    # model config must not silently change with the git working tree.
    # config/model-candidates.json is copy-installed too (fleet-ops#3322):
    # the audition seed lives in the LIVE state dir next to seat-caps.json.
    if [[ "$src" == config/seat-caps.json ]] || [[ "$src" == config/pi-models.json ]] || [[ "$src" == config/model-candidates.json ]] || is_extension_src "$src"; then
        # fleet-ops#3125/#3262/#3690: when a provider's cap block changes,
        # reset its learned AIMD state so a stale learned cap / bench from the
        # old config never pins a raised declared floor or ceiling. The
        # pre-install dest differs from the repo copy only on a real change
        # (this install step refuses cap downgrades above), so an idempotent
        # `install.sh` run is a no-op. fleet-ops#3690: reset ONLY the
        # providers whose providers.<p> block changed (hashed per-provider),
        # not the whole file — a ram_gb_per_worker / worker_memory edit must
        # not reset AIMD. Each reset provider is seeded at floor/2 with
        # ramp=true so the next tick ramps +1 per probe instead of bursting.
        if [[ "$src" == config/seat-caps.json && -f "$dest" ]] && ! cmp -s "$dest" "$repo"; then
            learned="$HOME/.local/state/pi-packet/learned-caps.json"
            if [[ -f "$learned" ]]; then
                if [[ -f "$here/lib/seat-lib.sh" ]] && command -v jq >/dev/null 2>&1; then
                    # shellcheck source=lib/seat-lib.sh
                    source "$here/lib/seat-lib.sh" 2>/dev/null || true
                    reset_learned_caps_on_provider_change "$dest" "$repo" "$learned" || true
                else
                    # seat-lib.sh or jq unavailable: fall back to the legacy
                    # whole-file reset so a stale learned cap never pins a
                    # raised floor (the pre-#3690 behaviour).
                    mv -f "$learned" "$learned.bak-$(date -u +%Y%m%dT%H%M%SZ)"
                    echo "reset learned-caps.json (seat-caps.json changed; seat-lib.sh unavailable for per-provider reset)"
                fi
            fi
        fi
        # fleet-ops#4205: merge unknown provider rows from the live state
        # file into the repo copy so a hand-wired seat (e.g. runinfra)
        # survives a deploy instead of being silently dropped. The repo
        # stays the source of truth for every provider it declares.
        # Resolve the live file BEFORE rm -f removes the dest symlink.
        # $src is local src=$1 (a string); the heredoc in
        # seat_caps_merge_unknown_providers above corrupts shellcheck 0.11's
        # array-tracking for the rest of this function, so it misreports a
        # plain string as an array. Line 777 uses the same $src in a case
        # at global scope with no warning.
        # shellcheck disable=SC2128
        if [[ "$src" == config/seat-caps.json ]]; then
            seat_caps_merge_unknown_providers "$dest" "$repo" > "$dest.merge.$$"
            rm -f "$dest"
            install -D -m 0644 "$dest.merge.$$" "$dest"
            rm -f "$dest.merge.$$"
        else
            rm -f "$dest"
            install -D -m 0644 "$repo" "$dest"
        fi
    else
        ln -sfn "$repo" "$dest"
    fi
  fi
}

# `while read` silently drops the final line if the file has no trailing
# newline (fleet-ops#1443: fleet-asset-census.timer was never installed
# because MANIFEST ended mid-line). The `|| [ -n "$src" ]` guard catches
# that last unterminated line so every MANIFEST entry is processed.
while read -r src dest || [ -n "$src" ]; do
  [ -z "$src" ] && continue
  # Skip whole-line comment lines (first token is '#' with no leading path).
  case "$src" in '#'*) continue ;; esac

  if dest_is_system "$dest"; then
    if [ "$do_user_install" = 1 ] || [ "$do_user_check" = 1 ]; then
      continue   # out of scope for the default mode
    fi
  else
    if [ "$do_system_install" = 1 ] || [ "$do_system_check" = 1 ]; then
      continue   # out of scope for --system
    fi
  fi
  process_entry "$src" "$dest" 0
done < "$manifest"

if [ "$mode" = "--" ]; then
  check_comment_junk
  check_bak_sprawl
  check_helper_symlinks
  exit "$rc"
fi

if [ "$do_user_install" = 1 ]; then
  remove_papered_heartbeat_dropin
  remove_stale_scout_prom_mode_dropin
  remove_judge_budget_dropins
  remove_canary_start_timeout_dropins
  remove_orphaned_fleet_auto_deploy_dropin
  remove_orphaned_fleet_auto_ship_dropin
  remove_orphaned_fleet_cheap_triage_dropin
  remove_orphaned_fleet_e2e_heartbeat_dropin
  remove_orphaned_fleet_hourly_audit_dropin
  remove_orphaned_fleet_idea_intake_dropin
  remove_orphaned_fleet_loop_dropin
  remove_superseded_litellm_proxy_override_dropin
  remove_retired_canaries
  remove_retired_staleness_timer
  remove_retired_provider_spawn_guard
  remove_dangling_helper_symlinks
  ensure_devin_config_trust
  # Only daemon-reload when a user-scope systemd unit/drop-in actually
  # changed. First install on a fresh box still reloads because every unit
  # is new. Bin/prompt/config changes do not waste a reload.
  if [ "$user_unit_changed" = 1 ]; then
    "$SYSTEMCTL" --user daemon-reload
  fi
  # Enable every non-template, [Install]-carrying unit declared by MANIFEST.
  # .path and .timer are also started with --now; .service is enabled only
  # so its timer/path is the trigger.
  if [ "${#to_enable[@]}" -gt 0 ]; then
    for unit in "${to_enable[@]}"; do
      case "$unit" in
        *.path|*.timer)
          if ! is_unit_enabled "$unit"; then
            "$SYSTEMCTL" --user enable --now "$unit"
            echo "enabled+started: $unit"
          elif ! "$SYSTEMCTL" --user is-active --quiet "$unit" 2>/dev/null; then
            # Enabled but not active/running: a prior enable landed without
            # --now (or the start was lost), so the generic loop above used
            # to skip this unit forever (fleet-ops#2089: staleness timer was
            # enabled but inactive, NextElapse=infinity, never scheduled).
            # `enable --now` on an already-enabled unit starts it; this
            # self-heals the whole enabled-but-inactive class, not just one
            # timer.
            "$SYSTEMCTL" --user enable --now "$unit"
            echo "started: $unit (was enabled but inactive)"
          fi
          ;;
        *.service)
          if ! is_unit_enabled "$unit"; then
            "$SYSTEMCTL" --user enable "$unit"
            echo "enabled: $unit"
          fi
          ;;
      esac
    done
  fi
  # fleet-ops#32: the reconciler was fail-closed on gh label-check errors,
  # so it was stopped/disabled. Once this fixed version is installed, the
  # path unit (fired by intake-repos.json changes) and the 30-minute timer
  # can be safely re-enabled. The loop above already handles these two, but
  # the historical call is kept here as a no-op safety net.
  # fleet-ops#559: skip when the unit file is not in this checkout. A
  # minimal install.sh run (MANIFEST without the unit) must not fail
  # `systemctl enable` on hosted CI. Same guard as the 0509 timer below.
  if [ -f "$here/systemd/intake-reconcile.path" ]; then
    if ! is_unit_enabled intake-reconcile.path; then
      "$SYSTEMCTL" --user enable --now intake-reconcile.path
    fi
  fi
  if [ -f "$here/systemd/intake-reconcile.timer" ]; then
    if ! is_unit_enabled intake-reconcile.timer; then
      "$SYSTEMCTL" --user enable --now intake-reconcile.timer
    fi
  fi
  # fleet-ops#183: the 0509 daily-market-signal timer ships in MANIFEST with
  # [Install], but was never enabled, so the cron never scheduled. Dedicated
  # enable rather than a generic [Install] loop: templates (pi-intake@ /
  # pi-scout@) are instantiated by the reconciler, and siterep-deploy.timer
  # deliberately omits [Install] so it cannot be auto-started.
  if [ -f "$here/systemd/agent-cron-0509-daily-market-signal.timer" ]; then
    if ! is_unit_enabled agent-cron-0509-daily-market-signal.timer; then
      "$SYSTEMCTL" --user enable --now agent-cron-0509-daily-market-signal.timer
    fi
  fi
  # fleet-ops#541: weekly continuous-research sweep. Same #183 class as the
  # 0509 timer: [Install] in MANIFEST is not enough; install.sh must enable.
  if [ -f "$here/systemd/quality-research-weekly.timer" ]; then
    if ! is_unit_enabled quality-research-weekly.timer; then
      "$SYSTEMCTL" --user enable --now quality-research-weekly.timer
    fi
  fi
  # fleet-ops#1146: Weekly Fleet Review — Sun 04:30 IST, post-vps-weekly-update.
  # Blind 6-lens senior research + conference, output capped at 5 specced
  # actions. Same install-sh enable as #541.
  if [ -f "$here/systemd/fleet-weekly-fleet-review.timer" ]; then
    if ! is_unit_enabled fleet-weekly-fleet-review.timer; then
      "$SYSTEMCTL" --user enable --now fleet-weekly-fleet-review.timer
    fi
  fi
  # fleet-ops#1236: weekly AEO visibility probe — Sun 03:30 IST, before WFR.
  # Same install-sh enable as #541 / #1146 (MANIFEST [Install] is not enough).
  if [ -f "$here/systemd/fleet-aeo-probe.timer" ]; then
    if ! is_unit_enabled fleet-aeo-probe.timer; then
      "$SYSTEMCTL" --user enable --now fleet-aeo-probe.timer
    fi
  fi
  # fleet-ops#1151: weekly baseline-delta pre-pass. Same #183 class.
  if [ -f "$here/systemd/fleet-baseline-delta.timer" ]; then
    if ! is_unit_enabled fleet-baseline-delta.timer; then
      "$SYSTEMCTL" --user enable --now fleet-baseline-delta.timer
    fi
  fi
elif [ "$do_system_install" = 1 ]; then
  # daemon-reload needs to happen at system scope; we are still in the user
  # session, so it must go through sudo.
  if [ "$system_unit_changed" = 1 ]; then
    sudo systemctl daemon-reload
  fi
  # fleet-ops#1307: install -D does not HUP prometheus (ExecReload is
  # kill -HUP), so a changed fleet_rules.yml would sit unloaded until the
  # next restart. Reload only when the file bytes actually changed, then
  # prove every group in the installed file appears in GET /api/v1/rules —
  # a group that fails to parse never loads, and Prometheus keeps serving
  # the old rules.
  if [ "$system_rules_changed" = 1 ]; then
    if sudo systemctl is-active --quiet prometheus 2>/dev/null; then
      if ! sudo systemctl reload prometheus; then
        echo "install.sh: prometheus reload failed after fleet_rules.yml change (fleet-ops#1307)" >&2
        rc=1
      elif ! prove_rules_loaded "${PM_RULES_FILE:-/etc/prometheus/fleet_rules.yml}" \
                                "${PM_RULES_URL:-http://127.0.0.1:9090/api/v1/rules}"; then
        echo "install.sh: rules proof failed — new fleet_rules.yml groups not all loaded (fleet-ops#1307)" >&2
        rc=1
      fi
    else
      echo "install.sh: prometheus not active — skipped reload + rules proof (fleet-ops#1307)" >&2
    fi
  fi
  # fleet-ops#1160: vps-post-reboot-verify.timer is system-scope (the
  # service it triggers is system-scope too). Install --system does not
  # auto-enable system units (is_installable_unit excludes systemd/system/*),
  # so enable it here — same class as the user timer --now enables above.
  if [ -f "$here/systemd/system/vps-post-reboot-verify.timer" ]; then
    if ! sudo systemctl is-enabled vps-post-reboot-verify.timer 2>/dev/null; then
      sudo systemctl enable --now vps-post-reboot-verify.timer \
        || { echo "install.sh: failed to enable vps-post-reboot-verify.timer" >&2; rc=1; }
      echo "enabled+started: vps-post-reboot-verify.timer (system)"
    elif ! sudo systemctl is-active --quiet vps-post-reboot-verify.timer 2>/dev/null; then
      sudo systemctl start vps-post-reboot-verify.timer \
        || { echo "install.sh: failed to start vps-post-reboot-verify.timer" >&2; rc=1; }
      echo "started: vps-post-reboot-verify.timer (system, was enabled but inactive)"
    fi
  fi
  # fleet-ops#4266: a changed audit rules.d file needs augenrules --load to
  # reach the RUNNING auditd (the rules.d file alone only takes effect at
  # boot). auditd absent = note only (the package install is the bare-metal
  # manifest / vps-weekly-update concern).
  if [ "$system_audit_changed" = 1 ]; then
    if sudo systemctl is-active --quiet auditd 2>/dev/null; then
      if ! sudo augenrules --load >/dev/null 2>&1; then
        echo "install.sh: augenrules --load failed after audit rules change (fleet-ops#4266)" >&2
        rc=1
      else
        echo "install.sh: audit rules loaded (fleet-ops#4266)"
      fi
    else
      echo "install.sh: auditd not active — audit rules file installed, will load at boot (fleet-ops#4266)" >&2
    fi
  fi
fi
exit "$rc"
