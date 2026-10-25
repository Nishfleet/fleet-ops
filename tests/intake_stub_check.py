"""Every enrolled repo's dispatch stub forwards every pull_request_target type
the fleet-ops dispatcher itself lists (README "Intake enrolment" precondition 3,
fleet-ops#9730).

Reads the enrolled set from config/intake-repos.json, the required list from
fleet-ops's own .github/workflows/agent-dispatch.yml in this checkout, and each
enrolled repo's stub from its default branch over the GitHub API. Fails when a
readable repo's stub omits a required type, or has no pull_request_target
trigger, or is not parseable YAML. A repo the CI token cannot read (a private
repo, or a deleted one) is named as not verified and skipped: with no credential
this job may read (new credentials are Nish's call), it can be neither verified
nor failed, and failing would red main forever. An unknown API state fails
closed.

usage: intake_stub_check.py [intake-repos.json] [fleet-ops agent-dispatch.yml]
"""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
ORG = "Nishfleet"
STUB_PATH = ".github/workflows/agent-dispatch.yml"


def _triggers(cfg):
    on = cfg.get(True, cfg.get("on")) if isinstance(cfg, dict) else None
    if not isinstance(on, dict):
        return None
    prt = on.get("pull_request_target")
    if not isinstance(prt, dict):
        return None
    types = prt.get("types")
    if not isinstance(types, list) or not all(isinstance(t, str) for t in types):
        return None
    return types


def _required(dispatch_path):
    try:
        types = _triggers(yaml.safe_load(dispatch_path.read_text()))
    except yaml.YAMLError:
        types = None
    if types is None:
        sys.exit(f"fleet-ops's own {STUB_PATH} has no pull_request_target.types to require")
    return types


def _gh(path):
    r = subprocess.run(["gh", "api", f"repos/{ORG}/{path}"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def _curl(path):
    url = f"https://api.github.com/repos/{ORG}/{path}"
    with tempfile.TemporaryDirectory() as tmp:
        body = pathlib.Path(tmp) / "body"
        r = subprocess.run(["curl", "-sS", "-o", str(body), "-w", "%{http_code}", url],
                           capture_output=True, text=True)
        if r.returncode != 0 or not (r.stdout or "").strip().isdigit():
            return None
        return r.stdout.strip(), body.read_text() if body.exists() else ""


def _stub_types(name):
    data = _gh(f"{name}/contents/{STUB_PATH}")
    if data is None:
        code, body = _curl(f"{name}/contents/{STUB_PATH}")
        if code == "200":
            data = json.loads(body)
        else:
            repo_code, _ = _curl(name)
            if repo_code == "404":
                return None, "not verified: the CI token cannot read this repo (private or gone); skipped"
            sys.exit(f"Nishfleet/{name}: GitHub API answered {code or 'an error'} on the stub and {repo_code or 'an error'} on the repo; failing closed")
    raw = data.get("content", "")
    if data.get("encoding") != "base64" or not raw:
        sys.exit(f"Nishfleet/{name}: stub exists but the contents API sent no base64 body")
    try:
        types = _triggers(yaml.safe_load(base64.b64decode(raw)))
    except yaml.YAMLError:
        types = None
    if types is None:
        sys.exit(f"Nishfleet/{name}: {STUB_PATH} has no pull_request_target.types list")
    return types, None


def main():
    cfg_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "config/intake-repos.json"
    dispatch_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / STUB_PATH
    repos = [r["name"] for r in json.loads(cfg_path.read_text())["repos"]]
    if not repos:
        sys.exit(f"{cfg_path} names no enrolled repos")
    required = _required(dispatch_path)
    print(f"required types (from {ORG}/fleet-ops's own stub): {', '.join(required)}")
    failures = 0
    for name in repos:
        types, notice = _stub_types(name)
        if notice is not None:
            print(f"::warning::{notice}")
            print(f"{ORG}/{name}: {notice}")
            continue
        missing = [t for t in required if t not in types]
        if missing:
            failures += 1
            print(f"::error::{ORG}/{name}: stub omits {', '.join(missing)} from pull_request_target.types")
            print(f"{ORG}/{name}: missing {', '.join(missing)}")
        else:
            print(f"{ORG}/{name}: ok ({len(types)} types)")
    if failures:
        sys.exit(f"{failures} enrolled stub(s) short of the required types")


if __name__ == "__main__":
    main()
