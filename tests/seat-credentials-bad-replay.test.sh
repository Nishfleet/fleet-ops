#!/usr/bin/env bash
# tests/seat-credentials-bad-replay.test.sh
#
# fleet-ops#5788 replay drill, PORTED to the litellm era (fleet-ops#4263
# / #5993 deleted lib/seat-lib.sh).
#
# The guarantee this drill has always protected is unchanged:
#
#   a provider 401 must NOT kill the worker with exit 1; it must
#   exclude that deployment for a FINITE window so the retry lands on
#   a different deployment in the same group.
#
# What changed is WHERE that guarantee lives. Before #4263 the fleet
# classified the 401 itself [is_credentials_error] and wrote a seat
# ledger bench [mark_seat_credentials_bad]. After #4263 the LiteLLM
# proxy owns routing and cooldown end to end — lib/litellm-seat.sh
# reduces every mark_seat_* helper to a logging stub that says
# "proxy cooldown owns routing". So this drill now pins the proxy
# contract that replaced those functions. Pinning the old helpers
# would pin dead code; deleting the drill would drop the guarantee.
#
# Proves offline, no live curl, no live seat writes:
#   1. lib/litellm-seat.sh really has NO fleet-side credential
#      classifier or ledger writer left [the #4263 invariant] — if one
#      comes back, seat health has two owners again and this drill
#      must be re-pointed deliberately, not by accident.
#   2. Every mark_seat_* helper that survives is a delegating stub, so
#      no caller silently benches a seat behind the proxy's back.
#   3. config/litellm-proxy.yaml excludes a deployment on the FIRST
#      authentication error [AuthenticationErrorAllowedFails: 0] —
#      the MiniMax burst of 2026-09-12 10:16-10:19 IST killed four
#      workers because nothing excluded the dead key.
#   4. The exclusion is a finite cooldown, never a permanent corpse
#      [fleet-ops#4640: a single 401 is a rotated key, not a decade of
#      death].
#   5. An authentication error is retried [AuthenticationErrorRetries
#      >= 1], so the retry is what lands on the healthy deployment
#      instead of the worker exiting 1.
#   6. The groups a senior/worker packet can route to have fallbacks,
#      so an excluded deployment has somewhere to fall back TO
#      [fleet-ops#4404: worker-capable must not dead-end].
#
# Worker App token cannot push .github/workflows/**, so new tests must
# be bash-invoked from an already-listed test file (fleet-ops#4396).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"
proxy_yaml="${SEAT_CRED_PROXY_YAML:-$repo_root/config/litellm-proxy.yaml}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$seat_lib" ]]   || fail "missing lib/litellm-seat.sh: $seat_lib"
[[ -f "$proxy_yaml" ]] || fail "missing config/litellm-proxy.yaml: $proxy_yaml"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

# --------- 1. no fleet-side credential classifier survives #4263 ----------
for gone in is_credentials_error mark_seat_credentials_bad; do
    if grep -qE "^[[:space:]]*${gone}\(\)" "$seat_lib"; then
        fail "1. $gone() is defined again in lib/litellm-seat.sh — seat health has two owners; re-point this drill deliberately (fleet-ops#4263)"
    fi
done
ok "1. no fleet-side credential classifier/ledger-writer in lib/litellm-seat.sh"

# --------- 2. surviving mark_seat_* helpers are delegating stubs ----------
# Every mark_seat_* definition must be a single-line stub that either
# delegates to the proxy or is an explicit no-op return. A multi-line
# body means someone re-grew fleet-side seat benching.
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
        *"proxy cooldown owns routing"*) : ;;
        *"return 0"*|*"return 1"*)       : ;;
        *) fail "2. non-stub seat marker in lib/litellm-seat.sh: $line" ;;
    esac
done < <(grep -E "^mark_seat_[a-z_]*\(\)" "$seat_lib" || true)
ok "2. every surviving mark_seat_* helper delegates to proxy cooldown"

# --------- 3-6. the proxy contract that replaced them ----------
python3 - "$proxy_yaml" <<'PY'
import sys, yaml

path = sys.argv[1]
with open(path) as fh:
    cfg = yaml.safe_load(fh) or {}

rs = cfg.get("router_settings") or {}


def fail(msg):
    print("FAIL: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def ok(msg):
    print("OK: %s" % msg)


# 3. first authentication error excludes the deployment.
afp = (rs.get("allowed_fails_policy") or {}).get("AuthenticationErrorAllowedFails")
if afp != 0:
    fail(
        "3. router_settings.allowed_fails_policy.AuthenticationErrorAllowedFails "
        "want 0 got %r - a 401 would be tolerated and keep killing workers "
        "(fleet-ops#5788)" % (afp,)
    )
ok("3. AuthenticationErrorAllowedFails=0 - first 401 excludes the deployment")

# 4. the exclusion is finite, not a permanent corpse (fleet-ops#4640).
cd = rs.get("cooldown_time")
if not isinstance(cd, int) or isinstance(cd, bool) or cd <= 0:
    fail("4. router_settings.cooldown_time want a positive int got %r" % (cd,))
if cd > 86400:
    fail(
        "4. router_settings.cooldown_time %ss exceeds 24h - that is a corpse "
        "wall, not a rotated-key bench (fleet-ops#4640)" % cd
    )
ok("4. cooldown_time=%ss - finite exclusion, not a corpse wall" % cd)

# 5. the retry is what lands on the healthy deployment.
rp = (rs.get("retry_policy") or {}).get("AuthenticationErrorRetries")
if not isinstance(rp, int) or isinstance(rp, bool) or rp < 1:
    fail(
        "5. router_settings.retry_policy.AuthenticationErrorRetries want >=1 "
        "got %r - without a retry the worker exits 1 on a rotated key "
        "(fleet-ops#5788)" % (rp,)
    )
ok("5. AuthenticationErrorRetries=%d - retry lands on another deployment" % rp)

# 6. an excluded deployment must have somewhere to fall back TO.
raw_fallbacks = rs.get("fallbacks") or []
fb = {}
for entry in raw_fallbacks:
    if isinstance(entry, dict):
        for group, targets in entry.items():
            fb[group] = targets or []
for group in ("worker-capable", "senior"):
    if not fb.get(group):
        fail(
            "6. router_settings.fallbacks has no terminal route for %r - an "
            "excluded deployment dead-ends (fleet-ops#4404)" % group
        )
ok("6. fallbacks keep %s routable after an exclusion" % ", ".join(sorted(fb)))
PY

echo "PASS: tests/seat-credentials-bad-replay.test.sh"
