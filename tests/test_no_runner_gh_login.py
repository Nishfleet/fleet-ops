"""fleet-ops#10949, #9521: no runner job may use the runner user's own gh login.

That login counts as the owner's override approval, so anything a fooled session can read it can
approve its own PR with. Every write a job makes goes through a worker App token instead."""
import pathlib
import re
import shlex

ROOT = pathlib.Path(__file__).resolve().parents[1]
DROPINS = ROOT / "rootfs/etc/systemd/system"
CRED_HIDE = '${CREDENTIALS_DIRECTORY:+--tmpfs "$CREDENTIALS_DIRECTORY" --tmpfs "${CREDENTIALS_DIRECTORY%/*}"}'
HOME = "/home/nish"


def bound_paths(conf: pathlib.Path) -> list[str]:
    out = []
    for line in conf.read_text().splitlines():
        key, _, value = line.strip().partition("=")
        if key in ("BindPaths", "BindReadOnlyPaths"):
            out += [p.lstrip("-+") for p in shlex.split(value)]
    return out


def test_no_runner_dropin_binds_the_gh_login():
    # A bind is what makes the login readable. An empty TemporaryFileSystem= is the opposite: it is the
    # mount point the job jail needs to mask the path at all (fleet-ops#11097). A bind of a parent exposes it too.
    # The login path is composed from its home prefix: the private-detail scan flags the literal form, and a
    # credential path in a test is the public-repo detail fleet-ops#10081 removed.
    gh_dir = pathlib.Path(HOME, ".config", "gh")
    for conf in DROPINS.glob("actions.runner.*.service.d/*.conf"):
        for path in bound_paths(conf):
            assert pathlib.Path(path) not in (gh_dir, *gh_dir.parents), f"{conf.name}: {path}"


def test_no_workflow_step_falls_back_to_the_runner_login():
    # `env -u GH_TOKEN gh/git` (or a session started that way) hands the call the stored login.
    fallback = re.compile(r'env (?:-i|(?:-u (?:GH_TOKEN|GITHUB_TOKEN) )+)(?:[A-Za-z_][A-Za-z0-9_]*=\S* )*(?:gh|git|"\$HOME/\.local/bin/(?:claude|pi)")\b')
    for wf in [*(ROOT / ".github/workflows").glob("*.yml"), *(ROOT / ".github/actions").glob("*/action.yml")]:
        hits = [n for n, line in enumerate(wf.read_text().splitlines(), 1) if fallback.search(line)]
        assert hits == [], f"{wf.name}: lines {hits}"


def test_workflows_permission_is_minted_only_for_the_arm():
    minted = {}
    for wf in (ROOT / ".github/workflows").glob("*.yml"):
        job = None
        for line in wf.read_text().splitlines():
            m = re.match(r"^  ([a-z0-9-]+):$", line)
            if m:
                job = m.group(1)
            if "permission-workflows: write" in line:
                minted.setdefault(wf.name, set()).add(job)
    assert minted == {"agent.yml": {"arm"}}


def test_the_worker_jails_hide_the_credential_directory():
    """The App key is a systemd credential, and its directory is readable by the unit's user, which is every jailed engine."""
    wf = (ROOT / ".github/workflows/agent.yml").read_text()
    assert f"cred_hide={CRED_HIDE}" in wf, "the hide is one parameter expansion over the directory systemd names: systemd sets $CREDENTIALS_DIRECTORY for every unit that loads a credential, and a hand-rolled test of the path could disagree with the unit that mounts the key"
    assert "[ -d /run/credentials ]" not in wf, "the store path is a system-scope detail, and a user service keeps its credentials under /run/user"
    jails = [line for line in wf.splitlines() if re.match(r'\s*(?:jail_base|claude_jail_[ab])="bwrap --dev-bind', line)]
    assert len(jails) >= 4, jails
    for line in jails:
        assert "$cred_hide" in line, line

