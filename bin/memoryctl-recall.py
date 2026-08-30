#!/usr/bin/env python3
"""memoryctl-recall — TTL + provenance layer for vault/memoryctl notes.

fleet-ops#1263 (item 2 of #1145). When assembling an agent preamble, every
loaded note is checked against (now - observed) > ttl. Expired claims are
rewritten as UNVERIFIED plus the literal check-command. Enforced here, not
by author discipline.

Directory mode (default): assemble a preamble from a notes directory.

Context mode (`memoryctl-recall context ...`): run `memoryctl context` and
wire the resulting packet through the same TTL layer (fleet-ops#1320), so
live preambles print `[recall: N loaded, M UNVERIFIED]` and expired bodies
are rewritten UNVERIFIED with their literal check-command.

check-command strings are printed, never executed, in both modes.

Environment seams (overridden by tests):
  MEMORYCTL_RECALL_NOW      ISO 8601 clock (same as --now)
  MEMORYCTL_RECALL_POLICY   path to ttl-policy.md (same as --policy)
  MEMORYCTL_BIN             memoryctl binary for context mode (default: memoryctl)
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import platform
import re
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
BUNDLED_POLICY = HERE.parent / "lib" / "shared-memory" / "ttl-policy.md"
HOME = Path(os.environ.get("HOME", "/home/nish"))
DEFAULT_VAULT = Path(
    os.environ.get("MEMORY_VAULT")
    or os.environ.get("NISH_VAULT")
    or (HOME / "workspaces" / "tooling" / "nish-vault")
)

CLASSES = (
    "drill-status",
    "seat-caps",
    "seat-health",
    "decision-ledger",
    "evidence",
    "procedure",
)

DURATION_RE = re.compile(r"^(\d+)([smhd])$")
POLICY_LINE_RE = re.compile(r"^([a-z0-9-]+):\s*(\d+[smhd])\s*$")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_duration(text: str, *, label: str) -> int:
    match = DURATION_RE.fullmatch(text.strip())
    if not match:
        raise SystemExit(f"memoryctl-recall: bad duration {text!r} ({label})")
    amount, unit = match.groups()
    return int(amount) * UNITS[unit]


def parse_iso(text: str) -> dt.datetime | None:
    raw = text.strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def parse_now(text: str | None) -> dt.datetime:
    if not text:
        return dt.datetime.now(dt.timezone.utc)
    parsed = parse_iso(text)
    if parsed is None:
        raise SystemExit(f"memoryctl-recall: bad --now {text!r}")
    return parsed


def parse_scalar(value: str) -> str:
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in {"'", '"'}:
        return text[1:-1]
    return text


def parse_frontmatter(text: str, *, label: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        raise SystemExit(f"memoryctl-recall: malformed frontmatter: {label}")
    metadata: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if not line or line.lstrip().startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        metadata[key.strip()] = parse_scalar(value)
    return metadata, text[end + 5 :]


def load_policy(path: Path) -> dict[str, int]:
    if not path.is_file():
        raise SystemExit(f"memoryctl-recall: policy not found: {path}")
    defaults: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = POLICY_LINE_RE.fullmatch(line.strip())
        if not match:
            continue
        name, duration = match.groups()
        if name not in CLASSES:
            continue
        defaults[name] = parse_duration(duration, label=f"policy {name}")
    missing = [name for name in CLASSES if name not in defaults]
    if missing:
        raise SystemExit(
            "memoryctl-recall: policy missing class defaults: " + ", ".join(missing)
        )
    return defaults


def ttl_seconds(metadata: dict[str, str], defaults: dict[str, int], *, label: str) -> int | None:
    note_class = metadata.get("class", "").strip()
    explicit = metadata.get("ttl", "").strip()
    if not note_class and not explicit:
        return None
    if explicit:
        return parse_duration(explicit, label=f"ttl in {label}")
    if note_class not in defaults:
        raise SystemExit(
            f"memoryctl-recall: unknown class {note_class!r} in {label} "
            f"(need a class default or an explicit ttl:)"
        )
    return defaults[note_class]


def is_expired(
    metadata: dict[str, str],
    defaults: dict[str, int],
    now: dt.datetime,
    *,
    label: str,
) -> bool:
    ttl = ttl_seconds(metadata, defaults, label=label)
    if ttl is None:
        return False
    observed = parse_iso(metadata.get("observed", ""))
    if observed is None:
        return True
    age = (now - observed).total_seconds()
    return age > ttl


def check_command(metadata: dict[str, str]) -> str:
    return (metadata.get("check-command") or metadata.get("check_command") or "").strip()


def render_body(body: str, expired: bool, metadata: dict[str, str]) -> str:
    text = body.strip("\n")
    if not expired:
        return text
    rewritten = f"UNVERIFIED: {text}" if text else "UNVERIFIED:"
    command = check_command(metadata)
    if command:
        rewritten = f"{rewritten}\n{command}"
    return rewritten


def iter_notes(notes_dir: Path) -> list[Path]:
    notes: list[Path] = []
    for path in sorted(notes_dir.iterdir()):
        if not path.is_file() or path.suffix != ".md":
            continue
        if path.name == "ttl-policy.md":
            continue
        notes.append(path)
    return notes


def assemble(notes_dir: Path, *, policy: Path, now: dt.datetime) -> str:
    if not notes_dir.is_dir():
        raise SystemExit(f"memoryctl-recall: notes dir not found: {notes_dir}")
    defaults = load_policy(policy)
    loaded = 0
    unverified = 0
    sections: list[str] = []
    for path in iter_notes(notes_dir):
        raw = path.read_text(encoding="utf-8")
        metadata, body = parse_frontmatter(raw, label=str(path))
        expired = is_expired(metadata, defaults, now, label=str(path))
        loaded += 1
        if expired:
            unverified += 1
        rendered = render_body(body, expired, metadata)
        sections.append(f"## {path.name}\n\n{rendered}".rstrip())
    lines = [f"[recall: {loaded} loaded, {unverified} UNVERIFIED]", ""]
    if sections:
        lines.append("\n\n".join(sections))
        lines.append("")
    return "\n".join(lines)


def default_policy() -> Path:
    env = os.environ.get("MEMORYCTL_RECALL_POLICY", "").strip()
    if env:
        return Path(env)
    vault_policy = DEFAULT_VAULT / "_system" / "shared-memory" / "ttl-policy.md"
    if vault_policy.is_file():
        return vault_policy
    return BUNDLED_POLICY


# Context mode: the vault the packet's `## <relative-path>` sections resolve
# against. Mirrors memoryctl's own platform defaults so the rewrite sees the
# same vault the packet was built from (fleet-ops#1320).
RECALL_CONTEXT_VAULTS = {
    "Darwin": Path("/Users/nish/dev/nish-vault"),
    "Linux": Path("/home/nish/workspaces/tooling/nish-vault"),
}


def context_vault(value: Path | None) -> Path:
    if value is not None:
        return Path(value).expanduser().resolve()
    for var in ("MEMORY_VAULT", "NISH_VAULT"):
        raw = os.environ.get(var, "").strip()
        if raw:
            return Path(raw).expanduser().resolve()
    return RECALL_CONTEXT_VAULTS.get(platform.system(), DEFAULT_VAULT)


def rewrite_packet(
    packet: str,
    vault: Path,
    *,
    policy: Path,
    now: dt.datetime,
) -> str:
    """Apply the TTL recall layer to a `memoryctl context` packet.

    Each `## <vault-relative-path>` section is resolved against the vault.
    Sections that do not resolve (KB surfaces, records, stale paths) pass
    through untouched and are not counted. Expired notes are rewritten as
    `UNVERIFIED: <body>` plus the literal check-command (printed, never
    run). A `[recall: N loaded, M UNVERIFIED]` receipt is inserted right
    before the first section, after the packet header.
    """
    defaults = load_policy(policy)
    lines = packet.splitlines()
    section_starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    loaded = 0
    unverified = 0
    for index in range(len(section_starts) - 1, -1, -1):
        start = section_starts[index]
        end = section_starts[index + 1] if index + 1 < len(section_starts) else len(lines)
        header_path = lines[start][3:].strip()
        source = vault / header_path
        if not source.is_file():
            continue
        loaded += 1
        raw = source.read_text(encoding="utf-8")
        metadata, _note_body = parse_frontmatter(raw, label=str(source))
        if not is_expired(metadata, defaults, now, label=str(source)):
            continue
        unverified += 1
        body = "\n".join(lines[start + 1 : end]).strip("\n")
        rewritten = render_body(body, True, metadata)
        lines[start + 1 : end] = rewritten.splitlines()
    receipt = f"[recall: {loaded} loaded, {unverified} UNVERIFIED]"
    if section_starts:
        lines[section_starts[0] : section_starts[0]] = [receipt, ""]
    else:
        lines.append("")
        lines.append(receipt)
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    return text


def build_context_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="memoryctl-recall context",
        description="Run `memoryctl context` and wire the packet through the TTL recall layer.",
    )
    parser.add_argument(
        "--vault",
        type=Path,
        default=None,
        help="canonical vault path (default: $MEMORY_VAULT/$NISH_VAULT, else memoryctl's platform default)",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=None,
        help="ttl-policy.md (same defaults as directory mode)",
    )
    parser.add_argument(
        "--now",
        default=os.environ.get("MEMORYCTL_RECALL_NOW", ""),
        help="ISO 8601 clock used for expiry (test seam; default: current UTC)",
    )
    parser.add_argument(
        "--memoryctl",
        default=os.environ.get("MEMORYCTL_BIN", "memoryctl"),
        help="memoryctl binary to run (default: $MEMORYCTL_BIN or 'memoryctl')",
    )
    parser.add_argument("--agent", required=True, help="agent lane, e.g. claude-vps")
    parser.add_argument("--query", required=True, help="task in one sentence")
    parser.add_argument("--repo", default="", help="repository path for project scope")
    parser.add_argument("--scope", default="", help="global or exact project scope")
    parser.add_argument("--limit", type=int, default=8)
    parser.add_argument("--max-chars", type=int, default=10000)
    parser.add_argument("--kb", type=Path, default=None, help="KB root (forwarded to memoryctl)")
    return parser


def cmd_context(argv: list[str]) -> int:
    args = build_context_parser().parse_args(argv)
    policy = args.policy if args.policy is not None else default_policy()
    now = parse_now(args.now or None)
    vault = context_vault(args.vault)
    memoryctl_argv = [
        args.memoryctl,
        "context",
        "--agent",
        args.agent,
        "--query",
        args.query,
    ]
    if args.repo:
        memoryctl_argv += ["--repo", args.repo]
    if args.scope:
        memoryctl_argv += ["--scope", args.scope]
    memoryctl_argv += ["--limit", str(args.limit), "--max-chars", str(args.max_chars)]
    if args.kb is not None:
        memoryctl_argv += ["--kb", str(args.kb)]
    if args.vault is not None:
        memoryctl_argv += ["--vault", str(args.vault)]
    proc = subprocess.run(memoryctl_argv, capture_output=True, text=True)
    if proc.returncode != 0:
        # memoryctl gates (pending approvals, vault contract, secrets) must
        # reach the agent exactly as they do today; never swallow them.
        sys.stderr.write(proc.stderr)
        if proc.stdout:
            sys.stdout.write(proc.stdout)
        return proc.returncode
    packet = rewrite_packet(proc.stdout, vault, policy=policy, now=now)
    sys.stdout.write(packet)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="memoryctl-recall",
        description="Assemble a TTL-checked agent preamble from vault notes.",
    )
    parser.add_argument(
        "--now",
        default=os.environ.get("MEMORYCTL_RECALL_NOW", ""),
        help="ISO 8601 clock used for expiry (default: current UTC)",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=None,
        help="ttl-policy.md (default: MEMORYCTL_RECALL_POLICY, else vault _system/shared-memory/ttl-policy.md if present, else bundled)",
    )
    parser.add_argument(
        "notes",
        type=Path,
        help="directory of markdown notes to load",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "context":
        return cmd_context(args[1:])
    parsed = build_parser().parse_args(args)
    policy = parsed.policy if parsed.policy is not None else default_policy()
    packet = assemble(parsed.notes, policy=policy, now=parse_now(parsed.now or None))
    sys.stdout.write(packet)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
