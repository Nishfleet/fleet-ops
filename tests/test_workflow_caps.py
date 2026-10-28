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
PERMISSION_LEVELS = {"none": 0, "read": 1, "write": 2}
WORKFLOWS = ROOT / ".github/workflows"


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


def test_the_pi_lane_has_one_cap_and_both_sides_read_it():
    text = AGENT.read_text()
    # The Gate (queue pull), the Worker fall-through and miss-review all compare the live pi
    # count against the same worker-capable seat sum, so the three cannot drift apart
    # (the removed opencode and devin lanes each had a hand-written constant instead).
    caps = re.findall(r'live pi\)"\s+-lt\s+(\S+)', text)
    assert len(caps) == 3, f"the pi lane has {len(caps)} comparisons, not the Gate, the Worker fall-through and miss-review: {caps}"
    assert set(caps) == {chr(34) + "$slots" + chr(34)}, f"every pi comparison must use the worker-capable seat sum: {sorted(set(caps))}"
    sum_line = "slots=" + chr(36) + "(yq"
    assert text.count(sum_line) == 3, "the seat sum is computed the same way in the Gate, the Worker and the queue pull"


def permissions_block(block, where):
    assert block is None or isinstance(block, dict), f"{where} uses the '{block}' shorthand; write the scopes out so this gate can read them"
    return block or {}


def agent_yml_requests():
    agent = yaml_json(AGENT)
    default = permissions_block(agent.get("permissions"), "agent.yml")
    asked = {}
    for name, job in agent["jobs"].items():
        block = permissions_block(job.get("permissions", default), f"agent.yml job {name}")
        for scope, level in block.items():
            assert level in PERMISSION_LEVELS, f"agent.yml job {name} asks {scope}: {level}; extend PERMISSION_LEVELS"
            asked[scope] = max(asked.get(scope, "none"), level, key=PERMISSION_LEVELS.get)
    return asked


def agent_yml_callers():
    found = []
    for path in sorted(WORKFLOWS.rglob("*.y*ml")):
        wf = yaml_json(path)
        for name, job in (wf.get("jobs") or {}).items():
            if str(job.get("uses") or "").split("@")[0].endswith("/agent.yml"):
                found.append((path.relative_to(ROOT).as_posix(), name, job, wf))
    return found


def test_every_agent_caller_grants_every_scope_agent_yml_jobs_request():
    asked = agent_yml_requests()
    assert asked, "agent.yml jobs request no permissions, so the caller grant check would pass vacuously"
    callers = agent_yml_callers()
    assert callers, "no workflow job calls agent.yml, so the caller grant check would pass vacuously"
    shortfalls = []
    for fname, jname, job, wf in callers:
        granted = permissions_block(job.get("permissions", wf.get("permissions")), f"{fname} job {jname}")
        for scope, level in sorted(asked.items()):
            have = PERMISSION_LEVELS.get(str(granted.get(scope, "none")), -1)
            if have < PERMISSION_LEVELS[level]:
                gives = f"{scope}: {granted.get(scope, 'none')}" if granted else "no permissions at all"
                shortfalls.append(f"{fname} job {jname} grants {gives}, agent.yml asks {scope}: {level}")
    assert not shortfalls, (
        "GitHub kills the whole run at startup when a caller job grants less than the called workflow's jobs request: "
        + "; ".join(shortfalls)
    )


def test_hand_summons_reaches_the_review_job():
    cfg = yaml_json(AGENT)
    dispatch = cfg["on"]["workflow_dispatch"]["inputs"]
    for name in ("review_pr", "review_sha"):
        assert dispatch.get(name, {}).get("type") == "string", f"agent.yml cannot be dispatched with {name}"
        assert name in cfg["on"]["workflow_call"]["inputs"], f"{name} is not on the workflow_call surface"
    review = cfg["jobs"]["review"]
    assert "inputs.review_pr" in review["if"] and "inputs.review_sha" in review["if"], (
        "the review job's if: does not read the dispatch inputs, so a hand summons reaches nothing"
    )
    main_only = "(github.event_name != 'workflow_dispatch' || github.ref == 'refs/heads/main')"
    for job in ("review", "arm"):
        cond = cfg["jobs"][job]["if"].replace("${{", "").replace("}}", "").strip()
        assert f"&& {main_only}" in cond, (
            f"the {job} job can be dispatched from any branch: a pushed branch with an edited {job} job "
            "would approve or arm under the bot identity the merge gate trusts"
        )
    assert review["env"]["PR"] == "${{ inputs.review_pr }}"
    assert review["env"]["SHA"] == "${{ inputs.review_sha }}"
    assert "!inputs.review_pr" in cfg["jobs"]["inish-daily"]["if"], (
        "inish-daily's if: does not exclude review_pr, so a review summons would also publish an edition"
    )


def test_hand_summons_reaches_the_orchestrate_job():
    cfg = yaml_json(DISPATCH)
    dispatch = cfg["on"]["workflow_dispatch"]["inputs"]
    for name in ("task", "issue"):
        assert dispatch.get(name, {}).get("type") == "string", f"agent-dispatch cannot be dispatched with {name}"
    orchestrate = cfg["jobs"]["orchestrate"]["if"]
    assert "inputs.task == 'orchestrate'" in orchestrate, "the orchestrate job's if: does not read inputs.task"
    assert "inputs.issue != ''" in orchestrate, "the orchestrate job's if: does not read inputs.issue"
