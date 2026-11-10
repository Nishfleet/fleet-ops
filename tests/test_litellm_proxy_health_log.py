"""HAProxy's readiness check must not reach the journal as a LiteLLM access-log line.

fleet-ops#11846: HAProxy checks /health/readiness every 2 s per instance, and uvicorn's
access log is on, so the router wrote one line per check (86,400 a day across the two
instances). LiteLLM's stock LITELLM_DISABLE_ACCESS_LOG_PATHS drops exactly those lines
(https://docs.litellm.ai/docs/proxy/config_settings#environment-variables---reference);
this keeps the variable on the path HAProxy actually probes.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HAPROXY = (ROOT / "rootfs/etc/haproxy/haproxy.cfg").read_text(encoding="utf-8")
QUADLET = (ROOT / "containers/quadlet/fleet-litellm-proxy@.container").read_text(
    encoding="utf-8"
)


def test_the_haproxy_check_path_is_dropped_from_the_litellm_access_log() -> None:
    check = re.search(r"^\s*http-check send .*\buri (\S+)$", HAPROXY, re.MULTILINE)
    assert check, "no 'http-check send ... uri <path>' line in haproxy.cfg"
    disabled = re.search(
        r"^Environment=LITELLM_DISABLE_ACCESS_LOG_PATHS=(\S+)$", QUADLET, re.MULTILINE
    )
    assert disabled, "the router quadlet sets no LITELLM_DISABLE_ACCESS_LOG_PATHS"
    assert check.group(1) in disabled.group(1).split(","), (
        f"HAProxy probes {check.group(1)} but the access log only drops {disabled.group(1)}: "
        "every check writes a journal line again"
    )
