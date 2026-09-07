#!/usr/bin/env python3
"""Run any agent workload with inherited orphan-cleanup ownership markers."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

REPO_ROOT = Path("/home/nish/.local/libexec/agent-governor-runtime")
sys.path.insert(0, str(REPO_ROOT))

from integrations.codex_gate_exec import run_supervised


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--"]:
        args = args[1:]
    if not args:
        print("usage: governed-run -- command [args...]", file=sys.stderr)
        return 2
    executable = shutil.which(args[0])
    if executable is None:
        print(f"governed-run: command not found: {args[0]}", file=sys.stderr)
        return 127
    return run_supervised(Path(executable).resolve(), args[1:])


if __name__ == "__main__":
    raise SystemExit(main())
