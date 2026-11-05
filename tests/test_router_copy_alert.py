"""A dead router copy files an issue: the alert rule exists and Prometheus scrapes what it reads."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
HAPROXY = ROOT / "rootfs/etc/haproxy/haproxy.cfg"
PROMETHEUS = ROOT / "rootfs/etc/prometheus/prometheus.yml"
RULES = ROOT / "rootfs/etc/prometheus/fleet_rules.yml"


def test_router_copy_down_rule_reads_a_scraped_haproxy_exporter() -> None:
    """With two router copies behind HAProxy, one that dies breaks nothing anyone sees, and the copies are
    user units that SystemUnitFailed does not read (fleet-ops#11764). RouterCopyDown is the only thing that
    says so, and it is blind unless Prometheus scrapes the exporter frontend HAProxy serves it from.
    """
    rules = [r for g in yaml.safe_load(RULES.read_text())["groups"] for r in g["rules"]]
    alert = [r for r in rules if r.get("alert") == "RouterCopyDown"]
    assert len(alert) == 1, "RouterCopyDown is missing from fleet_rules.yml"
    assert 'haproxy_backend_active_servers{proxy="litellm"}' in alert[0]["expr"]

    exporter = re.search(
        r"^frontend prometheus\n\tbind (\S+)\n\thttp-request use-service prometheus-exporter if \{ path /metrics \}$",
        HAPROXY.read_text(),
        re.MULTILINE,
    )
    assert exporter, "HAProxy's prometheus-exporter frontend is missing from haproxy.cfg"
    jobs = yaml.safe_load(PROMETHEUS.read_text())["scrape_configs"]
    scraped = {t for j in jobs if j.get("metrics_path", "/metrics") == "/metrics" for s in j.get("static_configs", []) for t in s["targets"]}
    assert exporter.group(1) in scraped, f"no Prometheus job scrapes HAProxy's exporter at {exporter.group(1)}"
