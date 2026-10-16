"""Does every Grafana alert rule route by severity? (fleet-ops, Nish's alerting contract)

Every alert rule carries a severity label, critical or warning, and no rule
overrides the notification policy tree with its own notification_settings. The
tree pages hermes-urgent (Telegram) by severity: critical re-sends at least
hourly, warning at least daily. Every firing alert, whatever its severity, also
reaches a webhook that files a fleet-ops issue. This reads the provisioning
files, walks the policy tree for each rule (also for the DatasourceError and
DatasourceNoData alerts the rule can turn into), and fails when any of that does
not hold.

usage: alert_routes_check.py [provisioning/alerting dir]
"""
import re
import sys
from pathlib import Path

import yaml

SEVERITIES = {"critical": 3600, "warning": 86400}
PAGE = "hermes-urgent"
ISSUE_SINKS = {"fleet-alert-dispatch", "cloudflare-spend-dispatch", "router-dead-row-dispatch"}
ERR = ("DatasourceError", "DatasourceNoData")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def seconds(text):
    parts = re.findall(r"(\d+)([smhdw])", str(text))
    assert parts and "".join(f"{n}{u}" for n, u in parts) == str(text), f"unreadable duration {text!r}"
    return sum(int(n) * UNITS[u] for n, u in parts)


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


def route(node, labels, repeat=None):
    """(receiver, repeat seconds) pairs reached by an alert with these labels
    (Alertmanager tree walk): a matching child contributes its own receivers and
    stops the walk unless it has continue; the node's own receiver applies only
    when no child matched; repeat_interval is inherited from the parent."""
    if node.get("repeat_interval") is not None:
        repeat = seconds(node["repeat_interval"])
    out, matched = set(), False
    for child in node.get("routes") or []:
        if matches(child.get("object_matchers") or [], labels):
            matched = True
            out |= route(child, labels, repeat)
            if not child.get("continue"):
                return out
    return out if matched else {(node["receiver"], repeat)}


def selftest():
    tree = {"receiver": "root", "repeat_interval": "24h", "routes": [
        {"receiver": "a", "object_matchers": [["x", "=", "1"]], "continue": True, "repeat_interval": "1h",
         "routes": [{"receiver": "a-sub", "object_matchers": [["y", "=", "1"]]}]},
        {"receiver": "b", "object_matchers": [["x", "=~", "1|2"]]}]}
    assert route(tree, {"x": "1", "y": "1"}) == {("a-sub", 3600), ("b", 86400)}
    assert route(tree, {"x": "1", "y": "0"}) == {("a", 3600), ("b", 86400)}
    assert route(tree, {"x": "2"}) == {("b", 86400)}
    assert route(tree, {"x": "3"}) == {("root", 86400)}
    assert route(tree, {"x": "11"}) == {("root", 86400)}
    only = {"receiver": "root", "routes": [{"receiver": "a", "object_matchers": [["x", "=", "1"]], "continue": True}]}
    assert route(only, {"x": "1"}) == {("a", None)}
    assert seconds("1h") == 3600 and seconds("1h30m") == 5400 and seconds("24h") == 86400
    assert re.search(r"\$[A-Za-z_{]", "{{ $labels.a }}".replace("$$", ""))
    assert not re.search(r"\$[A-Za-z_{]", "{{ $$labels.a }}".replace("$$", ""))


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
    assert PAGE in contacts and ISSUE_SINKS <= contacts, f"missing contact points {sorted(({PAGE} | ISSUE_SINKS) - contacts)}"
    bad, counts = [], {s: 0 for s in SEVERITIES}
    for r in rules:
        title, labels = r["title"], r.get("labels") or {}
        for k, v in labels.items():
            assert not re.search(r"\$[A-Za-z_{]", str(v).replace("$$", "")), f"{title}: label {k} has an unescaped $ that Grafana provisioning expands before the template runs (write $$labels or drop the label)"
        severity = labels.get("severity")
        if severity not in SEVERITIES:
            bad.append(f"{title}: severity label is {severity!r}, want one of {sorted(SEVERITIES)}")
            continue
        counts[severity] += 1
        if r.get("notification_settings"):
            bad.append(f"{title}: notification_settings bypasses the policy tree")
            continue
        for alertname in (title, *ERR):
            reached = route(policy, {**labels, "alertname": alertname})
            unknown = {rc for rc, _ in reached} - contacts
            if unknown:
                bad.append(f"{title}: unknown contact point(s) {sorted(unknown)}")
            if not {rc for rc, _ in reached} & ISSUE_SINKS:
                bad.append(f"{title} ({alertname}): no webhook that files a fleet-ops issue")
        reached = route(policy, {**labels, "alertname": title})
        pages = [rep for rc, rep in reached if rc == PAGE]
        if not pages:
            bad.append(f"{title}: {severity} alert does not reach {PAGE}")
        elif any(rep is None or rep > SEVERITIES[severity] for rep in pages):
            bad.append(f"{title}: {severity} alert pages with repeat_interval {pages}, want <= {SEVERITIES[severity]}s")
    if bad:
        for b in bad:
            print(f"::error::{b}")
        return 1
    print(f"{len(rules)} rules: {counts['critical']} critical (page every <=1h), {counts['warning']} warning (page every <=24h), all also file a fleet-ops issue")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "config/grafana/provisioning/alerting"))
