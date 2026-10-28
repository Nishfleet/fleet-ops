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
It also fails when a rule or a dashboard panel reads a data source this repo does
not provision, or an owner this repo's GitHub App has no installation for: that
read is blind, and a rule that reads nothing turns into a DatasourceError alert
nobody can act on (fleet-ops#9803).

It also holds the other end of the alert path: Alertmanager's API answers only
with basic auth, and every Prometheus client of it carries the credential
(fleet-ops#10058). Two files have to agree for that to hold and nothing else
in CI compares them: the options file that names the web config, and
Prometheus's client config, which needs the matching plaintext for both the
alerting target and the scrape job. A drift in the first stops the service
from starting. A drift in the second is silent until the outside dead-man
notices that the alert set stopped arriving. The credential pair itself is
hand-placed host state, root- and service-owned: any process that can reach
the loopback listener already runs as nish, so a credential nish could read
would protect nothing.

usage: alert_routes_check.py [provisioning/alerting dir]
"""
import json
import re
import sys
import tempfile
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
# A data source that was provisioned and then removed keeps its readers blind, so
# each one names the replacement the reader must take (fleet-ops#9803).
RETIRED_DATASOURCES = {"fleet-github-personal": "fleet-github"}
RETIRED_OWNERS = {"nish3451": "Nishfleet"}
# Grafana writes the built-in sources several ways: the UI names two of them, the
# expression engine uses __expr__, and a saved expression node carries -100 (older
# rules) or "grafana" (newer ones) as its data source uid.
BUILTIN_DATASOURCES = {"-- Mixed --", "-- Dashboard --", "-- Grafana --", "__expr__", "-100", "grafana"}


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


AM_OPTIONS = "rootfs/etc/default/prometheus-alertmanager"
AM_PROMETHEUS = "rootfs/etc/prometheus/prometheus.yml"
AM_WEB_CONFIG = "/etc/alertmanager/web.yml"
AM_AUTH_FILE = "/etc/prometheus/alertmanager_password"


def alertmanager_auth(repo):
    """What CI alone can see of the alertmanager credential: the options file that
    names the web config, and the client config that sends the credential to it.
    The two halves of the pair are hand-placed host state, so only a deploy can
    compare them; this catches the drift that is silent until then."""
    bad = []
    args = ""
    for line in (repo / AM_OPTIONS).read_text().splitlines():
        if line.startswith("ARGS="):
            args = line
    if f"--web.config.file={AM_WEB_CONFIG}" not in args:
        bad.append(f"{AM_OPTIONS}: ARGS does not set --web.config.file={AM_WEB_CONFIG}")
    if "--web.listen-address=127.0.0.1:9093" not in args:
        bad.append(f"{AM_OPTIONS}: ARGS no longer pins the listener to loopback")
    config = yaml.safe_load((repo / AM_PROMETHEUS).read_text())
    clients = [("alerting.alertmanagers", e) for e in (config.get("alerting") or {}).get("alertmanagers") or []]
    clients += [(f"scrape_configs[{j.get('job_name')}]", j) for j in config.get("scrape_configs") or [] if j.get("job_name") == "alertmanager"]
    if len(clients) < 2:
        bad.append(f"{AM_PROMETHEUS}: want an alerting target and an alertmanager scrape job, found {len(clients)}")
    for name, entry in clients:
        auth = entry.get("basic_auth")
        if not auth:
            bad.append(f"{AM_PROMETHEUS}: {name} has no basic_auth, so Alertmanager answers it 401")
            continue
        if not auth.get("username"):
            bad.append(f"{AM_PROMETHEUS}: {name} basic_auth has no username")
        if auth.get("password") or auth.get("password_file") != AM_AUTH_FILE:
            bad.append(f"{AM_PROMETHEUS}: {name} basic_auth must read password_file {AM_AUTH_FILE}, not an inline password")
    return bad


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
    repo = Path(__file__).resolve().parents[1]
    findings = alertmanager_auth(repo)
    assert findings == [], findings
    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp)
        for rel in (AM_OPTIONS, AM_PROMETHEUS):
            (fixture / rel).parent.mkdir(parents=True, exist_ok=True)
            (fixture / rel).write_text((repo / rel).read_text())
        doc = yaml.safe_load((fixture / AM_PROMETHEUS).read_text())
        for entry in (doc.get("alerting") or {}).get("alertmanagers") or []:
            entry.pop("basic_auth", None)
        for job in doc.get("scrape_configs") or []:
            if job.get("job_name") == "alertmanager":
                job.pop("basic_auth", None)
        (fixture / AM_PROMETHEUS).write_text(yaml.safe_dump(doc))
        assert sum("has no basic_auth" in f for f in alertmanager_auth(fixture)) == 2, alertmanager_auth(fixture)
        (fixture / AM_PROMETHEUS).write_text((repo / AM_PROMETHEUS).read_text())
        (fixture / AM_OPTIONS).write_text('ARGS="--config.file=/etc/alertmanager/alertmanager.yml --web.listen-address=127.0.0.1:9093"\n')
        assert any("--web.config.file" in f for f in alertmanager_auth(fixture)), alertmanager_auth(fixture)
        (fixture / AM_OPTIONS).write_text((repo / AM_OPTIONS).read_text())
    refs = []
    walk_refs({"datasource": {"uid": "x"}, "targets": [
        {"datasource": ["a", "b"]},
        {"datasource": {"uid": "fleet-github-personal"}, "queryType": "Issues", "owner": "nish3451"}]}, "f", refs)
    assert ("f", "datasource", "x") in refs
    assert ("f > targets[0]", "datasource", "a") not in refs
    assert ("f > targets[1]", "datasource", "fleet-github-personal") in refs
    assert ("f > targets[1]", "owner", "nish3451") in refs
    var = []
    walk_refs({"datasource": {"uid": "${DS}"}}, "f", var)
    assert [v for _, k, v in var if k == "variable"] == ["${DS}"]
    planted = ref_findings({"fleet-github"}, [
        ("f", "datasource", "fleet-github"), ("f", "datasource", "fleet-github-personal"),
        ("f", "owner", "nish3451"), ("f", "datasource", "gone"),
        ("f", "datasource", "-100"), ("f", "variable", "${DS}")])
    assert planted == ["f: data source fleet-github-personal was retired, read fleet-github instead",
                       "f: reads owner nish3451, which this repo's App has no installation for; read Nishfleet",
                       "f: data source gone is not provisioned in provisioning/datasources"], planted


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


def provisioned_uids(provisioning):
    uids = set()
    for f in sorted((Path(provisioning) / "datasources").glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        for d in doc.get("datasources") or []:
            assert d.get("uid"), f"{f.name}: a data source without a uid cannot be referenced"
            uids.add(d["uid"])
    assert uids, f"no data source provisioned under {provisioning}/datasources"
    return uids


def walk_refs(node, where, out):
    """Every data source uid, query owner and template variable in a rule model or
    a dashboard panel tree, as (where, kind, value)."""
    if isinstance(node, dict):
        ds = node.get("datasource")
        uid = ds.get("uid") if isinstance(ds, dict) else ds
        if isinstance(uid, str) and uid:
            out.append((where, "variable" if "${" in uid else "datasource", uid))
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
    """[(where, kind, value)] for every alert rule and dashboard panel that names one.
    A file that carries a rule or a dashboard but names no data source at all is a
    broken walk, not a silent pass."""
    out, per_file = [], {}
    for f in sorted(Path(root).glob("*.y*ml")):
        doc = yaml.safe_load(f.read_text()) or {}
        rules = [r for g in doc.get("groups") or [] for r in g["rules"]]
        before = len(out)
        for r in rules:
            walk_refs(r, f"{f.name}: {r.get('title') or 'rule'}", out)
        if rules:
            per_file[f.name] = len(out) - before
    dash = Path(provisioning).parent / "dashboards"
    files = sorted(dash.glob("*.json"))
    assert files, f"no dashboard json under {dash}"
    for f in files:
        before = len(out)
        walk_refs(json.loads(f.read_text()), f.name, out)
        per_file[f.name] = len(out) - before
    silent = sorted(k for k, n in per_file.items() if not n)
    assert not silent, f"{silent} carry rules or a dashboard but name no data source, so the walk never reached them"
    return out


def ref_findings(uids, refs):
    """Findings for every reference that reads a data source this repo does not
    provision, or an owner its GitHub App has no installation for."""
    bad = []
    for where, kind, value in refs:
        if kind == "owner" and value.lower() in RETIRED_OWNERS:
            bad.append(f"{where}: reads owner {value}, which this repo's App has no installation for; read {RETIRED_OWNERS[value.lower()]}")
        elif kind == "datasource" and value in RETIRED_DATASOURCES:
            bad.append(f"{where}: data source {value} was retired, read {RETIRED_DATASOURCES[value]} instead")
        elif kind == "datasource" and value not in uids and value not in BUILTIN_DATASOURCES:
            bad.append(f"{where}: data source {value} is not provisioned in provisioning/datasources")
    return bad


def check_datasource_refs(root, provisioning):
    uids = provisioned_uids(provisioning)
    bad = ref_findings(uids, datasource_refs(root, provisioning))
    if not bad:
        print(f"every rule and panel reads one of {len(uids)} provisioned data sources")
    return bad


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
    bad, paging = check_datasource_refs(root, Path(root).parent), {}
    for c in contacts_doc:
        for rcv in c.get("receivers") or []:
            if ".GeneratorURL" in json.dumps(rcv):
                bad.append(f"{c['name']}: the issue body must not interpolate .GeneratorURL, the private Grafana host, because this repo is public (fleet-ops#10763)")
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
    bad += alertmanager_auth(Path(__file__).resolve().parents[1])
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
    print(f"alertmanager: the options require {AM_WEB_CONFIG}, and both Prometheus paths read {AM_AUTH_FILE} from a host-only file")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "config/grafana/provisioning/alerting"))
