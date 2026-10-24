import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RULES = ROOT / "config/grafana/provisioning/alerting/fleet-host.yaml"
FIXTURE = ROOT / "config/grafana/tests/fleet-host.test.rules.yml"
YQ = shutil.which("yq")


def _yq(expr, path):
    assert YQ, "yq must be on PATH to read the alert rules"
    return json.loads(subprocess.run([YQ, "-o=json", expr, str(path)], capture_output=True, text=True, check=True).stdout)


def test_the_rule_reads_the_failed_unit_state_through_the_prometheus_data_source():
    (rule,) = [r for group in _yq(".groups", RULES) for r in group["rules"]]
    assert (rule["uid"], rule["title"], rule["condition"]) == ("host-systemd-unit-failed", "SystemUnitFailed", "C")
    assert (rule["for"], rule["noDataState"], rule["execErrState"]) == ("5m", "OK", "Error")
    assert rule["labels"] == {"severity": "warning", "signal": "host-unit"}
    query, condition = rule["data"]
    assert (query["refId"], query["datasourceUid"], query["model"]["datasource"]["uid"]) == ("A", "fleet-prometheus", "fleet-prometheus")
    assert (query["model"]["expr"], query["model"]["instant"]) == ('node_systemd_unit_state{state="failed"} == 1', True)
    assert (condition["refId"], condition["datasourceUid"], condition["model"]["type"]) == ("C", "__expr__", "threshold")
    assert condition["model"]["expression"] == "A"
    assert condition["model"]["conditions"] == [{
        "evaluator": {"params": [0], "type": "gt"},
        "operator": {"type": "and"},
        "query": {"params": ["C"]},
        "reducer": {"params": [], "type": "last"},
        "type": "query",
    }]


def test_the_promtool_fixture_carries_the_rules_expression_for_duration_and_labels():
    (rule,) = [r for group in _yq(".groups", RULES) for r in group["rules"]]
    (fixture,) = [r for group in _yq(".groups", FIXTURE) for r in group["rules"]]
    assert fixture["alert"] == rule["title"]
    assert fixture["expr"] == rule["data"][0]["model"]["expr"]
    assert fixture["for"] == rule["for"]
    assert fixture["annotations"] == rule["annotations"]
    assert {k: v for k, v in fixture["labels"].items() if k != "grafana_folder"} == rule["labels"]
