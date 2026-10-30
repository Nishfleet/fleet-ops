"""No curl in a workflow, unit or prompt puts a credential in argv (fleet-ops#9264).

`/proc/<pid>/cmdline` is world-readable, so `curl -H "Authorization: Bearer $KEY"`
shows the key to every process through `ps`. AGENTS.md "Secrets" requires a curl
config fd: `--config <(... header = "Authorization: Bearer ...")`.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRS = [".github", "prompts", "systemd", "rootfs", "ansible"]
SUFFIXES = {".yml", ".yaml", ".md", ".service", ".conf", ".sh", ".j2", ""}
# `-H`/`--header` whose value carries an auth header and a shell expansion.
ARGV_HEADER = re.compile(
    r"""(?:-H|--header)[ =]+(['"])[^'"\n]*(?:authorization|x-auth|api-key|bearer|token)[^'"\n]*\$[{(A-Za-z_]""",
    re.IGNORECASE,
)


def test_helper_flags_a_bearer_header_in_argv() -> None:
    assert ARGV_HEADER.search('curl -H "Authorization: Bearer $CF_TOKEN" https://x')
    assert ARGV_HEADER.search("curl --header 'X-Auth-Key: ${KEY}' https://x")
    assert not ARGV_HEADER.search("curl --config <(printf 'header = \"Authorization: Bearer %s\"' \"$k\") https://x")
    assert not ARGV_HEADER.search("curl -H 'content-type: application/json' -d \"$body\"")


def test_no_curl_puts_a_credential_in_argv() -> None:
    offenders = []
    for d in DIRS:
        for path in (ROOT / d).rglob("*"):
            if not path.is_file() or path.suffix not in SUFFIXES:
                continue
            for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
                if "curl" in line and ARGV_HEADER.search(line):
                    offenders.append(f"{path.relative_to(ROOT)}:{n}")
    assert not offenders, f"credential in curl argv: {offenders}"
