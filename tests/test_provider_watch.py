import json
import pathlib
import re
import shlex
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-provider-watch.service"
WATCH = ROOT / "config/provider-watch.json"
ROUTER = ROOT / "config/litellm-proxy.yaml"
YQ = shutil.which("yq")

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
    -w|-m|--retry|--retry-delay) shift 2;;
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
  "label create") [ -n "$FAIL_LABEL" ] && exit 1; exit 0;;
  "label list") cat "$SC/labels" 2>/dev/null; exit 0;;
  "issue list")
    case "$*" in
      *"--state all"*) cat "$SC/recent-titles" 2>/dev/null;;
      *) cat "$SC/open-titles" 2>/dev/null;;
    esac
    exit 0;;
  "issue create")
    [ -n "$FAIL_CREATE" ] && exit 1
    while [ $# -gt 0 ]; do
      [ "$1" = --body-file ] && cp "$2" "$SC/issue-body.md"
      [ "$1" = --title ] && echo "$2" >> "$SC/issue-titles"
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


def _router_rows():
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run([YQ, "-o=json", ".model_list", str(ROOT / "config/litellm-proxy.yaml")], capture_output=True, text=True, check=True).stdout
    return [row["litellm_params"] for row in json.loads(out)]


def _provider_name(var):
    return re.sub(r"-api-key", "", var.lower().replace("_", "-"))


def _header(text):
    return text.split("\nmodel_list:", 1)[0]


def _approved(text):
    found = {}
    for m in re.finditer(r"^# Approved ([a-z0-9-]+): (\S.*)$", _header(text), re.M):
        found[m.group(1)] = {i.strip() for i in m.group(2).split(",")}
    return found


def _no_row_decisions(text):
    return {m.group(1): m.group(2) for m in re.finditer(r"^# No row for ([a-z0-9-]+), (\d{4}-\d{2}-\d{2}):", _header(text), re.M)}


def _router_drift(text, watch):
    """Names every router row off the approved list, and every watched provider that no row serves."""
    out = subprocess.run([YQ, "-o=json", ".model_list", "-"], input=text, capture_output=True, text=True, check=True).stdout
    approved = _approved(text)
    problems = []
    served = set()
    for row in json.loads(out):
        params = row["litellm_params"]
        provider = _provider_name(params["api_key"].split("/", 1)[1])
        served.add(provider)
        model = params["model"].split("/", 1)[1]
        if model not in approved.get(provider, set()):
            problems.append(f"{row['model_info']['id']}: {provider} {model} is not on the approved list")
    decided = _no_row_decisions(text)
    problems += [f"{name}: in provider-watch.json, no row and no dated no-row decision" for name in watch if name not in served and name not in decided]
    return problems


@pytest.fixture
def box(tmp_path):
    assert YQ, "yq must be on PATH to run the provider-watch tests"
    sc = tmp_path / "sc"
    sc.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("curl", CURL), ("gh", GH)):
        f = bindir / name
        f.write_text(body)
        f.chmod(0o755)
    (tmp_path / "litellm-proxy.yaml").write_text(CONFIG)
    (tmp_path / "watch.json").write_text("{}")
    (tmp_path / "token").write_text("fake-issues-token")
    (tmp_path / "run").mkdir()

    class Box:
        def __init__(self):
            self.state = state

        def write(self, name, text):
            (sc / name).write_text(text)

        def snapshot(self, data):
            (state / "catalog.json").write_text(json.dumps(data))

        def saved(self):
            return json.loads((state / "catalog.json").read_text())

        def watch(self, data):
            (tmp_path / "watch.json").write_text(json.dumps(data))

        def config(self, text):
            (tmp_path / "litellm-proxy.yaml").write_text(text)

        def serve(self, host, ids, codes="200"):
            (sc / f"{host}.json").write_text(ids if isinstance(ids, str) else _listing(*ids))
            (sc / f"{host}.codes").write_text(codes + "\n")

        def open_issues(self, *titles):
            (sc / "open-titles").write_text("".join(t + "\n" for t in titles))

        def recent_issues(self, *titles):
            (sc / "recent-titles").write_text("".join(t + "\n" for t in titles))

        def log(self, name):
            p = sc / name
            return p.read_text() if p.exists() else ""

        def changes(self):
            return {p.name: p.read_text() for p in sorted((state / "changes").glob("*.txt"))} if (state / "changes").exists() else {}

        def run(self, drop=(), extra=None):
            env = {
                "PATH": f"{bindir}:/usr/bin:/bin",
                "HOME": str(tmp_path),
                "SC": str(sc),
                "RUNTIME_DIRECTORY": str(tmp_path / "run"),
                "STATE_DIRECTORY": str(state),
                "CONFIG": str(tmp_path / "litellm-proxy.yaml"),
                "WATCH_CONFIG": str(tmp_path / "watch.json"),
                "ISSUES_TOKEN": str(tmp_path / "token"),
                "GH": str(bindir / "gh"),
                "YQ": YQ,
                "LC_ALL": "C",
                "ALPHA_API_KEY": "fake-alpha-key",
                "BETA_API_KEY": "fake-beta-key",
                "FAIL_CREATE": "",
                "FAIL_LABEL": "",
            }
            env.update(extra or {})
            for k in drop:
                del env[k]
            return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=60)

        issue_body = property(lambda self: (sc / "issue-body.md").read_text())

    b = Box()
    b.snapshot({"alpha": ["a1", "a2"], "beta": ["b1"]})
    b.serve("alpha.test", ["a2", "a1"])
    b.serve("beta.test", ["b1"])
    return b


def test_first_run_seeds_every_provider_and_files_nothing(box):
    (box.state / "catalog.json").unlink()
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha seeded, 2 models, nothing filed" in r.stdout
    assert "provider-watch: beta seeded, 1 models, nothing filed" in r.stdout
    assert box.saved() == {"alpha": ["a1", "a2"], "beta": ["b1"]}
    assert box.log("gh.log") == ""
    assert box.changes() == {}


def test_a_new_provider_is_seeded_while_the_others_are_diffed(box):
    box.snapshot({"beta": ["b1"]})
    box.serve("beta.test", ["b1", "b2"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha seeded, 2 models, nothing filed" in r.stdout
    assert "provider-watch: beta changed (+1 -0), issue filed" in r.stdout
    assert box.saved()["alpha"] == ["a1", "a2"]


def test_no_change_prints_one_line_per_provider_and_never_touches_gh(box):
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout
    assert box.log("gh.log") == ""
    assert box.changes() == {}


def test_listing_urls_follow_the_api_base(box):
    box.run()
    urls = box.log("urls.log").split()
    assert "https://alpha.test/v1/models" in urls
    assert "https://beta.test/anthropic/v1/models" in urls


def test_added_id_writes_the_changes_file_and_files_one_labelled_issue_with_no_id(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    gh = box.log("gh.log").splitlines()
    creates = [ln for ln in gh if ln.startswith("issue create")]
    assert len(creates) == 1
    assert "--title Provider watch: alpha model list changed" in creates[0]
    assert "--label provider-watch --label needs-orchestrator --body-file" in creates[0]
    assert "-R Nishfleet/fleet-ops" in creates[0]
    assert any(ln.startswith("label create provider-watch") for ln in gh)
    body = box.issue_body
    assert "The alpha model list changed: 1 added, 0 removed." in body
    assert re.search(r"The ids are in the host state file changes/\d{4}-\d{2}-\d{2}-alpha\.txt under the StateDirectory of fleet-provider-watch\.service\.", body)
    for tag in ("(a)", "(b)", "(c)", "(d)"):
        assert tag in body
    assert "tests/evals" in body and "needs-nish-decision" in body
    assert "The hand-off runs on that host as the runner user and reads the file there." in body
    for model in ("a1", "a2", "a3", "b1"):
        assert not re.search(rf"(?<![A-Za-z0-9]){model}(?![A-Za-z0-9])", body)
    (name, text), = box.changes().items()
    assert name.endswith("-alpha.txt") and text == "+ a3\n"
    assert "provider-watch: alpha changed (+1 -0), issue filed" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_the_snapshot_is_updated_after_filing_so_the_next_run_is_quiet(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.run()
    assert box.saved()["alpha"] == ["a1", "a2", "a3"]
    r = box.run()
    assert "provider-watch: alpha ok, 3 models" in r.stdout
    assert len([ln for ln in box.log("gh.log").splitlines() if ln.startswith("issue create")]) == 1


def test_removed_ids_go_to_the_changes_file(box):
    box.serve("beta.test", ["b2"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    (name, text), = box.changes().items()
    assert name.endswith("-beta.txt") and text == "+ b2\n- b1\n"
    assert "The beta model list changed: 1 added, 1 removed." in box.issue_body
    assert "provider-watch: beta changed (+1 -1), issue filed" in r.stdout


def test_every_changed_id_is_in_the_changes_file_without_a_cap(box):
    box.serve("alpha.test", ["a1", "a2"] + [f"n{i:03d}" for i in range(40)])
    box.run()
    (name, text), = box.changes().items()
    assert text.count("\n") == 40
    assert "The alpha model list changed: 40 added, 0 removed." in box.issue_body


def test_state_files_are_private(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.run()
    assert oct((box.state / "catalog.json").stat().st_mode & 0o777) == "0o600"
    (path,) = (box.state / "changes").glob("*.txt")
    assert oct(path.stat().st_mode & 0o777) == "0o600"


def test_a_flat_rate_seat_may_call_only_free_or_in_plan_ids(box):
    box.watch({"alpha": {"billing": "flat"}})
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.run()
    body = box.issue_body
    assert "(a) The alpha seat is flat-rate" in body
    assert "only to an added id that is free or inside that plan" in body
    assert "Make NO call" not in body


def test_a_seat_without_flat_billing_gets_a_no_call_body(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.run()
    body = box.issue_body
    assert "(a) The alpha seat is pay-per-use or its billing is not recorded" in body
    assert "Make NO call to any id here" in body


def test_at_most_three_issues_are_filed_per_run_and_the_rest_keep_their_snapshot(box):
    names = ["p1", "p2", "p3", "p4", "p5"]
    box.config(
        "model_list:\n"
        + "".join(
            f"- model_name: g\n  litellm_params:\n    model: openai/x\n    api_base: https://{n}.test/v1\n    api_key: os.environ/{n.upper()}_API_KEY\n"
            for n in names
        )
    )
    box.snapshot({n: ["old"] for n in names})
    for n in names:
        box.serve(f"{n}.test", ["new"])
    r = box.run(extra={f"{n.upper()}_API_KEY": "k" for n in names})
    assert r.returncode == 0, r.stdout + r.stderr
    gh = box.log("gh.log").splitlines()
    assert len([ln for ln in gh if ln.startswith("issue create")]) == 3
    assert r.stdout.count("left for the next run") == 2
    saved = box.saved()
    assert sorted(n for n in names if saved[n] == ["old"]) == ["p4", "p5"]
    assert len(box.changes()) == 5


def test_a_recently_created_closed_issue_counts_as_known_and_still_updates_the_snapshot(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.recent_issues("Provider watch: alpha model list changed")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "issue create" not in box.log("gh.log")
    assert "issue already open or recent, skipped" in r.stdout
    assert "--state all --search created:>=" in box.log("gh.log")
    assert box.saved()["alpha"] == ["a1", "a2", "a3"]
    assert len(box.changes()) == 1


def test_already_open_issue_is_skipped(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.open_issues("Provider watch: alpha model list changed", "unrelated")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "issue create" not in box.log("gh.log")
    assert "provider-watch: alpha changed (+1 -0), issue already open or recent, skipped" in r.stdout


def test_a_filing_failure_fails_the_unit_and_keeps_the_old_snapshot(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    r = box.run(extra={"FAIL_CREATE": "1"})
    assert r.returncode == 1
    assert "provider-watch: alpha changed (+1 -0) but filing the issue failed" in r.stdout
    assert box.saved()["alpha"] == ["a1", "a2"]


def test_a_dead_key_is_logged_but_does_not_fail_the_unit(box):
    box.serve("alpha.test", "{}", codes="401")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert (
        "provider-watch: alpha key rejected (HTTP 401): Nish must renew the alpha key or log in to alpha again"
        in r.stdout
    )
    assert len([u for u in box.log("urls.log").split() if "alpha.test" in u]) == 1
    assert "provider-watch: beta ok, 1 models" in r.stdout
    assert "issue create" not in box.log("gh.log")


def test_a_403_key_is_logged_but_does_not_fail_the_unit(box):
    box.serve("beta.test", "{}", codes="403")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
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
        "x" * 65,
        "~~gone~~",
        "<img src=x>",
    ],
)
def test_hostile_id_is_refused_never_printed_and_never_recorded(box, hostile):
    box.serve("alpha.test", ["a1", "a2", hostile])
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: alpha REFUSED" in r.stdout
    assert hostile not in r.stdout + r.stderr
    assert "sanitized:" in r.stdout
    assert "issue create" not in box.log("gh.log")
    assert box.saved()["alpha"] == ["a1", "a2"]
    assert box.changes() == {}
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_the_refusal_line_shows_a_sanitized_prefix_of_the_offender(box):
    box.serve("alpha.test", ["a1", "a2", "bad@id and **bold**"])
    r = box.run()
    assert r.returncode == 1
    assert "sanitized: bad?id?and???bold??" in r.stdout
    assert "**" not in r.stdout and "@" not in r.stdout


def test_a_bad_first_listing_is_refused_before_it_is_seeded(box):
    (box.state / "catalog.json").unlink()
    box.serve("alpha.test", ["a1", "bad id"])
    r = box.run()
    assert r.returncode == 1
    assert "provider-watch: alpha REFUSED" in r.stdout
    assert "alpha" not in box.saved()


def test_curl_retries_twice_twenty_seconds_apart(box):
    box.run()
    for line in box.log("curl.log").splitlines():
        assert "--retry 2 --retry-delay 20" in line


@pytest.mark.parametrize("code", ["404", "400", "410"])
def test_other_4xx_on_the_listing_fails_the_unit(box, code):
    box.serve("alpha.test", "{}", codes=code)
    r = box.run()
    assert r.returncode == 1
    assert f"provider-watch: alpha listing request failed (HTTP {code})" in r.stdout


@pytest.mark.parametrize("code", ["503", "000", "429", "408"])
def test_an_outage_is_skipped_without_failing_the_unit(box, code):
    box.serve("alpha.test", "{}", codes=code)
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert (
        f"provider-watch: alpha listing unavailable (HTTP {code}), skipped; outages page through litellm_deployment_state"
        in r.stdout
    )
    assert "provider-watch: beta ok, 1 models" in r.stdout
    assert "issue create" not in box.log("gh.log")
    assert box.saved()["alpha"] == ["a1", "a2"]


def test_an_empty_listing_is_skipped_instead_of_reporting_every_model_gone(box):
    box.serve("alpha.test", [])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha listing unavailable (HTTP 200 without a model list), skipped" in r.stdout
    assert "issue create" not in box.log("gh.log")


def test_a_listing_that_is_empty_after_the_filters_is_skipped(box):
    box.watch({"alpha": {"watch": "^zzz"}})
    box.snapshot({"alpha": ["zzz1"], "beta": ["b1"]})
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha listing unavailable (no ids left after the filters), skipped" in r.stdout
    assert box.log("gh.log") == ""


def test_a_row_with_a_key_but_no_api_base_is_refused(box):
    box.config(CONFIG + """- model_name: worker-cheap
  litellm_params:
    model: openai/a1
    api_key: os.environ/GAMMA_API_KEY
""")
    r = box.run()
    assert r.returncode == 1
    assert "api_base that is not https, refused" in r.stdout
    assert "provider-watch: alpha ok, 2 models" in r.stdout


def test_an_existing_label_is_not_rewritten(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    box.write("labels", "provider-watch\nother\n")
    r = box.run(extra={"FAIL_LABEL": "1"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "--force" not in box.log("gh.log")
    assert "issue create" in box.log("gh.log")


def test_a_label_that_cannot_be_made_or_found_fails_the_unit(box):
    box.serve("alpha.test", ["a1", "a2", "a3"])
    r = box.run(extra={"FAIL_LABEL": "1"})
    assert r.returncode == 1
    assert "label could not be created" in r.stdout
    assert box.saved()["alpha"] == ["a1", "a2"]


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
    box.watch({"alpha": {"listing": "none"}})
    box.serve("alpha.test", "{}", codes="404")
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, listing none" in r.stdout
    assert not [u for u in box.log("urls.log").split() if "alpha.test" in u]


def test_watch_pattern_ignores_ids_outside_it(box):
    box.watch({"alpha": {"watch": "^a"}})
    box.serve("alpha.test", ["a1", "a2", "zzz-new", "https://not-watched.test/ x"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert box.log("gh.log") == ""


def test_ignore_file_in_the_state_dir_hides_ids_case_insensitively(box):
    (box.state / "ignore.txt").write_text("secret-codename\n-exp$\n")
    box.serve("alpha.test", ["a1", "a2", "Secret-Codename-1", "x/vision-EXP"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "provider-watch: alpha ok, 2 models" in r.stdout
    assert box.log("gh.log") == ""


def test_missing_key_fails_naming_the_provider(box):
    r = box.run(drop=("ALPHA_API_KEY",))
    assert r.returncode == 1
    assert "provider-watch: alpha has no key in the environment" in r.stdout
    assert "provider-watch: beta ok, 1 models" in r.stdout


def test_missing_watch_config_fails_loud(box):
    (box.state.parent / "watch.json").unlink()
    r = box.run()
    assert r.returncode == 1
    assert "config/provider-watch.json missing" in r.stdout


def test_two_rows_with_one_key_give_one_listing_and_one_issue(box):
    box.config(CONFIG + """- model_name: worker-cheap
  litellm_params:
    model: openai/a1
    api_base: https://alpha.test/v2
    api_key: os.environ/ALPHA_API_KEY
""")
    box.serve("alpha.test", ["a1", "a2", "a3"])
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert len([u for u in box.log("urls.log").split() if "alpha.test" in u]) == 1
    assert len([ln for ln in box.log("gh.log").splitlines() if ln.startswith("issue create")]) == 1
    assert r.stdout.count("provider-watch: alpha") == 1


@pytest.mark.parametrize(
    "key_line",
    [
        "os.environ/litellm_master_key",
        "os.environ/LITELLM_MASTER_KEY",
        "os.environ/HOME",
        "os.environ/EVIL_API_KEY; id",
        "literal-key-value",
    ],
)
def test_a_key_reference_outside_the_pattern_is_refused(box, key_line):
    box.config(CONFIG + f"""- model_name: worker-cheap
  litellm_params:
    model: openai/a1
    api_base: https://gamma.test/v1
    api_key: {key_line}
""")
    box.serve("gamma.test", ["g1"])
    r = box.run()
    assert r.returncode == 1
    assert "refused" in r.stdout
    assert not [u for u in box.log("urls.log").split() if "gamma.test" in u]
    assert "provider-watch: alpha ok, 2 models" in r.stdout


def test_an_http_api_base_is_refused(box):
    box.config(CONFIG + """- model_name: worker-cheap
  litellm_params:
    model: openai/a1
    api_base: http://gamma.test/v1
    api_key: os.environ/GAMMA_API_KEY
""")
    box.serve("gamma.test", ["g1"])
    r = box.run()
    assert r.returncode == 1
    assert "api_base that is not https, refused" in r.stdout
    assert not [u for u in box.log("urls.log").split() if "gamma.test" in u]


def test_a_trailing_slash_on_the_api_base_is_trimmed(box):
    box.config(CONFIG.replace("https://alpha.test/v1", "https://alpha.test/v1/"))
    r = box.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "https://alpha.test/v1/models" in box.log("urls.log").split()


def test_unit_is_wired_like_the_other_checks():
    text = UNIT.read_text()
    assert "OnFailure=fleet-unit-failed@%N.service" in text
    assert "After=fleet-grafana-github-token.service" in text
    assert "StateDirectory=provider-watch" in text and "StateDirectoryMode=0700" in text
    assert "Switch off:" in text and "Delete:" in text
    assert "/home/" not in text
    assert "IGNORE" not in text


def test_every_router_key_has_an_environment_file_in_the_unit():
    unit = UNIT.read_text()
    key_re = re.compile(r"^[A-Z][A-Z0-9_]*_API_KEY(_[0-9]+)?$")
    keys = {r["api_key"].split("/", 1)[1] for r in _router_rows() if str(r.get("api_key", "")).startswith("os.environ/")}
    assert keys
    for var in sorted(keys):
        assert key_re.match(var), var
        assert f"EnvironmentFile=-%E/fleet-ops/seats/{_provider_name(var)}.env\n" in unit, f"{var} has no EnvironmentFile= in {UNIT.name}"


def test_every_seat_file_in_the_unit_is_read_by_a_router_row():
    unit = UNIT.read_text()
    listed = set(re.findall(r"^EnvironmentFile=-%E/fleet-ops/seats/([\w-]+)\.env$", unit, re.M))
    served = {_provider_name(r["api_key"].split("/", 1)[1]) for r in _router_rows() if str(r.get("api_key", "")).startswith("os.environ/")}
    assert listed <= served, f"{UNIT.name} loads a seat file that no router row reads: {sorted(listed - served)}"


def test_every_router_row_with_a_key_has_an_https_api_base():
    rows = [r for r in _router_rows() if r.get("api_key")]
    assert rows
    for row in rows:
        assert str(row.get("api_base", "")).startswith("https://"), row.get("model")


def test_the_watch_config_names_only_router_providers_and_holds_no_model_id():
    config = json.loads(WATCH.read_text())
    providers = {_provider_name(r["api_key"].split("/", 1)[1]) for r in _router_rows() if str(r.get("api_key", "")).startswith("os.environ/")}
    for name, entry in config.items():
        assert name in providers or _no_row_decisions(ROUTER.read_text()).get(name), f"{name} is not a router provider and has no dated no-row decision in the router header"
        assert set(entry) <= {"watch", "billing", "listing"}, f"{name}: unknown key"
        if "watch" in entry:
            re.compile(entry["watch"])
        assert entry.get("billing", "flat") == "flat"
        assert entry.get("listing", "none") == "none"


def test_no_catalog_file_or_model_id_list_is_committed():
    assert not (ROOT / "config/provider-catalog.json").exists()
    assert "models" not in WATCH.read_text()


def test_the_inline_script_passes_shellcheck():
    tool = shutil.which("shellcheck")
    assert tool, "shellcheck must be on PATH to lint the inline ExecStart"
    script = _exec_start()[2]
    r = subprocess.run([tool, "-s", "bash", "-"], input="#!/bin/bash\n" + script + "\n", capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout


def test_every_router_row_is_on_the_approved_list_and_every_watched_provider_has_a_row_or_a_decision():
    assert _router_drift(ROUTER.read_text(), json.loads(WATCH.read_text())) == []


def test_a_row_off_the_approved_list_is_named():
    text = ROUTER.read_text().replace("# Approved minimax: MiniMax-M3.1-Flash-Preview", "# Approved minimax: MiniMax-M3.1-Flash", 1)
    problems = _router_drift(text, {})
    assert problems and all("minimax MiniMax-M3.1-Flash-Preview is not on the approved list" in p for p in problems)


def test_a_watched_provider_with_no_row_is_named_until_a_dated_decision_covers_it():
    text = ROUTER.read_text()
    assert _router_drift(text, {"newcomer": {}}) == ["newcomer: in provider-watch.json, no row and no dated no-row decision"]
    decided = text.replace("\n# Approved opencode:", "\n# No row for newcomer, 2026-10-28: test\n# Approved opencode:", 1)
    assert _router_drift(decided, {"newcomer": {}}) == []
