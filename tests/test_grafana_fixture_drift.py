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
]


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


def _fixture_expr(fixture, alert):
    rules = _yq(f'[.groups[].rules[] | select(.alert == "{alert}")]', FIXTURES / fixture)
    assert len(rules) == 1, f"{fixture} has {len(rules)} rules alerting {alert}, want 1"
    return rules[0]["expr"]


QUOTED = re.compile(r'("[^"]*")')


def _flatten(expr):
    return "".join(part if part.startswith('"') else "".join(part.split()) for part in QUOTED.split(expr))


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
