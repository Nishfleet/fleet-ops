"""Grafana token wiring moved here from ci.yml's systemd-verify job, unchanged in
shape: RuntimeDirectory, quadlet mount and $__file{} must name one directory, or
the contact points read a token path that the token unit never writes.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-grafana-github-token.service"
QUADLET = ROOT / "containers/quadlet/fleet-grafana.container"
CONTACTS = ROOT / "config/grafana/provisioning/alerting/cloudflare-spend-contact.yaml"


def test_runtime_directory_quadlet_mount_and_contact_points_name_one_directory():
    unit = UNIT.read_text()
    rd = re.search(r"^RuntimeDirectory=(.+)$", unit, re.M)
    assert rd
    rd = rd.group(1).strip()

    quadlet = QUADLET.read_text()
    m = re.search(rf"^Volume=%t/{re.escape(rd)}:(/[^:]*):ro$", quadlet, re.M)
    mount = m.group(1) if m else None
    assert mount, f"{QUADLET.name} does not mount %t/{rd} read-only"
    assert "\nWants=fleet-grafana-github-token.service\n" in quadlet
    assert "\nAfter=fleet-grafana-github-token.service\n" in quadlet

    contact_points = CONTACTS.read_text()
    n = len(re.findall(r"authorization_credentials:", contact_points))
    assert n >= 2, "no webhook contact point pair expected"
    read_from = len(
        re.findall(
            re.escape(f"authorization_credentials: $__file{{{mount}/token}}"),
            contact_points,
        )
    )
    assert n == read_from, f"{CONTACTS.name}: {read_from} of {n} webhook contact points read $__file{{{mount}/token}}"
