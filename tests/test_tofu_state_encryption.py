"""The Cloudflare token state must be written encrypted once the key file is placed (W1c).

The unit loads an optional env file with a TF_ENCRYPTION line. These tests run the
real `tofu` against a throwaway local state that holds a fake token, with the env
file read by systemd the way the unit reads it, and count the fake token in the
stored files.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "infra/cloudflare-tokens/state-encryption.env.example"
FAKE = "ghs_" + "TESTFAKE0123456789abcdefghijklmnop"
PASSPHRASE = "pytest-passphrase-0123456789-abcdefghij"
PLACEHOLDER = "PASTE_THE_GENERATED_PASSPHRASE_HERE"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))

needs_tofu = pytest.mark.skipif(shutil.which("tofu") is None, reason="tofu is not installed")
needs_user_manager = pytest.mark.skipif(
    shutil.which("systemd-run") is None or not (RUNTIME / "bus").exists(), reason="needs a systemd user manager"
)


def _write_env(path: Path, with_fallback: bool = True) -> None:
    line = [l for l in EXAMPLE.read_text().splitlines() if l.startswith("TF_ENCRYPTION=")][0]
    line = line.replace(PLACEHOLDER, PASSPHRASE)
    if not with_fallback:
        line = line.replace(',"fallback":{"method":"method.unencrypted.migrate"}', "")
    path.write_text(line + "\n")
    path.chmod(0o600)


def _tofu(work: Path, *args: str, env_file: Path | None = None) -> subprocess.CompletedProcess:
    tofu = shutil.which("tofu")
    assert tofu
    cmd = ["systemd-run", "--user", "--wait", "--pipe", "--collect", "--quiet", "-p", f"WorkingDirectory={work}", "-p", "Environment=TF_IN_AUTOMATION=1"]
    if env_file:
        cmd += ["-p", f"EnvironmentFile={env_file}"]
    return subprocess.run([*cmd, tofu, *args, "-input=false"], capture_output=True, text=True)


def _count(path: Path) -> int:
    return path.read_text().count(FAKE) if path.exists() else 0


@needs_tofu
@needs_user_manager
def test_state_holds_no_raw_token_once_the_key_file_exists(tmp_path: Path) -> None:
    work = tmp_path / "w"
    work.mkdir()
    (work / "main.tf").write_text(
        'terraform {\n  backend "local" {\n    path = "state/terraform.tfstate"\n  }\n}\n'
        f'resource "terraform_data" "t" {{\n  input = "{FAKE}"\n}}\n'
    )
    state, backup = work / "state/terraform.tfstate", work / "state/terraform.tfstate.backup"
    env_file = tmp_path / "tofu-state-encryption.env"
    _write_env(env_file)

    def grow(n: int) -> None:
        (work / "main.tf").write_text(
            (work / "main.tf").read_text() + f'resource "terraform_data" "extra{n}" {{\n  input = "plain{n}"\n}}\n'
        )

    assert _tofu(work, "init").returncode == 0
    assert _tofu(work, "apply", "-auto-approve").returncode == 0
    grow(1)
    assert _tofu(work, "apply", "-auto-approve").returncode == 0
    assert (_count(state) > 0, _count(backup) > 0) == (True, True)

    done = _tofu(work, "apply", "-auto-approve", env_file=env_file)
    assert done.returncode == 0, done.stdout + done.stderr
    assert _count(state) == 0 and '"resources"' not in state.read_text()
    assert _count(backup) > 0
    backup.unlink()

    grow(2)
    assert _tofu(work, "apply", "-auto-approve", env_file=env_file).returncode == 0
    assert (_count(state), _count(backup)) == (0, 0)
    assert backup.exists() and '"resources"' not in backup.read_text()

    plan = _tofu(work, "plan", "-detailed-exitcode", env_file=env_file)
    assert plan.returncode == 0, plan.stdout + plan.stderr
    assert _tofu(work, "plan").returncode != 0

    plain = work / "plain"
    shutil.copytree(work, plain, ignore=shutil.ignore_patterns("state", ".terraform*"))
    _tofu(plain, "init")
    (plain / "state").mkdir()
    _tofu(plain, "apply", "-auto-approve")
    strict = tmp_path / "strict.env"
    _write_env(strict, with_fallback=False)
    refused = _tofu(plain, "plan", env_file=strict)
    assert refused.returncode != 0
    assert _count(plain / "state/terraform.tfstate") > 0, "the refused run must not have rewritten the plain state"
