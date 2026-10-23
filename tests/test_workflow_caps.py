import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"
AGENT = ROOT / ".github/workflows/agent.yml"
ROUTER = ROOT / "config/litellm-proxy.yaml"
SWEEP_MATRICES = ("unblocked", "remerge", "stuck-rework", "miss-stalled")
AGENT_RUNNERS_MEASURED_2026_10_23 = 22


def yaml_json(path):
    out = subprocess.run(["yq", "-o=json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def seats(model):
    cfg = yaml_json(ROUTER)
    return sum(
        int((row.get("litellm_params") or {}).get("max_parallel_requests") or 0)
        for row in cfg["model_list"]
        if row.get("model_name") == model
    )


def max_parallel(job):
    return str(yaml_json(DISPATCH)["jobs"][job]["strategy"]["max-parallel"])


def default_of(expr):
    match = re.search(r"\|\|\s*'(\d+)'", expr)
    assert match, f"max-parallel carries no numeric default: {expr}"
    return int(match.group(1))


def gate_park_labels():
    match = re.search(r"for l in (agent-blocked[^;]*);", AGENT.read_text())
    assert match, "agent.yml has no 'for l in agent-blocked ...' park list"
    return set(match.group(1).split())


def sweep_park_labels():
    match = re.search(r'IN\("agent-blocked"[^)]*\)', DISPATCH.read_text())
    assert match, 'the sweep has no IN("agent-blocked", ...) ref filter'
    return set(re.findall(r'"([a-z-]+)"', match.group(0)))


def test_sweep_matrices_share_one_governor():
    defaults = {}
    for job in SWEEP_MATRICES:
        expr = max_parallel(job)
        assert re.search(r"vars\.AGENT_MAX_PARALLEL\b", expr), f"{job} max-parallel does not read vars.AGENT_MAX_PARALLEL: {expr}"
        defaults[job] = default_of(expr)
    assert len(set(defaults.values())) == 1, f"the sweep matrices disagree on the fan-out: {defaults}"


def test_sweep_fanout_stays_inside_its_governors():
    fanout = default_of(max_parallel("unblocked"))
    assert fanout <= AGENT_RUNNERS_MEASURED_2026_10_23, (
        f"fan-out {fanout} exceeds the {AGENT_RUNNERS_MEASURED_2026_10_23} online agent runners"
    )
    assert fanout <= seats("worker-capable"), f"fan-out {fanout} exceeds the {seats('worker-capable')} worker-capable seats"


def test_review_concurrency_stays_inside_the_judge_seats():
    reviews = int(max_parallel("stuck-review"))
    assert reviews <= seats("judge"), f"review concurrency {reviews} exceeds the {seats('judge')} judge seats"


def test_sweep_drops_exactly_the_gate_park_labels():
    assert sweep_park_labels() == gate_park_labels()
