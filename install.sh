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

mode=""
check_system=0
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

# Returns 0 if the destination is under /etc/, 1 otherwise. Used to route
# each MANIFEST line to the user/system handler.
dest_is_system() { case "$1" in /etc/*) return 0;; *) return 1;; esac; }

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
  local repo
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
    sudo install -D -m 0644 -o root -g root "$repo" "$dest"
    echo "installed (system): $dest"
  else
    # User scope: symlink, idempotent. mkdir -p so nested drop-in dirs
    # (e.g. vps-weekly-update.service.d/) exist on first install.
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
  systemctl --user daemon-reload
  # fleet-ops#32: the reconciler was fail-closed on gh label-check errors,
  # so it was stopped/disabled. Once this fixed version is installed, the
  # path unit (fired by intake-repos.json changes) and the 30-minute timer
  # can be safely re-enabled.
  systemctl --user enable intake-reconcile.path
  systemctl --user enable --now intake-reconcile.timer
elif [ "$do_system_install" = 1 ]; then
  # daemon-reload needs to happen at system scope; we are still in the user
  # session, so it must go through sudo.
  sudo systemctl daemon-reload
fi
exit "$rc"
