"""A repo path this change deletes has no live reference left at HEAD.

Deleting a file leaves dead links and stale prose behind: fleet-ops#11616 kept a
link to a deleted report, #11624 left six docs naming the org ruleset and the
deleted digest tests, #11700 left docs/remote-control.md naming a deleted
tmpfiles file, and #11623 deleted a test and a set of workflows while comments
and docs still named them. GitHub renders a dead link but does not fail a pull
request, and no stock check reads prose or comments.

The change is HEAD against its first parent: on a pull request and in the merge
queue, CI checks out a merge commit whose first parent is main. `docs/incidents/`
is the historical record, so references inside it are kept. A Markdown link is
resolved from its own file, so a relative link to the deleted file counts; any
other file must name the full repo path.
"""
import itertools
import pathlib
import posixpath
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
HISTORY = "docs/incidents/"

# config/intake-repos.json names each product repo's own agent-dispatch stub,
# which was also deleted here in #11623. That token is not this repo's path.
FOREIGN = {
    ("config/intake-repos.json", ".github/workflows/agent-dispatch.yml"),
}

# A link target, including an optional title: [text](path "title").
LINK = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+['\"][^'\"]*['\"])?\s*\)")
# A reference definition: [name]: path
REFERENCE = re.compile(r"^\[[^\]]+\]:\s*(\S+)", re.MULTILINE)


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def _deleted() -> list[str]:
    base = _git("rev-parse", "HEAD^1").strip()
    return _git("diff", "--no-renames", "--name-only", "--diff-filter=D", base, "HEAD").split()


def _files() -> list[str]:
    return [p for p in _git("ls-tree", "-r", "--name-only", "HEAD").splitlines() if not p.startswith(HISTORY)]


def _text(path: str) -> str | None:
    try:
        return (ROOT / path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def _exact_refs(deleted: list[str], files: dict[str, str]) -> list[str]:
    pattern = re.compile(
        r"(?<![\w./-])("
        + "|".join(map(re.escape, sorted(deleted, key=len, reverse=True)))
        + r")(?![\w./-])"
    )
    refs = []
    for path, text in files.items():
        for i, line in enumerate(text.splitlines(), 1):
            for match in pattern.finditer(line):
                if (path, match.group(1)) not in FOREIGN:
                    refs.append(f"{path}:{i}: {match.group(1)}")
    return refs


def _link_refs(deleted: set[str], files: dict[str, str]) -> list[str]:
    refs = []
    for path, text in files.items():
        if not path.endswith(".md"):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            for match in itertools.chain(LINK.finditer(line), REFERENCE.finditer(line)):
                target = match.group(1).strip("<>").split("#", 1)[0].split("?", 1)[0]
                if not target or "://" in target or target.startswith(("mailto:", "/")):
                    continue
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
                if resolved in deleted:
                    refs.append(f"{path}:{i}: {resolved}")
    return refs


def test_a_deleted_path_has_no_live_reference():
    deleted = _deleted()
    if not deleted:
        return
    files = {p: text for p in _files() if (text := _text(p)) is not None}
    refs = _exact_refs(deleted, files) + _link_refs(set(deleted), files)
    assert not refs, (
        "Deleted here, but still named at HEAD (update the file, or move the history to docs/incidents/): "
        + "; ".join(refs))
