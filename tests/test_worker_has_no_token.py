"""The AI worker holds no GitHub credential (fleet-ops#11715, owner 2026-11-04 "fully isolate it").

The worker runs on the `agent` runners as fleet-runner. Those jobs mint no App token and read
no key, the runner unit loads no key, and fleet-runner's home has no git credential. The App
token is minted only on GitHub-hosted jobs in environment `agent`.
https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
"""
from configparser import ConfigParser
from pathlib import Path

import ansible_host
import yaml

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-runner@.service"


def jobs():
    for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
        for name, job in (yaml.safe_load(wf.read_text()).get("jobs") or {}).items():
            yield wf.name, name, job


def on_agent_runners(job) -> bool:
    labels = job.get("runs-on")
    labels = labels.get("labels", []) if isinstance(labels, dict) else labels
    # agent.yml's work job picks its label from the engine input (fleet-ops#11958): the
    # expression string is not equal to `agent`, so match inside the label instead of on
    # whole-element equality; the fallback pool it names (`agent`) keeps the job covered.
    return any("agent" in str(l) for l in ([labels] if isinstance(labels, str) else labels or []))


def test_the_work_job_is_still_among_the_jobs_checked():
    # The check above only guards jobs it matches (fleet-ops#11971): pin agent.yml's work
    # job to this file so a future label change cannot drop it silently.
    assert any(wf == "agent.yml" and name == "work" and on_agent_runners(job)
               for wf, name, job in jobs())


def test_no_job_on_the_worker_runners_gets_a_github_credential():
    leaks = [(wf, name) for wf, name, job in jobs() if on_agent_runners(job) and (
        job.get("permissions") != {}
        or any(k in yaml.safe_dump(job) for k in ("create-github-app-token", "private-key", "CREDENTIALS_DIRECTORY", "secrets.", "github.token")))]
    assert leaks == []


def test_the_app_key_comes_only_from_hosted_jobs_in_environment_agent():
    readers = [(wf, name, job.get("runs-on"), job.get("environment"))
               for wf, name, job in jobs() if "APP_PRIVATE_KEY" in yaml.safe_dump(job)]
    assert readers and all(str(r).startswith("ubuntu-") and env == "agent" for _, _, r, env in readers)


def test_the_worker_runner_unit_loads_no_credential():
    unit = ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str
    unit.read_string(UNIT.read_text())
    assert not [k for k in unit["Service"] if "Credential" in k]


def test_the_play_leaves_no_git_credential_in_fleet_runners_home():
    writes = [t for t in ansible_host.play()["tasks"] for mod in ("ansible.builtin.copy", "ansible.builtin.template")
              if str(t.get(mod, {}).get("dest", "")).startswith("/var/lib/fleet-runner/.gitconfig")]
    assert writes == []
