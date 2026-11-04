"""A firing alert group files one issue per repeat_interval, not one per new instance.

Alertmanager re-sends a group after group_interval whenever an instance joins it
(https://prometheus.io/docs/alerting/latest/configuration/#route). With 5m, one
SystemUnitFailed cause filed six fleet-ops issues in an hour on 2026-11-04, and
each issue starts a lane run.
"""

import pathlib

import yaml

POLICY = (
    pathlib.Path(__file__).resolve().parents[1]
    / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"
)


def test_grouped_issue_routes_resend_only_on_repeat():
    routes = [
        r
        for p in yaml.safe_load(POLICY.read_text())["policies"]
        for r in p.get("routes", [])
    ]
    grouped = [r for r in routes if "..." not in r.get("group_by", ["..."])]
    assert grouped, "no route groups alerts, so this test checks nothing"
    for r in grouped:
        assert r["group_interval"] == r["repeat_interval"], (
            f"{r['receiver']}: group_interval {r['group_interval']} < repeat_interval {r['repeat_interval']} "
            "files a new issue each time an instance joins the group; set group_interval to repeat_interval"
        )
