import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCAN_CONFIG = ROOT / "config" / "token-store-scan.toml"
SHAPES = ROOT / "pi-extensions" / "token-redact" / "src" / "shapes.ts"
SEMGREP_RULES = ROOT / ".semgrep" / "token-store-shapes.yml"
EXTENSION = ROOT / "pi-extensions" / "token-redact"
INDEX = EXTENSION / "index.ts"
NODE_MIN = (22, 12)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

RULE = re.compile(
    r'(?m)^id = "(store-[a-z0-9-]+)"\s*\n.*?^regex = \'\'\'(.*?)\'\'\'(?:.*?^keywords = \[([^\]]*)\])?',
    re.DOTALL,
)
SHAPE = re.compile(r'id:\s*"(store-[a-z0-9-]+)".*?token:\s*"([^"]+)".*?chars:\s*"([^"]+)"', re.DOTALL)
SEMGREP_RULE = re.compile(r"- id: (store-[a-z0-9-]+)(?:.|\n)*?pattern-regex: (\S+)")


def _toml_rules() -> list[tuple[str, str, list[str]]]:
    rules = []
    for block in SCAN_CONFIG.read_text().split("[[rules]]")[1:]:
        found = RULE.search(block)
        assert found, f"a rule in {SCAN_CONFIG} has no id and regex: {block[:80]}"
        keywords = re.findall(r'"([^"]+)"', found.group(3) or "")
        assert keywords, f"{found.group(1)}: the rule needs keywords for gitleaks to run it"
        rules.append((found.group(1), found.group(2), keywords))
    return rules


def _ts_shapes() -> list[tuple[str, str, str]]:
    found = SHAPE.findall(SHAPES.read_text())
    assert found, f"no TOKEN_SHAPES entries parsed from {SHAPES}"
    return list(found)


def _semgrep_rules() -> list[tuple[str, str]]:
    found = SEMGREP_RULE.findall(SEMGREP_RULES.read_text())
    assert found, f"no rules parsed from {SEMGREP_RULES}"
    return list(found)


def test_the_three_shape_lists_are_the_same_list() -> None:
    toml_ids = [sid for sid, _, _ in _toml_rules()]
    ts_ids = [sid for sid, _, _ in _ts_shapes()]
    sg_ids = [sid for sid, _ in _semgrep_rules()]
    assert toml_ids == ts_ids, "config/token-store-scan.toml and src/shapes.ts drifted"
    assert toml_ids == sg_ids, ".semgrep/token-store-shapes.yml and config/token-store-scan.toml drifted"


@pytest.mark.parametrize("shape_id", [sid for sid, _, _ in _ts_shapes()])
def test_each_scanner_regex_holds_the_shape_the_redaction_uses(shape_id: str) -> None:
    token = dict((sid, tok) for sid, tok, _ in _ts_shapes())[shape_id]
    toml_regex = dict((sid, rx) for sid, rx, _ in _toml_rules())[shape_id]
    sg_pattern = dict(_semgrep_rules())[shape_id]
    assert token in toml_regex, f"{shape_id}: the gitleaks regex does not hold {token}"
    assert token in sg_pattern, f"{shape_id}: the semgrep pattern does not hold {token}"


@pytest.mark.parametrize("shape_id", [sid for sid, _, _ in _ts_shapes()])
def test_the_gitleaks_regex_matches_a_token_and_not_a_boundary_prefixed_one(shape_id: str) -> None:
    regex, keywords = next((rx, kw) for sid, rx, kw in _toml_rules() if sid == shape_id)
    pattern = re.compile(regex)
    body = "A" * 40
    assert pattern.search(f"{keywords[0]}{body}"), f"{shape_id}: the gitleaks regex missed a token-shaped string"
    assert not pattern.search(f"x{keywords[0]}{body}"), f"{shape_id}: the gitleaks regex matched a prefixed word"


@pytest.mark.parametrize("shape_id", [sid for sid, _, _ in _ts_shapes()])
def test_the_redaction_compiled_regex_uses_the_same_boundaries(shape_id: str) -> None:
    # src/shapes.ts wraps each shape in lookaround on shape.chars. If the
    # wrapper is dropped the extension redacts inside words, so it is asserted
    # here where a plain grep of the file cannot check it.
    chars = dict((sid, ch) for sid, _, ch in _ts_shapes())[shape_id]
    source = SHAPES.read_text()
    assert "new RegExp(" in source
    assert "(?<![${shape.chars}])" in source
    assert "(?![${shape.chars}])" in source
    assert f'chars: "{chars}"' in source, f"{shape_id}: no chars class to bound the shape"


def test_the_store_scan_config_is_the_shape_list_the_ci_rules_use() -> None:
    # CI cannot read ~/.pi, ~/.claude or the Devin database. semgrep holds the
    # gate for the files CI can see, this config carries the same shapes for
    # the on-disk stores, and the tests above hold the two together.
    rules = SCAN_CONFIG.read_text().split("[[rules]]")[1:]
    assert len(rules) == len(_ts_shapes())
    for block in rules:
        assert "secretGroup = 1" in block
    assert "generic-api-key" not in "".join(rules)


def test_the_extension_registers_no_tool_and_no_command() -> None:
    source = INDEX.read_text()
    for call in ("registerTool", "registerCommand", "registerFlag", "registerProvider"):
        assert f"pi.{call}" not in source, f"the redaction extension must not call {call}"
    assert 'pi.on("tool_result"' in source
    assert 'pi.on("message_end"' in source
    manifest = EXTENSION / "package.json"
    assert '"extensions": ["./index.ts"]' in manifest.read_text()


def test_the_off_switch_is_one_environment_variable() -> None:
    source = INDEX.read_text()
    assert "TOKEN_REDACT" in source
    assert (EXTENSION / "README.md").read_text().count("TOKEN_REDACT") >= 2


def node_is_new_enough() -> bool:
    node = shutil.which("node")
    if node is None:
        return False
    out = subprocess.run([node, "--version"], capture_output=True, text=True, check=False).stdout.strip()
    match = re.match(r"v(\d+)\.(\d+)", out)
    if match is None:
        return False
    return (int(match.group(1)), int(match.group(2))) >= NODE_MIN


@pytest.mark.skipif(shutil.which("npm") is None, reason="npm is not installed")
@pytest.mark.skipif(not node_is_new_enough(), reason="vitest 5 needs node 22.12 or newer")
def test_the_extension_tests_pass() -> None:
    install = subprocess.run(
        ["npm", "ci", "--no-audit", "--no-fund"],
        cwd=EXTENSION,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )
    assert install.returncode == 0, install.stderr
    tests = subprocess.run(
        ["npm", "test"],
        cwd=EXTENSION,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )
    assert tests.returncode == 0, tests.stdout + tests.stderr
    clean = ANSI.sub("", tests.stdout)
    assert "failed" not in clean, clean
    assert re.search(r"Tests\s+\d+ passed", clean), clean
