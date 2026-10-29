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
    "CommandCode idle": "money", "MiniMax idle": "money",
    "StepFun idle": "money", "z.ai idle": "money",
    "OpenCode Go idle": "money",
    "Alibaba token-plan SG idle": "money",
    "Session hop rate above 45%": "money",
    "Queue down for 2h agent-dispatch startup_failure": "outage: the queue cannot fix itself",
    **{f"Production deploy red for 24h {r}": "outage: the live site has not run main for a day" for r in (
        "Nishfleet/0509", "Nishfleet/aiconverter-app", "Nishfleet/drive",
        "Nishfleet/mailbox", "Nishfleet/siterep-public", "Nishfleet/seo-fix-kit")},
}
PAGE = "hermes-urgent"
SEVERITIES = ("critical", "warning")
CRITICAL_REPEAT = 3600
ISSUE_SINKS = {"fleet-alert-dispatch", "cloudflare-spend-dispatch", "router-dead-row-dispatch", "prometheus-alert-dispatch"}
GENERIC_SINK = "fleet-alert-dispatch"
# A paid plan out of credit keeps its rule firing until Nish acts, and the
# remedy is his, so its issue is filed weekly instead of daily: fleet-ops#9845,
# #9857, #9876 and #9897 are one Pareto credit wall across four issues. Paging is
# unchanged, a critical plan alert still reaches hermes-urgent at 1h.
PLAN_REPEAT = 604800
DEFAULT_REPEAT = 86400
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


def group_key(node, labels):
    """The Alertmanager group an alert lands in under this route: its group_by
    labels ('...' means every label, so each instance is its own group)."""
    by = node.get("group_by") or []
    return tuple(sorted(labels.items())) if "..." in by else tuple((k, labels.get(k, "")) for k in by)


def deepest(node, labels):
    """The route node (the first matching child, recursively) that owns these labels."""
    for child in node.get("routes") or []:
        if matches(child.get("object_matchers") or [], labels):
            return deepest(child, labels)
    return node


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


def dead_row_shape(rules, points, bad):
    rule = next((r for r in rules if r.get("uid") == "router-dead-row"), None)
    if rule is None:
        bad.append("router-dead-row: the rule is gone, so the proxy-level naming shape is no longer held anywhere")
        return
    expr = " ".join(next((d for d in rule.get("data") or [] if d.get("refId") == "A"), {}).get("model", {}).get("expr", "").split())
    row_side = 'sum by (model_id) (increase(litellm_deployment_failure_responses_total{exception_status=~"402|403|404",model_id!=""}[1h]))'
    proxy_side = 'or sum by (requested_model) (increase(litellm_deployment_failure_responses_total{exception_status=~"402|403|404",model_id=""}[1h]))'
    if row_side not in expr or proxy_side not in expr:
        bad.append("router-dead-row: the query must fire per router row (model_id) and per proxy-level series (requested_model) separately, so a page with no router row id still names the model it probed (fleet-ops#10069)")
    annotations = rule.get("annotations") or {}
    summary = annotations.get("summary", "")
    if '{{ with $labels.requested_model }}{{ . }} (proxy-level){{ else }}unknown row{{ end }}' not in summary:
        bad.append("router-dead-row: the summary must name a proxy-level series by its requested_model instead of 'unknown row'")
    description = annotations.get("description", "")
    if '{{ with $labels.requested_model }}{{ printf "%q" . }}{{ else }}MODEL_ID{{ end }}' not in description:
        bad.append("router-dead-row: the journal grep must fall back to the requested_model when the series carries no model_id")
    if "Do NOT remove or bench it without Nish's explicit yes" not in description or "{{ if $labels" in description:
        bad.append("router-dead-row: the description must keep the remove-or-bench gate for every series, proxy-level included")
    template = (points.get("router-dead-row-dispatch", {}).get("receivers") or [{}])[0].get("settings", {}).get("payload", {}).get("template", "")
    if ".Labels.requested_model" not in template or "proxy-level" not in template or "unnamed proxy request" not in template:
        bad.append("router-dead-row-dispatch: the issue title must name a proxy-level series by its requested_model instead of filing an empty row name")
    if re.search(r"(?<!\$)\$[A-Za-z_{]", template):
        bad.append("router-dead-row-dispatch: a template variable needs $$ in a contact point, or Grafana expands it to empty and the template fails to parse")


def main(root):
    selftest()
    rules, policy, contacts, contacts_doc, points = [], None, set(), [], {}
    for f in sorted(Path(root).glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        for g in doc.get("groups") or []:
            rules += g["rules"]
        for p in doc.get("policies") or []:
            policy = p
        for c in doc.get("contactPoints") or []:
            contacts.add(c["name"])
            points[c["name"]] = c
            contacts_doc.append(c)
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
        sinks = {rc.removesuffix("#muted"): rep for rc, rep in route(policy, {**labels, "alertname": title})}
        want = PLAN_REPEAT if "plan" in labels else DEFAULT_REPEAT
        got = sinks.get(GENERIC_SINK)
        if got is not None and got != want:
            bad.append(f"{title}: {GENERIC_SINK} must file its issue every {want}s "
                       f"({'a paid plan' if 'plan' in labels else 'any other rule'}), got {got}")
    dead_row_shape(rules, points, bad)
    # fleet-ops#10327: one host event (20 units failing) must file one issue per
    # alert name, not one per instance, and its body must name every instance.
    units = [{"signal": "prometheus", "severity": "warning", "alertname": "Prometheus alert firing",
              "prom_alertname": "SystemUnitFailed", "name": f"fleet-unit-{i}.service", "instance": "host"} for i in range(3)]
    keys = {group_key(deepest(policy, u), u) for u in units}
    if len(keys) != 1:
        bad.append(f"3 SystemUnitFailed instances form {len(keys)} notification groups, want 1")
    other = {**units[0], "prom_alertname": "RouterDown"}
    if group_key(deepest(policy, other), other) in keys:
        bad.append("two different alert names share one notification group")
    sink = [c for c in contacts_doc if c["name"] == "prometheus-alert-dispatch"]
    assert sink, "contact point prometheus-alert-dispatch not found"
    for rcv in sink[0]["receivers"]:
        tpl = rcv["settings"]["payload"]["template"]
        if "maxAlerts" in rcv["settings"] or "range $$.Alerts" not in tpl:
            bad.append("prometheus-alert-dispatch must not set maxAlerts and must range over every alert in its template")
        else:
            print(f"prometheus route: 3 SystemUnitFailed instances -> {len(keys)} group; template ranges over .Alerts")
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
