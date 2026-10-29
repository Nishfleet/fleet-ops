"""queue-stuck rules (fleet-ops#10306): each rule's real SQL, read out with yq and run in
sqlite, counts only the hits whose updated_at is old enough, and the real query shapes
(Pull_Requests timeField 3, Issues timeField 2) are what the pinned plugin accepts. The
ask rule (fleet-ops#10865) rings 4 hours after the last update of any open nish-ask with
no pull request, so an ask cannot slip off the board unseen."""
import json
import pathlib
import re
import shutil
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ALERTING = ROOT / "config/grafana/provisioning/alerting"
RULES = ALERTING / "queue-stuck.yaml"
YQ = shutil.which("yq")
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
AGE = {
    "queue-stuck-pr-unmerged": 2,
    "queue-stuck-pr-blocked": 2,
    "queue-stuck-issue-no-pr": 3,
    "queue-stuck-pr-needs-split": 2,
    "queue-stuck-ask-noslip": 4,
}


def _rules():
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".groups[].rules", str(RULES)], capture_output=True, text=True, check=True)
    return {r["uid"]: r for r in json.loads(out.stdout)}


def _github_queries(path):
    assert YQ, "yq must be on PATH to read the alert rules"
    out = subprocess.run([YQ, "-o=json", ".", str(path)], capture_output=True, text=True, check=True)

    def walk(node):
        if isinstance(node, dict):
            options = node.get("options")
            if isinstance(options, dict) and "query" in options:
                yield options["query"]
            for value in node.values():
                yield from walk(value)
        elif isinstance(node, list):
            for value in node:
                yield from walk(value)

    return list(walk(json.loads(out.stdout)))


def _unix_timestamp(*value):
    when = datetime.strptime(value[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if value else NOW
    return int(when.timestamp())


def _count(rule, hours_old_by_table):
    db = sqlite3.connect(":memory:")
    db.create_function("UNIX_TIMESTAMP", -1, _unix_timestamp)
    for table, hours in hours_old_by_table.items():
        db.execute(f"CREATE TABLE {table} (updated_at TEXT)")
        db.executemany(f"INSERT INTO {table} VALUES (?)", [((NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"),) for h in hours])
    sql = next(d for d in rule["data"] if d["refId"] == "C")["model"]["expression"]
    (row,) = db.execute(sql).fetchall()
    return row[0]


@pytest.mark.parametrize("uid", sorted(AGE))
def test_a_hit_counts_only_from_its_age_and_every_query_table_is_read(uid):
    rule = _rules()[uid]
    tables = [d["refId"] for d in rule["data"] if d["refId"] != "C"]
    hours = AGE[uid]
    fresh = {t: [hours - 0.5] for t in tables}
    assert _count(rule, fresh) == 0
    for table in tables:
        old = {t: ([hours + 0.5, hours - 0.5] if t == table else []) for t in tables}
        assert _count(rule, old) == 1, f"{uid}: a stuck hit in {table} must fire"
    assert _count(rule, {t: [] for t in tables}) == 0


def test_queries_scope_the_org_wide_search_to_unarchived_repos_with_their_own_timefield():
    for uid, rule in _rules().items():
        for d in (d for d in rule["data"] if d["datasourceUid"] == "fleet-github"):
            model = d["model"]
            kind, field = {"Pull_Requests": ("is:pr", 3), "Issues": ("is:issue", 2)}[model["queryType"]]
            assert d["datasourceUid"] == model["datasource"]["uid"] == "fleet-github"
            query = model["options"]["query"]
            assert query.startswith(f"org:Nishfleet {kind} is:open")
            assert model["options"]["timeField"] == field
            assert "archived:false" in query.split(), (uid, query)


def test_every_org_wide_github_search_in_the_alerting_rules_excludes_archived_repositories():
    for path in sorted(ALERTING.glob("*.yaml")):
        for query in _github_queries(path):
            if "org:Nishfleet" in query.split():
                assert "archived:false" in query.split(), (path.name, query)


def test_the_annotation_search_links_exclude_archived_repositories():
    for uid, rule in _rules().items():
        for link in re.findall(r"https://github\.com/search\?[^\s]+", rule["annotations"]["description"]):
            assert "org%3ANishfleet" in link, (uid, link)
            assert "archived%3Afalse" in link, (uid, link)


def test_every_org_wide_issue_search_leaves_the_fleets_own_alert_issues_out():
    for path in sorted(ALERTING.glob("*.yaml")):
        for query in _github_queries(path):
            if "org:Nishfleet" in query.split() and "is:issue" in query.split():
                assert 'NOT "grafana alert:" in:title' in query, (path.name, query)


def test_the_annotation_search_links_leave_the_fleets_own_alert_issues_out():
    for uid, rule in _rules().items():
        for link in re.findall(r"https://github\.com/search\?[^\s]+", rule["annotations"]["description"]):
            if "type=issues" in link:
                assert "NOT+%22grafana+alert%3A%22+in%3Atitle" in link, (uid, link)


def test_every_issue_query_in_a_rule_has_its_own_list_link():
    for uid, rule in _rules().items():
        links = re.findall(r"https://github\.com/search\?type=issues&q=[^\s]+", rule["annotations"]["description"])
        queries = [
            d["model"]["options"]["query"]
            for d in rule["data"]
            if d.get("datasourceUid") == "fleet-github" and d["model"].get("queryType") == "Issues"
        ]
        for query in queries:
            for label in (t for t in query.split() if t.startswith("label:")):
                assert any(f"label%3A{label.removeprefix('label:')}" in link for link in links), (uid, label, links)


def test_rules_are_warnings_on_their_own_signal_with_a_read_error_text():
    rules = _rules()
    assert len({r["uid"] for r in rules.values()}) == len(rules) == 5
    ask = rules["queue-stuck-ask-noslip"]
    (search,) = (d for d in ask["data"] if d["refId"] == "A")
    query = search["model"]["options"]["query"]
    assert "label:nish-ask" in query and "-label:nish-ask-tracker" in query, (
        "the ask rule must read the nish-ask board and leave the trackers out"
    )
    for r in rules.values():
        assert r["labels"] == {"severity": "warning", "signal": "queue-stuck"}
        assert (r["for"], r["execErrState"], r["noDataState"]) == ("0s", "Error", "OK")
        assert "cannot read GitHub" in r["annotations"]["summary"]
        assert "notification_settings" not in r


def test_needs_split_rule_reads_open_prs_with_that_label():
    (a,) = [d for d in _rules()["queue-stuck-pr-needs-split"]["data"] if d["refId"] != "C"]
    assert a["model"]["options"]["query"] == "org:Nishfleet is:pr is:open label:needs-split archived:false"
