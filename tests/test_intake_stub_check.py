"""The enrolled-stub check (tests/intake_stub_check.py), run against a fake gh
serving fixture stubs and a fixture config.

The real program runs in ci.yml with only the fleet-ops workflow token, so
these cases pin what a live run cannot show: a full stub passes, a short stub
fails naming the repo and the missing type, extra types are allowed, a stub
with no pull_request_target trigger, one with the trigger but no types, one with
a types list of non-strings, and one in the list form of `on:` fail with their
own reasons, a malformed stub fails with its line, a readable repo with no stub
fails, a transport failure and a missing gh binary fail closed, a repo the token
cannot read is named as not verified and skipped without masking a real failure
elsewhere, an API state other than 404 fails closed instead of reading as one
more unreadable repo, a run that read no stub at all fails, an empty required
list fails, the required list and the enrolled set both come from the run's base
ref rather than from the checkout, and each repo's own stub is read from that
repo's default branch, and ci.yml runs the check in one job that always runs with
the fleet-ops workflow token.
"""
import base64
import importlib.util
import json
import os
import pathlib
import sys

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "tests/intake_stub_check.py"
CONFIG = ROOT / "config/intake-repos.json"
DISPATCHER = ROOT / ".github/workflows/agent-dispatch.yml"
CI = ROOT / ".github/workflows/ci.yml"
NINE = [
    "dequeued", "auto_merge_disabled", "closed", "auto_merge_enabled",
    "synchronize", "labeled", "opened", "reopened", "ready_for_review",
]
DRIVE_EIGHT = [t for t in NINE if t != "ready_for_review"]
REF = "a" * 40
ABSENT = "absent"

GH = """#!/bin/bash
p=$3
name=${p#repos/Nishfleet/}; name=${name%%[/?]*}
kind=repo
case "$p" in */contents/*) kind=contents ;; esac
for n in $TRANSPORT; do
  if [ "$name" = "$n" ]; then echo "gh: connection refused" >&2; exit 7; fi
done
for n in $FAILED; do
  if [ "$name" = "$n" ]; then
    printf 'HTTP/2.0 500 Internal Server Error\\r\\n\\r\\n{"message":"boom"}'
    echo "gh: Internal Server Error (HTTP 500)" >&2
    exit 1
  fi
done
missing() {
  printf 'HTTP/2.0 404 Not Found\\r\\n\\r\\n{"message":"Not Found","status":"404"}'
  echo "gh: $1 (HTTP 404)" >&2
  exit 1
}
for n in $PRIVATE; do
  if [ "$name" = "$n" ]; then missing "Not Found"; fi
done
if [ "$kind" = repo ]; then
  printf 'HTTP/2.0 200 OK\\r\\n\\r\\n{"full_name":"Nishfleet/%s"}' "$name"
  exit 0
fi
case "$p" in
  *\\?ref=*) [ "$name" = fleet-ops ] || missing "No commit found for the ref" ;;
esac
for n in $BADCONTENT; do
  if [ "$name" = "$n" ]; then
    printf 'HTTP/2.0 200 OK\\r\\n\\r\\n{"encoding":"base64","content":"!!!"}'
    exit 0
  fi
done
case "$p" in
  *contents/config/intake-repos.json*)
    [ -f "$CONFIGS/intake-repos.json" ] || missing "Not Found"
    printf 'HTTP/2.0 200 OK\\r\\n\\r\\n{"encoding":"base64","content":"%s"}' "$(base64 -w0 "$CONFIGS/intake-repos.json" | fold -w 60 | jq -Rs . | tr -d '"')" ;;
  *contents/.github/workflows/agent-dispatch.yml*)
    [ -f "$STUBS/$name.yml" ] || missing "Not Found"
    printf 'HTTP/2.0 200 OK\\r\\n\\r\\n{"encoding":"base64","content":"%s"}' "$(base64 -w0 "$STUBS/$name.yml" | fold -w 60 | jq -Rs . | tr -d '"')" ;;
esac
"""


def _stub_body(types):
    if types is None:
        return "on:\n  push:\n    branches: [main]\n"
    if types == "malformed":
        return "on: [oops\n"
    if types == "list-form":
        return "on: [pull_request_target]\n"
    if types == "no-types":
        return "on:\n  pull_request_target:\n"
    if types == "empty":
        return "on:\n  pull_request_target:\n    types: []\n"
    if types == "not-strings":
        return "on:\n  pull_request_target:\n    types: [1]\n"
    return "on:\n  pull_request_target:\n    types: [%s]\n" % ", ".join(types)


def _dispatcher_body(types):
    if types is None:
        return "on:\n  issues:\n    types: [labeled]\n"
    return _stub_body(types)


def _load_program():
    spec = importlib.util.spec_from_file_location("intake_stub_check", PROGRAM)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def run(tmp_path, monkeypatch, capsys):
    """Call the real main() against fixture stubs, a fake gh and a fake config."""

    def _run(stubs, repos, private=(), transport=(), bad_content=(), failed=(), with_gh=True,
             dispatcher=NINE, base_ref=None, base_repos=None, token="x"):
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir(exist_ok=True)
        stubs_dir = tmp_path / "stubs"
        stubs_dir.mkdir(exist_ok=True)
        configs_dir = tmp_path / "configs"
        configs_dir.mkdir(exist_ok=True)
        for name, types in stubs.items():
            (stubs_dir / f"{name}.yml").write_text(_stub_body(types))
        if with_gh:
            fake = bin_dir / "gh"
            fake.write_text(GH)
            fake.chmod(0o755)
            monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
        else:
            empty = tmp_path / "no-bin"
            empty.mkdir(exist_ok=True)
            monkeypatch.setenv("PATH", str(empty))
        monkeypatch.setenv("STUBS", str(stubs_dir))
        monkeypatch.setenv("CONFIGS", str(configs_dir))
        monkeypatch.setenv("PRIVATE", " ".join(private))
        monkeypatch.setenv("TRANSPORT", " ".join(transport))
        monkeypatch.setenv("BADCONTENT", " ".join(bad_content))
        monkeypatch.setenv("FAILED", " ".join(failed))
        if token is None:
            monkeypatch.delenv("GH_TOKEN", raising=False)
        else:
            monkeypatch.setenv("GH_TOKEN", token)
        if base_ref is None:
            monkeypatch.delenv("BASE_REF", raising=False)
        else:
            monkeypatch.setenv("BASE_REF", REF)
            if base_ref != ABSENT:
                (stubs_dir / "fleet-ops.yml").write_text(_stub_body(NINE))
            configs_dir.joinpath("intake-repos.json").write_text(json.dumps(
                {"repos": [{"name": n} for n in (base_repos or repos)]}))
        checkout_config = tmp_path / "intake-repos.json"
        checkout_config.write_text(json.dumps({"repos": [{"name": n} for n in repos]}))
        checkout_dispatcher = tmp_path / "agent-dispatch.yml"
        checkout_dispatcher.write_text(_dispatcher_body(dispatcher))
        module = _load_program()
        monkeypatch.setattr(module, "CONFIG", checkout_config)
        monkeypatch.setattr(module, "DISPATCHER", checkout_dispatcher)
        capsys.readouterr()
        code = 0
        try:
            module.main()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
            if isinstance(exc.code, str):
                print(exc.code, file=sys.stderr)
        out, err = capsys.readouterr()
        return code, out, err

    return _run


def test_full_stubs_pass(run):
    code, out, _ = run({"a": NINE, "b": NINE}, ["a", "b"])
    assert code == 0
    assert "Nishfleet/a: ok (9 types)" in out
    assert "Nishfleet/b: ok (9 types)" in out
    assert "2 enrolled repo(s) checked, 2 stub(s) read" in out


def test_short_stub_fails_naming_repo_and_type(run):
    code, out, _ = run({"drive": DRIVE_EIGHT}, ["drive"])
    assert code == 1
    assert "::error::Nishfleet/drive: stub omits ready_for_review from pull_request_target.types" in out
    assert "Nishfleet/drive: missing ready_for_review" in out


def test_extra_types_are_allowed(run):
    code, out, _ = run({"a": NINE + ["assigned"]}, ["a"])
    assert code == 0
    assert "ok (10 types)" in out


def test_stub_without_pull_request_target_fails(run):
    code, out, _ = run({"a": None}, ["a"])
    assert code == 1
    assert "::error::Nishfleet/a: .github/workflows/agent-dispatch.yml has no pull_request_target trigger" in out


def test_stub_trigger_with_no_types_list_fails_with_its_own_reason(run):
    code, out, _ = run({"a": "no-types"}, ["a"])
    assert code == 1
    assert ("a pull_request_target trigger with no types list, so only the opened, "
            "synchronize and reopened defaults fire") in out


def test_stub_in_the_list_form_of_on_fails_with_the_same_reason(run):
    code, out, _ = run({"a": "list-form"}, ["a"])
    assert code == 1
    assert "a pull_request_target trigger with no types list" in out


def test_a_types_list_of_non_strings_fails_with_its_own_reason(run):
    code, out, _ = run({"a": "not-strings"}, ["a"])
    assert code == 1
    assert "a pull_request_target.types that is not a list of event names" in out


def test_malformed_stub_fails_with_its_line(run):
    code, out, _ = run({"a": "malformed"}, ["a"])
    assert code == 1
    assert "::error::Nishfleet/a: .github/workflows/agent-dispatch.yml is not parseable YAML (" in out
    assert ", line 2, column 1" in out


def test_a_stub_that_is_not_base64_fails(run):
    code, out, _ = run({"a": NINE}, ["a"], bad_content=["a"])
    assert code == 1
    assert "::error::Nishfleet/a: .github/workflows/agent-dispatch.yml the content is not base64" in out


def test_readable_repo_with_no_stub_fails(run):
    code, out, _ = run({"b": NINE}, ["a", "b"])
    assert code == 1
    assert "::error::Nishfleet/a: .github/workflows/agent-dispatch.yml gh api failed" in out
    assert "Not Found (HTTP 404)" in out


def test_an_api_state_other_than_404_fails_closed_instead_of_skipping(run):
    code, out, _ = run({"a": NINE, "b": NINE}, ["a", "b"], failed=["b"])
    assert code == 1
    assert ("::error::Nishfleet/b: the repo could not be read (gh api failed: gh: Internal Server Error "
            "(HTTP 500)); failing closed") in out
    assert "not verified" not in out


def test_a_transport_failure_fails_closed(run):
    code, _, err = run({"a": NINE}, ["a"], transport=["fleet-ops"])
    assert code == 1
    assert "::error::the GitHub API is not answering through gh (gh api failed: gh: connection refused)" in err


def test_missing_gh_binary_fails_closed(run):
    code, _, err = run({"a": NINE}, ["a"], with_gh=False)
    assert code == 1
    assert "::error::the GitHub API is not answering through gh (gh is not on PATH" in err


def test_unreadable_repo_is_named_and_skipped(run):
    code, out, _ = run({"b": NINE}, ["a", "b"], private=["a"])
    assert code == 0
    assert "::warning::Nishfleet/a: not verified: the CI token cannot read this repo" in out
    assert "Nishfleet/b: ok" in out


def test_unreadable_repo_does_not_mask_a_real_failure(run):
    code, out, _ = run({"b": DRIVE_EIGHT}, ["a", "b"], private=["a"])
    assert code == 1
    assert "Nishfleet/a: not verified" in out
    assert "Nishfleet/b: stub omits ready_for_review" in out


def test_a_run_that_read_no_stub_fails(run):
    code, _, err = run({}, ["a", "b"], private=["a", "b"])
    assert code == 1
    assert "::error::no enrolled repo's stub could be read, so nothing was verified" in err


def test_required_list_comes_from_the_dispatcher_file(run):
    code, out, _ = run({"a": ["labeled", "opened"]}, ["a"], dispatcher=["labeled", "opened", "synchronize"])
    assert code == 1
    assert "stub omits synchronize" in out
    code, out, _ = run({"a": ["labeled", "opened", "synchronize", "closed"]}, ["a"],
                       dispatcher=["labeled", "opened", "synchronize"])
    assert code == 0
    assert "ok (4 types)" in out


def test_required_list_comes_from_the_base_ref_not_the_checkout(run):
    code, out, _ = run({"a": NINE}, ["a"], dispatcher=["labeled", "opened"], base_ref=REF)
    assert code == 0
    assert (f"required types (from Nishfleet/fleet-ops's own .github/workflows/agent-dispatch.yml "
            f"at {REF})") in out
    assert "Nishfleet/a: ok (9 types)" in out
    code, out, _ = run({"a": DRIVE_EIGHT}, ["a"], dispatcher=NINE, base_ref=REF)
    assert code == 1
    assert "Nishfleet/a: stub omits ready_for_review" in out


def test_a_pr_cannot_loosen_the_list_it_is_judged_against(run):
    code, out, _ = run({"a": NINE, "b": DRIVE_EIGHT}, ["a", "b"], dispatcher=NINE + ["assigned"],
                       base_ref=REF)
    assert code == 1
    assert "stub omits ready_for_review" in out
    assert "assigned" not in out


def test_a_pr_cannot_shrink_the_enrolled_set_it_is_judged_against(run):
    code, out, _ = run({"a": NINE, "b": DRIVE_EIGHT}, ["a"], base_ref=REF, base_repos=["a", "b"])
    assert code == 1
    assert "Nishfleet/b: stub omits ready_for_review" in out


def test_unreadable_base_ref_fails_closed(run):
    stubs = {"a": NINE}
    code, out, err = run(stubs, ["a"], base_ref=ABSENT)
    assert code == 1
    assert "::error::fleet-ops's own .github/workflows/agent-dispatch.yml gh api failed" in err
    assert "Not Found (HTTP 404)" in err


def test_empty_required_list_fails(run):
    code, _, err = run({"a": NINE}, ["a"], dispatcher="empty")
    assert code == 1
    assert "an empty pull_request_target.types, so this check would enforce nothing" in err


def test_dispatcher_without_pull_request_target_fails(run):
    code, _, err = run({"a": NINE}, ["a"], dispatcher=None)
    assert code == 1
    assert "::error::fleet-ops's own .github/workflows/agent-dispatch.yml has no pull_request_target trigger" in err


def test_empty_token_stops_the_run(run):
    code, _, err = run({"a": NINE}, ["a"], token=None)
    assert code == 1
    assert "GH_TOKEN is empty" in err


def test_empty_enrolled_set_fails(run):
    code, _, err = run({}, [])
    assert code == 1
    assert "names no enrolled repos" in err


def test_the_check_runs_in_ci_and_its_tests_are_discovered():
    ci = CI.read_text()
    assert "python3 tests/intake_stub_check.py" in ci
    assert "#9730" in ci
    discovering = next(l for l in ci.splitlines() if " tests " in l and "pytest -q -p no:cacheprovider" in l)
    assert "test_router_" in discovering
    assert "test_intake_stub_check" not in discovering


def test_the_check_runs_in_one_job_ci_needs_and_always():
    jobs = yaml.safe_load(CI.read_text())["jobs"]
    hosts = sorted(
        name for name, job in jobs.items()
        if any("tests/intake_stub_check.py" in str(s.get("run", "")) for s in job.get("steps", []))
    )
    assert hosts == ["systemd-verify"], f"the enrolled-stub check must run in one job, got {hosts}"
    step = next(s for s in jobs["systemd-verify"]["steps"] if "tests/intake_stub_check.py" in str(s.get("run", "")))
    assert step["if"] == "always()", "a broken stub must fail the job even when an earlier step failed"
    assert step["env"]["GH_TOKEN"] == "${{ github.token }}"
    assert "github.event.merge_group.base_sha" in step["env"]["BASE_REF"]
    assert "systemd-verify" in jobs["ci"]["needs"]
    assert "tests/alert_routes_check.py" in step["run"], "the shared step still runs the alert-route check"


def test_real_fleet_ops_config_and_dispatcher_are_accepted_offline():
    config = json.loads(CONFIG.read_text())
    assert [r["name"] for r in config["repos"]]
    dispatcher = yaml.safe_load(DISPATCHER.read_text())
    assert dispatcher[True]["pull_request_target"]["types"] == NINE
