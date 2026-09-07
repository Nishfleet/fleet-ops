#!/usr/bin/env bash
# spawn-guard-core.sh — below-the-agent spawn guard (fleet-ops#3126)
#
# The Pi extension spawn-guard-core.ts only sees Pi's OWN bash tool calls.
# devin/cursor provider CLIs (spawned by template/extensions/{devin,cursor}-
# provider/index.ts with --permission-mode dangerous / --force --trust) run
# their OWN agent with their OWN tools, so Pi never sees a bash call and the
# extension rules never run (proven live 2026-08-25: a real `git stash push`
# on the devin seat ran with no SPAWN_BLOCKED). This bash engine is the
# below-the-agent guard: it rides along inside the vendor's processes via
# PATH shims + a BASH_ENV DEBUG trap, mirroring the SAME rule set as the
# extension so a block means the same thing wherever it fires.
#
# Rule parity contract: every rule below MUST mirror template/extensions/
# spawn-guard-core.ts DANGEROUS_RULES + WRANGLER_DEPLOY_0509 + the depth and
# ceiling gates. If you add a rule to one, add it to both.
#
# Sourced by:
#   libexec/spawn-guard-env.sh   (BASH_ENV payload — per-bash-session trap)
#   libexec/spawn-guard-bin/*    (PATH shims — argv validation)
#   bin/fleet-spawn-guard        (status + hermetic probe)
#   bin/pi-issue-run  bin/pi-packet-run  bin/pi-audit-run
#   bin/fleet-heartbeat-tier2    (seat activation for shim providers)
#
# Safety: this file is sourced ONLY by guarded shells/shims; it defines
# functions and exports defaults, it does not run anything dangerous.

# --- defaults (mirror spawn-guard-core.ts) -----------------------------------
FLEET_SPEC_MAX_DEPTH_DEFAULT=1
FLEET_SLICE_TASKS_MAX_DEFAULT=8000
FLEET_SPAWN_SOFT_CEILING_DEFAULT=7500
SPAWN_BLOCK_LOG_DEFAULT="/home/nish/workspaces/agent-state/spawn-blocks.log"
# Ceiling re-check cache seconds per shell (a systemctl call per command is
# too hot; once per 60s per shell is the same signal at the TS layer's scale).
SPAWN_GUARD_CEILING_CACHE_S_DEFAULT=60
# Providers whose CLI runs its own agent tools (shim-class). The runners arm
# the guard exactly for these; native seats stay byte-identical.
FLEET_SHIM_PROVIDERS_DEFAULT="devin cursor"

spawn_guard_block_log_file() {
    printf '%s' "${FLEET_SPAWN_GUARD_LOG:-${SPAWN_BLOCK_LOG:-$SPAWN_BLOCK_LOG_DEFAULT}}"
}

spawn_guard_shim_providers() {
    printf '%s' "${FLEET_SHIM_PROVIDERS:-$FLEET_SHIM_PROVIDERS_DEFAULT}"
}

spawn_guard_is_shim_provider() {
    local p="$1" sp
    # shellcheck disable=SC2086
    for sp in $(spawn_guard_shim_providers); do
        [[ "$sp" == "$p" ]] && return 0
    done
    return 1
}

# Resolve the guard's own install paths. Order: env seams (tests + operator
# override) -> installed (MANIFEST: ~/.local/lib/pi-packet) -> repo checkout
# (dev / CI hosted tests, pre-install).
spawn_guard_core_file() {
    if [[ -n "${FLEET_SPAWN_GUARD_CORE:-}" ]]; then printf '%s' "$FLEET_SPAWN_GUARD_CORE"; return 0; fi
    if [[ -f "$HOME/.local/lib/pi-packet/spawn-guard-core.sh" ]]; then
        printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-core.sh"; return 0
    fi
    local _root
    if _root=$(spawn_guard_repo_root); then
        printf '%s' "$_root/lib/spawn-guard-core.sh"; return 0
    fi
    printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-core.sh"
}

spawn_guard_env_file() {
    if [[ -n "${FLEET_SPAWN_GUARD_ENV:-}" ]]; then printf '%s' "$FLEET_SPAWN_GUARD_ENV"; return 0; fi
    if [[ -f "$HOME/.local/lib/pi-packet/spawn-guard-env.sh" ]]; then
        printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-env.sh"; return 0
    fi
    local _root
    if _root=$(spawn_guard_repo_root); then
        printf '%s' "$_root/libexec/spawn-guard-env.sh"; return 0
    fi
    printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-env.sh"
}

spawn_guard_bin_dir() {
    if [[ -n "${FLEET_SPAWN_GUARD_BIN:-}" ]]; then printf '%s' "$FLEET_SPAWN_GUARD_BIN"; return 0; fi
    if [[ -d "$HOME/.local/lib/pi-packet/spawn-guard-bin" ]]; then
        printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-bin"; return 0
    fi
    local _root
    if _root=$(spawn_guard_repo_root); then
        printf '%s' "$_root/libexec/spawn-guard-bin"; return 0
    fi
    printf '%s' "$HOME/.local/lib/pi-packet/spawn-guard-bin"
}

# repo root for the checkout the SOURCING file was delivered from. When this
# core is the installed copy there is no repo, so the first -f test above
# wins before we ever get here.
spawn_guard_repo_root() {
    local _self _dir
    _self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null) || return 1
    _dir=$(dirname "$_self")
    # lib/spawn-guard-core.sh -> repo root; libexec/... -> repo root too
    local _cand
    for _cand in "$_dir/.." "$_dir/../.."; do
        if [[ -f "$_cand/lib/spawn-guard-core.sh" && -d "$_cand/bin" && -d "$_cand/libexec" ]]; then
            printf '%s' "$(cd "$_cand" && pwd)"
            return 0
        fi
    done
    return 1
}

# --- rule engine (mirror template/extensions/spawn-guard-core.ts) ------------
# ERE patterns live in variables: bash's [[ =~ ]] parser mis-parses `;`/`&`
# inside inline character classes, so the standard fix is an unquoted variable
# reference (regex semantics preserved). JS lookaheads are two-step tests.
SG_RE_GIT_STASH='(^|[^[:alnum:]_])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+stash([^[:alnum:]_]|$)'
SG_RE_GIT_STASH_READ='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+stash[[:space:]]+(list|show)([^[:alnum:]_]|$)'
SG_RE_SYSTEMCTL_SLICE='systemctl[[:space:]]+restart[^;|&]*\.slice([^[:alnum:]_]|$)'
SG_RE_SYSTEMCTL_FLEET='systemctl[[:space:]]+restart[^;|&]*(fleet-|implementation-worker-)'
SG_RE_CRED_WRITE='(>>?|tee[[:space:]]+)[^;|&]*(fleet2/etc/|/\.env([^[:alnum:]_]|$)|auth\.json([^[:alnum:]_]|$))'
SG_RE_RM_RF='(^|[^[:alnum:]_])rm[[:space:]]+(-[^[:space:]]*f[^[:space:]]*[[:space:]]+|-rf[[:space:]]+)[^;|&]*(/home/nish([^[:alnum:]_]|$)|workspaces/)'
SG_RE_SUDO_TOOL='sudo[^;|&]*[[:space:]](install|cp|mv|ln|dd|tee)([[:space:]]|>)'
SG_RE_SUDO_PROTECTED='sudo[^;|&]*(/home/nish/\.local/bin|/home/nish/\.local/lib/node_modules|/home/nish/\.pi|/etc/systemd)'
SG_RE_SUDO_DEVNULL='sudo[^;|&]*[[:space:]](install|cp|mv|ln|dd)([[:space:]]|>)'
SG_RE_SUDO_DEVNULL_HOME='sudo[^;|&]*/dev/null[^;|&]*/home/nish'
SG_RE_WRANGLER='(wrangler[[:space:]]+(deploy|versions[[:space:]]+upload)|npm[[:space:]]+run[[:space:]]+deploy|node[[:space:]]+scripts/deploy-production\.mjs)'
SG_RE_SPEC_AUTHOR='(^|[^[:alnum:]_'"'=])(/home/nish/\.local/bin/)?fleet-spec-author([^[:alnum:]_'"'=]|$)'

# Each rule is a bash-extended-regex test over the command string and prints
# the rule id (or nothing when the command is allowed).
spawn_guard_rule_git_stash() {
    local c="$1"
    [[ "$c" =~ $SG_RE_GIT_STASH ]] || return 1
    # read-only forms stay allowed (fleet-ops#754)
    [[ "$c" =~ $SG_RE_GIT_STASH_READ ]] && return 1
    printf '%s' "git_stash_forbidden"
    return 0
}

spawn_guard_rule_systemctl_restart() {
    local c="$1"
    if [[ "$c" =~ $SG_RE_SYSTEMCTL_SLICE ]]; then
        printf '%s' "systemctl_restart_slice"; return 0
    fi
    if [[ "$c" =~ $SG_RE_SYSTEMCTL_FLEET ]]; then
        printf '%s' "systemctl_restart_fleet_unit"; return 0
    fi
    return 1
}

spawn_guard_rule_credential_write() {
    local c="$1"
    [[ "$c" =~ $SG_RE_CRED_WRITE ]] || return 1
    printf '%s' "credential_path_write"; return 0
}

spawn_guard_rule_rm_rf() {
    local c="$1"
    [[ "$c" =~ $SG_RE_RM_RF ]] || return 1
    printf '%s' "rm_rf_home_or_workspaces"; return 0
}

spawn_guard_rule_sudo_write() {
    local c="$1"
    if [[ "$c" =~ $SG_RE_SUDO_TOOL ]] && [[ "$c" =~ $SG_RE_SUDO_PROTECTED ]]; then
        printf '%s' "sudo_write_protected_path"; return 0
    fi
    if [[ "$c" =~ $SG_RE_SUDO_DEVNULL ]] && [[ "$c" =~ $SG_RE_SUDO_DEVNULL_HOME ]]; then
        printf '%s' "sudo_devnull_into_home"; return 0
    fi
    return 1
}

# 0509 prod deploy (P10-B item 4): CI is the only sanctioned deploy path.
# Mirrors the extension's cwd+command gating; in the below-agent layer $PWD
# is accurate even after `cd` inside the session.
spawn_guard_rule_wrangler_deploy() {
    local c="$1" cwd="${2:-${PWD:-}}"
    [[ "$c" =~ $SG_RE_WRANGLER ]] || return 1
    if [[ "${FLEET_BREAKGLASS_DEPLOY_0509:-0}" == "1" ]]; then return 1; fi
    if [[ "$cwd" == *0509* || "$c" == *0509* ]]; then
        printf '%s' "wrangler_deploy_0509"; return 0
    fi
    return 1
}

# Spec-gate re-entry (depth limit 1): a session spawned by the gate must not
# re-spawn the gate. Mirrors evaluateBashToolCall's SPEC_AUTHOR check.
spawn_guard_rule_spec_reentry() {
    local c="$1" depth
    depth="${FLEET_SPEC_DEPTH:-${FLEET_SPAWN_DEPTH:-0}}"
    [[ "$depth" =~ ^[0-9]+$ ]] || depth=0
    if (( depth >= ${FLEET_SPEC_MAX_DEPTH:-$FLEET_SPEC_MAX_DEPTH_DEFAULT} )) \
        && [[ "$c" =~ $SG_RE_SPEC_AUTHOR ]]; then
        printf '%s' "spec_gate_reentry depth=$depth max=${FLEET_SPEC_MAX_DEPTH:-$FLEET_SPEC_MAX_DEPTH_DEFAULT}"
        return 0
    fi
    return 1
}

# Full command-line verdict. Prints the reason id (possibly with details) or
# nothing when the command is allowed.
spawn_guard_check_command() {
    local c="$1" cwd="${2:-${PWD:-}}" r
    # normalize newlines/tabs so multi-line commands match like the TS layer
    c="${c//$'\n'/ }"; c="${c//$'\t'/ }"
    if r=$(spawn_guard_rule_git_stash "$c"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_systemctl_restart "$c"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_credential_write "$c"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_rm_rf "$c"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_sudo_write "$c"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_wrangler_deploy "$c" "$cwd"); then printf '%s' "$r"; return 0; fi
    if r=$(spawn_guard_rule_spec_reentry "$c"); then printf '%s' "$r"; return 0; fi
    return 0
}

# --- block + log (mirror the TS blocked()/logBlock() shape) -------------------
# Row format: <iso-ts>\t<reason>\t<cwd>\t<cmd> — the SAME log the extension
# appends to, so one canonical spawn-blocks.log holds every blocked spawn
# regardless of which layer fired.
spawn_guard_log_block() {
    local reason="$1" cmd="$2" cwd="${3:-${PWD:-}}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cmd="${cmd:0:500}"
    cmd="${cmd//$'\n'/\\n}"
    cwd="${cwd//$'\t'/ }"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$reason" "$cwd" "$cmd" \
        >> "$(spawn_guard_block_log_file)" 2>/dev/null || true
}

# Writes the canonical SPAWN_BLOCKED stderr line (same as the TS layer) and
# returns 2, the exit code the vendor sees.
spawn_guard_block() {
    local reason="$1" cmd="$2" cwd="${3:-${PWD:-}}"
    spawn_guard_log_block "$reason" "$cmd" "$cwd"
    printf 'SPAWN_BLOCKED reason=%s\n' "$reason" >&2
    return 2
}

# --- process ceiling (mirror fleetTasksCurrent gate in the extension) ---------
# Best-effort: when user systemd is unreachable (CI, hosted tests) the check
# passes. Cached 60s per shell.
spawn_guard_ceiling_verdict() {
    local now tasks soft max
    if [[ -n "${__fleet_sg_ceiling_ts:-}" ]]; then
        now=$(date +%s)
        if (( now - __fleet_sg_ceiling_ts < ${SPAWN_GUARD_CEILING_CACHE_S:-$SPAWN_GUARD_CEILING_CACHE_S_DEFAULT} )); then
            printf '%s' "${__fleet_sg_ceiling_verdict:-}"
            return 0
        fi
    fi
    soft="${FLEET_SPAWN_SOFT_CEILING:-$FLEET_SPAWN_SOFT_CEILING_DEFAULT}"
    max="${FLEET_SLICE_TASKS_MAX:-$FLEET_SLICE_TASKS_MAX_DEFAULT}"
    tasks=$(systemctl --user show fleet-work.slice -p TasksCurrent --value 2>/dev/null | tr -d '[:space:]')
    if [[ "$tasks" =~ ^[0-9]+$ ]] && (( tasks >= soft )); then
        __fleet_sg_ceiling_verdict="process_ceiling tasks=$tasks soft=$soft slice_max=$max"
    else
        __fleet_sg_ceiling_verdict=""
    fi
    __fleet_sg_ceiling_ts=$(date +%s)
    printf '%s' "${__fleet_sg_ceiling_verdict:-}"
    return 0
}

# --- DEBUG trap (bash sessions) -----------------------------------------------
# Installed by the BASH_ENV payload into every non-interactive bash under an
# armed seat: fires before EVERY command (including commands bash would
# resolve off PATH, so absolute paths cannot walk around the shims).
spawn_guard_debug_trap() {
    [[ -n "${__fleet_sg_in_trap:-}" ]] && return 0
    __fleet_sg_in_trap=1
    local cmd="${BASH_COMMAND:-}" reason
    reason=$(spawn_guard_check_command "$cmd" "$PWD")
    if [[ -n "$reason" ]]; then
        spawn_guard_block "$reason" "$cmd" "$PWD"
        __fleet_sg_in_trap=0
        exit 2
    fi
    reason=$(spawn_guard_ceiling_verdict)
    if [[ -n "$reason" ]]; then
        spawn_guard_block "$reason" "$cmd" "$PWD"
        __fleet_sg_in_trap=0
        exit 2
    fi
    __fleet_sg_in_trap=0
    return 0
}

spawn_guard_env_install() {
    # Only the real bash stdin/script path; DEBUG is bash-only. dash (sh)
    # sessions are covered by the PATH shims instead.
    [[ -n "${BASH_VERSION:-}" ]] || return 0
    [[ "${FLEET_SPAWN_GUARD:-0}" == "1" ]] || return 0
    [[ -n "${__fleet_sg_env_installed:-}" ]] && return 0
    __fleet_sg_env_installed=1
    trap 'spawn_guard_debug_trap' DEBUG
    return 0
}

# --- activation (runner-facing) ------------------------------------------------
# Arms the guard for a shim-class provider seat: PATH shims first, BASH_ENV
# for every non-interactive bash the vendor spawns (absolute `/bin/bash`
# included), FLEET_SPAWN_GUARD=1 as the armed marker. Deactivates when the
# seat is native so those lanes stay byte-identical to today.
spawn_guard_activate() {
    local provider="$1"
    local guard_bin guard_env
    guard_bin=$(spawn_guard_bin_dir)
    guard_env=$(spawn_guard_env_file)
    if spawn_guard_is_shim_provider "$provider" && [[ -d "$guard_bin" ]]; then
        case ":$PATH:" in
            *":$guard_bin:"*) ;;
            *) PATH="$guard_bin:$PATH" ;;
        esac
        export PATH
        export FLEET_SPAWN_GUARD=1
        export BASH_ENV="$guard_env"
        export FLEET_SPAWN_GUARD_ENV="$guard_env"
        export FLEET_SPAWN_GUARD_BIN="$guard_bin"
        export FLEET_SPAWN_GUARD_CORE="$(spawn_guard_core_file)"
        return 0
    fi
    # native seat — restore byte-identical env
    spawn_guard_deactivate
    return 0
}

spawn_guard_deactivate() {
    local guard_bin out=() p
    guard_bin=$(spawn_guard_bin_dir)
    if [[ -n "$guard_bin" && -n "${PATH:-}" ]]; then
        local i
        IFS=: read -r -a _sg_old_path <<< "${PATH:-}"
        for (( i = 0; i < ${#_sg_old_path[@]}; i++ )); do
            p="${_sg_old_path[$i]}"
            [[ -n "$p" && "$p" != "$guard_bin" ]] && out+=("$p")
        done
        if (( ${#out[@]} > 0 )); then
            PATH=$(IFS=:; printf '%s' "${out[*]}")
            export PATH
        fi
    fi
    unset BASH_ENV FLEET_SPAWN_GUARD FLEET_SPAWN_GUARD_ENV FLEET_SPAWN_GUARD_BIN FLEET_SPAWN_GUARD_CORE
    return 0
}