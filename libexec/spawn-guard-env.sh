#!/usr/bin/env bash
# spawn-guard-env.sh — BASH_ENV payload for armed (shim-class) seats
# (fleet-ops#3126)
#
# Sourced by EVERY non-interactive bash the vendor spawns under an armed
# seat (the runner exports BASH_ENV=$this_file; the bash PATH shim does the
# same as belt-and-suspenders). The payload installs a DEBUG trap over
# $BASH_COMMAND so that even an absolute-path `/bin/bash` inside the vendor
# gets the guard: bash reads BASH_ENV regardless of how it was started.
#
# When the guard is NOT armed (FLEET_SPAWN_GUARD != 1) this file does
# nothing, so native seats stay byte-identical. dash (`sh`) ignores
# BASH_ENV and has no DEBUG trap; dash sessions are covered by the PATH
# shims on the dangerous tools instead.
#
# Must be bash-tolerant of being sourced at depth 0 (BASH_ENV is sourced,
# not executed, so `return` is legal, but we use an if-block anyway).
if [[ "${FLEET_SPAWN_GUARD:-0}" != "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

_core="${FLEET_SPAWN_GUARD_CORE:-$HOME/.local/lib/pi-packet/spawn-guard-core.sh}"
if [[ ! -f "$_core" ]]; then
    # repo fallback (pre-install / CI hosted tests)
    _cand="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
    _cand="${_cand%/libexec}"
    [[ -f "$_cand/lib/spawn-guard-core.sh" ]] && _core="$_cand/lib/spawn-guard-core.sh"
fi
if [[ -f "$_core" ]]; then
    # shellcheck disable=SC1090
    . "$_core"
    spawn_guard_env_install
fi
unset _core _cand
return 0 2>/dev/null || exit 0