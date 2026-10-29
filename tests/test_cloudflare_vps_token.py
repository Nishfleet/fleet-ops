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
    assert set(re.findall(r'"([^"]+)"', groups)) == {"Account Analytics Read"}, (
        "the consumer queries account-level GraphQL datasets only, so a wider group is unused access"
    )


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


def test_the_apply_hands_the_rotation_to_the_existing_writer():
    """Grafana mounts a copy, so a rotation that only rewrites the file blinds it.

    The Cloudflare spend watch reads through that secret. One writer already
    refreshes it from this file, so the apply starts that writer instead of
    writing the secret a second time and drifting from it.
    """
    text = UNIT.read_text()
    post = next(line for line in text.splitlines() if line.startswith("ExecStartPost="))
    assert post == "ExecStartPost=/usr/bin/systemctl start --no-block fleet-host-config.service"
    assert "polkit" in text, "the unit must say why a user unit may start a system unit"
    assert "grafana-cloudflare-api-token" in HOST.read_text()
    assert "--no-block" in post, "a long playbook must not hold the apply"
    assert not [line for line in text.splitlines() if line.startswith(("ExecStart=", "ExecStartPost=")) and "/bin/sh" in line and "TF_VAR_github_app_pem" not in line], (
        "no second writer in shell: ansible/tasks/secrets.yml already does this"
    )


def test_the_grafana_queries_are_account_level_so_no_zone_group_is_needed():
    """The token carries no zone group, so a zone-scoped query would 401."""
    queried = set()
    for path in (ROOT / "config/grafana").rglob("*.yaml"):
        text = path.read_text()
        queried |= set(re.findall(r"\b[a-z0-9][A-Za-z0-9]*AdaptiveGroups\b", text))
        assert "viewer { zones" not in text and "zones(" not in text, f"{path} queries a zone dataset"
    assert queried, "the spend watch queries no dataset at all"
    assert re.search(r"zone\s+= \[\]", _entry("vps-grafana"))
    spend = (ROOT / "config/grafana/provisioning/alerting/cloudflare-spend.yaml").read_text()
    assert spend.count("execErrState: Error") == spend.count("noDataState:")


def test_only_the_github_secret_tokens_take_the_gha_prefix():
    """The README's lost-state cleanup deletes `gha-` tokens, so the host one must not match."""
    name = next(line for line in MAIN.read_text().splitlines() if line.strip().startswith("name") and "formatdate" in line)
    assert 'each.value.file == null ? "gha-" : ""' in name
    assert "${each.key}-" in name, "the rendered name starts with the map key"
    assert _entry("vps-grafana").count("file        = ") == 1
