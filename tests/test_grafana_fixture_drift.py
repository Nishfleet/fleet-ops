import json
import pathlib
import re
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROVISIONING = ROOT / "config/grafana/provisioning/alerting"
FIXTURES = ROOT / "config/grafana/tests"
YQ = shutil.which("yq")

FIXTURED_RULES = [
    ("prompt-cache-hit.yaml", "prompt-cache-hit-low", "prompt-cache-hit.test.rules.yml", "PromptCacheHitLow"),
    ("paid-plan-idle.yaml", "ppi-alibaba", "paid-plan-idle.test.rules.yml", "AlibabaTokenPlanSgIdle"),
    ("paid-plan-idle.yaml", "ppi-commandcode", "paid-plan-idle.test.rules.yml", "CommandCodeIdle"),
    ("paid-plan-idle.yaml", "ppi-minimax", "paid-plan-idle.test.rules.yml", "MiniMaxIdle"),
    ("router-dead-row.yaml", "router-dead-row", "router-dead-row.test.rules.yml", "RouterRowAnswers402403404"),
]
GUARD = (
    "prompt-cache-share-guard.yaml",
    "prompt-cache-share-guard",
    "prompt-cache-share-guard.test.rules.yml",
    "PromptCacheShareBelowBaseline",
)
GUARD_FIXTURE = "prompt-cache-share-guard.test.yml"
FLOOR = re.compile(r'vector\(([0-9.]+)\), "vendor", "([a-z0-9]+)"')


def _yq(expr, path):
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", expr, str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def _rule(rule_file, uid):
    rules = _yq(f'[.groups[].rules[] | select(.uid == "{uid}")]', PROVISIONING / rule_file)
    assert len(rules) == 1, f"{rule_file} has {len(rules)} rules with uid {uid}, want 1"
    return rules[0]


def _deployed_a(rule_file, uid):
    queries = [d for d in _rule(rule_file, uid)["data"] if d.get("refId") == "A"]
    assert len(queries) == 1, f"{rule_file}'s {uid} has {len(queries)} A queries, want 1"
    return queries[0]["model"]["expr"]


def _threshold(rule_file, uid):
    rule = _rule(rule_file, uid)
    steps = [d for d in rule["data"] if d.get("refId") == rule["condition"]]
    assert len(steps) == 1, f"{rule_file}'s {uid} has {len(steps)} queries at condition {rule['condition']}, want 1"
    evaluator = steps[0]["model"]["conditions"][0]["evaluator"]
    assert evaluator["type"] == "gt", f"{rule_file}'s {uid} thresholds with {evaluator['type']}, want gt"
    return f"> {evaluator['params'][0]:g}"


def _fixture_rule(fixture, alert):
    rules = _yq(f'[.groups[].rules[] | select(.alert == "{alert}")]', FIXTURES / fixture)
    assert len(rules) == 1, f"{fixture} has {len(rules)} rules alerting {alert}, want 1"
    return rules[0]


def _fixture_expr(fixture, alert):
    return _fixture_rule(fixture, alert)["expr"]


QUOTED = re.compile(r'("[^"]*")')


def _flatten(expr):
    return "".join(part if part.startswith('"') else "".join(part.split()) for part in QUOTED.split(expr))


def _floors(expr):
    return sorted((vendor, value) for value, vendor in FLOOR.findall(expr))


@pytest.mark.parametrize(("rule_file", "uid", "fixture", "alert"), FIXTURED_RULES)
def test_fixture_carries_the_deployed_a_expression(rule_file, uid, fixture, alert):
    expected = f"({_deployed_a(rule_file, uid)})\n{_threshold(rule_file, uid)}"
    actual = _fixture_expr(fixture, alert)
    assert _flatten(actual) == _flatten(expected), (
        f"{fixture} no longer carries {rule_file}'s {uid} A expression under Grafana's threshold, so promtool "
        f"tests a copy: the fixture stays green while the deployed rule drifts. Rewrite the expr from the "
        f"provisioning rule.\n"
        f"want {PROVISIONING.name}/{rule_file} {uid} A:\n{expected}\n"
        f"got {FIXTURES.name}/{fixture} {alert}:\n{actual}"
    )


@pytest.mark.parametrize(("rule_file", "uid", "fixture", "alert"), FIXTURED_RULES)
def test_fixture_carries_the_deployed_hold(rule_file, uid, fixture, alert):
    deployed = _rule(rule_file, uid).get("for") or "0s"
    actual = _fixture_rule(fixture, alert).get("for") or "0s"
    assert actual == deployed, (
        f"{fixture} evaluates {alert} with a {actual} hold while {rule_file}'s {uid} deploys {deployed}, so "
        f"promtool replays a different rule: the fixture stays green while the deployed hold shrinks back to a "
        f"page on the first burst. Copy the deployed `for` into the fixture."
    )


def test_prompt_cache_floors_match_across_the_three_copies():
    rule_file, uid, fixture, alert = GUARD
    deployed = f"{PROVISIONING.name}/{rule_file} {uid} A"
    copies = {
        deployed: _deployed_a(rule_file, uid),
        f"{FIXTURES.name}/{fixture}": _fixture_expr(fixture, alert),
        f"{FIXTURES.name}/{GUARD_FIXTURE} promql_expr_test": "\n".join(
            _yq("[.tests[].promql_expr_test[].expr]", FIXTURES / GUARD_FIXTURE)
        ),
    }
    expected = _floors(copies[deployed])
    assert expected, f"{deployed} carries no vendor floor"
    for name, expr in copies.items():
        got = _floors(expr)
        assert got == expected, (
            f"{name} floors {got} where {deployed} floors {expected}. promtool never reads the provisioning file "
            f"and no case exercises every vendor, so a floor that moves in one copy and not the others leaves the "
            f"fixture green while the deployed rule judges by another bar. Copy the deployed floors into {name}."
        )
