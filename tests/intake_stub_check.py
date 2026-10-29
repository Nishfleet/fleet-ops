"""Every enrolled repo's agent-dispatch stub must forward every
pull_request_target type fleet-ops's own stub lists.

The enrolment precondition (docs/intake-enrolment.md, precondition 3) says a
stub whose on.pull_request_target.types is short leaves that repo with no
review and no coordinator gate on risky PRs, because hold-risky is the only
door into review-risky and a pull_request_target trigger fires only for the
types its own repo's stub lists. Nothing checked the precondition: drive and
siterep-public both shipped eight of the nine types (fleet-ops#9730).

The required list and the enrolled set are both read from the run's base ref
when one is given, so a PR cannot loosen the rules that judge it, the way
hold-risky reads its path list from the base branch. Each enrolled repo's stub
is read from that repo's own default branch, because a ref that exists in
fleet-ops does not exist anywhere else.

A repo the CI token cannot read is named as not verified and skipped, never
counted as a pass. Any other state fails closed naming the repo: a readable
repo with no stub, a stub that will not parse, a trigger with no types, an API
call that fails, and a run that read no enrolled repo's stub at all.
"""
import base64
import json
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/intake-repos.json"
DISPATCHER = ROOT / ".github/workflows/agent-dispatch.yml"
CONFIG_PATH = "config/intake-repos.json"
DISPATCHER_PATH = ".github/workflows/agent-dispatch.yml"
ORG = "Nishfleet"
SELF = "fleet-ops"
NO_TYPES = "a pull_request_target trigger with no types list, so only the opened, synchronize and reopened defaults fire"
NOT_VERIFIED = "not verified: the CI token cannot read this repo (private or gone); skipped"


def _gh(path):
    """`gh api <path>` as (parsed json, None) or (None, one-line notice)."""
    try:
        done = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    except FileNotFoundError:
        return None, "gh is not on PATH, so no stub can be read"
    if done.returncode != 0:
        why = " ".join((done.stderr or done.stdout or f"exit {done.returncode}").split())
        return None, f"gh api failed: {why}"
    try:
        return json.loads(done.stdout), None
    except json.JSONDecodeError as exc:
        return None, f"the reply is not JSON ({exc.msg})"


def _text_of(data):
    """The decoded file body of a contents reply, or a one-line notice."""
    if "content" not in data:
        return None, "the reply carries no content"
    try:
        return base64.b64decode("".join(data["content"].split()), validate=True).decode(), None
    except (ValueError, UnicodeDecodeError):
        return None, "the content is not base64"


def _types_of(text):
    """A stub's pull_request_target types as (list, None) or (None, reason)."""
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return None, "is not parseable YAML (%s)" % " ".join(str(exc).split())
    if not isinstance(data, dict):
        return None, "is not a mapping"
    on = data.get("on", data.get(True))
    if isinstance(on, list):
        if "pull_request_target" not in on:
            return None, "has no pull_request_target trigger"
        return None, NO_TYPES
    if not isinstance(on, dict):
        return None, "has no on: block"
    if "pull_request_target" not in on:
        return None, "has no pull_request_target trigger"
    trigger = on["pull_request_target"]
    if trigger is None:
        return None, NO_TYPES
    if not isinstance(trigger, dict):
        return None, "a pull_request_target trigger that is not a mapping of keys"
    types = trigger.get("types")
    if types is None:
        return None, NO_TYPES
    if not isinstance(types, list) or not all(isinstance(t, str) for t in types):
        return None, "a pull_request_target.types that is not a list of event names"
    return types, None


def _stub(name, ref=None):
    """A repo's dispatcher stub as (types, None) or (None, one-line reason)."""
    path = f"repos/{ORG}/{name}/contents/{DISPATCHER_PATH}"
    if ref:
        path += f"?ref={ref}"
    data, notice = _gh(path)
    if data is None:
        return None, notice
    text, notice = _text_of(data)
    if text is None:
        return None, notice
    return _types_of(text)


def _api_answering():
    """Fail closed when gh cannot reach the API at all, so a transport or auth
    failure is never reported as one unreadable repo after another."""
    data, notice = _gh(f"repos/{ORG}/{SELF}")
    if data is None:
        sys.exit(f"::error::the GitHub API is not answering through gh ({notice}); failing closed")


def _repo_readable(name):
    """None when the token can read the repo, else a one-line notice."""
    data, notice = _gh(f"repos/{ORG}/{name}")
    if data is None:
        return notice
    if not isinstance(data, dict) or "full_name" not in data:
        return "the reply is not a repo"
    return None


def _enrolled(ref):
    """The enrolled repo names, from the base ref when one is given."""
    if ref:
        path = f"repos/{ORG}/{SELF}/contents/{CONFIG_PATH}?ref={ref}"
        data, notice = _gh(path)
        if data is None:
            sys.exit(f"::error::{CONFIG_PATH}: {notice} at the base ref; failing closed")
        text, notice = _text_of(data)
        if text is None:
            sys.exit(f"::error::{CONFIG_PATH}: {notice} at the base ref; failing closed")
        try:
            config = json.loads(text)
        except json.JSONDecodeError as exc:
            sys.exit(f"::error::{CONFIG_PATH} at the base ref is not JSON ({exc.msg}); failing closed")
    else:
        try:
            config = json.loads(CONFIG.read_text())
        except (OSError, ValueError) as exc:
            sys.exit(f"::error::{CONFIG_PATH} could not be read ({exc}); failing closed")
    repos = [r["name"] for r in config.get("repos", []) if isinstance(r, dict) and "name" in r]
    if not repos:
        sys.exit(f"::error::{CONFIG_PATH} names no enrolled repos")
    return repos


def _required(ref):
    """The required type list as (list, None) or (None, one-line reason)."""
    if ref:
        return _stub(SELF, ref)
    try:
        text = DISPATCHER.read_text()
    except OSError as exc:
        return None, f"could not be read ({exc.strerror})"
    return _types_of(text)


def main():
    if not os.environ.get("GH_TOKEN"):
        sys.exit("GH_TOKEN is empty; this check reads other repos' stubs with the job token")
    ref = os.environ.get("BASE_REF", "")
    _api_answering()
    repos = _enrolled(ref)
    required, notice = _required(ref)
    if required is None:
        sys.exit(f"::error::{SELF}'s own {DISPATCHER_PATH} {notice}; failing closed")
    if not required:
        sys.exit(f"::error::{SELF}'s own {DISPATCHER_PATH} has an empty pull_request_target.types, "
                 "so this check would enforce nothing; failing closed")
    where = f"at {ref}" if ref else "in this checkout"
    print(f"required types (from {ORG}/{SELF}'s own {DISPATCHER_PATH} {where}): {', '.join(required)}")
    verified = 0
    failures = 0
    for name in repos:
        unreadable = _repo_readable(name)
        if unreadable is not None:
            print(f"::warning::Nishfleet/{name}: {NOT_VERIFIED} ({unreadable})")
            continue
        types, why = _stub(name)
        if types is None:
            print(f"::error::Nishfleet/{name}: {DISPATCHER_PATH} {why}")
            failures += 1
            continue
        missing = [t for t in required if t not in types]
        if missing:
            print(f"::error::Nishfleet/{name}: stub omits {', '.join(missing)} from pull_request_target.types")
            print(f"Nishfleet/{name}: missing {', '.join(missing)}")
            failures += 1
            continue
        print(f"Nishfleet/{name}: ok ({len(types)} types)")
        verified += 1
    if not verified:
        sys.exit("::error::no enrolled repo's stub could be read, so nothing was verified")
    if failures:
        sys.exit(f"::error::{failures} enrolled repo(s) have a stub this check cannot pass")
    print(f"{len(repos)} enrolled repo(s) checked, {verified} stub(s) read")


if __name__ == "__main__":
    main()
