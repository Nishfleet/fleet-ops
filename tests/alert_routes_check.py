"""Who can Grafana page? (fleet-ops, Nish's message contract)

Only a real outage, a money problem, or something only Nish can act on may reach
hermes-urgent (Telegram); every other rule must reach the fleet as an issue.
This reads the provisioning files, works out the contact points each alert rule
can reach (its own notification_settings receiver, otherwise the notification
policy tree, also for the DatasourceError / DatasourceNoData alerts the rule can
turn into), and fails when the set of rules that can reach hermes-urgent differs
from URGENT below. Adding a paging rule means adding it here, with its reason.
It also fails when a rule or a dashboard panel reads a data source that this
repo does not provision (or one that was retired), because that read is blind
and the rule turns into a DatasourceError alert nobody can act on.

usage: alert_routes_check.py [provisioning/alerting dir]
"""
import json
import re
import sys
from pathlib import Path

import yaml

RETIRED_DATASOURCES = {
    # The nishfleet-worker App installation behind it is gone (fleet-ops#9803).
    "fleet-github-personal": "fleet-github",
}
RETIRED_OWNERS = {
    # Same cause: the App has no installation on the nish3451 account any more,
    # so a panel that names it reads nothing whatever data source it picks.
    "nish3451": "Nishfleet",
}
BUILTIN_DATASOURCES = {"-- Mixed --", "-- Grafana --", "-- Dashboard --", "__expr__"}

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
    assert re.search(r"\$[A-Za-z_{]", "{{ $labels.a }}".replace("$$", ""))
    assert not re.search(r"\$[A-Za-z_{]", "{{ $$labels.a }}".replace("$$", ""))


def provisioned_uids(provisioning):
    uids = set()
    for f in sorted((Path(provisioning) / "datasources").glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        for d in doc.get("datasources") or []:
            uids.add(d["uid"])
    assert uids, f"no data source provisioned under {provisioning}/datasources"
    return uids


def walk_refs(node, where, out):
    """Every datasource uid and query owner in a Grafana panel tree or rule model."""
    if isinstance(node, dict):
        ds = node.get("datasource")
        uid = ds.get("uid") if isinstance(ds, dict) else ds
        if uid:
            out.append((where, "datasource", uid))
        if node.get("datasourceUid"):
            out.append((where, "datasource", node["datasourceUid"]))
        if node.get("queryType") and node.get("owner"):
            out.append((where, "owner", node["owner"]))
        for key, value in node.items():
            if isinstance(value, (dict, list)):
                walk_refs(value, where if key in ("model", "options") else f"{where} > {key}", out)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            walk_refs(value, f"{where}[{i}]", out)


def datasource_refs(root, provisioning):
    """[(where, kind, value)] for every alert rule and dashboard panel that names one."""
    out = []
    for f in sorted(Path(root).glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        for g in doc.get("groups") or []:
            for r in g["rules"]:
                walk_refs(r, f"{f.name}: {r.get('title') or 'rule'}", out)
    for f in sorted((Path(provisioning).parent / "dashboards").glob("*.json")):
        walk_refs(json.loads(f.read_text()), f.name, out)
    assert len(out) >= 10, f"only {len(out)} data source references found; the walk is broken"
    return out


def check_datasource_refs(root, provisioning):
    uids = provisioned_uids(provisioning)
    bad = 0
    for where, kind, value in datasource_refs(root, provisioning):
        if kind == "owner" and value in RETIRED_OWNERS:
            print(f"::error::{where}: reads owner {value}, which this repo's App has no installation for; read {RETIRED_OWNERS[value]}")
            bad = 1
        elif kind == "datasource" and value in RETIRED_DATASOURCES:
            print(f"::error::{where}: data source {value} was retired, read {RETIRED_DATASOURCES[value]} instead")
            bad = 1
        elif kind == "datasource" and value not in uids and value not in BUILTIN_DATASOURCES:
            print(f"::error::{where}: data source {value} is not provisioned in provisioning/datasources")
            bad = 1
    if not bad:
        print(f"every rule and panel reads one of {len(uids)} provisioned data sources")
    return bad


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
    bad = check_datasource_refs(root, Path(root).parent)
    paging = {}
    for r in rules:
        for k, v in (r.get("labels") or {}).items():
            assert not re.search(r"\$[A-Za-z_{]", str(v).replace("$$", "")), f"{r['title']}: label {k} has an unescaped $ that Grafana provisioning expands before the template runs (write $$labels or drop the label)"
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
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "config/grafana/provisioning/alerting"))
