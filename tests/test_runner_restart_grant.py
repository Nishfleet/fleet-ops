"""The grant must name every runner that runs as another user: nish cannot signal one, and a restart reaches polkit first (fleet-ops#11016)."""

import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
RULE = ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-runner-restart.rules"
NISH = "nish"


def rule() -> str:
    return RULE.read_text()


def granted_units() -> list[str]:
    array = re.search(r"var fleetRestartableUnits = \[(.*?)\];", rule(), re.S)
    assert array is not None
    return re.findall(r'"([^"]+)"', array.group(1))


def granted_verbs() -> list[str]:
    return re.findall(r'action\.lookup\("verb"\) == "([a-z]+)"', rule())


def runner_units() -> list[str]:
    base = {path.name for path in SYSTEM.glob("actions.runner.*.service")}
    return sorted(base | {path.name.removesuffix(".d") for path in SYSTEM.glob("actions.runner.*.service.d")})


def effective_user(unit: str) -> str | None:
    """The user systemd runs this unit as: the base unit, then each drop-in in lexical order."""
    base = SYSTEM / unit
    files = ([base] if base.exists() else []) + sorted((SYSTEM / f"{unit}.d").glob("*.conf"))
    user = None
    for path in files:
        for line in path.read_text().splitlines():
            value = line.split("=", 1)[1].strip() if line.startswith("User=") else ""
            if value:
                user = value
    return user


def units_that_run_as_another_user() -> list[str]:
    return [unit for unit in runner_units() if effective_user(unit) not in (None, NISH)]


def test_the_grant_names_every_runner_that_runs_as_another_user() -> None:
    assert sorted(granted_units()) == units_that_run_as_another_user()


def test_the_grant_is_start_and_restart_for_nish_only() -> None:
    assert sorted(granted_verbs()) == ["restart", "start"]
    assert 'subject.user == "nish"' in rule()
    assert 'action.id == "org.freedesktop.systemd1.manage-units"' in rule()


def test_the_rule_parses_and_answers_the_way_polkit_would(tmp_path: Path) -> None:
    node = shutil.which("node")
    if node is None:
        return
    script = tmp_path / "rule.js"
    script.write_text(rule())
    subprocess.run([node, "--check", str(script)], check=True)
    harness = tmp_path / "harness.js"
    harness.write_text(
        """
const fs = require("fs");
const rule = fs.readFileSync(process.argv[2], "utf8");
let decide = null;
global.polkit = { addRule: (fn) => { decide = fn; }, Result: { YES: "yes" } };
eval(rule);
const ask = (unit, verb, user) =>
  decide(
    { id: "org.freedesktop.systemd1.manage-units", lookup: (key) => ({ unit, verb })[key] },
    { user }
  ) ?? "no";
const rows = [
  ["actions.runner.Nishfleet.netcup-agent-9.service", "restart", "nish", "yes"],
  ["actions.runner.Nishfleet.netcup-agent-10.service", "start", "nish", "yes"],
  ["actions.runner.Nishfleet.netcup-agent-9.service", "stop", "nish", "no"],
  ["actions.runner.Nishfleet.netcup-agent-2.service", "restart", "nish", "no"],
  ["actions.runner.Nishfleet.netcup-agent-9.service", "restart", "jev", "no"],
];
for (const [unit, verb, user, want] of rows) {
  const got = ask(unit, verb, user);
  console.log(`${got === want ? "ok" : "FAIL"} ${verb} ${unit} as ${user} -> ${got}`);
  if (got !== want) process.exitCode = 1;
}
"""
    )
    result = subprocess.run(
        [node, str(harness), str(script)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.count("ok ") == 5
