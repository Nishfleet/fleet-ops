"""Pipeline control comments count only from trusted authors (fleet-ops#9273)."""
import json
import re
import subprocess
from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"
AGENT = WORKFLOWS / "agent.yml"
DISPATCH = WORKFLOWS / "agent-dispatch.yml"
PREFIXES = ["park:", "opus-vet:", "agent run started: ", "agent run infra-failed: ", "agent run failed: ", "miss-review:"]


def trusted_def(path):
    return yaml.safe_load(path.read_text())["env"]["TRUSTED_JQ"]


def comment(body, assoc="NONE", login="stranger"):
    return {"body": body, "authorAssociation": assoc, "author": {"login": login}}


def jq(program, data):
    out = subprocess.run(["jq", "-c", program], input=json.dumps(data), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def test_both_workflows_share_one_definition():
    assert trusted_def(AGENT) == trusted_def(DISPATCH)


def test_every_comment_read_filters_to_trusted_authors():
    for path in (AGENT, DISPATCH):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if "--json comments" in line or re.search(r"jq .*\.comments\[\] \| (select|if)", line):
                assert '"$TRUSTED_JQ"' in line and "select(trusted)" in line, f"{path.name}:{n} reads comments from any author"


def test_outsider_prefixes_are_dropped_and_trusted_authors_kept():
    prog = trusted_def(AGENT) + " [.[] | select(trusted) | .body]"
    outsiders = [comment(p + "x", a) for p in PREFIXES for a in ("NONE", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR")]
    assert jq(prog, outsiders) == []
    kept = [
        comment("park: a", "OWNER", "nish3451"),
        comment("park: b", "MEMBER"),
        comment("park: c", "COLLABORATOR"),
        comment("agent run started: u", "CONTRIBUTOR", "nishfleet-worker"),
        comment("agent run infra-failed: u", "NONE", "github-actions"),
    ]
    assert len(jq(prog, kept)) == 5


def test_outsider_park_does_not_reset_the_attempt_cap():
    # Run the Gate's own counting program, read out of agent.yml.
    line = next(l for l in AGENT.read_text().splitlines() if l.lstrip().startswith("runs=$(gh issue view"))
    prog = re.search(r"--jq \"\$TRUSTED_JQ\"'(.*)'\)$", line).group(1)
    start = comment("agent run started: u1", "CONTRIBUTOR", "nishfleet-worker")
    assert jq(trusted_def(AGENT) + prog, {"comments": [start]}) == 1
    forged = [start, comment("park: reset"), comment("agent run infra-failed: u1")]
    # Wrapped the way gh prints it: {"comments": [...]}; the program reads .comments.
    assert jq(trusted_def(AGENT) + prog, {"comments": forged}) == 1
    real = [start, comment("park: reset", "MEMBER", "nish3451")]
    assert jq(trusted_def(AGENT) + prog, {"comments": real}) == 0
