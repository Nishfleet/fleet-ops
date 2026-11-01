"""Every Claude Code managed-settings file parses, ships from the repo and is installed.

A drop-in that does not parse stops Claude Code from starting on the whole box,
so each file must be a JSON object, and the same file must be installed by a
host.yml task that runs that same check before the file reaches /etc. A plugin id
is `name@marketplace`: the
marketplace half must be one the box knows, either because a drop-in declares it
in `extraKnownMarketplaces` or because the box already registered it. When the
marketplace's directory is on disk (this box, or a runner with the checkout) the
plugin name is read out of that marketplace's own manifest, so an id no
marketplace lists fails here instead of at Claude Code start-up.

An id set to `false` is a switch-off, not an enable: it overrides an entry the
box already has at user scope, so it needs no marketplace of its own and is not
held to the manifest check.

No managed settings file may name the plugin-directory override that made Claude
Code load plugins straight from working-tree checkouts (fleet-ops#10540). Only
the repo's own tree is read: a user settings file is the play's business, which
refuses the deploy while one names the variable.

The box-wide defaults file's permission lists hold three invariants, each one a
live hole before 2026-10-30 (fleet-ops#10567): no rule names a tool whose rules
the file permission check ignores, because Claude Code matches a file rule by
tool name and maps Write, NotebookEdit and MultiEdit onto Edit, so a `Write(path)`
rule is dead text while an `Edit(path)` deny already covers the Write tool; no
`ask` rule's command is already denied, because deny is checked first and such a
rule never prompts; and no Bash command reads a seat or tincan file by hiding its
path inside a quoted string, which the Read path denies alone do not stop.
"""
import fnmatch
import json
import pathlib
import re
import shutil
import subprocess

import pytest
import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANAGED_TREE = ROOT / "rootfs/etc/claude-code"
MANAGED = ROOT / "rootfs/etc/claude-code/managed-settings.json"
DROPINS = ROOT / "rootfs/etc/claude-code/managed-settings.d"
JSON_OBJECT_GATE = "import json,sys; sys.exit(0 if isinstance(json.load(open(sys.argv[1])), dict) else 1)"
NEEDS_YQ = pytest.mark.skipif(not shutil.which("yq"), reason="yq missing")
RULE_SHAPE = re.compile(r"^\w+\(.*\)$")
FILE_TOOLS_THE_CHECK_IGNORES = ("Write", "Glob")
PROTECTED_MARKERS = ("seats", "tincan")


def _permissions():
    return json.loads(MANAGED.read_text())["permissions"]


def _rules(behavior):
    return _permissions()[behavior]


def _bash_patterns(behavior):
    return [rule[len("Bash("):-1] for rule in _rules(behavior) if rule.startswith("Bash(")]


def _bash_blocks(pattern, command):
    if pattern.endswith(":*"):
        prefix = pattern[:-2]
        return command == prefix or command.startswith(prefix + " ")
    return fnmatch.fnmatchcase(command, pattern)


def _denied(command):
    return any(_bash_blocks(pattern, command) for pattern in _bash_patterns("deny"))
HOST_MARKETPLACES = pathlib.Path.home() / ".claude/plugins/known_marketplaces.json"
PLUGINS_FROM_WORKING_TREE = "CLAUDE_CODE_PLUGIN_DIRS"


def _dropins():
    return sorted(DROPINS.glob("*.json"))


def _load(path):
    data = json.loads(path.read_text())
    assert isinstance(data, dict), f"{path.name} is not a JSON object"
    return data


def _known_marketplaces():
    known = {}
    for path in _dropins():
        known.update(_load(path).get("extraKnownMarketplaces", {}))
    if HOST_MARKETPLACES.is_file():
        known.update(json.loads(HOST_MARKETPLACES.read_text()))
    return known


def _enabled():
    enabled = {}
    for path in _dropins():
        for plugin_id, value in _load(path).get("enabledPlugins", {}).items():
            if value:
                enabled[plugin_id] = path.name
    return enabled


def _switched_off():
    off = {}
    for path in _dropins():
        for plugin_id, value in _load(path).get("enabledPlugins", {}).items():
            if value is False:
                off.setdefault(plugin_id, []).append(path.name)
    return off


def test_the_repo_ships_at_least_one_drop_in():
    assert _dropins(), f"no drop-in under {DROPINS}"


@pytest.mark.parametrize("path", _dropins(), ids=lambda p: p.name)
def test_every_drop_in_is_a_json_object(path):
    _load(path)


def test_the_playwright_plugin_is_switched_off():
    off = _switched_off()
    assert "playwright@claude-plugins-official" in off, (
        "no drop-in sets playwright@claude-plugins-official to false (fleet-ops#10529: Chrome DevTools is the one browser tool)"
    )
    assert off["playwright@claude-plugins-official"] == ["85-no-playwright.json"], off
    assert "playwright@claude-plugins-official" not in _enabled()


def test_every_switched_off_plugin_is_off_in_exactly_one_drop_in():
    twice = {plugin_id: files for plugin_id, files in _switched_off().items() if len(files) > 1}
    assert not twice, f"switched off in more than one drop-in: {twice}"


def test_every_enabled_plugin_names_a_known_marketplace():
    known = _known_marketplaces()
    bad = {f"{p} (in {f})": sorted(known) for p, f in _enabled().items() if p.split("@")[-1] not in known}
    assert not bad, f"enabled plugins from an unknown marketplace: {bad}"


def test_every_enabled_plugin_is_listed_in_its_marketplace_manifest():
    known = _known_marketplaces()
    for plugin_id in _enabled():
        name, _, marketplace = plugin_id.rpartition("@")
        source = known.get(marketplace, {}).get("source", {})
        if source.get("source") != "directory":
            continue
        manifest = pathlib.Path(source["path"]) / ".claude-plugin/marketplace.json"
        if not manifest.is_file():
            continue
        listed = {p["name"] for p in json.loads(manifest.read_text())["plugins"]}
        assert name in listed, f"{plugin_id} is enabled but {manifest} lists {sorted(listed)}"


def test_no_managed_settings_file_loads_plugins_from_a_working_tree():
    """G1 of the 2026-10-28 glue sweep (fleet-ops#10540): an env override made
    every agent load five plugins straight out of working-tree checkouts. Nothing
    pinned, tested or reviewed a checkout, so a pull in one changed what every
    agent loaded. The checkouts are retired and no plugin is enabled from one, and
    this keeps the override out of the repo: a drop-in carrying it fails the pull
    request."""
    files = [path for path in sorted(MANAGED_TREE.rglob("*.json")) if path.is_file()]
    assert files, f"{MANAGED_TREE.relative_to(ROOT)} holds no settings file to check"
    offenders = [str(path) for path in files if PLUGINS_FROM_WORKING_TREE in path.read_text()]
    assert not offenders, (
        f"{PLUGINS_FROM_WORKING_TREE} loads plugins from working-tree checkouts with no pin "
        f"or review: {offenders}"
    )


def _managed_copies():
    out = subprocess.run(["yq", "-o=json", "."], input=ansible_host.text(), capture_output=True, text=True, check=True).stdout
    tasks = [task for play in json.loads(out) for task in play.get("tasks", [])]
    copies = [t["ansible.builtin.copy"] for t in tasks if "ansible.builtin.copy" in t and t["ansible.builtin.copy"].get("dest", "").startswith("/etc/claude-code/")]
    return tasks, copies


def test_the_connector_drop_in_keeps_the_claude_ai_connectors_off():
    assert _load(DROPINS / "80-claudeai-connectors.json")["disableClaudeAiConnectors"] is True


@NEEDS_YQ
def test_every_managed_settings_file_is_shipped_and_installed_by_a_gated_task():
    _, copies = _managed_copies()
    assert copies, "no host.yml copy task installs anything under /etc/claude-code/"
    for copy in copies:
        assert JSON_OBJECT_GATE in copy["validate"], f"{copy['dest']} is installed without the JSON-object gate"
        assert copy["owner"] == "root" and copy["group"] == "root", copy["dest"]
        assert copy["mode"] == "preserve", copy["dest"]

    def installed(path):
        src = "{{ rootfs }}/" + path.relative_to(ROOT / "rootfs").as_posix()
        return any(copy.get("src") == src or (copy.get("src", "").endswith("/") and src.startswith(copy["src"])) for copy in copies)

    files = sorted(p for p in MANAGED_TREE.rglob("*") if p.is_file())
    assert files, f"no files under {MANAGED_TREE}"
    for path in files:
        assert isinstance(json.loads(path.read_text()), dict), f"{path.relative_to(ROOT)} is not a JSON object"
        assert installed(path), f"{path.relative_to(ROOT)} is installed by no /etc/claude-code copy task"


@NEEDS_YQ
def test_the_box_wide_defaults_file_is_installed_as_itself():
    tasks, _ = _managed_copies()
    task = next((t for t in tasks if t.get("name") == "Install the Claude Code managed-settings defaults file"), None)
    assert task, "no task installs the box-wide managed-settings.json"
    assert task["ansible.builtin.copy"]["src"] == "{{ rootfs }}/etc/claude-code/managed-settings.json"
    assert task["ansible.builtin.copy"]["dest"] == "/etc/claude-code/managed-settings.json"


def test_force_with_lease_is_allowed_off_main_and_plain_force_still_asks() -> None:
    """Nish 2026-10-28 ("Yes, allow it"): --force-with-lease on a non-default branch needs no prompt;
    plain --force and -f, a lease push to main or master in any order or refspec form,
    and a +refspec force push to main or master, still ask. fnmatch's * matches any run of
    characters, as a Claude Code permission rule's * does."""
    pats = _bash_patterns("ask")
    asks = lambda cmd: any(fnmatch.fnmatchcase(cmd, p) for p in pats)
    assert not asks("git push --force-with-lease origin claim/issue-1")
    assert not asks("git push -u origin feature --force-with-lease")
    assert asks("git push --force origin feature")
    assert asks("git push origin feature --force")
    assert asks("git push -f origin feature")
    for cmd in [
        "git push --force-with-lease origin main",
        "git push origin main --force-with-lease",
        "git push --force-with-lease origin HEAD:main",
        "git push --force-with-lease origin feature:main",
        "git push --force-with-lease=main origin main",
        "git push --force-with-lease origin main --force-if-includes",
        "git push origin --force-with-lease master",
        "git push origin master --force-with-lease",
        "git push origin +main",
        "git push origin +HEAD:master",
    ]:
        assert asks(cmd), cmd


def test_every_rule_names_a_tool_and_a_pattern() -> None:
    """A rule that is not `Tool(pattern)` is matched by no check, so a typo would drop out of
    the set the other invariants here read."""
    for behavior, rules in _permissions().items():
        for rule in rules:
            assert RULE_SHAPE.match(rule), f"{behavior} rule {rule!r} is not Tool(pattern)"


def test_no_rule_names_a_tool_whose_rules_the_file_permission_check_ignores() -> None:
    """Claude Code matches a file rule by tool name and maps Write, NotebookEdit and MultiEdit
    onto Edit, and Glob onto Read, when it does
    (https://docs.claude.com/en/docs/claude-code/iam). Proved on the box 2026-10-30 with one
    isolated `--settings` deny per rule: `Write(**/*.txt)` left the Write tool free to create
    the file, and `Edit(**/*.txt)` blocked it. A `Write(path)` or `Glob(path)` rule is dead
    text, and an `Edit(path)` deny already covers the Write tool, so the path denies in this
    file need no mirror."""
    for behavior, rules in _permissions().items():
        for rule in rules:
            tool = rule.split("(", 1)[0]
            assert tool not in FILE_TOOLS_THE_CHECK_IGNORES, (
                f"{behavior} rule {rule!r} is never matched: use the tool the check maps it onto"
            )


def test_a_protected_directory_denies_the_file_editing_tools_not_just_read() -> None:
    """A path this file stops the Read tool on must stop the file-editing tools on too.
    `Edit(path)` is the rule that covers Write, NotebookEdit and MultiEdit, so a directory an
    agent cannot read but can overwrite is not protected: the seats directory holds the box's
    seat keys and the tincan directory its inbox secret. The paths are read back off the file's
    own Read denies, so this test adds no home path of its own."""
    deny = _rules("deny")
    protected = [
        rule[5:-1]
        for rule in deny
        if rule.startswith("Read(") and any(marker in rule for marker in PROTECTED_MARKERS)
    ]
    assert protected, "no Read deny protects the seat or tincan directories"
    for path in protected:
        assert f"Edit({path})" in deny, f"{path} is read-denied but not edit-denied"


def test_no_ask_rule_is_unreachable_because_a_deny_rule_already_blocks_it() -> None:
    """Claude Code checks the deny list before the ask list, so an ask rule whose commands a
    deny rule already blocks never prompts: it is dead text. The three `wrangler delete`
    asks sat under `Bash(wrangler:*)` and never fired (proved on the box 2026-10-30:
    `wrangler delete --help` was denied, not asked). Each ask rule is replaced by a command
    it matches and no deny rule matches, so an ask that loses to a deny fails. The removed
    wrangler asks stay denied, so narrowing `Bash(wrangler:*)` cannot quietly allow them."""
    for pattern in _bash_patterns("ask"):
        command = pattern[:-2] + " x" if pattern.endswith(":*") else pattern.replace("*", "x")
        assert not _denied(command), f"ask rule {pattern!r} is unreachable: deny already blocks {command!r}"
    for command in ("wrangler delete x", "wrangler d1 delete x", "wrangler r2 bucket delete x"):
        assert _denied(command), command


def test_no_bash_command_reads_a_seat_or_tincan_file_by_hiding_its_path() -> None:
    """The Read path denies stop a command that names a protected path as its own argument
    (proved on the box 2026-10-30: `head -c 0`, `rg` and `ls` on a seats path were all denied),
    but a command that hides the path inside a quoted string is stopped only by a Bash rule
    that names the directory itself: `python3 -c "open('.../seats/x').read()"` ran before
    that rule existed. The limit is a string rule's reach: a command that reaches the file by
    a relative path (`cd ~/.config && cat fleet-ops/seats/x`) names no denied substring, so
    closing that needs a file mode or a sandbox, not another pattern (fleet-ops#11114)."""
    paths = [
        rule[5:-1].rsplit("/", 1)[0] + "/inbox.secret"
        for rule in _rules("deny")
        if rule.startswith("Read(") and any(marker in rule for marker in PROTECTED_MARKERS)
    ]
    assert paths, "no Read deny protects the seat or tincan directories"
    for path in paths:
        for command in (
            f"cat {path}",
            f"head -c 0 {path}",
            f"tail -n 2 {path}",
            f"rg key {path}",
            f"sed -n 1p {path}",
            f"openssl enc -d -aes-256-cbc -in {path}",
            f'python3 -c "open(\'{path}\').read()"',
            f'bash -c "cat {path}"',
        ):
            assert _denied(command), command
