#!/usr/bin/env bash
# tests/fleet-prompt-cache-hit-alert.test.sh
#
# fleet-ops#4643: locks the FleetPromptCacheHitLow alert and the cache-TTL
# documentation so a later overwrite cannot silently drop the spend guard or
# route a spend alert to Nish's phone.
#
# The alert is the closeout of accept 3: the metric fleet_prompt_cache_hit_ratio
# is emitted by libexec/fleet-metrics-export.py (pinned by
# tests/fleet-metrics-export.test.sh 10b); this test pins the ALERT rule that
# fires on it and the seat-caps TTL comment that names the per-provider
# windows.
#
# Contract:
#   1. FleetPromptCacheHitLow exists in config/fleet_rules.yml.
#   2. expr keys on fleet_prompt_cache_hit_ratio{class="metered"} < 0.85
#      (per-lane, not a min() aggregate, so the firing alert carries the
#      provider+packet_type labels).
#   3. for: 6h (the issue's 6h window).
#   4. severity=warning (-> repair-dispatch = am-executor, NOT the phone).
#      A spend optimisation is never a Nish page.
#   5. service=fleet.
#   6. The alert name is NOT in the alert-repair-dispatch SKIP_SET, so a
#      firing alert actually dispatches a repair worker (not silently
#      swallowed like a trend alert).
#   7. config/seat-caps.json carries the _comment_4643_cache_ttl field that
#      documents the per-provider cache-TTL windows (DeepSeek ~5 min, others
#      inferred until the metric proves them).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
rules="$repo_root/config/fleet_rules.yml"
caps="$repo_root/config/seat-caps.json"
dispatch="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$rules" ]] || fail "missing: $rules"
[[ -f "$caps" ]]  || fail "missing: $caps"
[[ -f "$dispatch" ]] || fail "missing: $dispatch"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

python3 - "$rules" "$caps" "$dispatch" <<'PY'
import sys, json, re
rules_path, caps_path, dispatch_path = sys.argv[1:4]

def fail(msg): print(f"FAIL: {msg}", file=sys.stderr); sys.exit(1)
def ok(msg): print(f"OK: {msg}")

try:
    import yaml
except ImportError:
    fail("pyyaml required")

with open(rules_path) as f:
    cfg = yaml.safe_load(f)

alert = None
for g in cfg.get("groups", []):
    for r in g.get("rules", []):
        if r.get("alert") == "FleetPromptCacheHitLow":
            alert = r
assert alert is not None, fail("FleetPromptCacheHitLow rule not found in fleet_rules.yml")
ok("FleetPromptCacheHitLow present in fleet_rules.yml")

expr = alert.get("expr", "")
assert "fleet_prompt_cache_hit_ratio" in expr, \
    fail(f"expr must key on fleet_prompt_cache_hit_ratio, got: {expr}")
assert 'class="metered"' in expr, \
    fail(f"expr must scope to class=\"metered\", got: {expr}")
assert "<0.85" in expr.replace(" ", ""), \
    fail(f"expr must threshold < 0.85, got: {expr}")
# Per-lane (no min()/max() aggregate) so the firing alert carries labels.
assert not re.search(r"\b(min|max)\s*\(", expr), \
    fail(f"expr must be per-lane, not an aggregate (min/max), got: {expr}")
ok(f"expr keys on fleet_prompt_cache_hit_ratio{{class=\"metered\"}} < 0.85 per-lane: {expr}")

assert alert.get("for") == "6h", \
    fail(f"for must be 6h, got: {alert.get('for')}")
ok("for: 6h (the issue's 6h window)")

labels = alert.get("labels", {})
assert labels.get("severity") == "warning", \
    fail(f"severity must be warning (-> repair-dispatch, not the phone), got: {labels.get('severity')}")
assert labels.get("severity") != "page", \
    fail("a spend alert must NEVER be severity=page (phones Nish)")
assert labels.get("service") == "fleet", \
    fail(f"service must be fleet, got: {labels.get('service')}")
ok("severity=warning, service=fleet (routes to am-executor, NOT Nish's phone)")

# The alert name must NOT be in the alert-repair-dispatch SKIP_SET, or a
# firing alert would be silently swallowed (like a trend alert) instead of
# dispatching a repair worker.
with open(dispatch_path) as f:
    dispatch_src = f.read()
# SKIP_SET is a python set literal; extract the names.
skip_match = re.search(r"SKIP_SET\s*=\s*\{([^}]*)\}", dispatch_src, re.DOTALL)
assert skip_match, fail("could not find SKIP_SET in alert-repair-dispatch")
skip_names = set(re.findall(r'"([A-Za-z0-9_]+)"', skip_match.group(1)))
assert "FleetPromptCacheHitLow" not in skip_names, \
    fail("FleetPromptCacheHitLow is in SKIP_SET — a firing alert would be swallowed, not dispatched to am-executor")
ok("FleetPromptCacheHitLow NOT in alert-repair-dispatch SKIP_SET (dispatches a repair worker)")

# seat-caps TTL comment.
with open(caps_path) as f:
    caps = json.load(f)
ttl = caps.get("_comment_4643_cache_ttl", "")
assert ttl, fail("config/seat-caps.json missing _comment_4643_cache_ttl field")
assert "5 min" in ttl or "5min" in ttl, \
    fail("_comment_4643_cache_ttl must document the DeepSeek ~5 min window")
assert "fleet_prompt_cache_hit_ratio" in ttl, \
    fail("_comment_4643_cache_ttl must name the metric as the proof")
assert "FleetPromptCacheHitLow" in ttl, \
    fail("_comment_4643_cache_ttl must name the alert")
ok("seat-caps.json _comment_4643_cache_ttl documents TTL windows + metric + alert")
PY

echo "fleet-prompt-cache-hit-alert: PASS"
