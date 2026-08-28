#!/usr/bin/env bash
# tests/alertmanager-routing-matrix.test.sh
#
# fleet-ops#1534: locks the alertmanager routing matrix so only severity=page
# reaches the phone (telegram). critical/warning/none reach repair-dispatch
# (the webhook at 127.0.0.1:9095), which spawns a repair worker or skips
# (SKIP_SET). A repair worker never texts Nish; its outcome folds into the
# daily digest. This is the alertmanager side of the two-gate policy; the
# hermes outbound class-gate is the other side.
#
# This is a static shape check (no live alertmanager). It parses
# config/alertmanager.yml with python/yaml and proves the routing matrix:
#   - severity=page      -> telegram, stop (continue: false)
#   - severity=critical  -> repair-dispatch, continue: true
#   - severity=warning   -> repair-dispatch, continue: true
#   - Watchdog           -> null, stop (continue: false)
#   - default            -> repair-dispatch
#   - telegram receiver uses bot_token_file (not inline token)
#   - repair-dispatch receiver points at 127.0.0.1:9095
#   - exactly one severity=page route
#   - no route sends severity=critical/warning to telegram
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
am="$repo_root/config/alertmanager.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$am" ]] || fail "missing: $am"

python3 - "$am" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f)

def fail(msg): print(f"FAIL: {msg}", file=sys.stderr); sys.exit(1)
def ok(msg): print(f"OK: {msg}")

route = cfg.get("route") or fail("no route block")
routes = route.get("routes") or fail("no sub-routes")
receivers = {r["name"]: r for r in cfg.get("receivers", [])}

# --- default receiver ---
assert route.get("receiver") == "repair-dispatch", \
    fail(f"default receiver must be repair-dispatch, got {route.get('receiver')}")
ok("default receiver -> repair-dispatch")

# --- find routes by matcher ---
def find_route(matcher_val):
    for r in routes:
        ms = r.get("matchers") or []
        for m in ms:
            if m == matcher_val or m.startswith(matcher_val):
                return r
    return None

page = find_route('severity="page"') or fail("no severity=page route")
assert page["receiver"] == "telegram", fail("severity=page must -> telegram")
assert page.get("continue") is False, fail("severity=page must continue: false (stop)")
ok('severity=page -> telegram, continue: false (stop — reaches phone)')

crit = find_route('severity="critical"') or fail("no severity=critical route")
assert crit["receiver"] == "repair-dispatch", fail("severity=critical must -> repair-dispatch")
assert crit.get("continue") is True, fail("severity=critical must continue: true")
ok('severity=critical -> repair-dispatch, continue: true (no phone)')

warn = find_route('severity="warning"') or fail("no severity=warning route")
assert warn["receiver"] == "repair-dispatch", fail("severity=warning must -> repair-dispatch")
assert warn.get("continue") is True, fail("severity=warning must continue: true")
ok('severity=warning -> repair-dispatch, continue: true (no phone)')

wd = find_route('alertname="Watchdog"') or fail("no Watchdog route")
assert wd["receiver"] == "null", fail("Watchdog must -> null")
assert wd.get("continue") is False, fail("Watchdog must continue: false")
ok('Watchdog -> null, continue: false (heartbeat, no phone, no repair)')

# --- exactly one severity=page route ---
page_count = sum(1 for r in routes if any(
    m == 'severity="page"' for m in (r.get("matchers") or [])))
assert page_count == 1, fail(f"exactly one severity=page route expected, got {page_count}")
ok("exactly one severity=page route")

# --- no route sends critical/warning to telegram ---
for r in routes:
    if r["receiver"] == "telegram":
        ms = r.get("matchers") or []
        for m in ms:
            assert '"critical"' not in m and '"warning"' not in m, \
                fail(f"telegram route must not match critical/warning: {m}")
ok("no telegram route matches critical or warning")

# --- telegram receiver: bot_token_file, not inline token ---
tg = receivers.get("telegram") or fail("no telegram receiver")
tcfg = tg.get("telegram_configs") or fail("no telegram_configs")
assert "bot_token_file" in tcfg[0], fail("telegram must use bot_token_file (not inline token)")
assert "bot_token" not in tcfg[0], fail("telegram must NOT have inline bot_token (secret in file)")
ok("telegram receiver uses bot_token_file (no inline token)")

# --- repair-dispatch receiver: 127.0.0.1:9095 ---
rd = receivers.get("repair-dispatch") or fail("no repair-dispatch receiver")
wcfg = rd.get("webhook_configs") or fail("no webhook_configs")
assert "127.0.0.1:9095" in wcfg[0]["url"], \
    fail(f"repair-dispatch webhook must point at 127.0.0.1:9095, got {wcfg[0]['url']}")
ok("repair-dispatch receiver -> 127.0.0.1:9095 webhook")

# --- null receiver exists and is empty ---
null = receivers.get("null") or fail("no null receiver")
ok("null receiver present (Watchdog sink)")

print()
print("alertmanager-routing-matrix: all invariants pass (fleet-ops#1534)")
PY
