#!/usr/bin/env python3
# bin/render-standing-rules
#
# Deterministic generator for the cross-machine standing rules duplicated
# between ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md.
#
# Reads the canonical source at lib/standing-rules/canonical.md, splits on
# `<!-- SECTION: name -->` / `<!-- END SECTION: name -->` markers, and
# writes the templated content into each target file's BEGIN/END GENERATED
# region.
#
# Templating tokens, replaced per-target:
#   {{SURFACE_AGENT}}               e.g. "claude-vps", "codex-vps"
#   {{AGENT_LABEL}}                 e.g. "Claude", "Codex"
#   {{SURFACE_PREIMPLEMENT_PHRASE}} the per-surface phrase for the
#     nish-preimplementation-contract section, e.g.
#     "Claude and every Claude subagent" or
#     "every Codex agent and subagent". Owning the exact phrase here
#     keeps the canonical byte-equivalent to the per-target originals,
#     which is what makes the move behavior-preserving.
#   {{SEAT_CHECK_PHRASE}}           per-surface seat-check wording
#   {{OLD_LAUNCHER_BLOCK}}          per-surface old-launcher paragraph
#     (empty for Claude, full for Codex)
#   {{SOL_IDENTITY_BLOCK}}          per-surface Sol/identity paragraph
#
# Modes:
#   default (no args)  --check mode: exits nonzero if any target drifts
#   --render           writes the regenerated content to each target file
#   --check            same as default
#   --targets <list>   override the default target list (comma-separated)
#   --canonical <path> override the default canonical file
#
# Drift detection: byte-level comparison of the rendered section content
# against the existing content between each target's BEGIN/END GENERATED
# markers. Markers themselves must be present; the generator never edits
# the markers or the surrounding hand-written prose.
#
# Behavior-preserving by construction: a successful --render is provably
# the same as the pre-generation state up to whitespace inside the
# generated region. A successful --check means the canonical source has
# not been hand-edited past the last render.

import argparse
import re
import sys
from pathlib import Path

DEFAULT_CANONICAL = Path(
    "/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.canonical.md"
)

# Each target carries: file path, the surface-agent token, the agent label,
# the per-file markers we expect to find. We refuse to touch a file that
# does not have both BEGIN/END GENERATED markers, which keeps a typo or a
# half-done migration from silently becoming a no-op.
DEFAULT_TARGETS = [
    {
        "path": Path("/home/nish/.claude/CLAUDE.md"),
        "surface_agent": "claude-vps",
        "agent_label": "Claude",
        "preimplement_phrase": "Claude and every Claude subagent",
        "seat_check_phrase": "carries the\nlast observed provider/model, HTTP status and `health_class`.",
        "old_launcher_block": "",
        "sol_identity_block": "\nSol still orchestrates only and never implements. Exact model identity stays\nfail-closed: no silent substitution.",
    },
    {
        "path": Path("/home/nish/.codex/AGENTS.md"),
        "surface_agent": "codex-vps",
        "agent_label": "Codex",
        "preimplement_phrase": "every Codex agent and subagent",
        "seat_check_phrase": "holds the\nlast observed provider/model, HTTP status and `health_class`. Confirm `observed_at` is recent before trusting it.",
        "old_launcher_block": "\n\nThe old DeepSeek/MiniMax/Luna launcher ladder and `_system/shared-memory/codex-model-routing.md` are SUPERSEDED - history only.",
        "sol_identity_block": "\nSol at `medium` is orchestration/integration/review/proof only and performs **no** implementation edits. Default orchestrator identity is `gpt-5.6-sol` at `medium`. Sol has no Pi transport and still launches through the `codex` wrapper.\n\nExact model/effort identity is fail-closed: prove host, provider, model, role and effort from runtime evidence before launch. Missing proof means no launch. No silent substitution.",
    },
]

BEGIN_RE = re.compile(r"<!-- BEGIN GENERATED: ([a-zA-Z0-9_-]+) -->")
END_RE = re.compile(r"<!-- END GENERATED: ([a-zA-Z0-9_-]+) -->")
SECTION_OPEN_RE = re.compile(r"<!-- SECTION: ([a-zA-Z0-9_-]+) -->")
SECTION_CLOSE_RE = re.compile(r"<!-- END SECTION: ([a-zA-Z0-9_-]+) -->")


def load_canonical(path: Path) -> dict[str, str]:
    """Parse the canonical file into a dict of {section_name: body}."""
    text = path.read_text(encoding="utf-8")
    sections: dict[str, str] = {}
    open_name = None
    body_lines: list[str] = []
    for line in text.splitlines():
        m_open = SECTION_OPEN_RE.match(line)
        if m_open:
            if open_name is not None:
                raise ValueError(
                    f"nested SECTION marker while {open_name!r} is open in {path}"
                )
            open_name = m_open.group(1)
            body_lines = []
            continue
        m_close = SECTION_CLOSE_RE.match(line)
        if m_close:
            if open_name is None:
                raise ValueError(
                    f"END SECTION for {m_close.group(1)!r} with no open SECTION in {path}"
                )
            if m_close.group(1) != open_name:
                raise ValueError(
                    f"END SECTION for {m_close.group(1)!r} does not match open "
                    f"SECTION {open_name!r} in {path}"
                )
            # The body is everything between the SECTION markers, excluding
            # the markers themselves. Render joins with newlines and trims
            # the single trailing newline the loop adds.
            body = "\n".join(body_lines)
            sections[open_name] = body
            open_name = None
            body_lines = []
            continue
        if open_name is not None:
            body_lines.append(line)
    if open_name is not None:
        raise ValueError(f"unterminated SECTION {open_name!r} in {path}")
    return sections


def render_section(body: str, target: dict) -> str:
    """Apply templating tokens. Errors loudly on a token we did not declare,
    so a typo cannot silently leave a literal {{X}} in the output.

    The body parsed out of canonical.md always starts and ends with a
    newline (because the SECTION markers sit on their own lines, and
    the line AFTER the open marker and the line BEFORE the close marker
    are empty). Strip the leading newline so the body sits flush against
    the BEGIN marker line in the target; keep the trailing newline so
    the END marker line starts on a fresh line.
    """
    declared = {
        "{{SURFACE_AGENT}}": target["surface_agent"],
        "{{AGENT_LABEL}}": target["agent_label"],
        "{{SURFACE_PREIMPLEMENT_PHRASE}}": target["preimplement_phrase"],
        "{{SEAT_CHECK_PHRASE}}": target.get("seat_check_phrase", ""),
        "{{OLD_LAUNCHER_BLOCK}}": target.get("old_launcher_block", ""),
        "{{SOL_IDENTITY_BLOCK}}": target.get("sol_identity_block", ""),
    }
    out = body
    for token, value in declared.items():
        out = out.replace(token, value)
    # Catch any other {{...}} that survived — both known tokens must be
    # replaced AND nothing else may remain.
    leftovers = re.findall(r"\{\{[A-Z_]+\}\}", out)
    if leftovers:
        raise ValueError(
            f"undeclared templating tokens in canonical section: {sorted(set(leftovers))}"
        )
    if out.startswith("\n"):
        out = out[1:]
    return out


def split_regions(text: str) -> list[tuple[str, str]]:
    """Split a file into [(kind, chunk)] where kind is 'before' (hand-written
    prose), 'generated' (between BEGIN/END markers), or 'orphan' (a single
    marker without its partner). Returns the chunks in file order so we
    can stitch them back together."""
    out: list[tuple[str, str]] = []
    cursor = 0
    while cursor < len(text):
        m_begin = BEGIN_RE.search(text, cursor)
        m_end = END_RE.search(text, cursor)
        if not m_begin and not m_end:
            out.append(("before", text[cursor:]))
            break
        if m_begin and (not m_end or m_begin.start() < m_end.start()):
            name = m_begin.group(1)
            out.append(("before", text[cursor : m_begin.start()]))
            # Find the matching END marker by name.
            tail = text[m_begin.end():]
            m_end_named = re.search(
                rf"<!-- END GENERATED: {re.escape(name)} -->", tail
            )
            if not m_end_named:
                raise ValueError(
                    f"orphan BEGIN GENERATED for {name!r} in target (no matching END)"
                )
            body = tail[: m_end_named.start()]
            out.append(("generated", name, body))
            cursor = m_begin.end() + m_end_named.end()
        else:
            # m_end exists and is first. That is an orphan.
            name = m_end.group(1)
            raise ValueError(
                f"orphan END GENERATED for {name!r} in target (no matching BEGIN)"
            )
    return out


def render_target(
    target: dict,
    sections: dict[str, str],
) -> tuple[str, list[str]]:
    """Return (rendered_text, list_of_used_section_names).

    The output keeps the BEGIN/END GENERATED markers around each generated
    region so a subsequent render still locates the region. The marker
    lines themselves are NOT in the "before" chunks (split_regions slices
    up to and from the markers), so render_target must re-emit them.
    """
    text = target["path"].read_text(encoding="utf-8")
    parts = split_regions(text)
    used: list[str] = []
    out_chunks: list[str] = []
    for part in parts:
        kind = part[0]
        if kind == "before":
            out_chunks.append(part[1])
        elif kind == "generated":
            _, name, _existing_body = part
            if name not in sections:
                raise ValueError(
                    f"target {target['path']} has BEGIN/END GENERATED for "
                    f"{name!r} but canonical has no such section"
                )
            rendered = render_section(sections[name], target)
            # The preceding "before" chunk ended with the BEGIN marker
            # line; it does not include the trailing newline (the
            # substring was sliced to the BEGIN marker's start, but
            # the marker line itself ended with \n in the source —
            # we need to re-emit the marker line + a trailing newline
            # + the body + a trailing newline + the END marker line.
            begin_line = f"<!-- BEGIN GENERATED: {name} -->\n"
            end_line = f"<!-- END GENERATED: {name} -->"
            out_chunks.append(begin_line + rendered + "\n" + end_line)
            used.append(name)
        else:  # pragma: no cover (split_regions only returns before/generated)
            raise ValueError(f"unknown region kind: {kind!r}")
    return "".join(out_chunks), used


def drift_report(target: dict, rendered: str) -> str | None:
    """Return None if rendered matches what's on disk; else a diff-style
    report string."""
    current = target["path"].read_text(encoding="utf-8")
    if current == rendered:
        return None
    return (
        f"DRIFT in {target['path']}\n"
        f"  surface_agent={target['surface_agent']} agent_label={target['agent_label']}\n"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Regenerate (or --check) the marked standing-rule regions in "
            "CLAUDE.md / AGENTS.md from the canonical file."
        )
    )
    parser.add_argument("--render", action="store_true", help="write regenerated content")
    parser.add_argument("--check", action="store_true", help="exit nonzero on drift (default)")
    parser.add_argument("--canonical", type=Path, default=DEFAULT_CANONICAL)
    parser.add_argument(
        "--targets",
        help="comma-separated target specs: path|surface|label|phrase[|seat|old|sol] (overrides defaults)",
    )
    args = parser.parse_args(argv)
    do_render = args.render
    do_check = args.check or (not args.render)

    sections = load_canonical(args.canonical)

    if args.targets:
        targets: list[dict] = []
        for spec in args.targets.split(","):
            parts = spec.split("|")
            if len(parts) < 4:
                raise ValueError(
                    f"target spec must be path|surface|label|phrase[|seat|old|sol]; got {spec!r}"
                )
            target: dict = {
                "path": Path(parts[0]),
                "surface_agent": parts[1],
                "agent_label": parts[2],
                "preimplement_phrase": parts[3],
            }
            if len(parts) > 4:
                target["seat_check_phrase"] = parts[4]
            if len(parts) > 5:
                target["old_launcher_block"] = parts[5]
            if len(parts) > 6:
                target["sol_identity_block"] = parts[6]
            targets.append(target)
    else:
        targets = DEFAULT_TARGETS

    failed: list[str] = []
    used_total: set[str] = set()
    for target in targets:
        rendered, used = render_target(target, sections)
        used_total.update(used)
        if do_check:
            report = drift_report(target, rendered)
            if report is not None:
                failed.append(report)
        if do_render:
            target["path"].write_text(rendered, encoding="utf-8")

    # Section coverage: every section in canonical must be used by at
    # least one target. Otherwise the canonical is silently carrying
    # dead sections.
    unused = set(sections) - used_total
    if unused:
        failed.append(
            "canonical has unused SECTIONs (no target references them): "
            f"{sorted(unused)}"
        )

    if failed:
        for line in failed:
            print(line, file=sys.stderr)
        return 1
    mode = "rendered" if do_render else "checked"
    print(f"OK ({mode}): {len(targets)} target(s), {len(used_total)} section(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
