"""fleet-ops#10417: every reject file must fail on the rule it names, and only that.

config/litellm-proxy.schema.rejects/ holds the negative fixtures for
config/litellm-proxy.schema.json: `check-jsonschema` must refuse each one. A file
that is a hand-cut minimal config fails for many reasons at once, so loosening the
rule it names would not turn CI red - which is what happened to the judge-* files
after later rules added required keys.

Each fixture is now the live config's rows plus its router_settings with one
mutation, and its header states the mutation's inverse on `# undo:` lines. A line
is either `<dotted path> = <JSON value>` or `<dotted path> = drop`, except the
appended-row mutation, which reads `model_list = drop the last N rows`. This test
proves each fixture fails, that its header lines make it pass, and that every
line changes the document, so a header cannot go stale and an unrelated failure
cannot hide behind the named rule.
"""

import copy
import glob
import json
import pathlib
import re

import jsonschema
import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config/litellm-proxy.yaml"
SCHEMA_PATH = ROOT / "config/litellm-proxy.schema.json"
REJECTS_DIR = ROOT / "config/litellm-proxy.schema.rejects"
UNDO = "# undo: "
DROP_ROWS = re.compile(r"^drop the last (\d+) rows?$")

schema = json.loads(SCHEMA_PATH.read_text())
assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema", schema["$schema"]
jsonschema.Draft202012Validator.check_schema(schema)
VALIDATOR = jsonschema.Draft202012Validator(schema)
FIXTURES = sorted(REJECTS_DIR.glob("*.yaml"))
# Part 1 of 2 (the other half of the fixtures) lands separately, because the whole change is
# over the 250 KB review limit. Until it does these files carry no `# undo:` lines; they must
# still fail the schema. The follow-up that empties this set closes fleet-ops#10417.
LEGACY = frozenset({
    "anthropic-key-on-another-group.yaml",
    "assistant-falls-to-tether.yaml",
    "bench-block.yaml",
    "glm-row-outside-worker-groups.yaml",
    "judge-fallback-api-base-changed.yaml",
    "judge-fallback-model-changed.yaml",
    "judge-fallback-row-renamed.yaml",
    "judge-fallbacks-on-order-1.yaml",
    "judge-fourth-row.yaml",
    "judge-paid-api-base-changed.yaml",
    "judge-paid-key-changed.yaml",
    "judge-paid-model-changed.yaml",
    "judge-paid-no-thinking-budget.yaml",
    "judge-paid-row-as-fallback.yaml",
    "judge-plan-concurrency-raised.yaml",
    "judge-plan-rpm-raised.yaml",
    "openrouter-row-no-daily-wall-park.yaml",
    "quota-wall-row-on-the-burst-cooldown.yaml",
    "qwen-row-in-worker-group.yaml",
    "retry-policy-authentication-error-retries-not-zero.yaml",
    "retry-policy-default-retries-over-one.yaml",
    "retry-policy-missing.yaml",
    "retry-policy-not-found-error-retries-over-one.yaml",
    "retry-policy-rate-limit-over-one.yaml",
    "retry-policy-timeout-error-retries-over-one.yaml",
    "retry-policy-unknown-key.yaml",
    "router-404-allowed-fails-block-missing.yaml",
})


def header(text):
    lines = []
    for line in text.splitlines():
        if not line.startswith("#"):
            break
        lines.append(line)
    return lines


def undo_lines(text, name):
    lines = [line[len(UNDO):] for line in header(text) if line.startswith(UNDO)]
    assert lines, f"{name}: no `{UNDO.strip()}` line in the header"
    return lines


def apply_undo(doc, line, name):
    path, sep, value = line.partition(" = ")
    assert sep, f"{name}: `{line}` is not `<path> = <JSON value|drop>`"
    appended = DROP_ROWS.match(value)
    if appended:
        assert path == "model_list", f"{name}: `{line}` is not a model_list line"
        del doc["model_list"][-int(appended.group(1)):]
        return
    parts = path.split(".")
    node = doc
    for part in parts[:-1]:
        node = node[int(part)] if isinstance(node, list) else node[part]
    key = parts[-1]
    if value == "drop":
        if isinstance(node, list):
            del node[int(key)]
        else:
            node.pop(key, None)
        return
    restored = json.loads(value)
    if isinstance(node, list):
        if int(key) == len(node):
            node.append(restored)
        else:
            node[int(key)] = restored
    else:
        node[key] = restored


def errors(doc):
    return [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
            for e in VALIDATOR.iter_errors(doc)]


def test_the_live_config_passes_the_schema():
    assert errors(yaml.safe_load(CONFIG_PATH.read_text())) == []


def test_every_file_in_the_rejects_directory_is_covered():
    assert FIXTURES, REJECTS_DIR
    assert sorted(REJECTS_DIR.iterdir()) == FIXTURES, sorted(REJECTS_DIR.iterdir())


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.name)
def test_reject_fails_on_its_own_mutation_and_passes_once_reverted(path):
    text = path.read_text()
    doc = yaml.safe_load(text)
    assert errors(doc), f"{path.name}: the schema accepts it, so it rejects nothing"
    if path.name in LEGACY and UNDO not in text:
        return
    lines = undo_lines(text, path.name)
    for line in lines:
        before = copy.deepcopy(doc)
        apply_undo(doc, line, path.name)
        assert doc != before, f"{path.name}: `{line}` changes nothing, so the header is stale"
    assert errors(doc) == [], f"{path.name}: still refused after its own `# undo:` lines"
