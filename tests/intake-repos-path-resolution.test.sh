#!/usr/bin/env bash
# tests/intake-repos-path-resolution.test.sh
#
# Locks the RESOLUTION ORDER of _intake_repos_path() in lib/seat-lib.sh.
#
# The 2026-09-08 fault this pins (fleet-ops#4450 follow-up): the resolver
# probed "$HOME/workspaces/products/fleet-ops/config/intake-repos.json"
# FIRST. On the VPS that mirror is a stale checkout (4f7d0e3e, 2026-09-04)
# that predates the `product` flag #4450 added, while the live deploy
# checkout (fleet-ops-deploy-clone) carries it. The stale sibling therefore
# SHADOWED the deployed config and REPO_PRODUCT_MAP loaded empty:
#
#   repo_is_product 0509            -> false
#   work_supply_label_budget 0509   -> 8 (floor) against a measured drain
#                                      of 11.5 issues/h, so the scout only
#                                      ever filed 8 labels per run
#   product_only seats              -> skipped for every packet
#
# The invariant: a stale sibling checkout can never shadow the config that
# ships beside the running code, or the checkout the deploy lane maintains.
#
# Set SEAT_LIB_UNDER_TEST to point at another copy of seat-lib.sh (used to
# demonstrate the pre-fix failure).

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
seat_lib="${SEAT_LIB_UNDER_TEST:-$repo_root/lib/seat-lib.sh}"
[[ -f "$seat_lib" ]] || { echo "FAIL: seat-lib not found: $seat_lib"; exit 1; }
# P3b (fleet-ops#4263): seat-lib.sh is now a forwarder that sources
# litellm-seat.sh from its own directory. Copy both so the forwarder resolves.
litellm_seat_lib="$(dirname "$seat_lib")/litellm-seat.sh"
[[ -f "$litellm_seat_lib" ]] || { echo "FAIL: litellm-seat.sh not found: $litellm_seat_lib"; exit 1; }

fails=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

labels='["agent-ready","agent-in-progress","agent-blocked"]'
stale="{\"checkout_root\":\"/x\",\"required_labels\":$labels,\"repos\":[{\"name\":\"0509\"},{\"name\":\"fleet-ops\"}]}"
fresh="{\"checkout_root\":\"/x\",\"required_labels\":$labels,\"repos\":[{\"name\":\"0509\",\"product\":true},{\"name\":\"fleet-ops\"}]}"

home="$tmp/home"
mkdir -p "$home/workspaces/products/fleet-ops/config" \
         "$home/workspaces/tooling/fleet-ops/config" \
         "$home/deploy-clone/config" \
         "$home/.local/lib/pi-packet" \
         "$tmp/checkout/lib" "$tmp/checkout/config"

# Both legacy sibling mirrors are STALE (no product flag) — the live fault.
printf '%s' "$stale" > "$home/workspaces/products/fleet-ops/config/intake-repos.json"
printf '%s' "$stale" > "$home/workspaces/tooling/fleet-ops/config/intake-repos.json"
# The deploy checkout carries the flag.
printf '%s' "$fresh" > "$home/deploy-clone/config/intake-repos.json"

# probe <lib path> [VAR=value ...]
# The env assignments go through `env` deliberately: a bash function-prefix
# assignment (VAR=x probe ...) is a shell variable, not an exported one, so
# the child `bash -c` below would never see it and every override case would
# silently pass for the wrong reason.
probe() {
  local lib="$1"; shift
  env "$@" bash -c '
    source "$1" >/dev/null 2>&1 || exit 9
    p=$(_intake_repos_path 2>/dev/null) || p=NONE
    if repo_is_product 0509 2>/dev/null; then s=PRODUCT; else s=not-product; fi
    printf "%s|%s\n" "$p" "$s"
  ' _ "$lib"
}

# --- case 1: installed lib (no co-located config) must reach the deploy
# checkout, not the stale sibling mirror. This is the live topology:
# ~/.local/lib/pi-packet/seat-lib.sh has no ../config.
cp "$seat_lib" "$home/.local/lib/pi-packet/seat-lib.sh"
cp "$litellm_seat_lib" "$home/.local/lib/pi-packet/litellm-seat.sh"
out=$(probe "$home/.local/lib/pi-packet/seat-lib.sh" \
        HOME="$home" FLEET_OPS_CHECKOUT="$home/deploy-clone" FLEET_INTAKE_REPOS_JSON=)
case "$out" in
  "$home/deploy-clone/config/intake-repos.json|PRODUCT")
    ok "installed lib resolves the deploy checkout; 0509 is PRODUCT" ;;
  *"products/fleet-ops"*)
    fail "stale products/fleet-ops mirror shadowed the deploy config (got: $out)" ;;
  *)
    fail "unexpected resolution for installed lib (got: $out)" ;;
esac

# --- case 2: a lib inside a checkout must read that checkout's own config,
# even when a stale sibling mirror exists and no FLEET_OPS_CHECKOUT is set.
cp "$seat_lib" "$tmp/checkout/lib/seat-lib.sh"
cp "$litellm_seat_lib" "$tmp/checkout/lib/litellm-seat.sh"
printf '%s' "$fresh" > "$tmp/checkout/config/intake-repos.json"
out=$(probe "$tmp/checkout/lib/seat-lib.sh" HOME="$home" FLEET_INTAKE_REPOS_JSON=)
case "$out" in
  *"$tmp/checkout/"*"|PRODUCT")
    ok "co-located config wins over a stale sibling mirror" ;;
  *)
    fail "co-located config did not win (got: $out)" ;;
esac

# --- case 3: the explicit override still beats everything (regression guard).
printf '%s' "$fresh" > "$tmp/override.json"
out=$(probe "$home/.local/lib/pi-packet/seat-lib.sh" \
        HOME="$home" FLEET_INTAKE_REPOS_JSON="$tmp/override.json")
case "$out" in
  "$tmp/override.json|PRODUCT") ok "FLEET_INTAKE_REPOS_JSON override still wins" ;;
  *) fail "FLEET_INTAKE_REPOS_JSON override did not win (got: $out)" ;;
esac

# --- case 4: fail-closed is preserved — an unlisted repo is never product.
out=$(env HOME="$home" FLEET_INTAKE_REPOS_JSON="$tmp/override.json" bash -c '
  source "$1" >/dev/null 2>&1 || exit 9
  if repo_is_product fleet-ops 2>/dev/null; then echo PRODUCT; else echo not-product; fi
  ' _ "$home/.local/lib/pi-packet/seat-lib.sh")
[[ "$out" == "not-product" ]] \
  && ok "fleet-ops (no product flag) stays not-product" \
  || fail "fleet-ops must never be a product repo (got: $out)"

if (( fails )); then
  echo "intake-repos-path-resolution: $fails failure(s)"
  exit 1
fi
echo "intake-repos-path-resolution: all checks passed"
