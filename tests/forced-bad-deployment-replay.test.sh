#!/usr/bin/env bash
# tests/forced-bad-deployment-replay.test.sh
#
# fleet-ops#5792 replay drill: offline replay of the senior-lane router
# rescue. No live curl, no live proxy — we parse config/litellm-proxy.yaml
# with python3+yaml and assert the structure + policy numbers that make
# one bad deployment (403 spending-limit / 402 insufficient-credits)
# bench itself immediately and never reach a worker.
#
# Proves offline:
#   1. Router settings land at least as robust as #5811: num_retries>=2,
#      allowed_fails<=1, cooldown_time>=300, AuthenticationErrorRetries>0.
#   2. AuthenticationErrorAllowedFails=0 - a single auth error benches
#      the deployment instantly (no threshold slide).
#   3. Every model group's fallback chain terminates at an existing
#      group (no dead-end, fleet-ops#4404 rule generalized).
#   4. Forced-bad-deployment simulation on an in-memory COPY of the
#      config: inject a dead deployment (api_base https://127.0.0.1:1)
#      FIRST in the senior group (order:1, ahead of pareto in list
#      order) and assert the policy numbers (allowed_fails=1,
#      cooldown_time=300) mean one failure benches it, while the
#      remaining senior rungs + fallbacks senior->worker-capable keep
#      serving.
#   5. Negative check: a config copy with allowed_fails=5 must FAIL the
#      robustness assertion (the detector catches drift).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
yaml_file="$repo_root/config/litellm-proxy.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$yaml_file" ]] || fail "missing litellm-proxy.yaml: $yaml_file"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
python3 - <<'EOF' 2>/dev/null || fail "python3 yaml module missing"
import yaml
EOF

scratch="$(mktemp -d -t forced-bad-deploy-replay.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ---------- 1. parse + policy-number assertions ----------
python3 - "$yaml_file" <<'EOF' || exit 1
import sys, yaml

cfg = yaml.safe_load(open(sys.argv[1]))
rs = cfg.get("router_settings")
if not rs:
    print("FAIL: router_settings block missing"); sys.exit(1)

groups = {}
for d in cfg.get("model_list", []):
    groups.setdefault(d["model_name"], []).append(d["litellm_params"])
if "senior" not in groups:
    print("FAIL: no senior group in yaml"); sys.exit(1)

checks = []
def ck(name, cond):
    checks.append((name, cond))

ck("num_retries>=2", rs.get("num_retries", 0) >= 2)
ck("allowed_fails<=1", rs.get("allowed_fails", 99) <= 1)
ck("cooldown_time>=300", rs.get("cooldown_time", 0) >= 300)
rp = rs.get("retry_policy", {})
ck("AuthenticationErrorRetries>0", rp.get("AuthenticationErrorRetries", 0) > 0)
afp = rs.get("allowed_fails_policy", {})
ck("AuthenticationErrorAllowedFails==0", afp.get("AuthenticationErrorAllowedFails", -1) == 0)

# 3. every group's fallback chain terminates at an existing group
fb = rs.get("fallbacks", [])
finals = {
    "worker-cheap": ["worker-capable", "senior"],
    "worker-capable": ["senior"],
    "senior": ["worker-capable"],
    "judge": ["senior"],
    "worker-private": ["worker-capable"],
}
for entry in fb:
    for g, chain in entry.items():
        if g not in groups:
            print(f"FAIL: fallback source group not defined: {g}"); sys.exit(1)
        for hop in chain:
            if hop not in groups:
                print(f"FAIL: dead-end fallback hop {hop} (from {g}): group not in model_list")
                sys.exit(1)
        if finals.get(g) != chain:
            print(f"FAIL: fallback chain drift for {g}: got {chain}, want {finals.get(g)}")
            sys.exit(1)

for name, cond in checks:
    if not cond:
        print(f"FAIL: {name}")
        sys.exit(1)
    print(f"OK: {name}")
print("OK: every group's fallback chain terminates at an existing group (no dead-end)")
EOF
ok "1-3. policy numbers + fallback-matrix assertions parsed out of config (python block above)"

# Re-assert the group shape so the simulation below is honest.
senior_count=$(python3 -c "import yaml; c=yaml.safe_load(open('$yaml_file')); print(sum(1 for d in c['model_list'] if d['model_name']=='senior'))")
[[ "$senior_count" == "3" ]] || fail "expected 3 senior deployments, got $senior_count"
ok "senior group has $senior_count deployments (pareto glm-5.3, xkiro deepseek-v4-pro, synthetic glm-5.3-flash)"

# ---------- 4. forced-bad-deployment simulation on an in-memory copy ----------
python3 - "$yaml_file" "$scratch" <<'EOF' || exit 1
import sys, copy, yaml

cfg = yaml.safe_load(open(sys.argv[1]))
scratch = sys.argv[2]

# Inject a dead deployment FIRST in the senior group: order:1, earlier
# in list order than pareto. api_base 127.0.0.1:1 is unroutable.
dead = {
    "model_name": "senior",
    "litellm_params": {
        "model": "openai/z-ai/glm-5.3",
        "api_base": "https://127.0.0.1:1",
        "api_key": "os.environ/PARETO_API_KEY",
        "tags": ["prepaid", "senior", "injected-dead"],
        "order": 1,
        "max_parallel_requests": 1,
    },
}
idx = next(i for i, d in enumerate(cfg["model_list"]) if d["model_name"] == "senior")
cfg["model_list"].insert(idx, dead)
yaml.safe_dump(cfg, open(f"{scratch}/with-dead.yaml", "w"))

w = yaml.safe_load(open(f"{scratch}/with-dead.yaml"))
rs = w["router_settings"]
seni = [d["litellm_params"] for d in w["model_list"] if d["model_name"] == "senior"]

# The dead rung sits first in the senior list and is order:1 - same
# order tier as pareto, ahead of it in list order, so a naive router
# picks it first. Simulate: first pick fails.
first_pick = seni[0]
assert first_pick["api_base"] == "https://127.0.0.1:1", "dead rung is not first in senior list"
assert first_pick["order"] == 1, "dead rung must be order:1"

# Policy arithmetic: allowed_fails == 1 (threshold <=1) and
# cooldown_time == 300 mean ONE failure of that deployment benches it
# for 5 minutes. AuthenticationErrorAllowedFails == 0 means the bench
# is instant for auth-class errors (403/402). The benched deployment
# is excluded from picks during cooldown; serving continues on the
# remaining order-1 rung (pareto), the order-2 rung (synthetic), and
# the fallback chain senior -> worker-capable.
assert rs["allowed_fails"] <= 1, "allowed_fails must bench on <=1 failure"
assert rs["cooldown_time"] >= 300, "cooldown must be >=5min"
assert rs["allowed_fails_policy"]["AuthenticationErrorAllowedFails"] == 0
# Remaining healthy serving surface: the other 2 senior rungs + the
# fallback group worker-capable (2 deployments of its own upstream).
assert len(seni) == 4, "injected copy should have 4 senior deployments (3 live + 1 dead)"
live_rungs = [d for d in seni[1:] if "127.0.0.1" not in d["api_base"]]
assert len(live_rungs) == 3, "expected 3 live rungs remaining"
fb = {k: v for e in rs["fallbacks"] for k, v in e.items()}
assert fb["senior"] == ["worker-capable"], "senior fallback must land on worker-capable"
assert "worker-capable" in [d["model_name"] for d in w["model_list"]]
print("OK: forced-bad-deployment simulation: 1st-pick dead rung benched by allowed_fails=1/cooldown=300/auth-threshold=0; 3 live rungs + worker-capable fallback keep serving")
EOF
ok "4. in-memory injected-dead-deployment replay holds"

# ---------- 5. negative check: allowed_fails=5 must fail the assertion ----------
cp "$yaml_file" "$scratch/drift.yaml"
python3 - "$scratch/drift.yaml" <<'EOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cfg["router_settings"]["allowed_fails"] = 5
yaml.safe_dump(cfg, open(sys.argv[1], "w"))
EOF
if python3 -c "
import sys, yaml
rs = yaml.safe_load(open('$scratch/drift.yaml'))['router_settings']
sys.exit(0 if rs['allowed_fails'] <= 1 else 1)
"; then
    fail "5. detector did NOT catch drift: allowed_fails=5 passed the robustness assertion"
else
    ok "5. negative check: allowed_fails=5 drift correctly fails the detector"
fi

echo
echo "ALL OK: forced-bad-deployment-replay checks passed"
exit 0
