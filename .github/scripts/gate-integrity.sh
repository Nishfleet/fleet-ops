#!/usr/bin/env bash
# gate-integrity.sh — generalized deterministic decision logic for the
# Nishfleet gate-integrity reusable workflow.
#
# Reads a context bundle JSON on stdin, prints PASS (exit 0) or FAIL (exit 1),
# performs no network access and no repository mutation, so a deterministic
# fixture regression exercises the exact shipped bytes.
#
# Repo-specific parts live in the bundle as inputs:
#   - gate_globs: which paths are gate-owned
#   - ratchet_paths: which files carry ratchet ceilings
#   - admin_attestation_marker: the attestation phrase admins must post
#   - auto_revert_attestation_marker: the attestation phrase the auto-revert
#     workflow posts
#   - auto_revert_body_opener: the exact first sentence of an auto-revert PR body
#   - git_revert_subject_prefix: the prefix every git-revert commit subject carries
#   - test_removal_trailer: the trailer that justifies test-integrity changes
#
# The core violation classes (test-integrity, gate-path, CI-step softeners,
# ratchet weakening, auto-revert waiver) live once in this file.
#
# Context bundle shape:
# {
#   "head_sha": "0123...def",
#   "files": [{"filename": "tests/a.test.ts",
#              "previous_filename": null,
#              "status": "removed",
#              "patch": "+added\n-removed"}],
#   "commit_messages": ["fix: ...\n\ntest-removal-justified: merged into b"],
#   "pr_body": "...",
#   "attestations": [{"user": "nish3451", "sha": "0123...def"}],
#   "permissions": {"nish3451": "admin"},
#   "auto_revert_attestations": [{"user": "github-actions[bot]", "sha": "0123...def"}],
#   "gate_globs": [".github/workflows/**", ...],
#   "ratchet_paths": ["docs/design-system-ratchet.json", ...],
#   "admin_attestation_marker": "gate-integrity-attest",
#   "auto_revert_attestation_marker": "gate-integrity-auto-revert",
#   "auto_revert_body_opener": "Automatic revert opened because...",
#   "git_revert_subject_prefix": "Revert \"",
#   "test_removal_trailer": "test-removal-justified"
# }
#
# Rule (fail closed): an unparseable or structurally wrong bundle FAILS. A
# missing patch never silently excuses a violation — it is recorded and the
# filename-level rules still apply.
set -euo pipefail

# The decision logic is written to a temp file rather than fed to python on
# stdin, because stdin belongs to the context bundle.
_gi_py="$(mktemp "${TMPDIR:-/tmp}/gate-integrity.XXXXXX.py")"
trap 'rm -f "$_gi_py"' EXIT
cat > "$_gi_py" <<'PY'
import fnmatch
import json
import os
import re
import sys

HEX40 = re.compile(r"^[0-9a-f]{40}$")


def attest_line_re(marker):
    """A comment attests when ANY of its lines (after stripping per-line
    whitespace and CRs) is EXACTLY `marker: <40-hex>`.

    The whole-body exact match the original workflow jq filter used rejected
    every multi-line attest comment — the real-world shape, where the attest
    line is followed by other markers and review prose (fleet-ops#828,
    0509#1273) — so every valid admin attestation was silently dropped and
    the gate reported "no current attest" against a comment whose line matched
    the head sha exactly. Line-anchored matching keeps the security property
    (prose merely mentioning the marker does not attest: the line must be the
    marker and nothing else) while accepting the multi-line shape.
    """
    return re.compile(rf"^{re.escape(marker)}: ([0-9a-fA-F]{{40}})$")


TEST_PATH = re.compile(
    r"(?:^|/)(?:tests?|__tests__|e2e)/|"
    r"[^/]+\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs)$"
)

# A newly skipped or focused test. `.only` is included because it silently
# disables every OTHER test in the file, which is a larger hole than `.skip`.
SKIP_MARKERS = re.compile(
    r"\b(?:it|test|describe)\s*\.\s*(?:skip|only|todo|fixme)\b|"
    r"\b(?:xit|xdescribe|xtest)\s*\(|"
    r"\.skipIf\s*\(|"
    r"\btest\s*\.\s*fails\b"
)

ASSERTION = re.compile(r"\b(?:it|test)\s*\(|\bexpect\s*\(")

# A CI step softened so it can no longer fail the build.
CI_SOFTENER = re.compile(r"\|\|\s*true\b|continue-on-error\s*:\s*true\b")

# Shell `test`/`[` conditionals are not CI test steps. A line whose command is
# `test`, `[`, or `[[` may legitimately contain `|| true` (e.g. a detached-HEAD
# guard or a command substitution that tolerates failure), and a brand-new file
# cannot soften a step that did not exist before.
SHELL_TEST_COND = re.compile(
    r"^\s*(?:run:\s*)?(?:!\s+)?(?:test(?:\s+|$)|\[\s+|\[\[\s+)"
)

# Prose that merely NAMES a banned construct is not that construct. Without
# this, documenting the rule trips the rule: the first real run of this check
# flagged its own workflow header for containing the words "|| true" inside a
# sentence explaining what `|| true` is. A comment cannot soften a CI step or
# skip a test, so comment lines are excluded from the content rules. They are
# excluded from BOTH added and removed lines, so commenting a line out still
# shows up as the assertion loss it is.
COMMENT_LINE = re.compile(r"^\s*(?:#|//|\*|/\*|<!--)")


def is_comment(line):
    return bool(COMMENT_LINE.match(line))


def code_lines(lines):
    return [ln for ln in lines if not is_comment(ln)]


def format_remedies(admin_marker, auto_revert_marker, test_trailer):
    return f"""
Remedies (each violation class needs its own; neither one waives the other).

  test-integrity — add a trailer line to any commit message in this PR (or to
     the PR body):

         {test_trailer}: <why this test may go, in one line>

     Put it in the commit that removes the test so the reason lands in
     `git log` next to the removal. Amend and force-push, or add an empty
     commit carrying the trailer.

  gate-path — a repository ADMIN posts a pull-request comment containing a
     line that is exactly

         {admin_marker}: <40-hex current head sha>

     then re-runs this check. Admin permission is verified through the
     collaborator-permission API by the base-branch-owned workflow, never from
     the comment itself. The sha must equal the PR's current head sha, so
     pushing any new commit invalidates the attestation and a fresh one is
     required. Taking this path emits a loud warning annotation and a
     job-summary entry naming the admin and the sha. The rest of the comment
     body may carry other markers or review prose; only the marker line is
     read.

  auto-revert test-integrity waiver — the auto-revert workflow may post a
     comment containing a line that is exactly

         {auto_revert_marker}: <40-hex current head sha>

     when the PR body and commit subjects match the workflow's signals.
     This waives test-integrity only; gate-path still needs the admin
     attestation above.
""".rstrip()


def announce(title, message):
    print(f"::warning title={title}::{message}")


def summary(entry):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(entry)
    except OSError as exc:
        print(f"::warning::could not write the gate-integrity entry to the job summary: {exc}")


def fail(reasons, remedies_text=None):
    print("FAIL: this pull request weakens a quality gate without the required justification")
    for why in reasons:
        print(f"  - {why}")
    if remedies_text:
        print(remedies_text)
    return 1


def added_lines(patch):
    return [ln[1:] for ln in patch.split("\n") if ln.startswith("+") and not ln.startswith("+++")]


def removed_lines(patch):
    return [ln[1:] for ln in patch.split("\n") if ln.startswith("-") and not ln.startswith("---")]


def is_test_path(path):
    return bool(path) and bool(TEST_PATH.search(path))


def matches_gate(path, globs):
    if not path:
        return False
    for pattern in globs:
        if fnmatch.fnmatch(path, pattern):
            return True
        # fnmatch's `*` crosses `/`, so `.github/workflows/**` already covers
        # nested paths; this second form keeps a bare directory prefix working
        # if one is ever added to the glob list.
        if pattern.endswith("/**") and path.startswith(pattern[:-2]):
            return True
    return False


def ratchet_weakened(patch):
    """Ceilings that went UP (more legacy debt allowed) or vanished entirely.

    The ratchet's contract is that every ceiling only ever falls. A raised
    ceiling is the cheapest way to land banned markers with a green suite, and
    it is invisible to the ratchet's own test, which reads whatever number the
    same PR just wrote.
    """
    entry = re.compile(r'"([^"]+)"\s*:\s*(-?\d+)')
    before = {}
    after = {}
    for line in removed_lines(patch):
        m = entry.search(line)
        if m:
            before[m.group(1)] = int(m.group(2))
    for line in added_lines(patch):
        m = entry.search(line)
        if m:
            after[m.group(1)] = int(m.group(2))
    findings = []
    for key, old in sorted(before.items()):
        if key not in after:
            findings.append(f"ratchet ceiling {key!r} was deleted (was {old})")
        elif after[key] > old:
            findings.append(f"ratchet ceiling {key!r} raised {old} -> {after[key]}")
    return findings


def extract_attestations_from_comments(comments, marker, notes):
    """Line-anchored attestation extraction from raw PR comments.

    A comment attests when any of its lines (CR-stripped, whitespace-trimmed)
    is EXACTLY `marker: <40-hex>`. The first matching line in a comment wins;
    the rest of the body (prose, other markers) is ignored. Returns a list of
    `{"user", "sha"}` objects (sha lowercased), or None when `comments` is not
    a list — the caller decides whether that is fatal.
    """
    if not isinstance(comments, list):
        return None
    line_re = attest_line_re(marker)
    out = []
    for c in comments:
        if not isinstance(c, dict):
            continue
        body = c.get("body")
        if not isinstance(body, str):
            continue
        user = c.get("user") or ""
        for raw in body.replace("\r", "").split("\n"):
            m = line_re.match(raw.strip())
            if m:
                out.append({"user": user, "sha": m.group(1).lower()})
                break
    return out


def find_attestation(attestations, permissions, head_sha, notes):
    if not isinstance(attestations, list):
        notes.append("context bundle attestations is not an array")
        return None
    if not attestations:
        return None
    if not head_sha:
        notes.append("head sha missing or malformed; attestation currency cannot be proven")
        return None
    for a in attestations:
        if not isinstance(a, dict):
            notes.append("attestation entry is not an object")
            continue
        user = a.get("user") or ""
        if not user:
            notes.append("attestation comment has no resolvable author")
            continue
        raw = a.get("sha")
        if not isinstance(raw, str):
            notes.append(f"attestation by {user} carries a non-string sha")
            continue
        sha = raw.strip().lower()
        perm = permissions.get(user)
        if perm != "admin":
            notes.append(
                f"attesting commenter {user} has permission {perm!r}, not admin; "
                "the gate-path remedy requires repository admin"
            )
            continue
        if not HEX40.match(sha):
            notes.append(f"attestation by {user} does not carry a 40-hex sha")
            continue
        if sha != head_sha:
            notes.append(
                f"attestation by {user} names sha {sha}, not the current head sha "
                f"{head_sha} (stale: a newer commit was pushed after it)"
            )
            continue
        return user, sha
    return None


def trailer_re(marker):
    return re.compile(
        rf"^[ \t]*{re.escape(marker)}:[ \t]*(\S.*?)[ \t]*$",
        re.IGNORECASE | re.MULTILINE,
    )


def find_trailer(commit_messages, pr_body, test_removal_trailer):
    pattern = trailer_re(test_removal_trailer)
    for i, msg in enumerate(commit_messages):
        if not isinstance(msg, str):
            continue
        m = pattern.search(msg)
        if m:
            return f"commit message #{i + 1}", m.group(1)
    if isinstance(pr_body, str):
        m = pattern.search(pr_body)
        if m:
            return "pull request body", m.group(1)
    return None


def is_auto_revert_pr(pr_body, commit_messages, auto_revert_body_opener, git_revert_subject_prefix):
    """True when the PR is a workflow-generated git revert.

    The body opener is a verbatim string the auto-revert workflow owns; the
    commit prefix is git's own. Both must hold: a PR that opens with the
    workflow's sentence but whose commits are not git reverts is not a true
    revert and gets no exemption, and a PR whose commits are git reverts
    but whose body was paraphrased has no workflow anchor.
    """
    if not isinstance(pr_body, str):
        return False
    if not pr_body.startswith(auto_revert_body_opener):
        return False
    if not commit_messages:
        return False
    for m in commit_messages:
        if not isinstance(m, str):
            return False
        if not m.lstrip().startswith(git_revert_subject_prefix):
            return False
    return True


def find_auto_revert_attestation(attestations, head_sha, notes):
    """Match an auto-revert attestation comment at head sha.

    The auto-revert workflow posts this comment immediately after opening
    the PR, sha-bound so any new commit invalidates it. The author is not
    permission-checked: any commenter can post the marker, but only the
    auto-revert workflow arrives with the body opener AND git-revert commits
    at the same time. That combo is the only authorization this path needs.
    """
    if not isinstance(attestations, list):
        notes.append("context bundle auto-revert attestations is not an array")
        return None
    if not attestations:
        return None
    if not HEX40.match(head_sha):
        notes.append("head sha missing or malformed; auto-revert attestation currency cannot be proven")
        return None
    for a in attestations:
        if not isinstance(a, dict):
            notes.append("auto-revert attestation entry is not an object")
            continue
        user = a.get("user") or ""
        raw = a.get("sha")
        if not isinstance(raw, str):
            notes.append(f"auto-revert attestation by {user or '?'} carries a non-string sha")
            continue
        sha = raw.strip().lower()
        if not HEX40.match(sha):
            notes.append(f"auto-revert attestation by {user or '?'} does not carry a 40-hex sha")
            continue
        if sha != head_sha:
            notes.append(
                f"auto-revert attestation by {user or '?'} names sha {sha}, not the current "
                f"head sha {head_sha} (stale: a newer commit was pushed after it)"
            )
            continue
        return user, sha
    return None


def main():
    try:
        bundle = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return fail([f"context bundle is not valid JSON: {exc}"])

    if not isinstance(bundle, dict):
        return fail(["context bundle is not a JSON object"])

    files = bundle.get("files")
    if not isinstance(files, list):
        return fail(["context bundle files is not an array"])

    raw_head = bundle.get("head_sha")
    head_sha = raw_head.strip().lower() if isinstance(raw_head, str) else ""
    if not HEX40.match(head_sha):
        head_sha = ""

    commit_messages = bundle.get("commit_messages") or []
    if not isinstance(commit_messages, list):
        return fail(["context bundle commit_messages is not an array"])
    pr_body = bundle.get("pr_body") or ""

    attestations = bundle.get("attestations") or []
    if not isinstance(attestations, list):
        return fail(["context bundle attestations is not an array"])

    permissions = bundle.get("permissions") or {}
    if not isinstance(permissions, dict):
        return fail(["context bundle permissions is not an object"])

    auto_revert_attestations = bundle.get("auto_revert_attestations") or []
    if not isinstance(auto_revert_attestations, list):
        return fail(["context bundle auto_revert_attestations is not an array"])

    gate_globs = bundle.get("gate_globs") or []
    if not isinstance(gate_globs, list):
        return fail(["context bundle gate_globs is not an array"])

    ratchet_paths = bundle.get("ratchet_paths") or []
    if not isinstance(ratchet_paths, list):
        return fail(["context bundle ratchet_paths is not an array"])

    admin_attestation_marker = bundle.get("admin_attestation_marker") or "gate-integrity-attest"
    if not isinstance(admin_attestation_marker, str):
        return fail(["context bundle admin_attestation_marker is not a string"])

    auto_revert_attestation_marker = bundle.get("auto_revert_attestation_marker") or "gate-integrity-auto-revert"
    if not isinstance(auto_revert_attestation_marker, str):
        return fail(["context bundle auto_revert_attestation_marker is not a string"])

    auto_revert_body_opener = bundle.get("auto_revert_body_opener") or (
        "Automatic revert opened because a push-to-main CI workflow went red."
    )
    if not isinstance(auto_revert_body_opener, str):
        return fail(["context bundle auto_revert_body_opener is not a string"])

    git_revert_subject_prefix = bundle.get("git_revert_subject_prefix") or 'Revert "'
    if not isinstance(git_revert_subject_prefix, str):
        return fail(["context bundle git_revert_subject_prefix is not a string"])

    test_removal_trailer = bundle.get("test_removal_trailer") or "test-removal-justified"
    if not isinstance(test_removal_trailer, str):
        return fail(["context bundle test_removal_trailer is not a string"])

    # When the caller ships raw PR comments, extract attestations from them
    # line-anchored (see extract_attestations_from_comments). Pre-extracted
    # `attestations`/`auto_revert_attestations` are still honored when
    # `comments` is absent, so existing fixtures that build bundles directly
    # keep working.
    comments = bundle.get("comments")
    if isinstance(comments, list):
        extracted = extract_attestations_from_comments(
            comments, admin_attestation_marker, notes=[]
        )
        if extracted is not None:
            attestations = extracted
        extracted_ar = extract_attestations_from_comments(
            comments, auto_revert_attestation_marker, notes=[]
        )
        if extracted_ar is not None:
            auto_revert_attestations = extracted_ar

    remedies_text = format_remedies(
        admin_attestation_marker,
        auto_revert_attestation_marker,
        test_removal_trailer,
    )

    test_violations = []
    gate_violations = []
    notes = []
    assertion_delta = 0

    for f in files:
        if not isinstance(f, dict):
            return fail(["context bundle file entry is not an object"])
        name = f.get("filename") or ""
        prev = f.get("previous_filename") or ""
        status = f.get("status") or ""
        patch = f.get("patch")
        if patch is not None and not isinstance(patch, str):
            return fail([f"context bundle patch for {name!r} is not a string"])

        # --- test-integrity, filename level -------------------------------
        if status == "removed" and is_test_path(name):
            test_violations.append(f"test file deleted: {name}")
        if status == "renamed" and is_test_path(prev) and not is_test_path(name):
            test_violations.append(f"test file renamed out of the suite: {prev} -> {name}")

        # --- gate-path, filename level ------------------------------------
        if matches_gate(name, gate_globs):
            gate_violations.append(f"gate-owned path changed ({status or 'changed'}): {name}")
        if prev and matches_gate(prev, gate_globs):
            gate_violations.append(f"gate-owned path renamed away: {prev} -> {name}")

        if patch is None:
            if is_test_path(name) or matches_gate(name, gate_globs):
                notes.append(
                    f"no patch available for {name} (binary or oversized diff); "
                    "content rules could not be applied to it"
                )
            continue

        adds = added_lines(patch)
        dels = removed_lines(patch)

        # --- test-integrity, content level --------------------------------
        if is_test_path(name):
            for ln in code_lines(adds):
                if SKIP_MARKERS.search(ln):
                    test_violations.append(f"test disabled in {name}: {ln.strip()[:120]}")
                    break
            if status in ("modified", "removed", "changed"):
                assertion_delta += sum(len(ASSERTION.findall(ln)) for ln in code_lines(adds))
                assertion_delta -= sum(len(ASSERTION.findall(ln)) for ln in code_lines(dels))

        # --- gate-path, content level -------------------------------------
        if status != "added" and (
            name.endswith(".yml") or name.endswith(".yaml") or name.startswith("scripts/")
        ):
            for ln in code_lines(adds):
                if CI_SOFTENER.search(ln) and not SHELL_TEST_COND.match(ln):
                    gate_violations.append(f"CI step softened in {name}: {ln.strip()[:120]}")
                    break
        if matches_gate(name, ratchet_paths) or matches_gate(prev, ratchet_paths):
            gate_violations.extend(ratchet_weakened(patch))

    if assertion_delta < 0:
        test_violations.append(
            f"net assertion count fell by {-assertion_delta} across the changed test files "
            "(it(/test(/expect( occurrences removed minus added)"
        )

    test_violations = sorted(set(test_violations))
    gate_violations = sorted(set(gate_violations))

    for note in notes:
        print(f"::notice::{note}")

    if not test_violations and not gate_violations:
        print("PASS: no test-integrity or gate-path violation in this diff")
        return 0

    reasons = []
    waived = []

    if test_violations:
        trailer = find_trailer(commit_messages, pr_body, test_removal_trailer)
        if trailer is None:
            # Auto-revert waiver. The clause is waived only when ALL three
            # signals agree: the workflow's body opener, git-revert commit
            # subjects, AND a sha-bound auto-revert attestation comment.
            auto_revert_attested = find_auto_revert_attestation(
                auto_revert_attestations, head_sha, notes
            )
            auto_revert_signal = is_auto_revert_pr(
                pr_body, commit_messages, auto_revert_body_opener, git_revert_subject_prefix
            )
            if auto_revert_signal and auto_revert_attested is not None:
                u, s = auto_revert_attested
                waived.append((
                    "test-integrity",
                    test_violations,
                    f"auto-revert PR body opener + git-revert commits + "
                    f"auto-revert attestation by {u or 'anonymous'} at sha {s}",
                ))
            else:
                reasons.extend(test_violations)
                reasons.append(
                    f"no `{test_removal_trailer}:` trailer in any commit message or in the PR body"
                )
                if auto_revert_signal and auto_revert_attested is None:
                    reasons.append(
                        "auto-revert body+commit signal matched but no sha-bound "
                        f"`{auto_revert_attestation_marker}:` attestation comment was found"
                    )
                    reasons.extend(n for n in notes if "auto-revert attestation" in n)
        else:
            where, why = trailer
            waived.append(("test-integrity", test_violations, f"{where}: {why}"))

    if gate_violations:
        attested = find_attestation(attestations, permissions, head_sha, notes)
        if attested is None:
            reasons.extend(gate_violations)
            reasons.append(
                f"no current `{admin_attestation_marker}: <head sha>` comment from a repository admin"
            )
            reasons.extend(n for n in notes if "attest" in n)
        else:
            user, sha = attested
            waived.append(("gate-path", gate_violations, f"admin {user} attested {sha}"))

    if reasons:
        return fail(reasons, remedies_text=remedies_text)

    for cls, violations, how in waived:
        listed = "; ".join(violations)
        announce(
            f"Gate integrity: {cls} waived",
            f"{cls} violations accepted via {how}. NO independent reviewer saw this. "
            f"Violations: {listed}",
        )
        summary(
            f"### :warning: gate-integrity: {cls} waived\n\n"
            f"- **Accepted via:** {how}\n"
            f"- **Violations waived:** `{listed}`\n"
            "- **Independent review:** none — the attestation path is an audit trail, "
            "not an authorization boundary, until worker credentials are split from the owner.\n\n"
        )
    print("PASS: every gate-integrity violation carries its required justification")
    return 0


sys.exit(main())
PY

python3 "$_gi_py"
