"""The daily update's safety net: a restic snapshot before any update step and the update's healthchecks ping."""
import json
import pathlib
import re
import shlex
import shutil
import subprocess

import pytest
import yaml
import ansible_host

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]
BLOCK = next(t for t in PLAY["tasks"] if "block" in t and "always" in t)
INNER = {t["name"]: t for t in BLOCK["block"]}
NAMES = [t["name"] for t in BLOCK["block"]]
ASSERT = next(t for t in BLOCK["always"] if t["name"] == "Fail loudly if any step or check went wrong")
UNIT = (ROOT / "rootfs/etc/systemd/system/fleet-update.service").read_text()
HOST = json.loads(subprocess.run(["yq", "-o=json", "."], input=ansible_host.text(), capture_output=True, text=True, check=True).stdout)[0]
HOST_TASKS = {t["name"]: t for t in HOST["tasks"]}
BACKUP = INNER["Back the box up before anything changes"]
BACKUP_STEPS = {t["name"]: t for t in BACKUP.get("block", [])}


def test_backup_runs_after_the_drain_and_before_any_update_step():
    stop = NAMES.index("Stop the runner services, so no CI job starts mid-update")
    backup = NAMES.index("Back the box up before anything changes")
    versions = NAMES.index("Record tool versions before the update")
    apt = NAMES.index("Upgrade every Ubuntu package (security and regular updates)")
    assert stop < backup < versions < apt


def test_the_backup_is_the_stock_restic_unit_and_fails_on_a_failed_run():
    start = BACKUP_STEPS["Run the backup and wait for it to finish"]
    assert start["ansible.builtin.command"]["argv"] == ["systemctl", "start", "restic-r2-backup.service"]
    assert start["timeout"] == 3600
    assert "not (pre_update_backup | default({})).failed | default(false)" in ASSERT["ansible.builtin.assert"]["that"]


def test_the_run_refuses_to_update_an_unbacked_box_rather_than_skipping_the_backup():
    check = BACKUP_STEPS["Check the backup's configuration"]
    assert check["ansible.builtin.stat"]["path"] == "/etc/restic/netcup-r2.env"
    refuse = BACKUP_STEPS["Refuse to update a box that cannot be restored"]
    assert refuse["ansible.builtin.assert"]["that"] == "backup_env.stat.exists"
    assert [n for n in BACKUP_STEPS].index("Refuse to update a box that cannot be restored") < [n for n in BACKUP_STEPS].index("Run the backup and wait for it to finish")


def test_the_unit_pings_healthchecks_only_after_a_green_run_and_skips_without_a_url():
    line = next(l for l in UNIT.splitlines() if l.startswith("ExecStartPost="))
    assert line.startswith("ExecStartPost=-")
    assert "bash" not in line
    assert line.endswith("/usr/bin/curl -fsS -m 10 --retry 3 -o /dev/null --config /etc/fleet-ops/update-hc.curl")


def test_host_config_builds_the_healthchecks_curl_config_from_the_box():
    hc = HOST_TASKS["Hand the update unit its own healthchecks URL, root-only"]
    assert hc["ansible.builtin.copy"]["dest"] == "/etc/fleet-ops/update-hc.curl"
    assert hc["ansible.builtin.copy"]["mode"] == "0600"
    assert hc["diff"] is False and hc["no_log"] is True
    assert HOST_TASKS["Read the healthchecks ping URLs nish keeps for the box"]["no_log"] is True
    assert HOST_TASKS["Make the directory for the update unit's root-only files"]["ansible.builtin.file"]["path"] == "/etc/fleet-ops"
    assert "HC_URL_UPDATE=" in hc["vars"]["hc_update_lines"]
    ping = shlex.split(next(l for l in UNIT.splitlines() if l.startswith("ExecStartPost="))[len("ExecStartPost="):])
    assert ping[ping.index("--config") + 1] == "/etc/fleet-ops/update-hc.curl"


def test_semgrep_blocks_the_return_of_yt_dlp_self_update():
    rule = next(r for r in yaml.safe_load((ROOT / ".semgrep/no-glue.yml").read_text())["rules"] if r["id"] == "no-yt-dlp-self-update")
    assert re.search(rule["pattern-regex"], "yt-dlp --update")
    assert not re.search(rule["pattern-regex"], "uv tool upgrade --all")
