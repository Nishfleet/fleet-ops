"""The pilot runner's home is private and no folder on its PATH is writable by a job (fleet-ops#11959).

Every runner shares one user and home, so a job could leave a tool (a no-op `claude`) in the
home's bin folder that every later job ran. The pilot's drop-in puts a tmpfs over the home
(systemd.exec(5), TemporaryFileSystem=) and binds back only read-only paths and the runner's
own _work and _diag. Design: docs/design/ephemeral-runners.md, "Where the reset happens".
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
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
    assert all(p.startswith(HOME + "/") for p in ro)
    assert not ro & RW_ALLOWED


def test_no_folder_on_path_is_job_writable():
    ro = set(_values("BindReadOnlyPaths"))
    for folder in _path():
        assert folder.startswith("/"), folder
        if folder.startswith(HOME + "/"):
            # Under the tmpfs home: root-owned, so only what is bound read-only is there.
            assert not any(folder == p or folder.startswith(p + "/") for p in RW_ALLOWED), folder
            assert any(p.startswith(folder + "/") for p in ro), f"{folder} holds nothing bound read-only"
        else:
            assert folder in {"/usr/local/bin", "/usr/bin", "/bin"}, folder


def test_the_caches_live_in_the_runtime_directory():
    assert _values("RuntimeDirectory") == ["fleet-runner-22"]
    assert "XDG_CACHE_HOME=/run/fleet-runner-22" in _values("Environment")


def test_the_shared_template_is_not_changed_by_the_pilot():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    assert "TemporaryFileSystem" not in unit
