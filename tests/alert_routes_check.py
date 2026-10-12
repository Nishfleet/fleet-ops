"""Who can Grafana page? (fleet-ops, Nish's message contract)

Only a real outage, a money problem, or something only Nish can act on may reach
hermes-urgent (Telegram); every other rule must reach the fleet as an issue.
This reads the provisioning files, works out the contact points each alert rule
can reach (its own notification_settings receiver, otherwise the notification
policy tree, also for the DatasourceError / DatasourceNoData alerts the rule can
turn into), and fails when the set of rules that can reach hermes-urgent differs
from URGENT below. Adding a paging rule means adding it here, with its reason.

usage: alert_routes_check.py [provisioning/alerting dir]
"""
import re
import sys
from pathlib import Path

import yaml

URGENT = {
    # money: the cost alarm and the rule that says the cost alarm could not report
    "Cloudflare Workers AI neurons": "money",
    "Cloudflare D1 rows read": "money",
    "Cloudflare D1 rows written": "money",
    "Cloudflare email sends": "money",
    "Cloudflare R2 Standard storage total": "money",
    "Cloudflare R2 bucket growth": "money",
    "Cost alarm GitHub issue delivery failed": "money: the cost alarm could not report",
    "Prompt-cache read share below 50%": "money: every request pays full input price",
    # money: a paid plan sits unused, and cancelling it is Nish's call
    "Cline idle": "money", "CommandCode idle": "money", "MiniMax idle": "money",
    "StepFun idle": "money", "z.ai idle": "money", "Ollama idle": "money",
    "OpenCode Go idle": "money", "Pareto idle": "money",
    "Alibaba token-plan SG idle": "money",
}
PAGE = "hermes-urgent"
ERR = ("DatasourceError", "DatasourceNoData")


def matches(matchers, labels):
    for name, op, value in matchers:
        have = labels.get(name, "")
        if op == "=" and have != value:
            return False
        if op == "!=" and have == value:
            return False
        if op == "=~" and not re.fullmatch(value, have):
            return False
        if op == "!~" and re.fullmatch(value, have):
            return False
    return True


def route(node, labels):
    """Receivers reached by an alert with these labels (Alertmanager tree walk)."""
    out = set()
    for child in node.get("routes") or []:
        if matches(child.get("object_matchers") or [], labels):
            out |= route(child, labels)
            if not child.get("continue"):
                return out
    return out | {node["receiver"]}


def selftest():
    """The tree walk must follow Alertmanager: a matching child (also with continue)
    contributes its own receiver, or its sub-route's when one matches; a non-matching
    sub-route leaves the child's receiver; the root applies only when nothing matched."""
    tree = {"receiver": "root", "routes": [
        {"receiver": "a", "object_matchers": [["x", "=", "1"]], "continue": True,
         "routes": [{"receiver": "a-sub", "object_matchers": [["y", "=", "1"]]}]},
        {"receiver": "b", "object_matchers": [["x", "=~", "1|2"]]}]}
    assert route(tree, {"x": "1", "y": "1"}) == {"a-sub", "b"}
    assert route(tree, {"x": "1", "y": "0"}) == {"a", "b"}
    assert route(tree, {"x": "2"}) == {"b"}
    assert route(tree, {"x": "3"}) == {"root"}
    assert route(tree, {"x": "11"}) == {"root"}  # =~ is anchored


def main(root):
    selftest()
    rules, policy, contacts = [], None, set()
    for f in sorted(Path(root).glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        for g in doc.get("groups") or []:
            rules += g["rules"]
        for p in doc.get("policies") or []:
            policy = p
        for c in doc.get("contactPoints") or []:
            contacts.add(c["name"])
    assert policy, "no notification policy found"
    paging = {}
    for r in rules:
        own = (r.get("notification_settings") or {}).get("receiver")
        reached = set()
        for alertname in (r["title"], *ERR):
            labels = {**(r.get("labels") or {}), "alertname": alertname}
            reached |= {own} if own else route(policy, labels)
        missing = reached - contacts
        assert not missing, f"{r['title']}: unknown contact point(s) {missing}"
        if PAGE in reached:
            paging[r["title"]] = sorted(reached)
    extra = sorted(set(paging) - set(URGENT))
    gone = sorted(set(URGENT) - set(paging))
    for t in sorted(paging):
        print(f"pages: {t} -> {paging[t]}")
    if extra or gone:
        print(f"::error::rules that can page but are not urgent: {extra}; urgent rules that no longer page: {gone}")
        return 1
    print(f"{len(paging)} of {len(rules)} rules can page; every other rule reaches the fleet only")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "config/grafana/provisioning/alerting"))
