#!/usr/bin/env python3
"""Build a policy runner with role defaults embedded in its certificate scope."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

MARKER = "CERTIFIED_ROLE_DEFAULTS: dict[str, list[str | None]] = {}"


def main() -> int:
    if len(sys.argv) != 4:
        return 2
    source, agents_dir, destination = map(Path, sys.argv[1:])
    roles: dict[str, list[str | None]] = {}
    for role_path in sorted(agents_dir.glob("*.toml")):
        if re.fullmatch(r"[A-Za-z0-9_-]+", role_path.stem) is None:
            continue
        document = tomllib.loads(role_path.read_text(encoding="utf-8"))
        model = document.get("model")
        effort = document.get("model_reasoning_effort")
        if isinstance(model, str):
            roles[role_path.stem] = [model, effort if isinstance(effort, str) else None]
    policy = source.read_text(encoding="utf-8")
    replacement = f"CERTIFIED_ROLE_DEFAULTS: dict[str, list[str | None]] = {roles!r}"
    if policy.count(MARKER) != 1:
        raise RuntimeError("certified role marker missing or duplicated")
    destination.write_text(policy.replace(MARKER, replacement), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
