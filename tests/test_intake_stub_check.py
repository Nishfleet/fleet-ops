"""The enrolled-stub check (tests/intake_stub_check.py), run against fake gh and
fake curl serving fixture stubs.

The real program runs in ci.yml with only the fleet-ops workflow token. These
cases prove: a full stub passes, a short stub fails naming the repo and the
missing type, a public repo with no stub or a malformed one fails, an unknown
API state fails closed, a repo the token cannot read is named as not verified
and skipped without masking a real failure elsewhere, the required list comes
from the dispatcher file the run points at, and extra types are allowed.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "tests/intake_stub_check.py"
NINE = [
    "dequeued", "auto_merge_disabled", "closed", "auto_merge_enabled",
    "synchronize", "labeled", "opened", "reopened", "ready_for_review",
]
DRIVE_EIGHT = [t for t in NINE if t != "ready_for_review"]

GH = """#!/bin/bash
p=$2
name=${p#repos/Nishfleet/}; name=${name%%/*}
for n in $PRIVATE; do [ "$name" = "$n" ] && exit 1; done
case "$p" in
  *contents/*)
    [ -f "$STUBS/$name.yml" ] || exit 1
    printf '{"encoding":"base64","content":"%s"}' "$(base64 -w0 "$STUBS/$name.yml")" ;;
  *) exit 1 ;;
esac
"""

CURL = """#!/bin/bash
body=$3; url=$6
name=${url#*repos/Nishfleet/}; name=${name%%/*}
kind=repo
case "$url" in */contents/*) kind=contents ;; esac
for n in $RATELIMIT; do
  if [ "$name" = "$n" ]; then echo 403; exit 0; fi
done
for n in $PRIVATE; do
  if [ "$name" = "$n" ]; then echo 404; exit 0; fi
done
if [ "$kind" = contents ]; then
  if [ -f "$STUBS/$name.yml" ]; then
    printf '{"encoding":"base64","content":"%s"}' "$(base64 -w0 "$STUBS/$name.yml")" > "$body"
    echo 200
  else
    echo 404
  fi
else
  echo 200
fi
"""


def _write_fakes(tmp_path, stubs, private=(), ratelimit=()):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    stubs_dir = tmp_path / "stubs"
    stubs_dir.mkdir(exist_ok=True)
    for name, types in stubs.items():
        if types is None:
            body = "on:\n  push:\n    branches: [main]\n"
        elif types == "malformed":
            body = "on: [oops\n"
        else:
            body = "on:\n  pull_request_target:\n    types: [%s]\n" % ", ".join(types)
        (stubs_dir / f"{name}.yml").write_text(body)
    for fname, text, envs in (("gh", GH, {}), ("curl", CURL, {})):
        f = bin_dir / fname
        f.write_text(text)
        f.chmod(0o755)
    env = {
        "PATH": f"{bin_dir}:{os.defpath}",
        "STUBS": str(stubs_dir),
        "PRIVATE": " ".join(private),
        "RATELIMIT": " ".join(ratelimit),
        "HOME": str(tmp_path),
    }
    return env


def _write_inputs(tmp_path, repos, dispatcher_types=NINE):
    cfg = tmp_path / "intake-repos.json"
    cfg.write_text(json.dumps({"repos": [{"name": n} for n in repos]}))
    disp = tmp_path / "dispatcher.yml"
    if dispatcher_types is not None:
        disp.write_text("on:\n  pull_request_target:\n    types: [%s]\n" % ", ".join(dispatcher_types))
    else:
        disp.write_text("on:\n  issues:\n    types: [labeled]\n")
    return cfg, disp


def _run(tmp_path, stubs, repos, private=(), ratelimit=(), dispatcher_types=NINE):
    env = _write_fakes(tmp_path, stubs, private, ratelimit)
    cfg, disp = _write_inputs(tmp_path, repos, dispatcher_types)
    return subprocess.run(
        ["python3", str(PROGRAM), str(cfg), str(disp)],
        capture_output=True, text=True, env=env,
    )


def test_full_stubs_pass(tmp_path):
    r = _run(tmp_path, {"a": NINE, "b": NINE}, ["a", "b"])
    assert r.returncode == 0
    assert "Nishfleet/a: ok (9 types)" in r.stdout
    assert "Nishfleet/b: ok (9 types)" in r.stdout


def test_short_stub_fails_naming_repo_and_type(tmp_path):
    r = _run(tmp_path, {"drive": DRIVE_EIGHT}, ["drive"])
    assert r.returncode == 1
    assert "::error::Nishfleet/drive: stub omits ready_for_review" in r.stdout
    assert "short of the required types" in r.stderr


def test_extra_types_are_allowed(tmp_path):
    r = _run(tmp_path, {"a": NINE + ["assigned"]}, ["a"])
    assert r.returncode == 0
    assert "ok (10 types)" in r.stdout


def test_stub_without_pull_request_target_fails(tmp_path):
    r = _run(tmp_path, {"a": None}, ["a"])
    assert r.returncode == 1
    assert "no pull_request_target.types list" in r.stderr


def test_malformed_stub_fails(tmp_path):
    r = _run(tmp_path, {"a": "malformed"}, ["a"])
    assert r.returncode == 1
    assert "no pull_request_target.types list" in r.stderr


def test_public_repo_with_no_stub_fails(tmp_path):
    r = _run(tmp_path, {"b": NINE}, ["a", "b"])
    assert r.returncode == 1
    assert "answered 404 on the stub and 200 on the repo" in r.stderr


def test_unknown_api_state_fails_closed(tmp_path):
    r = _run(tmp_path, {"b": NINE}, ["a", "b"], ratelimit=["a"])
    assert r.returncode == 1
    assert "answered 403 on the stub" in r.stderr


def test_unreadable_repo_is_named_and_skipped(tmp_path):
    r = _run(tmp_path, {"b": NINE}, ["a", "b"], private=["a"])
    assert r.returncode == 0
    assert "::warning::" in r.stdout
    assert "Nishfleet/a: not verified" in r.stdout
    assert "Nishfleet/b: ok" in r.stdout


def test_unreadable_repo_does_not_mask_a_real_failure(tmp_path):
    r = _run(tmp_path, {"b": DRIVE_EIGHT}, ["a", "b"], private=["a"])
    assert r.returncode == 1
    assert "Nishfleet/a: not verified" in r.stdout
    assert "Nishfleet/b: stub omits ready_for_review" in r.stdout


def test_required_list_comes_from_the_dispatcher_file(tmp_path):
    r = _run(tmp_path, {"a": ["labeled", "opened"]}, ["a"], dispatcher_types=["labeled", "opened", "synchronize"])
    assert r.returncode == 1
    assert "stub omits synchronize" in r.stdout
    r2 = _run(tmp_path, {"a": ["labeled", "opened", "synchronize", "closed"]}, ["a"],
              dispatcher_types=["labeled", "opened", "synchronize"])
    assert r2.returncode == 0
    assert "ok (4 types)" in r2.stdout


def test_dispatcher_without_pull_request_target_fails(tmp_path):
    r = _run(tmp_path, {"a": NINE}, ["a"], dispatcher_types=None)
    assert r.returncode == 1
    assert "no pull_request_target.types to require" in r.stderr


def test_empty_enrolled_set_fails(tmp_path):
    r = _run(tmp_path, {}, [])
    assert r.returncode == 1
    assert "names no enrolled repos" in r.stderr


def test_real_fleet_ops_config_and_dispatcher_are_accepted_offline():
    import yaml
    cfg = json.loads((ROOT / "config/intake-repos.json").read_text())
    assert [r["name"] for r in cfg["repos"]]
    disp = yaml.safe_load((ROOT / ".github/workflows/agent-dispatch.yml").read_text())
    assert disp[True]["pull_request_target"]["types"] == NINE
