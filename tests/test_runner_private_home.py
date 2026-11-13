"""The pilot runner's home is private and no folder on its PATH is writable by a job (fleet-ops#11959).

Every runner shares one user and home, so a job could leave a tool (a no-op `claude`) in the
home's bin folder that every later job ran. The pilot's drop-in puts a tmpfs over the home
(systemd.exec(5), TemporaryFileSystem=) and binds back only read-only paths and the runner's
own _work and _diag. Its pi and the check tools are installed by the play into one
root-owned folder outside the home, and pi's session files go to the runtime directory.
Design: docs/design/ephemeral-runners.md, "Where the reset happens".
"""
import pathlib

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
DROPIN = ROOT / "rootfs/etc/systemd/system/fleet-runner@22.service.d/10-private-home.conf"
HOME = "/var/lib/fleet-runner"
RW_ALLOWED = {f"{HOME}/22/_work", f"{HOME}/22/_diag"}


def _values(key):
    out = []
    for line in DROPIN.read_text().splitlines():
        if line.startswith(f"{key}="):
            out.append(line.split("=", 1)[1])
    return out


def _path():
    env = [v for v in _values("Environment") if v.startswith("PATH=")]
    assert len(env) == 1, "the unit must set PATH itself, once"
    return env[0][len("PATH="):].split(":")


def _vars():
    return ansible_host.play()["vars"]


def _render(value):
    """Expand {{ name }} against the play's vars, until no reference is left."""
    for _ in range(10):
        start = value.find("{{")
        if start == -1:
            return value
        end = value.find("}}", start)
        name = value[start + 2:end].strip()
        value = value[:start] + _vars()[name] + value[end + 2:]
    raise AssertionError("the render does not end")


def test_the_home_is_a_tmpfs_a_job_cannot_write():
    tmpfs = _values("TemporaryFileSystem")
    assert len(tmpfs) == 1 and tmpfs[0].split(":")[0] == HOME, tmpfs
    opts = tmpfs[0].partition(":")[2]
    assert "mode=0755" in opts and "uid=" not in opts, "the tmpfs root must stay root-owned"


def test_only_work_and_diag_are_read_write_under_the_home():
    rw = set(_values("BindPaths"))
    assert rw == RW_ALLOWED, rw


def test_everything_else_bound_back_is_read_only():
    ro = set(_values("BindReadOnlyPaths"))
    assert f"{HOME}/22" in ro, "the runner install must be bound read-only"
    assert not ro & RW_ALLOWED
    # The pinned Node comes back read-only: its bin holds npm and npx, and npm there is a
    # script that runs the node beside it.
    assert _render(_vars()["tether_node_dir"]) in ro, "the pinned Node must be bound read-only"
    # pi and the tools are outside the home, so no bind reaches into it but the three above.
    assert all(p == _render(_vars()["tether_node_dir"]) or p.startswith(HOME + "/") for p in ro), ro
    assert not any(p.startswith(f"{HOME}/.local") for p in ro), "the home's tools folder must not be bound"


def test_every_folder_on_path_is_root_owned_and_outside_the_home():
    path = _path()
    assert path == _render(_vars()["fleet_pilot_path"]).split(":"), (
        "the drop-in's PATH and the play's .path for runner 22 must be the same value")
    tools = _vars()["fleet_pilot_tools"]
    assert not any(folder.startswith(HOME + "/") for folder in path), "no folder in the home may go on PATH"
    assert f"{tools}/venv/bin" in path and f"{tools}/bin" in path, path
    assert _render(_vars()["tether_node_dir"]) + "/bin" in path, "npm and npx come from the pinned Node"
    assert all(folder in {"/usr/local/bin", "/usr/bin", "/bin"} or folder.startswith("/opt/")
               for folder in path), path


def test_the_caches_and_pi_sessions_live_in_the_runtime_directory():
    assert _values("RuntimeDirectory") == ["fleet-runner-22"]
    for env in ["XDG_CACHE_HOME=/run/fleet-runner-22",
                "npm_config_cache=/run/fleet-runner-22/npm",
                "PI_CODING_AGENT_SESSION_DIR=/run/fleet-runner-22/pi-sessions"]:
        assert env in _values("Environment"), env


def test_the_play_installs_the_pinned_tools_into_the_root_owned_folder():
    tasks = ansible_host.text()
    pins = ["ansible-lint==26.11.0", "black==26.10.1", "pytest==8.3.5", "ruff==0.17.3",
            "semgrep==1.183.0", "yamllint==1.38.0", "zizmor==1.32.0", "uv==0.13.7"]
    for pin in pins:
        assert pin in tasks, pin
    assert 'virtualenv: "{{ fleet_pilot_tools }}/venv"' in tasks, "the pip tools go into the folder's venv"
    for vendor in ["actionlint_1.7.12_linux_amd64.tar.gz",
                   "sha256:8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
                   "mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64",
                   "sha256:a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"]:
        assert vendor in tasks, vendor
    assert '--prefix, "{{ fleet_pilot_tools }}"' in tasks, "pi is installed into the folder, not the home"
    assert 'content: "{{ fleet_pilot_path if item == 22 else' in tasks, (
        "runner 22's .path is the pilot PATH")


def test_the_shared_template_is_not_changed_by_the_pilot():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    assert "TemporaryFileSystem" not in unit
