#!/usr/bin/env bash
# gate-integrity.sh — deterministic decision logic for the fleet gate-integrity
# check (P10-B, "cover all our bases so no agent can run amok and bypass our
# quality gates", Nish, 2026-08-25). Portable follow-up to the 0509-local copy
# (fleet-ops#303): repo-specific globs, ratchet paths, and auto-revert opener
# arrive in the context bundle, not as hardcoded 0509 paths.
#
# Sibling of required-verifier-integrity.sh, same contract: reads a context
# bundle JSON on stdin, prints PASS (exit 0) or FAIL (exit 1), performs no
# network access and no repository mutation, so the deterministic fixture
# regression (tests/gate-integrity.test.sh) exercises the exact shipped bytes.
#
# WHAT THIS CATCHES that required-verifier-integrity.sh does not:
#   required-verifier-integrity guards a fixed list of verifier DEFINITIONS by
#   exact filename. It says nothing about the diff's CONTENT, so a PR can still
#   delete the tests a gate runs, skip them, widen an ignore file, or raise a
#   design-ratchet ceiling — all without touching a single listed file. GitHub's
#   own agent-PR review guidance names CI gaming as red flag #1 and lists
#   exactly these moves (github.blog, 2026-05-07); SpecBench (arXiv:2605.21384)
#   shows visible-suite saturation is what weak models do at scale. This check
#   closes that surface.
#
# TWO VIOLATION CLASSES, TWO REMEDIES
# -----------------------------------
#   test-integrity  — deleted/renamed-away test files, newly skipped tests, a
#                     net reduction in assertions. Remedy: a
#                       test-removal-justified: <reason>
#                     trailer in any commit message of the PR or in the PR body.
#                     The justification travels with the change and lands in
#                     `git log`, which is the whole point.
#
#   gate-path       — any change to a gate-owned path (`.github/workflows/**`,
#                     `.github/scripts/**`, CODEOWNERS, gitleaks/semgrep ignore
#                     files, the design-system ratchet and its ceilings, the CI
#                     runner scripts), a ratchet ceiling raised or dropped, or a
#                     CI step softened with `|| true` / `continue-on-error`.
#                     Remedy: a repository ADMIN posts a pull-request comment
#                     whose ENTIRE body is exactly
#
#                         gate-integrity-attest: <40-hex current head sha>
#
# WHY AN ATTESTATION COMMENT AND NOT AN APPROVAL LABEL
# ---------------------------------------------------
# The packet spec proposed a label. A label is strictly weaker here: it persists
# across pushes, so a PR labelled while it was innocuous keeps the label after a
# later force-push adds the gate edit — the exact stale-approval hole GitHub's
# own "dismiss stale approvals" setting exists to close. The sha-bound
# attestation comment is the shape Nish already approved on this repository on
# 2026-08-20 for required-verifier-integrity, is invalidated automatically by any
# new commit, and leaves a named, timestamped audit record. Same owner decision,
# same properties, one fewer concept.
#
# HONEST LIMIT (reported to Nish with this check, P10-B item 5): Nishfleet/0509
# has exactly ONE collaborator, and the fleet's workers hold that identity's
# token. Every identity-keyed control on this repository — code-owner review,
# an approval label, this attestation — is therefore an audit trail, not an
# authorization boundary, until worker credentials are split from the owner's.
# The controls that bind mechanically regardless of identity are the ones that
# do not ask "who": enforce_admins, and the deterministic content rules below.
#
# AUTO-REVERT WAIVER (added 2026-08-25, "the guardrail that fails 12% of the
# time trains everyone to ignore red"). The reversible-merge invariant says
# every failing push-to-main gets a one-shot undo opened by .github/workflows/
# auto-revert.yml. The undo is, by construction, the inverse of a commit that
# almost certainly added tests — so every auto-revert PR lands here with a
# negative assertion delta and a deleted test file. Catching that as
# "test-integrity weakened" was the correct rule reading but the wrong
# outcome: the gate was red on the one PR it should never block. Three
# independent signals must all agree before the test-integrity clause is
# waived, so the hole stays narrow:
#
#   1. The PR body starts with the exact opening sentence the auto-revert
#      workflow emits (a fixed string, not a pattern, so paraphrasing is not
#      enough — the workflow writes it verbatim).
#   2. Every commit in the PR carries git's standard `Revert "<subject>"`
#      subject line. A PR that deletes tests but whose commits are NOT git
#      reverts gets no exemption, even if its body was paraphrased.
#   3. A pull-request comment whose entire body is exactly
#      `gate-integrity-auto-revert: <40-hex current head sha>` exists on the
#      PR. The sha binding is what makes a force-push invalidate the waiver,
#      same currency property as the admin attestation. The comment author
#      is intentionally NOT permission-checked: any user can post the marker,
#      but only the auto-revert workflow lands here with both signals (1)
#      and (2) true at the same time. The combo is the cryptographic anchor.
#
# The gate-path clause is NOT waived on this path. A revert of a
# `.github/workflows/**` change is still a change to a gate-owned path and
# still needs an admin attestation, because the auto-revert body only
# promises "the diff is the inverse of HEAD_SHA" — it does not promise
# "HEAD_SHA did not weaken a gate".
#
# Context bundle shape:
# {
#   "head_sha": "0123...def",              # PR head sha, 40 lowercase hex
#   "files": [{"filename": "tests/a.test.ts",
#              "previous_filename": null,
#              "status": "removed",
#              "patch": "+added\n-removed"}],  # context lines pre-stripped
#   "commit_messages": ["fix: ...\n\ntest-removal-justified: merged into b"],
#   "pr_body": "...",
#   "attestations": [{"user": "nish3451", "sha": "0123...def"}],
#   "permissions": {"nish3451": "admin"},
#   "gate_globs": [".github/workflows/**", ...],
#   "ratchet_ceilings": ["docs/design-system-ratchet.json"],   # optional
#   "auto_revert_body_opener": "Automatic revert opened because ..."  # optional
# }
#
# Rule (fail closed): an unparseable or structurally wrong bundle FAILS. A
# missing patch never silently excuses a violation — it is recorded and the
# filename-level rules still apply.
set -euo pipefail

# The decision logic is written to a temp file rather than fed to python on
# stdin, because stdin belongs to the context bundle. (required-verifier-
# integrity.sh passes its bundle through argv instead; that cannot work here —
# this bundle carries diff patches and would hit the ARG_MAX ceiling on a large
# PR, which is precisely the PR most worth checking.)
_gi_py="$(mktemp "${TMPDIR:-/tmp}/gate-integrity.XXXXXX.py")"
trap 'rm -f "$_gi_py"' EXIT
cat > "$_gi_py" <<'PY'
import fnmatch
import json
import os
import re
import sys

HEX40 = re.compile(r"^[0-9a-f]{40}$")

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

TRAILER = re.compile(
    r"^[ \t]*test-removal-justified:[ \t]*(\S.*?)[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

REMEDIES = """
Remedies (each violation class needs its own; neither one waives the other).

  test-integrity — add a trailer line to any commit message in this PR (or to
     the PR body):

         test-removal-justified: <why this test may go, in one line>

     Put it in the commit that removes the test so the reason lands in
     `git log` next to the removal. Amend and force-push, or add an empty
     commit carrying the trailer.

  gate-path — a repository ADMIN posts a pull-request comment whose ENTIRE
     body is exactly

         gate-integrity-attest: <40-hex current head sha>

     then re-runs this check. Admin permission is verified through the
     collaborator-permission API by the base-branch-owned workflow, never from
     the comment itself. The sha must equal the PR's current head sha, so
     pushing any new commit invalidates the attestation and a fresh one is
     required. Taking this path emits a loud warning annotation and a
     job-summary entry naming the admin and the sha.
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


def fail(reasons, remedies=False):
    print("FAIL: this pull request weakens a quality gate without the required justification")
    for why in reasons:
        print(f"  - {why}")
    if remedies:
        print(REMEDIES)
    return 1


def added_lines(patch):
    return [ln[1:] for ln in patch.split("\n") if ln.startswith("+") and not ln.startswith("+++")]


def removed_lines(patch):
    return [ln[1:] for ln in patch.split("\n") if ln.startswith("-") and not ln.startswith("---")]


def is_test_path(path):
    return bool(path) and bool(TEST_PATH.search(path))


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


def find_trailer(commit_messages, pr_body):
    for i, msg in enumerate(commit_messages):
        if not isinstance(msg, str):
            continue
        m = TRAILER.search(msg)
        if m:
            return f"commit message #{i + 1}", m.group(1)
    if isinstance(pr_body, str):
        m = TRAILER.search(pr_body)
        if m:
            return "pull request body", m.group(1)
    return None


# Default opener the fleet auto-revert workflow writes into the PR body
# verbatim. A consumer may override via bundle.auto_revert_body_opener.
DEFAULT_AUTO_REVERT_BODY_OPENER = (
    "Automatic revert opened because a push-to-main CI workflow went red."
)
# `git revert` always produces a subject of the form `Revert "<original>"`
# when run without `--edit` / `--no-edit`. A pure revert PR's commits all
# carry this exact prefix; that is what makes the diff the inverse of the
# original commit.
GIT_REVERT_SUBJECT_PREFIX = 'Revert "'


def is_auto_revert_pr(pr_body, commit_messages, opener):
    """True when the PR is a workflow-generated git revert.

    The body opener is a verbatim string the auto-revert workflow owns; the
    commit prefix is git's own. Both must hold: a PR that opens with the
    workflow's sentence but whose commits are not git reverts is not a true
    revert and gets no exemption, and a PR whose commits are git reverts
    but whose body was paraphrased has no workflow anchor.
    """
    if not isinstance(pr_body, str):
        return False
    if not opener or not pr_body.startswith(opener):
        return False
    if not commit_messages:
        return False
    for m in commit_messages:
        if not isinstance(m, str):
            return False
        if not m.lstrip().startswith(GIT_REVERT_SUBJECT_PREFIX):
            return False
    return True


def find_auto_revert_attestation(attestations, head_sha, notes):
    """Match a `gate-integrity-auto-revert: <40-hex>` comment at head sha.

    The auto-revert workflow posts this comment immediately after opening
    the PR, sha-bound so any new commit invalidates it. The author is not
    permission-checked: any commenter can post the marker, but only the
    auto-revert workflow arrives with a body opener AND git-revert commits
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
    permissions = bundle.get("permissions") or {}
    if not isinstance(permissions, dict):
        return fail(["context bundle permissions is not an object"])
    auto_revert_attestations = bundle.get("auto_revert_attestations") or []
    if not isinstance(auto_revert_attestations, list):
        return fail(["context bundle auto_revert_attestations is not an array"])
    gate_globs = bundle.get("gate_globs") or []
    if not isinstance(gate_globs, list):
        return fail(["context bundle gate_globs is not an array"])
    if not all(isinstance(g, str) and g for g in gate_globs):
        return fail(["context bundle gate_globs must be a list of non-empty strings"])

    raw_ratchet = bundle.get("ratchet_ceilings")
    if raw_ratchet in (None, "", []):
        ratchet_paths = set()
    elif isinstance(raw_ratchet, str):
        ratchet_paths = {raw_ratchet} if raw_ratchet else set()
    elif isinstance(raw_ratchet, list):
        if not all(isinstance(x, str) and x for x in raw_ratchet):
            return fail(["context bundle ratchet_ceilings must be a list of non-empty strings"])
        ratchet_paths = set(raw_ratchet)
    else:
        return fail(["context bundle ratchet_ceilings has the wrong type"])

    opener = bundle.get("auto_revert_body_opener")
    if opener in (None, ""):
        opener = DEFAULT_AUTO_REVERT_BODY_OPENER
    elif not isinstance(opener, str):
        return fail(["context bundle auto_revert_body_opener is not a string"])

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
        if name in ratchet_paths or prev in ratchet_paths:
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
        trailer = find_trailer(commit_messages, pr_body)
        if trailer is None:
            # Auto-revert waiver (see the header comment). The clause is
            # waived only when ALL three signals agree: the workflow's body
            # opener, git-revert commit subjects, AND a sha-bound
            # auto-revert attestation comment. Any signal missing or
            # mistaken falls through to the trailer check below, which
            # still fails closed.
            auto_revert_attested = find_auto_revert_attestation(
                auto_revert_attestations, head_sha, notes
            )
            auto_revert_signal = is_auto_revert_pr(pr_body, commit_messages, opener)
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
                    "no `test-removal-justified:` trailer in any commit message or in the PR body"
                )
                # Loudly name the missing auto-revert signal so a future
                # handler knows exactly why the waiver did not apply.
                if auto_revert_signal and auto_revert_attested is None:
                    reasons.append(
                        "auto-revert body+commit signal matched but no sha-bound "
                        "`gate-integrity-auto-revert:` attestation comment was found"
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
                "no current `gate-integrity-attest: <head sha>` comment from a repository admin"
            )
            reasons.extend(n for n in notes if "attest" in n)
        else:
            user, sha = attested
            waived.append(("gate-path", gate_violations, f"admin {user} attested {sha}"))

    if reasons:
        return fail(reasons, remedies=True)

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
            "- **Independent review:** none — this waiver is an audit trail, not a second reviewer.\n\n"
        )
    print("PASS: every gate-integrity violation carries its required justification")
    return 0


sys.exit(main())
PY

python3 "$_gi_py"
