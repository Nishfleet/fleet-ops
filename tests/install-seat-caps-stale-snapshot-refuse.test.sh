#!/usr/bin/env bash
# tests/install-seat-caps-stale-snapshot-refuse.test.sh
#
# fleet-ops#5493 (backfilled from the 20260826 gap audit): a canonical repo
# holding the pre-#331 seat-caps snapshot (devin cap=0, ollama cap=2) has
# its mtimes REFRESHED by git checkout, so the repo copy appears NEWER than
# the live state file and the plain mtime guard reads "repo newer = normal
# install". A plain `./install.sh` must still refuse that overwrite (it
# would downgrade live devin 4->0 = "fleet goes single-handed" and ollama
# 4->2) via the seat_caps_would_downgrade cap-drop guard. Two escape
# hatches must still work:
#   - a merged cap reduction committed on origin/main (blob compare) installs,
#   - FLEET_OPS_ALLOW_SEAT_CAPS_OVERWRITE=1 forces the overwrite.
#
# Behavioral, not grep-level: runs a COPY of install.sh against a fake
# MANIFEST + fake HOME (same harness as tests/install-refuse-continues.test.sh,
# fleet-ops#4223). Does NOT touch the real live state file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

make_stub() {
  cat >"$1/stub-systemctl.sh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"is-enabled"*) echo "disabled"; exit 0 ;;
  *"is-active --quiet"*) exit 1 ;;
  *"enable"*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$1/stub-systemctl.sh"
}

# Trimmed but structurally faithful to the pre/post-#331 seat caps.
pre331='{"providers":{"devin":{"cap":0},"ollama":{"cap":2,"models":{"deepseek-v4-flash:0731":2}}}}'
post331='{"providers":{"devin":{"cap":4,"quota_bench_default_s":900},"ollama":{"cap":4,"models":{"deepseek-v4-flash:0731":4,"_hard_cap":4}}}}'
merged_drop='{"providers":{"devin":{"cap":2}}}'

RES_LIVE=livetgt-not-set
# install_in_scratch <repo-json> <live-json> [ENV=value...] -> writes $RES_RC/$RES_OUT/$RES_LIVE
RES_RC=0; RES_OUT=""; RES_LIVE=""
install_in_scratch() {
  local repo_json=$1 live_json=$2
  shift 2
  local scratch
  scratch="$(mktemp -d -t seat-caps-snapshot.XXXXXX)"
  trap 'rm -rf "$scratch"' RETURN
  make_stub "$scratch"

  cp -a "$install_src" "$scratch/install.sh"
  mkdir -p "$scratch/config" "$scratch/home/nish/.local/state/pi-packet" "$scratch/template"
  printf '{}' >"$scratch/template/devin-config.json"
  cat >"$scratch/MANIFEST" <<MANIFEST
config/seat-caps.json $scratch/home/nish/.local/state/pi-packet/seat-caps.json
MANIFEST

  # Live state file first (older), then the repo copy (newer). This is the
  # git-checkout-refreshed-mtime shape of fleet-ops#5493: the repo copy
  # looks NEWER than live, so live_newer_than_repo alone would permit it.
  live="$scratch/home/nish/.local/state/pi-packet/seat-caps.json"
  printf '%s\n' "$live_json" >"$live"
  RES_LIVE="$live"
  sleep 1
  printf '%s\n' "$repo_json" >"$scratch/config/seat-caps.json"

  set +e
  RES_OUT=$(
    env \
    HOME="$scratch/home" \
    FLEET_OPS_WORKSPACES_ROOT=/nonexistent-workspaces \
    FLEET_OPS_ALLOW_NONCANONICAL=1 \
    SYSTEMCTL="$scratch/stub-systemctl.sh" \
    "$@" \
      "$scratch/install.sh" 2>&1
  )
  RES_RC=$?
  RES_LIVE_CONTENT=$(cat "$live")
  set -e
}

# --- Scenario A: the exact #5493 stale-snapshot overwrite attempt -----------
install_in_scratch "$pre331" "$post331"
[[ "$RES_RC" -ne 0 ]] || fail "install.sh must exit non-zero after the seat-caps REFUSE, got rc=$RES_RC
$RES_OUT"
[[ "$RES_OUT" == *"NONFATAL REFUSE:"* ]] || fail "expected NONFATAL REFUSE marker, got:
$RES_OUT"
[[ "$RES_OUT" == *"seat-caps.json"* ]] || fail "REFUSE line must name seat-caps.json, got:
$RES_OUT"
[[ "$RES_OUT" == *"devin"* && "$RES_OUT" == *"ollama"* ]] \
  || fail "REFUSE line must name the downgraded providers, got:
$RES_OUT"
[[ "$RES_OUT" == *"4->0"* ]] || fail "expected a devin 4->0 drop in the REFUSE line, got:
$RES_OUT"

ok "stale pre-#331 snapshot repo cannot overwrite live post-#331 caps: NONFATAL REFUSE names seat-caps.json + devin/ollama drops (fleet-ops#5493 / #371)"

# --- Scenario B: FLEET_OPS_ALLOW_SEAT_CAPS_OVERWRITE=1 override installs ----
install_in_scratch "$pre331" "$post331" FLEET_OPS_ALLOW_SEAT_CAPS_OVERWRITE=1
[[ "$RES_RC" -eq 0 ]] || fail "override must install cleanly, got rc=$RES_RC
$RES_OUT"
[[ "$RES_OUT" == *"NONFATAL REFUSE:"* ]] \
  && fail "override run must NOT emit the seat-caps REFUSE, got:
$RES_OUT" || true
# Live was overwritten by the (stale) repo copy under the explicit override.
grep -q '"cap": *0' <(printf '%s' "$RES_LIVE_CONTENT") \
  || fail "override did not overwrite live seat-caps.json (live=$RES_LIVE)"
ok "FLEET_OPS_ALLOW_SEAT_CAPS_OVERWRITE=1 is the explicit operator override"

# --- Scenario C: merged cap reduction on origin/main still installs ---------
# Real git repo: commit the repo copy to refs/remotes/origin/main so
# seat_caps_is_origin_main_blob matches and the intentional reduction goes
# through (indistinguishable from a merge of the cap-lowering PR).
scratch3="$(mktemp -d -t seat-caps-originmain.XXXXXX)"
trap 'rm -rf "$scratch3"' EXIT INT TERM
make_stub "$scratch3"
cp -a "$install_src" "$scratch3/install.sh"
mkdir -p "$scratch3/config" "$scratch3/home/nish/.local/state/pi-packet"
cat >"$scratch3/MANIFEST" <<MANIFEST
config/seat-caps.json $scratch3/home/nish/.local/state/pi-packet/seat-caps.json
MANIFEST
printf '%s\n' "$post331" >"$scratch3/home/nish/.local/state/pi-packet/seat-caps.json"
sleep 1
printf '%s\n' "$merged_drop" >"$scratch3/config/seat-caps.json"
git -C "$scratch3" init -q
git -C "$scratch3" config user.email t@t && git -C "$scratch3" config user.name t
git -C "$scratch3" add config/seat-caps.json
git -C "$scratch3" commit -qm "merged cap reduction"
git -C "$scratch3" branch -M main
# origin/main must point at a NO-CHANGE-others blob identical to the repo file.
git -C "$scratch3" update-ref refs/remotes/origin/main HEAD

set +e
out=$(
  HOME="$scratch3/home" \
  FLEET_OPS_WORKSPACES_ROOT=/nonexistent-workspaces \
  FLEET_OPS_ALLOW_NONCANONICAL=1 \
  SYSTEMCTL="$scratch3/stub-systemctl.sh" \
    "$scratch3/install.sh" 2>&1
)
rc3=$?
set -e
[[ "$rc3" -eq 0 ]] || fail "origin-main-blob cap reduction must install cleanly, got rc=$rc3
$out"
live3=$(cat "$scratch3/home/nish/.local/state/pi-packet/seat-caps.json")
if grep -q '"devin"' <(printf '%s' "$live3") && grep -q '"cap": *2' <(printf '%s' "$live3"); then
  ok "origin/main-blob cap drop installs (merged reductions are intentional)"
else
  fail "merged cap reduction (devin 4->2 via origin/main) must reach live, live=$live3"
fi
exit 0
