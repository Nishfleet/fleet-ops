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
#   --check --system     — drift detection for system-scope entries only.
#                          Useful for "is this box up to date?" without
#                          changing anything.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; rc=0
manifest="$here/MANIFEST"
# Tests inject a stub via SYSTEMCTL= (fleet-ops#290). Live installs leave this unset.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

mode=""
check_system=0
user_unit_changed=0
system_unit_changed=0
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

if [ "$mode" != "--" ]; then
  refuse_noncanonical_install
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

# Returns 0 if dest exists and its live target is a different file whose
# mtime is newer than the repo copy AND whose content differs from the repo
# copy. A newer, byte-identical file is not a hot-patch; it is only newer
# because it has already been installed (#463). Re-sync its mtime so the
# guard does not re-check, then allow the normal install to proceed.
live_newer_than_repo() {
    local dest=$1 repo=$2
    local live live_m repo_m
    live=$(live_target_file "$dest")
    [ -n "$live" ] && [ -e "$live" ] || return 1
    [ "$live" = "$repo" ] && return 1
    live_m=$(stat -c %Y "$live" 2>/dev/null || echo 0)
    repo_m=$(stat -c %Y "$repo" 2>/dev/null || echo 0)
    [ "$live_m" -gt "$repo_m" ] || return 1
    if cmp -s "$live" "$repo" 2>/dev/null; then
        # Byte-identical: re-sync mtime to the repo copy and do not refuse.
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

# Drift-or-install one entry. `_skip=1` means skip — out of scope for the
# current mode. `_install_user` defaults to ln -s; `install_system` defaults
# to sudo install -D.
#
# Comment-junk check (fleet-ops#156 finding 11): the old MANIFEST parser
# created symlinks named after the second token of a comment line (e.g.
# `# P14: ...` became a symlink called `P14: ...`). This scans the MANIFEST
# for any such line and proves no filesystem entry with that name exists.
check_comment_junk() {
  local src dest check_path
  while read -r src dest; do
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

process_entry() {
  local src=$1 dest=$2 skip=$3
  local repo why=""
  repo=$(readlink -f "$here/$src")

  if [ "$skip" = 1 ]; then return 0; fi

  if [ "$mode" = "--" ]; then
    # Drift detection: symlink to repo OR byte-identical regular file = OK.
    if [ -L "$dest" ]; then
      if [ "$(readlink -f "$dest" 2>/dev/null)" = "$repo" ]; then return 0; fi
    elif [ -f "$dest" ] && cmp -s "$dest" "$repo" 2>/dev/null; then
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
            echo "REFUSE: $dest would lower live seat caps ($why) from $repo (fleet-ops#371)"
            rc=1
            return 0
        elif live_newer_than_repo "$dest" "$repo"; then
            echo "REFUSE: $dest is newer than repo copy $repo and the content differs (will not overwrite live config)"
            file_install_refuse "$dest" "$repo"
            rc=1
            return 0
        fi
    elif live_newer_than_repo "$dest" "$repo"; then
        echo "REFUSE: $dest is newer than repo copy $repo and the content differs (will not overwrite live config)"
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
    ln -sfn "$repo" "$dest"
  fi
}

while read -r src dest; do
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
  exit "$rc"
fi

if [ "$do_user_install" = 1 ]; then
  remove_papered_heartbeat_dropin
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
elif [ "$do_system_install" = 1 ]; then
  # daemon-reload needs to happen at system scope; we are still in the user
  # session, so it must go through sudo.
  if [ "$system_unit_changed" = 1 ]; then
    sudo systemctl daemon-reload
  fi
fi
exit "$rc"
