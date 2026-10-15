import json
import pathlib
import shlex
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-provider-watch.service"

CONFIG = """model_list:
- model_name: worker-capable
  litellm_params:
    model: openai/a1
    api_base: https://alpha.test/v1
    api_key: os.environ/ALPHA_API_KEY
- model_name: worker-cheap
  litellm_params:
    model: openai/a1
    api_base: https://alpha.test/v1
    api_key: os.environ/ALPHA_API_KEY
- model_name: worker-capable
  litellm_params:
    model: anthropic/b1
    api_base: https://beta.test/anthropic
    api_key: os.environ/BETA_API_KEY
"""

CURL = """#!/bin/sh
echo "$@" >> "$SC/curl.log"
out=; hdr=; url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2;;
    -H) hdr=${2#@}; shift 2;;
    -w|-m) shift 2;;
    -sS) shift;;
    *) url=$1; shift;;
  esac
done
host=${url#https://}; host=${host%%/*}
echo "$url" >> "$SC/urls.log"
cat "$hdr" >> "$SC/auth.log"
n=$(cat "$SC/$host.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$SC/$host.n"
code=$(sed -n "${n}p" "$SC/$host.codes"); [ -n "$code" ] || code=$(tail -n 1 "$SC/$host.codes")
cp "$SC/$host.json" "$out"
printf %s "$code"
"""

GH = """#!/bin/sh
echo "$*" >> "$SC/gh.log"
echo "token=$GH_TOKEN config=$GH_CONFIG_DIR" >> "$SC/gh.env"
case "$1 $2" in
  "issue list") cat "$SC/open-titles" 2>/dev/null; exit 0;;
  "issue create")
    while [ $# -gt 0 ]; do
      [ "$1" = --body-file ] && cp "$2" "$SC/issue-body.md"
      shift
    done
    echo https://github.com/Nishfleet/fleet-ops/issues/1; exit 0;;
esac
exit 0
"""


def _exec_start():
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$").replace("%%", "%"))


def _listing(*ids):
    return json.dumps({"object": "list", "data": [{"id": i, "object": "model"} for i in ids]})


@pytest.fixture
def box(tmp_path):
    sc = tmp_path / "sc"
    sc.mkdir()
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("curl", CURL), ("gh", GH)):
        f = bindir / name
        f.write_text(body)
        f.chmod(0o755)
    (tmp_path / "litellm-proxy.yaml").write_text(CONFIG)
    (tmp_path / "token").write_text("fake-issues-token")
    (tmp_path / "run").mkdir()

    class Box:
        def catalog(self, data):
            (tmp_path / "catalog.json").write_text(json.dumps(data))

        def serve(self, host, ids, codes="200"):
            (sc / f"{host}.json").write_text(ids if isinstance(ids, str) else _listing(*ids))
            (sc / f"{host}.codes").write_text(codes + "\n")

        def open_issues(self, *titles):
            (sc / "open-titles").write_text("".join(t + "\n" for t in titles))

        def log(self, name):
            p = sc / name
            return p.read_text() if p.exists() else ""

        def run(self, drop=()):
            env = {
                "PATH": f"{bindir}:/usr/bin:/bin",
                "HOME": str(tmp_path),
                "SC": str(sc),
                "RUNTIME_DIRECTORY": str(tmp_path / "run"),
                "CONFIG": str(tmp_path / "litellm-proxy.yaml"),
                "CATALOG": str(tmp_path / "catalog.json"),
                "ISSUES_TOKEN": str(tmp_path / "token"),
                "GH": str(bindir / "gh"),
                "YQ": shutil.which("yq"),
                "PAUSE": "0",
                "LC_ALL": "C",
                "ALPHA_API_KEY": "fake-alpha-key",
                "BETA_API_KEY": "fake-beta-key",
            }
            for k in drop:
                del env[k]
            return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=60)

        issue_body = property(lambda self: (sc / "issue-body.md").read_text())

    b = Box()
    b.catalog({"alpha": {"models": ["a1", "a2"]}, "beta": {"models": ["b1"]}})
    b.serve("alpha.test", ["a2", "a1"])
    b.serve("beta.test", ["b1"])
    return b


def test_no_change_prints_one_line_per_provider_and_never_touches_gh(box):
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout
    assert box.log("gh.log") == ""


def test_listing_urls_follow_the_api_base(box):
    box.run()
    urls = box.log("urls.log").split()
    assert "https://alpha.test/v1/models" in urls
    assert "https://beta.test/anthropic/v1/models" in urls


def test_added_id_files_one_issue_with_both_labels(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    gh = box.log("gh.log").splitlines()
    creates = [ln for ln in gh if ln.startswith("issue create")]
    assert len(creates) == 1
    assert "--title Provider watch: alpha model list changed" in creates[0]
    assert "--label provider-watch --label needs-orchestrator" in creates[0]
    assert "-R Nishfleet/fleet-ops" in creates[0]
    assert any(ln.startswith("label create provider-watch") for ln in gh)
    body = box.issue_body
    assert "- a3" in body and "Added (first 20 of 1)" in body and "Removed (first 20 of 0)" in body
    for tag in ("(a)", "(b)", "(c)", "(d)", "(e)"):
        assert tag in body
    assert "tests/evals" in body and "needs-nish-decision" in body
    assert "provider-watch: alpha changed (+1 -0), issue filed" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_removed_id_is_reported(box):
    box.serve("beta.test", ["b2"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    body = box.issue_body
    assert "- b2" in body and "- b1" in body
    assert "provider-watch: beta changed (+1 -1), issue filed" in r.stdout


def test_ids_are_capped_in_the_body(box):
    box.serve("alpha.test", ["a1", "a2"] + [f"n{i:03d}" for i in range(30)])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    body = box.issue_body
    assert "Added (first 20 of 30)" in body
    assert "- n019" in body and "- n020" not in body


def test_already_open_issue_is_skipped(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.open_issues("Provider watch: alpha model list changed", "unrelated")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "issue create" not in box.log("gh.log")
    assert "provider-watch: alpha changed (+1 -0), issue already open, skipped" in r.stdout


def test_dead_key_fails_with_one_plain_line_and_files_nothing(box):
    box.serve("alpha.test", "{}", codes="401")
    r = box.run()
    assert r.returncode == 1
    assert (
        "provider-watch: alpha key rejected (HTTP 401): Nish must renew the alpha key or log in to alpha again"
        in r.stdout
    )
    assert len([u for u in box.log("urls.log").split() if "alpha.test" in u]) == 1
    assert "provider-watch: beta ok, 1 models" in r.stdout
    assert "issue create" not in box.log("gh.log")


def test_403_is_a_dead_key_too(box):
    box.serve("beta.test", "{}", codes="403")
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: beta key rejected (HTTP 403)" in r.stdout


@pytest.mark.parametrize(
    "hostile",
    [
        "a3 and more words",
        "[click](https://evil.test/x)",
        "https://evil.test/payload",
        "www.evil.test/payload",
        "ftp://evil.test",
        "**bold**",
        "a3‮",
        "x" * 101,
        "~~gone~~",
        "<img src=x>",
    ],
)
def test_hostile_id_is_refused_and_never_printed(box, hostile):
    box.serve("alpha.test", ["a1", "a2", hostile])
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: alpha REFUSED" in r.stdout
    assert hostile not in r.stdout + r.stderr
    assert "issue create" not in box.log("gh.log")
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_one_blip_then_success_does_not_fail(box):
    box.serve("alpha.test", ["a1", "a2"], codes="503\n200")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert len([u for u in box.log("urls.log").split() if "alpha.test" in u]) == 2


def test_three_failed_tries_fail_the_unit(box):
    box.serve("alpha.test", "{}", codes="503")
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: alpha listing failed (HTTP 503 after 3 tries)" in r.stdout
    assert len([u for u in box.log("urls.log").split() if "alpha.test" in u]) == 3


def test_empty_listing_fails_instead_of_reporting_every_model_gone(box):
    box.serve("alpha.test", [])
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: alpha listing is not a non-empty data array" in r.stdout
    assert "issue create" not in box.log("gh.log")


def test_key_never_reaches_argv_and_goes_in_a_header_file(box):
    box.run()
    assert "fake-alpha-key" not in box.log("curl.log")
    assert "fake-beta-key" not in box.log("curl.log")
    assert "Authorization: Bearer fake-alpha-key" in box.log("auth.log")
    assert "Authorization: Bearer fake-beta-key" in box.log("auth.log")


def test_gh_gets_the_issues_token_and_an_empty_config_dir(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.run()
    env = box.log("gh.env")
    assert "token=fake-issues-token" in env
    assert "config=" in env and "/run/gh" in env


def test_listing_none_is_skipped(box):
    box.catalog({"alpha": {"listing": "none"}, "beta": {"models": ["b1"]}})
    box.serve("alpha.test", "{}", codes="404")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, listing none" in r.stdout
    assert not [u for u in box.log("urls.log").split() if "alpha.test" in u]


def test_watch_pattern_ignores_ids_outside_it(box):
    box.catalog({"alpha": {"watch": "^a", "models": ["a1", "a2"]}, "beta": {"models": ["b1"]}})
    box.serve("alpha.test", ["a1", "a2", "zzz-new", "https://not-watched.test/ x"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert box.log("gh.log") == ""


def test_provider_missing_from_the_snapshot_is_filed_as_all_added(box):
    box.catalog({"beta": {"models": ["b1"]}})
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha changed (+2 -0), issue filed" in r.stdout


def test_missing_key_fails_naming_the_provider(box):
    r = box.run(drop=("ALPHA_API_KEY",))
    assert r.returncode == 1
    assert "provider-watch: alpha has no key in the environment" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_unit_is_wired_like_the_other_checks():
    text = UNIT.read_text()
    assert "OnFailure=fleet-unit-failed@%N.service" in text
    assert "After=fleet-grafana-github-token.service" in text
    assert "Switch off:" in text and "Delete:" in text
    assert "/home/" not in text
