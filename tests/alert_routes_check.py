"""Which Grafana rules page Nish, and how often? (fleet-ops, Nish's message contract)

Only a real outage, a money problem, or something only Nish can act on may reach
hermes-urgent (Telegram); every other rule reaches the fleet as an issue. Every
rule carries a severity label: critical for the rules in URGENT (they page again
at least hourly until they resolve), warning for every other rule (never pages).
Every firing alert, whatever its severity, also reaches a webhook that files a
fleet-ops issue. No rule may set its own notification_settings, which would
bypass the policy tree. This reads the provisioning files, walks the policy tree
for each rule (also for the DatasourceError and DatasourceNoData alerts the rule
can turn into), and fails when any of that does not hold. Adding a paging rule
means adding it to URGENT here, with its reason, and labelling it critical.

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
    **{f"Production deploy red for 24h {r}": "outage: the live site has not run main for a day" for r in (
        "Nishfleet/0509", "Nishfleet/aiconverter-app", "Nishfleet/drive",
        "Nishfleet/mailbox", "Nishfleet/siterep-public", "Nishfleet/seo-fix-kit")},
}
PAGE = "hermes-urgent"
SEVERITIES = ("critical", "warning")
CRITICAL_REPEAT = 3600
ISSUE_SINKS = {"fleet-alert-dispatch", "cloudflare-spend-dispatch", "router-dead-row-dispatch"}
ERR = ("DatasourceError", "DatasourceNoData")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def seconds(text):
    parts = re.findall(r"(\d+)([smhdw])", str(text))
    if not parts or "".join(f"{n}{u}" for n, u in parts) != str(text):
        raise ValueError(f"unreadable duration {text!r}")
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
    if node.get("mute_time_intervals"):
        return {(node["receiver"] + "#muted", repeat)}
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
    bad, paging = [], {}
    for r in rules:
        title, labels = r["title"], r.get("labels") or {}
        for k, v in labels.items():
            assert not re.search(r"\$[A-Za-z_{]", str(v).replace("$$", "")), f"{title}: label {k} has an unescaped $ that Grafana provisioning expands before the template runs (write $$labels or drop the label)"
        severity = labels.get("severity")
        if severity not in SEVERITIES:
            bad.append(f"{title}: severity label is {severity!r}, want one of {list(SEVERITIES)}")
            continue
        if severity != ("critical" if title in URGENT else "warning"):
            bad.append(f"{title}: severity {severity} but {'it is in' if title in URGENT else 'it is not in'} the urgent list")
        if r.get("notification_settings"):
            bad.append(f"{title}: notification_settings bypasses the policy tree")
            continue
        reached_any = set()
        for alertname in (title, *ERR):
            reached = route(policy, {**labels, "alertname": alertname})
            reached_any |= {rc for rc, _ in reached}
            unknown = {rc.removesuffix("#muted") for rc, _ in reached} - contacts
            if unknown:
                bad.append(f"{title}: unknown contact point(s) {sorted(unknown)}")
            if all(rc.endswith("#muted") for rc, _ in reached):
                continue
            if not {rc for rc, _ in reached} & ISSUE_SINKS:
                bad.append(f"{title} ({alertname}): no webhook that files a fleet-ops issue")
        if PAGE in reached_any:
            paging[title] = sorted(reached_any)
        pages = [rep for rc, rep in route(policy, {**labels, "alertname": title}) if rc == PAGE]
        if severity == "critical" and (not pages or any(rep is None or rep > CRITICAL_REPEAT for rep in pages)):
            bad.append(f"{title}: critical alert must page {PAGE} with repeat_interval <= {CRITICAL_REPEAT}s, got {pages}")
    extra = sorted(set(paging) - set(URGENT))
    gone = sorted(set(URGENT) - set(paging))
    for t in sorted(paging):
        print(f"pages: {t} -> {paging[t]}")
    if extra or gone:
        bad.append(f"rules that can page but are not urgent: {extra}; urgent rules that no longer page: {gone}")
    if bad:
        for b in bad:
            print(f"::error::{b}")
        return 1
    print(f"{len(paging)} of {len(rules)} rules can page (critical, every <=1h); the other {len(rules) - len(paging)} are warning and reach the fleet only; every rule files a fleet-ops issue")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "config/grafana/provisioning/alerting"))
