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

# fleet-ops#4643 follow-up (2026-09-11): the expr MUST exclude the two
# packet_types that can never have a prefix-cache hit by construction.
#   interactive — a human typing a different prompt each turn;
#   probe       — a one-word liveness sentinel ('Reply OK' / 'PONG').
# Both drove a false FleetPromptCacheHitLow on 2026-09-11 (litellm/other
# 0.27 was 100% 'Reply OK' seat probes; paretoinference/other 0.81 was all
# cwd=/home/nish) while the real packet lanes were above target. If this
# scoping is dropped, the alert fires on lanes the packet layout cannot move.
assert 'packet_type!="interactive"' in expr.replace(" ", "") \
    or 'packet_type!~"interactive|probe"' in expr.replace(" ", ""), \
    fail(f"expr must exclude interactive sessions (they have no stable prefix by construction), got: {expr}")
assert 'probe' in expr, \
    fail(f"expr must also exclude packet_type=probe (one-word liveness sentinels), got: {expr}")
assert 'packet_type="other"' not in expr.replace(" ", ""), \
    fail(f"expr must NOT exclude packet_type=\"other\" — genuine packets with no named lane live there, got: {expr}")
ok("expr excludes interactive+probe lanes, keeps 'other' (real packets) in scope")

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

# 8. Classifier contract: the packet_type labels the alert scopes on must
#    actually be produced, and genuine packets must NOT be swallowed into the
#    excluded buckets. fleet-ops#4643 follow-up (2026-09-11).
python3 - "$repo_root" <<'PY'
import sys, importlib.util
repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("fleet_usd", f"{repo}/lib/fleet_usd.py")
fu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fu)

def fail(msg): print(f"FAIL: {msg}", file=sys.stderr); sys.exit(1)
def ok(msg): print(f"OK: {msg}")

S = "/home/nish/.pi/agent/sessions/"
cases = [
    (S + "--home-nish--/x.jsonl", "interactive",
     "ad-hoc interactive session in /home/nish"),
    (S + "--tmp--/x.jsonl", "interactive", "ad-hoc interactive session in /tmp"),
    (S + "pi-issue-fleet-ops-5010/x.jsonl", "worker", "a real dispatched packet"),
    (S + "--tmp-seat-probe--/x.jsonl", "probe", "a seat liveness probe"),
    (S + "--home-nish-workspaces-agent-worktrees-issue-fleet-ops-4263-rebase--/x.jsonl",
     "other", "a packet run from a plain worktree (must stay in scope)"),
]
for path, want, why in cases:
    got = fu.packet_type_from_path(path)
    assert got == want, fail(f"{why}: want packet_type={want!r}, got {got!r} for {path}")
ok("packet_type_from_path labels interactive/probe/worker/other as the alert expects")

# The excluded buckets must never be produced for a real packet header, and a
# probe prompt must be recognised by content (path alone cannot tell them apart).
probes = ["Reply OK", "PONG", "Reply with exactly: OK"]
packets = [
    "# Pi fleet issue worker\nYou implement exactly ONE GitHub issue",
    "difficulty: light # Pi fleet issue worker\nYou implement",
    "# Pi fleet product scout\nYou are the product-work scout",
]
for t in probes:
    assert fu._is_probe_prompt(t), fail(f"liveness sentinel not detected as a probe: {t!r}")
for t in packets:
    assert not fu._is_probe_prompt(t), fail(f"a real packet was misread as a probe: {t!r}")
assert not fu._is_probe_prompt(""), fail("empty prompt must not be a probe")
ok("probe prompt sentinels detected by content; real packet headers never misread")

# A free-class MODEL wired on a metered PROVIDER (e.g. openrouter/
# nvidia/nemotron-3-ultra-550b:free, input/cacheRead price 0) must be scored
# class=free: a $0 lane has no metered spend to protect (fleet-ops#4643,
# 2026-09-11). Pins _provider_metric_class + the model captured from
# model_change lines.
import importlib.util, json, os, tempfile
spec = importlib.util.spec_from_file_location("fu", f"{repo}/lib/fleet_usd.py")
fu = importlib.util.module_from_spec(spec); spec.loader.exec_module(fu)
fail2 = lambda m: (print(f"FAIL: {m}", file=sys.stderr), sys.exit(1))
caps = {"providers": {"openrouter": {
    "class": "metered",
    "models": {"nvidia/nemotron-3-ultra-550b-a55b:free": {"cap": 2, "class": "free"}},
}}}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(caps, f); path = f.name
rc = fu.load_rate_card(path)
if fu._provider_metric_class(rc, "openrouter") != "metered":
    fail2("provider-level class must stay metered when no model is given")
if fu._provider_metric_class(rc, "openrouter", "nvidia/nemotron-3-ultra-550b-a55b:free") != "free":
    fail2("free-class model on a metered provider must score class=free")
if fu._provider_metric_class(rc, "openrouter", "some/unknown-slug") != "metered":
    fail2("unknown model on a metered provider must fall back to provider class")
# End-to-end: a session on the free model must emit class=free.
sess = tempfile.mkdtemp()
jsonl = os.path.join(sess, "pi-issue-5010", "s.jsonl")
os.makedirs(os.path.dirname(jsonl))
with open(jsonl, "w") as f:
    f.write(json.dumps({"type": "model_change", "provider": "openrouter",
                        "modelId": "nvidia/nemotron-3-ultra-550b-a55b:free"}) + "\n")
    f.write(json.dumps({"type": "message", "timestamp": "2026-09-11T09:00:00Z",
                        "message": {"role": "user", "content": [{"type": "text", "text": "# Pi fleet issue worker\nreal packet"}]}}) + "\n")
    f.write(json.dumps({"type": "message", "timestamp": "2026-09-11T09:01:00Z",
                        "message": {"role": "assistant", "usage": {"input": 900, "cacheRead": 100}}}) + "\n")
rows = fu.compute_cache_hit_24h(sess, rc, now_epoch=1789119600)
if len(rows) != 1 or rows[0]["class"] != "free" or rows[0]["packet_type"] != "worker":
    fail2(f"free-model session must emit class=free packet_type=worker, got {rows}")
os.unlink(path)
print("OK: free-class model on a metered provider scores class=free (no metered target for a $0 lane)")
PY

echo "fleet-prompt-cache-hit-alert: PASS"
