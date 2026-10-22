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

It also holds the other end of the alert path: Alertmanager's API answers only
with basic auth, and every Prometheus client of it carries the credential
(fleet-ops#10058). Three files have to agree for that to hold and nothing else
in CI compares them: the options file that names the web config, ansible, which
has to see both hand-placed files in place before it installs either side, and
Prometheus's client config, which needs the matching plaintext for both the
alerting target and the scrape job. A drift in the first two stops the service
from starting, or stops the play that would install it. A drift in the third is
silent until the outside dead-man notices that the alert set stopped arriving.
The two credential files are hand-placed host state, root- and service-owned:
any process that can reach the loopback listener already runs as nish, so a
credential nish could read would protect nothing.

usage: alert_routes_check.py [provisioning/alerting dir]
"""
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
    "Cline idle": "money", "CommandCode idle": "money", "MiniMax idle": "money",
    "StepFun idle": "money", "z.ai idle": "money", "Ollama idle": "money",
    "OpenCode Go idle": "money",
    "Alibaba token-plan SG idle": "money",
    **{f"Production deploy red for 24h {r}": "outage: the live site has not run main for a day" for r in (
        "Nishfleet/0509", "Nishfleet/aiconverter-app", "Nishfleet/drive",
        "Nishfleet/mailbox", "Nishfleet/siterep-public", "Nishfleet/seo-fix-kit")},
}
PAGE = "hermes-urgent"
SEVERITIES = ("critical", "warning")
CRITICAL_REPEAT = 3600
ISSUE_SINKS = {"fleet-alert-dispatch", "cloudflare-spend-dispatch", "router-dead-row-dispatch"}
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


def task_blocks(text):
    """The play's tasks and handlers, one string each, comments kept for context."""
    blocks, current = [], None
    for line in text.splitlines():
        if line.startswith("    - name: "):
            current = [line]
            blocks.append(current)
        elif current is not None:
            current.append(line)
    return ["\n".join(b) for b in blocks]


def code(task):
    """The task's lines that run, so a comment cannot stand in for a setting."""
    return "\n".join(l for l in task.splitlines() if not l.lstrip().startswith("#"))


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
AM_ANSIBLE = "ansible/host.yml"
AM_WEB_CONFIG = "/etc/alertmanager/web.yml"
AM_AUTH_FILE = "/etc/prometheus/alertmanager_password"


def alertmanager_auth(repo):
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
    ansible = (repo / AM_ANSIBLE).read_text()
    tasks = task_blocks(ansible)
    if ".config/fleet-ops/alertmanager" in ansible:
        bad.append(f"{AM_ANSIBLE}: an alertmanager credential is read from nish's home, where any process on the box can read it")
    for dest in (AM_WEB_CONFIG, AM_AUTH_FILE):
        looked = [t for t in tasks if dest in code(t) and "ansible.builtin.stat" in code(t)]
        if not looked:
            bad.append(f"{AM_ANSIBLE}: nothing stats {dest}, so the play cannot tell whether the auth pair is in place")
        elif not all("follow: false" in code(t) for t in looked):
            bad.append(f"{AM_ANSIBLE}: the stat of {dest} follows symlinks, so a link could steer the check")
        if any("ansible.builtin.copy" in code(t) and dest in code(t) for t in tasks):
            bad.append(f"{AM_ANSIBLE}: the play copies {dest}; it is hand-placed host state, root- and service-owned")
    check = [t for t in tasks if "credential is shaped like one" in t]
    if not check:
        bad.append(f"{AM_ANSIBLE}: nothing checks that the two halves are shaped like a credential before auth is switched on")
    else:
        body = code(check[0])
        if "basic_auth_users" not in body:
            bad.append(f"{AM_ANSIBLE}: the credential check never looks for basic_auth_users")
        if "{{ rootfs }}/etc/prometheus/prometheus.yml" not in body:
            bad.append(f"{AM_ANSIBLE}: the credential check never reads the prometheus config, so a user the web config does not define passes")
    for name in ("Install prometheus and blackbox exporter config", "Install the alertmanager options"):
        task = [t for t in tasks if f"name: {name}" in t]
        if not task:
            bad.append(f"{AM_ANSIBLE}: no task named {name}")
        elif "alertmanager_auth_ready" not in code(task[0]):
            bad.append(f"{AM_ANSIBLE}: {name} installs a config that names the credential without waiting for both halves of the pair")
    return bad


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
        for rel in (AM_OPTIONS, AM_PROMETHEUS, AM_ANSIBLE):
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
        (fixture / AM_ANSIBLE).write_text((repo / AM_ANSIBLE).read_text().replace(
            "      when: alertmanager_auth_ready | default(false) | bool\n      notify:\n        - Reload prometheus",
            "      notify:\n        - Reload prometheus", 1))
        assert any("without waiting for both halves" in f for f in alertmanager_auth(fixture)), alertmanager_auth(fixture)


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
        sinks = {rc.removesuffix("#muted"): rep for rc, rep in route(policy, {**labels, "alertname": title})}
        want = PLAN_REPEAT if "plan" in labels else DEFAULT_REPEAT
        got = sinks.get(GENERIC_SINK)
        if got is not None and got != want:
            bad.append(f"{title}: {GENERIC_SINK} must file its issue every {want}s "
                       f"({'a paid plan' if 'plan' in labels else 'any other rule'}), got {got}")
    bad += alertmanager_auth(Path(__file__).resolve().parents[1])
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
