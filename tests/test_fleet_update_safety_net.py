"""The daily update's safety net: a restic snapshot before any update step, a killed run still resumes the fleet, and every private path is discovered from the box, not named in the repo."""
import json
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]
BLOCK = next(t for t in PLAY["tasks"] if "block" in t and "always" in t)
INNER = {t["name"]: t for t in BLOCK["block"]}
NAMES = [t["name"] for t in BLOCK["block"]]
ASSERT = next(t for t in BLOCK["always"] if t["name"] == "Fail loudly if any step or check went wrong")
UNIT = (ROOT / "rootfs/etc/systemd/system/fleet-update.service").read_text()
HOST = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/host.yml")], capture_output=True, text=True, check=True).stdout)[0]
HOST_TASKS = {t["name"]: t for t in HOST["tasks"]}
BACKUP = INNER["Back the box up before anything changes"]
BACKUP_STEPS = {t["name"]: t for t in BACKUP.get("block", [])}
TINCAN_PATH_TELL = ".config/tin" + "can"


def test_backup_runs_after_the_drain_and_before_any_update_step():
    stop = NAMES.index("Stop the runner services, so no CI job starts mid-update")
    backup = NAMES.index("Back the box up before anything changes")
    versions = NAMES.index("Record tool versions before the update")
    apt = NAMES.index("Upgrade every Ubuntu package (security and regular updates)")
    assert stop < backup < versions < apt


def test_the_backup_is_the_stock_restic_unit_and_fails_on_a_failed_run():
    start = BACKUP_STEPS["Run the backup and wait for it to finish"]
    assert start["ansible.builtin.command"]["argv"] == ["systemctl", "start", "restic-r2-backup.service"]
    assert start["timeout"] == 7200
    assert "not (pre_update_backup | default({})).failed | default(false)" in ASSERT["ansible.builtin.assert"]["that"]


def test_the_run_refuses_to_update_an_unbacked_box_rather_than_skipping_the_backup():
    check = BACKUP_STEPS["Check the backup's configuration"]
    assert check["ansible.builtin.stat"]["path"] == "/etc/restic/netcup-r2.env"
    refuse = BACKUP_STEPS["Refuse to update a box that cannot be restored"]
    assert refuse["ansible.builtin.assert"]["that"] == "backup_env.stat.exists"
    assert [n for n in BACKUP_STEPS].index("Refuse to update a box that cannot be restored") < [n for n in BACKUP_STEPS].index("Run the backup and wait for it to finish")


def test_the_play_skips_tincan_by_name_instead_of_naming_its_config_path():
    assert PLAY["vars"]["tincan_env_config"] == "{{ lookup('ansible.builtin.env', 'TINCAN_CONFIG') }}"
    assert INNER["Update tincan"]["when"] == "tincan_env_config | length > 0"
    assert "TINCAN_CONFIG is unset" in json.dumps(next(t for t in BLOCK["always"] if t["name"] == "Report the run")["ansible.builtin.debug"]["msg"])
    assert TINCAN_PATH_TELL not in json.dumps(PLAY)


def test_a_killed_run_resumes_the_fleet():
    stale_stat = next(t for t in PLAY["tasks"] if t["name"] == "Look for a dispatch pause an earlier run left behind")
    clear_block = next(t for t in PLAY["tasks"] if t["name"] == "Clear the flags a killed earlier run left set")
    assert stale_stat.get("tags") == ["resume"]
    assert clear_block.get("tags") == ["resume"]


def test_the_unit_resumes_on_any_stop_with_the_play():
    line = next(l for l in UNIT.splitlines() if l.startswith("ExecStopPost="))
    assert line.startswith("ExecStopPost=-")
    assert "/var/lib/fleet-ops/update-repo/ansible/update.yml" in line
    assert "--tags resume" in line


def test_the_unit_reads_the_relay_config_from_a_root_only_env_file():
    envfiles = [l for l in UNIT.splitlines() if l.startswith("EnvironmentFile=")]
    assert envfiles == ["EnvironmentFile=-/etc/fleet-ops/update-tincan.env"]


def test_the_unit_pings_healthchecks_only_after_a_green_run_and_skips_without_a_url():
    line = next(l for l in UNIT.splitlines() if l.startswith("ExecStartPost="))
    assert line.startswith("ExecStartPost=-")
    assert "bash" not in line
    assert line.endswith("/usr/bin/curl -fsS -m 10 --retry 3 -o /dev/null --config /etc/fleet-ops/update-hc.curl")


def test_host_config_builds_both_root_only_env_files_from_the_box():
    tincan = HOST_TASKS["Name the update unit's tincan relay config in a root-only env file"]
    assert tincan["ansible.builtin.copy"]["dest"] == "/etc/fleet-ops/update-tincan.env"
    assert tincan["ansible.builtin.copy"]["mode"] == "0600"
    hc = HOST_TASKS["Hand the update unit its own healthchecks URL, root-only"]
    assert hc["ansible.builtin.copy"]["dest"] == "/etc/fleet-ops/update-hc.curl"
    assert hc["ansible.builtin.copy"]["mode"] == "0600"
    assert hc["diff"] is False and hc["no_log"] is True
    assert HOST_TASKS["Read the healthchecks ping URLs nish keeps for the box"]["no_log"] is True
    assert HOST_TASKS["Make the directory for the update unit's root-only files"]["ansible.builtin.file"]["path"] == "/etc/fleet-ops"
    assert "HC_URL_UPDATE=" in hc["vars"]["hc_update_lines"]
    assert "keystone-hc.env" in HOST_TASKS["Read the healthchecks ping URLs nish keeps for the box"]["ansible.builtin.slurp"]["src"]
    assert "/etc/fleet-ops/update-tincan.env" in UNIT
    assert "update-hc.curl" in UNIT


def test_private_detail_scan_and_semgrep_block_the_return_of_both_patterns():
    assert "private-tincan-relay-config" in (ROOT / ".github/gitleaks-private-detail.toml").read_text()
    assert "no-yt-dlp-self-update" in (ROOT / ".semgrep/no-glue.yml").read_text()
