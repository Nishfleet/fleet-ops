"""The VPS Cloudflare token is narrow, IP-locked and lands in the file Grafana reads (fleet-ops#10169).

The token this config writes for the VPS replaced a hand-made user token with no
expiry, no IP lock, and Workers, D1, KV and Zone read permissions for a consumer
that needs one read-only group. These tests read main.tf and ansible/host.yml and
fail when the entry loses the lock, gains a permission its consumer cannot use,
or stops writing the file and key the grafana-cloudflare-api-token Podman secret
reads.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "infra/cloudflare-tokens/main.tf"
HOST = ROOT / "ansible/host.yml"
UNIT = ROOT / "systemd/cloudflare-tokens-apply.service"


def _entry(key: str) -> str:
    text = MAIN.read_text()
    start = text.index(f'"{key}" = {{')
    return text[start : text.index("\n    }", start)]


def test_vps_token_is_ip_locked_and_read_only():
    entry = _entry("vps-grafana")
    assert "vps_only    = true" in entry
    assert re.search(r"zone\s+= \[\]", entry)
    groups = re.search(r"account\s+= \[([^\]]*)\]", entry).group(1)
    assert groups, "the VPS token needs the one group its consumer calls"
    for name in re.findall(r'"([^"]+)"', groups):
        assert name.endswith(" Read"), f"{name} is not read-only"


def test_vps_token_writes_the_file_and_key_ansible_reads():
    entry = _entry("vps-grafana")
    path = re.search(r'file\s+= "([^"]+)"', entry).group(1)
    main = MAIN.read_text()
    key = re.search(r'content\s+= "([A-Z_]+)=', main).group(1)

    secret = next(line for line in HOST.read_text().splitlines() if "grafana-cloudflare-api-token" in line)
    assert f'src: "{path.replace("~", "{{ nish_home }}")}"' in secret
    assert f"key: {key}" in secret
    assert 'file_permission      = "0600"' in main
    assert "if v.environment == null && v.repo != null" in main, "a file token must not be written to a repo secret"


def test_the_weekly_apply_supplies_the_addresses_the_vps_token_needs():
    """The precondition fails closed, so the unit must hand tofu the addresses.

    Without this the weekly apply fails at plan time and no token rotates at
    all, so the repo deploy tokens expire 45 days after their last rotation.
    """
    text = UNIT.read_text()
    exec_start = next(line for line in text.splitlines() if line.startswith("ExecStart="))
    var_file = re.search(r"-var-file=(\S+?)(?:'|\s|$)", exec_start)
    assert var_file, "the apply does not pass the gitignored vps_cidrs tfvars file"
    assert var_file.group(1).endswith("vps-cidrs.tfvars")
    assert "vps_cidrs" in (ROOT / "infra/cloudflare-tokens/README.md").read_text()


def test_the_apply_republishes_the_secret_that_grafana_mounts():
    """Grafana mounts a copy, so a rotation that only rewrites the file blinds it.

    The Cloudflare spend watch reads through that secret; a rotation without
    this step leaves it holding the token the apply just deleted until the next
    host-config run.
    """
    text = UNIT.read_text()
    post = next(line for line in text.splitlines() if line.startswith("ExecStartPost="))
    assert "grafana-cloudflare-api-token" in post, "the rotated token never reaches Grafana"
    assert "deploy-ci.env" in post, "the secret must come from the file the apply writes"
    assert "restart fleet-grafana.service" in post
    assert "--replace" in post and "secret inspect" in post, "restart Grafana only when the value changed"
    assert "{{.SecretData}}" in post
    assert 'printf %s "$$new" |' in post, "the value must reach podman on stdin, never argv"
    assert "grafana-cloudflare-api-token" in HOST.read_text()


def test_only_the_github_secret_tokens_take_the_gha_prefix():
    """The README's lost-state cleanup deletes `gha-` tokens, so the host one must not match."""
    name = next(line for line in MAIN.read_text().splitlines() if line.strip().startswith("name") and "formatdate" in line)
    assert 'each.value.file == null ? "gha-" : ""' in name
    assert _entry("vps-grafana").count("file        = ") == 1
