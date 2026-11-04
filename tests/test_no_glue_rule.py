"""The no-glue semgrep rule catches an inline program however the interpreter is named.

fleet-ops#11694 review: the old pattern only matched a bare `python3 -c` at the start
of a line, so `ExecStart=/bin/sh -c '...'` and `validate: /usr/bin/python3 -c '...'`
passed unseen. semgrep's own `--test` mode skips a fixture outside the rule's
`paths:` (https://semgrep.dev/docs/writing-rules/testing-rules), so this reads the
same `# ruleid:` / `# ok:` annotations and checks the rule's regex on each next line.
"""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
RULE = next(
    r
    for r in yaml.safe_load((ROOT / ".semgrep/no-glue.yml").read_text())["rules"]
    if r["id"] == "no-inline-program"
)


def test_fixture_lines_match_as_annotated():
    pattern = re.compile(RULE["pattern-regex"])
    lines = (ROOT / "tests/fixtures/no-glue.service").read_text().splitlines()
    cases = [
        (lines[i].split(":", 1)[0].lstrip("# "), lines[i + 1])
        for i in range(len(lines) - 1)
        if lines[i].startswith(("# ruleid:", "# ok:"))
    ]
    assert cases
    for want, line in cases:
        assert bool(pattern.search(line)) == (want == "ruleid"), line
