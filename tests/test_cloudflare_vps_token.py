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
