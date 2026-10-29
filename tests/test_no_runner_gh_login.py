"""fleet-ops#10949, #9521: no runner job may use the runner user's own gh login.

That login counts as the owner's override approval, so anything a fooled session can read it can
approve its own PR with. Every write a job makes goes through a worker App token instead."""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
DROPINS = ROOT / "rootfs/etc/systemd/system"


def test_no_runner_dropin_binds_the_gh_login():
    for conf in DROPINS.glob("actions.runner.*.service.d/*.conf"):
        assert ".config/gh" not in conf.read_text(), conf.name


def test_no_workflow_step_falls_back_to_the_runner_login():
    # `env -u GH_TOKEN gh/git` (or a session started that way) hands the call the stored login.
    fallback = re.compile(r'env -u GH_TOKEN(?: -u GITHUB_TOKEN)? (?:\S+=\S+ )*(?:gh|git|"\$HOME/\.local/bin/(?:claude|pi)")\b')
    for wf in [*(ROOT / ".github/workflows").glob("*.yml"), *(ROOT / ".github/actions").glob("*/action.yml")]:
        hits = [n for n, line in enumerate(wf.read_text().splitlines(), 1) if fallback.search(line)]
        assert hits == [], f"{wf.name}: lines {hits}"


def test_workflows_permission_is_minted_only_for_the_orchestrator_and_the_arm():
    minted = {}
    for wf in (ROOT / ".github/workflows").glob("*.yml"):
        job = None
        for line in wf.read_text().splitlines():
            m = re.match(r"^  ([a-z0-9-]+):$", line)
            if m:
                job = m.group(1)
            if "permission-workflows: write" in line:
                minted.setdefault(wf.name, set()).add(job)
    assert minted == {"agent-dispatch.yml": {"orchestrate"}, "agent.yml": {"arm"}}
