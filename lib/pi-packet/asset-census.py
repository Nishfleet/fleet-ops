#!/usr/bin/env python3
"""Mechanical VPS asset census, guard mapping, and unguarded-asset canary.

fleet-ops#1149. Enumerates the live VPS surface, compares it to a versioned
asset->guard map, writes Prometheus textfile metrics, and auto-files deduped
`unguarded asset:` issues for anything outside the map.

Deterministic, stdlib only, no secrets in output.

Asset classes:
  systemd-{user,system}-{service,timer,path,socket}
  port-tcp, port-udp
  github-repo, github-workflow, github-subscription
  credential-file, endpoint-key, pi-seat, pi-provider
  storage-rclone, storage-restic
  test-suite, test-header-claim

Usage:
  python3 lib/pi-packet/asset-census.py census [--output-json PATH] [--state-dir DIR]
  python3 lib/pi-packet/asset-census.py diff --map PATH [--output-json PATH] [--metrics PATH]
                                  [--file-issues] [--dry-run] [--state-dir DIR]
  python3 lib/pi-packet/asset-census.py validate-map --map PATH
  python3 lib/pi-packet/asset-census.py issue-title --json ITEM
  python3 lib/pi-packet/asset-census.py issue-body --json ITEM
  python3 lib/pi-packet/asset-census.py set-subscriptions [--dry-run]

Environment seams (tests):
  FLEET_ASSET_CENSUS_STATE_DIR          state directory (default ~/.local/state/pi-packet)
  FLEET_ASSET_CENSUS_CENSUS_FILE        previous/current census path
  FLEET_ASSET_CENSUS_MAP_FILE           default guard map
  FLEET_ASSET_CENSUS_METRICS_FILE       Prometheus textfile path
  FLEET_ASSET_CENSUS_FLEET_OPS_REPO     path to fleet-ops checkout (for config)
  FLEET_ASSET_CENSUS_REPO_ROOTS         colon-separated test-repo roots
  FLEET_ASSET_CENSUS_ENROLLED_REPOS     JSON array of {"name": "..."} repos to scan
  FLEET_ASSET_CENSUS_GH                 gh binary (default gh)
  FLEET_ASSET_CENSUS_SYSTEMCTL          systemctl binary (default systemctl)
  FLEET_ASSET_CENSUS_SS                 ss binary (default ss)
  FLEET_ASSET_CENSUS_SKIP_LIVE          skip live system calls
  FLEET_ASSET_CENSUS_FILE_ISSUES        1/0 (default 1)
  FLEET_ASSET_CENSUS_ISSUE_REPO         Nishfleet/fleet-ops
  FLEET_ASSET_CENSUS_ISSUE_FILE         path to fleet-issue-file wrapper
  FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS  1/0 (default 0; set to 1 to auto-correct)
  FLEET_ASSET_CENSUS_DRY_RUN            skip side effects
  FLEET_ASSET_CENSUS_PROM_FILE          metrics path (default /var/lib/prometheus/node-exporter/fleet-asset-census.prom)
"""
from __future__ import annotations

import argparse
import configparser
import concurrent.futures
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VERSION = "1"

SIGNAL_FMT = "signal: asset-census/{id}"

# Sensitive key/value patterns: we never emit these. re.search already scans
# the whole string, so no leading/trailing .* — wrapping in .*(...).* forces
# O(n^2) backtracking per line and hung the census on 13k config files
# (fleet-ops#1149 inner-loop fix).
SECRET_KEY_RE = re.compile(
    r"(TOKEN|KEY|SECRET|PASSWORD|PRIVATE_KEY|CERT|CREDENTIAL|API_KEY|ACCESS_KEY|"
    r"SECRET_KEY|AUTH|PIN)",
    re.I,
)
ENDPOINT_KEY_PATTERNS = frozenset(
    ["URL", "ENDPOINT", "API", "PING", "WEBHOOK", "BASE", "ORIGIN", "HOST"]
)

TAILSCALE_INSTALL_HINT = (
    " Tailscale access-plane lifeline: do not stop/tunnel without Nish approval."
)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str, *args: Any) -> None:
    if args:
        line = f"[{now_iso()}] [asset-census] {msg % args}"
    else:
        line = f"[{now_iso()}] [asset-census] {msg}"
    print(line, file=sys.stderr)


def atomic_write(path: Path, text: str, mode: int = 0o644) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def cmd_output(
    *args: str,
    timeout: int = 30,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """Run a command and return (rc, stdout, stderr). Never raises."""
    try:
        proc = subprocess.run(
            list(args),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        return proc.returncode, (proc.stdout or ""), (proc.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 126, "", str(exc)


def _rel_to_or_name(p: Path, root: Path) -> str:
    """Return a path relative to the scan root, or just the filename."""
    try:
        return str(p.relative_to(root))
    except ValueError:
        return p.name


# Subtrees under the scan roots that are runtime/vendored/session state, not
# config sinks. Scanning them crawls tens of thousands of files (e.g.
# ~/.pi/agent/git holds vendored checkouts, ~/.pi/agent/sessions holds per-run
# transcripts) and turns a weekly census into a multi-minute hot loop. They are
# not where credentials or endpoint declarations live, so prune them.
SCAN_PRUNE_DIRS = frozenset(
    {
        "git",        # ~/.pi/agent/git — vendored/pi-managed checkouts
        "sessions",   # ~/.pi/agent/sessions — per-run transcripts
        "skills",     # ~/.pi/agent/skills — vendored skill bundles
        "node_modules",
        ".git",
        ".cache",
        "cache",
    }
)


def _pruned_dirs(root: Path):
    """Yield (dirpath, dirnames) like os.walk but with prune dirs removed in
    place, so rglob does not descend into them."""
    import os
    for dirpath, dirnames, filenames in os.walk(root):
        # Mutate dirnames in place to prevent descent into pruned subtrees.
        dirnames[:] = [d for d in dirnames if d not in SCAN_PRUNE_DIRS and not d.startswith(".git")]
        yield dirpath, dirnames, filenames


# Hard cap on files read per scan root, so a runaway tree can never make the
# weekly census hang. The credential/endpoint sinks are small; 4000 is generous.
SCAN_FILE_CAP = 4000


class Config:
    def __init__(self, args: argparse.Namespace | None = None) -> None:
        self.home = Path(os.environ.get("HOME", "/home/nish"))
        self.state_dir = Path(
            os.environ.get("FLEET_ASSET_CENSUS_STATE_DIR")
            or str(self.home / ".local" / "state" / "pi-packet")
        )
        self.census_file = Path(
            os.environ.get("FLEET_ASSET_CENSUS_CENSUS_FILE")
            or str(self.state_dir / "asset-census.json")
        )
        self.metrics_file = Path(
            os.environ.get("FLEET_ASSET_CENSUS_METRICS_FILE")
            or os.environ.get("FLEET_ASSET_CENSUS_PROM_FILE")
            or "/var/lib/prometheus/node-exporter/fleet-asset-census.prom"
        )
        self.fleet_ops_repo = Path(
            os.environ.get("FLEET_ASSET_CENSUS_FLEET_OPS_REPO")
            or "/home/nish/workspaces/tooling/fleet-ops-deploy-clone"
        )
        self.map_file = Path(
            os.environ.get("FLEET_ASSET_CENSUS_MAP_FILE")
            or str(self.fleet_ops_repo / "config" / "asset-guard-map.json")
        )
        self.gh = os.environ.get("FLEET_ASSET_CENSUS_GH", "gh")
        self.systemctl = os.environ.get("FLEET_ASSET_CENSUS_SYSTEMCTL", "systemctl")
        self.ss = os.environ.get("FLEET_ASSET_CENSUS_SS", "ss")
        self.skip_live = _env_bool("FLEET_ASSET_CENSUS_SKIP_LIVE", False)
        self.file_issues = _env_bool("FLEET_ASSET_CENSUS_FILE_ISSUES", True)
        self.dry_run = _env_bool("FLEET_ASSET_CENSUS_DRY_RUN", False)
        self.issue_repo = os.environ.get("FLEET_ASSET_CENSUS_ISSUE_REPO", "Nishfleet/fleet-ops")
        self.issue_file = os.environ.get(
            "FLEET_ASSET_CENSUS_ISSUE_FILE",
            str(self.fleet_ops_repo / "bin" / "fleet-issue-file"),
        )
        self.set_subscriptions = _env_bool("FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS", False)
        if args is not None:
            if getattr(args, "map", None):
                self.map_file = Path(args.map)
            if getattr(args, "state_dir", None):
                self.state_dir = Path(args.state_dir)
                self.census_file = self.state_dir / "asset-census.json"
            if getattr(args, "output_json", None):
                self.output_json = Path(args.output_json)
            if getattr(args, "metrics", None):
                self.metrics_file = Path(args.metrics)
            if getattr(args, "dry_run", None):
                self.dry_run = args.dry_run
            if getattr(args, "fleet_ops_repo", None):
                self.fleet_ops_repo = Path(args.fleet_ops_repo)


def _env_bool(name: str, default: bool) -> bool:
    val = os.environ.get(name, "")
    if val == "":
        return default
    return val in ("1", "true", "True", "TRUE", "yes")


class CensusTaker:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.assets: list[dict[str, Any]] = []
        self._seen_ids: set[str] = set()
        self._lock = threading.Lock()

    def add(self, asset: dict[str, Any]) -> None:
        aid = str(asset.get("id", ""))
        if not aid:
            log("WARN: skipping asset with no id: %s", asset)
            return
        with self._lock:
            if aid in self._seen_ids:
                log("WARN: duplicate asset id skipped: %s", aid)
                return
            self._seen_ids.add(aid)
            self.assets.append(asset)

    def run(self) -> dict[str, Any]:
        log("census starting")
        self.systemd_units()
        self.ports()
        self.github_repos()
        self.credentials()
        self.endpoints()
        self.storage()
        self.pi_seats()
        self.test_suites_and_claims()
        report = {
            "version": VERSION,
            "generated_at": now_iso(),
            "asset_count": len(self.assets),
            "assets": sorted(self.assets, key=lambda a: a["id"]),
        }
        log("census complete: %s assets", len(self.assets))
        return report

    # -----------------------------------------------------------------------
    # systemd
    # -----------------------------------------------------------------------
    def systemd_units(self) -> None:
        if self.cfg.skip_live:
            log("systemd: skip-live")
            return
        for scope in ("user", "system"):
            types = ("service", "timer", "path", "socket")
            if scope == "user":
                rc, out, err = cmd_output(
                    self.cfg.systemctl,
                    "--user",
                    "list-units",
                    "--type=service,timer,path,socket",
                    "--no-legend",
                    "--plain",
                    timeout=30,
                    env={**os.environ, "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")},
                )
            else:
                rc, out, err = cmd_output(
                    self.cfg.systemctl,
                    "list-units",
                    "--type=service,timer,path,socket",
                    "--no-legend",
                    "--plain",
                    timeout=30,
                )
            if rc != 0:
                log("systemd %s list-units failed (rc=%s): %s", scope, rc, err[:200])
                continue
            for line in out.splitlines():
                parts = line.split()
                unit = parts[0] if parts else ""
                if not unit or not unit.endswith(tuple("." + t for t in types)):
                    continue
                self.add(
                    {
                        "id": f"systemd:{scope}:{unit}",
                        "class": f"systemd-{scope}-{unit.rsplit('.', 1)[1]}",
                        "name": unit,
                        "source": f"systemctl {scope} list-units",
                        "scope": scope,
                    }
                )

            # Also enumerate unit files (installed but not loaded)
            if scope == "user":
                rc, out, err = cmd_output(
                    self.cfg.systemctl,
                    "--user",
                    "list-unit-files",
                    "--type=service,timer,path,socket",
                    "--no-legend",
                    "--plain",
                    timeout=30,
                    env={**os.environ, "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")},
                )
            else:
                rc, out, err = cmd_output(
                    self.cfg.systemctl,
                    "list-unit-files",
                    "--type=service,timer,path,socket",
                    "--no-legend",
                    "--plain",
                    timeout=30,
                )
            if rc != 0:
                log("systemd %s list-unit-files failed (rc=%s): %s", scope, rc, err[:200])
                continue
            for line in out.splitlines():
                parts = line.split()
                unit = parts[0] if parts else ""
                if not unit or not unit.endswith(tuple("." + t for t in types)):
                    continue
                if f"systemd:{scope}:{unit}" in self._seen_ids:
                    continue
                self.add(
                    {
                        "id": f"systemd:{scope}:{unit}",
                        "class": f"systemd-{scope}-{unit.rsplit('.', 1)[1]}",
                        "name": unit,
                        "source": f"systemctl {scope} list-unit-files",
                        "scope": scope,
                    }
                )

    # -----------------------------------------------------------------------
    # ports
    # -----------------------------------------------------------------------
    def ports(self) -> None:
        if self.cfg.skip_live:
            log("ports: skip-live")
            return
        for proto, extra in (("tcp", "-ltnp"), ("udp", "-lunp")):
            rc, out, err = cmd_output(
                self.cfg.ss, extra, "--no-header", "--processes", timeout=15
            )
            if rc != 0 or not out.strip():
                # Fallback without process info
                extra2 = extra.replace("p", "")
                if extra2 == extra:
                    extra2 = extra[:-1] if extra.endswith("p") else extra
                rc, out, err = cmd_output(
                    self.cfg.ss, extra2, "--no-header", timeout=15
                )
            if rc != 0:
                log("ss %s failed (rc=%s): %s", proto, rc, err[:200])
                continue
            for line in out.splitlines():
                parts = line.split()
                if len(parts) < 4:
                    continue
                local = parts[3]
                if ":" not in local:
                    continue
                addr, _, port = local.rpartition(":")
                try:
                    int(port)
                except ValueError:
                    continue
                process = ""
                if len(parts) > 4:
                    process = parts[-1]
                if process.startswith("users:"):
                    m = re.search(r'"([^"]+)"', process)
                    if m:
                        process = m.group(1)
                self.add(
                    {
                        "id": f"port:{proto}:{addr}:{port}",
                        "class": f"port-{proto}",
                        "name": f"{proto}/{port}",
                        "source": "ss",
                        "details": {"local_address": addr, "port": port, "process": process},
                    }
                )

    # -----------------------------------------------------------------------
    # GitHub plane
    # -----------------------------------------------------------------------
    def github_repos(self) -> None:
        if self.cfg.skip_live:
            log("github: skip-live")
            return
        if not shutil.which(self.cfg.gh):
            log("github: gh not found")
            return

        rc, out, err = cmd_output(
            self.cfg.gh,
            "repo",
            "list",
            "Nishfleet",
            "--limit",
            "200",
            "--json",
            "name,owner,visibility,isArchived",
            timeout=60,
        )
        if rc != 0:
            log("github repo list failed (rc=%s): %s", rc, err[:200])
            return
        try:
            repos = json.loads(out)
        except json.JSONDecodeError as exc:
            log("github repo list JSON parse failed: %s", exc)
            return
        if not isinstance(repos, list):
            return

        repo_names: list[str] = []
        for repo in repos:
            if not isinstance(repo, dict):
                continue
            name = repo.get("name", "")
            owner = repo.get("owner", {}).get("login", "Nishfleet") if isinstance(repo.get("owner"), dict) else "Nishfleet"
            if not name:
                continue
            full = f"{owner}/{name}"
            repo_names.append(full)
            self.add(
                {
                    "id": f"github:repo:{full}",
                    "class": "github-repo",
                    "name": full,
                    "source": "gh repo list Nishfleet",
                    "details": {
                        "visibility": repo.get("visibility", "unknown"),
                        "archived": repo.get("isArchived", False),
                    },
                }
            )

        # Fetch per-repo subscription + workflows in parallel. The worker token
        # may lack access to some endpoints; each call is bounded and isolated.
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
            for r in repo_names:
                ex.submit(self._github_subscription, r)
                ex.submit(self._github_workflows, r)

    def _github_subscription(self, repo: str) -> None:
        rc, out, err = cmd_output(
            self.cfg.gh,
            "api",
            f"/repos/{repo}/subscription",
            timeout=30,
        )
        if rc != 0:
            log("github subscription fetch failed for %s (rc=%s): %s", repo, rc, err[:200])
            return
        try:
            sub = json.loads(out)
        except json.JSONDecodeError:
            return
        if not isinstance(sub, dict):
            return
        subscribed = sub.get("subscribed", False)
        ignored = sub.get("ignored", False)
        drift = bool(subscribed or ignored)
        self.add(
            {
                "id": f"github:subscription:{repo}",
                "class": "github-subscription",
                "name": repo,
                "source": "gh api /repos/{owner}/{repo}/subscription",
                "details": {"subscribed": subscribed, "ignored": ignored, "drift": drift},
            }
        )
        if drift and self.cfg.set_subscriptions and not self.cfg.dry_run:
            log("github: correcting subscription for %s to subscribed=false/ignored=false", repo)
            set_rc, _, set_err = cmd_output(
                self.cfg.gh,
                "api",
                "--method",
                "PUT",
                f"/repos/{repo}/subscription",
                "-f",
                "subscribed=false",
                "-f",
                "ignored=false",
                timeout=30,
            )
            if set_rc != 0:
                log("github subscription update for %s failed (rc=%s): %s", repo, set_rc, set_err[:200])

    def _github_workflows(self, repo: str) -> None:
        rc, out, err = cmd_output(
            self.cfg.gh,
            "api",
            f"/repos/{repo}/actions/workflows",
            "--paginate",
            timeout=60,
        )
        if rc != 0:
            log("github workflows for %s failed (rc=%s): %s", repo, rc, err[:200])
            return
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            return
        if not isinstance(data, dict):
            return
        workflows = data.get("workflows", [])
        if not isinstance(workflows, list):
            return
        for wf in workflows:
            if not isinstance(wf, dict):
                continue
            wf_id = wf.get("id")
            path = wf.get("path", "")
            name = wf.get("name", "")
            if wf_id is None:
                continue
            self.add(
                {
                    "id": f"github:workflow:{repo}:{wf_id}",
                    "class": "github-workflow",
                    "name": path or name,
                    "source": "gh api /repos/{owner}/{repo}/actions/workflows",
                    "details": {"repo": repo, "path": path, "name": name},
                }
            )

    # -----------------------------------------------------------------------
    # credentials
    # -----------------------------------------------------------------------
    def credentials(self) -> None:
        # Limit to the machine's own credential sinks. Product repo worktrees
        # may hold .env files, but scanning them would crawl node_modules and
        # vendor trees; they are guarded by the repo's own CI and secret-scan.
        # Use os.walk with pruning so vendored/session subtrees
        # (~/.pi/agent/git, sessions, skills) are not descended into.
        search_roots = [
            self.cfg.home / ".config",
            self.cfg.home / ".local" / "state",
            self.cfg.home / ".pi" / "agent",
        ]
        for root in search_roots:
            if not root.is_dir():
                continue
            seen_files = 0
            for dirpath, _dirnames, filenames in _pruned_dirs(root):
                for fname in sorted(filenames):
                    p = Path(dirpath) / fname
                    if seen_files >= SCAN_FILE_CAP:
                        log("credentials: file cap reached at %s (%s), stopping scan of %s", seen_files, p, root)
                        break
                    seen_files += 1
                    if not p.is_file() or p.is_symlink():
                        continue
                    if not self._looks_credentialish(p, fname):
                        continue
                    identities = self._credential_identities(p)
                    if not identities:
                        identities = ["(no named identity keys)"]
                    rel = _rel_to_or_name(p, root)
                    self.add(
                        {
                            "id": f"credential:{rel}",
                            "class": "credential-file",
                            "name": fname,
                            "source": f"scan {root}",
                            "details": {
                                "path": rel,
                                "identities": identities,
                            },
                        }
                    )
                if seen_files >= SCAN_FILE_CAP:
                    break

    def _looks_credentialish(self, p: Path, name: str) -> bool:
        lower = name.lower()
        if lower.endswith((".key", ".pem", ".p12", ".pfx", ".crt")):
            return True
        if lower.endswith((".env",)):
            return True
        if any(
            frag in lower
            for frag in ("token", "secret", "credential", "api-key", "apikey", "private")
        ):
            return True
        if p.stat().st_size > 65536:
            return False
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
        if SECRET_KEY_RE.search(text):
            return True
        return False

    def _credential_identities(self, p: Path) -> list[str]:
        """Return key names that look like credential identities, never values."""
        identities: list[str] = []
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return identities
        for line in text.splitlines():
            line = line.split("#", 1)[0].rstrip()
            if "=" in line:
                key, _, _ = line.partition("=")
                key = key.strip()
                if SECRET_KEY_RE.match(key) and key not in identities:
                    identities.append(key)
            # JSON/YAML key-only patterns
            m = re.match(r'^\s*"([^"]+)"\s*:', line)
            if m:
                key = m.group(1)
                if SECRET_KEY_RE.match(key) and key not in identities:
                    identities.append(key)
            m = re.match(r"^\s*([^:\s]+):", line)
            if m:
                key = m.group(1)
                if SECRET_KEY_RE.match(key) and key not in identities:
                    identities.append(key)
        return identities[:20]

    # -----------------------------------------------------------------------
    # external endpoints referenced in configs
    # -----------------------------------------------------------------------
    def endpoints(self) -> None:
        # Endpoint declarations live in config/systemd in the control plane
        # and in the machine's own config sinks. Avoid crawling the whole repo.
        # Use os.walk with pruning so vendored/session subtrees are skipped.
        search_roots = [
            self.cfg.home / ".config",
            self.cfg.home / ".pi" / "agent",
            self.cfg.home / ".local" / "state",
            self.cfg.fleet_ops_repo / "config",
            self.cfg.fleet_ops_repo / "systemd",
        ]
        seen: set[tuple[str, str]] = set()
        for root in search_roots:
            if not root.is_dir():
                continue
            seen_files = 0
            for dirpath, _dirnames, filenames in _pruned_dirs(root):
                for fname in sorted(filenames):
                    p = Path(dirpath) / fname
                    if seen_files >= SCAN_FILE_CAP:
                        log("endpoints: file cap reached at %s (%s), stopping scan of %s", seen_files, p, root)
                        break
                    seen_files += 1
                    if not p.is_file() or p.is_symlink():
                        continue
                    if p.suffix.lower() not in (".env", ".sh", ".service", ".timer", ".conf", ".json", ".yml", ".yaml", ".toml", ".md"):
                        if fname not in ("hc.env",):
                            continue
                    try:
                        st = p.stat()
                    except OSError:
                        continue
                    if st.st_size > 262144:
                        continue
                    try:
                        text = p.read_text(encoding="utf-8", errors="replace")
                    except OSError:
                        continue
                    for line in text.splitlines():
                        line = line.split("#", 1)[0]
                        for key in self._endpoint_keys(line):
                            rel = _rel_to_or_name(p, root)
                            if (rel, key) in seen:
                                continue
                            seen.add((rel, key))
                            self.add(
                                {
                                    "id": f"endpoint:{rel}:{key}",
                                    "class": "endpoint-key",
                                    "name": key,
                                    "source": f"scan {root}",
                                    "details": {
                                        "file": rel,
                                        "key": key,
                                    },
                                }
                            )
                if seen_files >= SCAN_FILE_CAP:
                    break

    def _endpoint_keys(self, line: str) -> list[str]:
        keys: list[str] = []
        # Match assignments like HC_URL=..., TELEGRAM_BOT_TOKEN=..., CF_API_TOKEN=...
        if "=" in line:
            key, _, _ = line.partition("=")
            key = key.strip()
            upper = key.upper()
            if any(upper.endswith(s) or (":" + s) in (":" + upper) for s in ENDPOINT_KEY_PATTERNS):
                if any(
                    host in upper
                    for host in ("HEALTH", "HC_", "TELEGRAM", "TG_", "CLOUDFLARE", "CF_", "API", "PING", "ENDPOINT")
                ):
                    keys.append(key)
            if any(
                host in upper
                for host in ("HEALTHCHECKS", "HEALTHCHECK", "HC_PING", "TELEGRAM", "TG_BOT", "CLOUDFLARE", "CF_API")
            ):
                if key not in keys:
                    keys.append(key)
        # Match JSON/YAML keys
        for m in re.finditer(r'"([^"]+)"\s*:', line):
            k = m.group(1)
            if any(p in k.upper() for p in ENDPOINT_KEY_PATTERNS):
                if any(host in k.upper() for host in ("HEALTH", "HC", "TELEGRAM", "CLOUDFLARE", "CF", "PING")):
                    if k not in keys:
                        keys.append(k)
        for m in re.finditer(r"(\w+)\s*:", line):
            k = m.group(1)
            if any(p in k.upper() for p in ENDPOINT_KEY_PATTERNS):
                if any(host in k.upper() for host in ("HEALTH", "HC", "TELEGRAM", "CLOUDFLARE", "CF", "PING")):
                    if k not in keys:
                        keys.append(k)
        return keys

    # -----------------------------------------------------------------------
    # storage
    # -----------------------------------------------------------------------
    def storage(self) -> None:
        rclone_conf = self.cfg.home / ".config" / "rclone" / "rclone.conf"
        if rclone_conf.is_file():
            try:
                cp = configparser.ConfigParser()
                cp.read(rclone_conf, encoding="utf-8")
            except (OSError, configparser.Error):
                cp = None
            if cp:
                for section in cp.sections():
                    stype = cp.get(section, "type", fallback="unknown")
                    self.add(
                        {
                            "id": f"storage:rclone:{section}",
                            "class": "storage-rclone",
                            "name": section,
                            "source": str(rclone_conf.relative_to(self.cfg.home)),
                            "details": {"type": stype},
                        }
                    )

        # Restic systemd unit pair is covered by the systemd enumerator.
        # We also record the restic state directory if it exists.
        restic_state = self.cfg.home / ".local" / "state" / "restic"
        if restic_state.is_dir():
            self.add(
                {
                    "id": f"storage:restic-state:{restic_state}",
                    "class": "storage-restic-state",
                    "name": str(restic_state.relative_to(self.cfg.home)),
                    "source": str(restic_state.relative_to(self.cfg.home)),
                }
            )

    # -----------------------------------------------------------------------
    # pi seats / providers
    # -----------------------------------------------------------------------
    def pi_seats(self) -> None:
        seat_caps = self.cfg.fleet_ops_repo / "config" / "seat-caps.json"
        entitled = self.cfg.fleet_ops_repo / "config" / "entitled-seats.json"

        for path, cls in ((seat_caps, "pi-seat"), (entitled, "pi-entitled")):
            if not path.is_file():
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            providers = data.get("providers") or data.get("seats") or {}
            if not isinstance(providers, dict):
                continue
            for provider, val in providers.items():
                if isinstance(val, dict):
                    models = val.get("models") or val.get("order") or []
                    for model in models:
                        self.add(
                            {
                                "id": f"pi-seat:{provider}/{model}",
                                "class": "pi-seat",
                                "name": f"{provider}/{model}",
                                "source": str(path.relative_to(self.cfg.fleet_ops_repo)),
                                "details": {"provider": provider, "model": model},
                            }
                        )
                self.add(
                    {
                        "id": f"pi-provider:{provider}",
                        "class": "pi-provider",
                        "name": provider,
                        "source": str(path.relative_to(self.cfg.fleet_ops_repo)),
                    }
                )

    # -----------------------------------------------------------------------
    # test suites and test-header claims
    # -----------------------------------------------------------------------
    def test_suites_and_claims(self) -> None:
        repo_roots: list[Path] = []

        # Fleet-ops itself
        if self.cfg.fleet_ops_repo.is_dir():
            repo_roots.append(self.cfg.fleet_ops_repo)

        # Enrolled product repos on disk
        enrolled_json = os.environ.get("FLEET_ASSET_CENSUS_ENROLLED_REPOS")
        if enrolled_json:
            try:
                enrolled = json.loads(enrolled_json)
            except json.JSONDecodeError:
                enrolled = []
        else:
            intake = self.cfg.fleet_ops_repo / "config" / "intake-repos.json"
            enrolled = _load_intake_repos(intake)

        for row in enrolled:
            if isinstance(row, dict) and "name" in row:
                name = row["name"]
            elif isinstance(row, str):
                name = row
            else:
                continue
            candidate = self.cfg.home / "workspaces" / "products" / name
            if candidate.is_dir():
                repo_roots.append(candidate)

        # Explicit repo roots from env/args
        extra = os.environ.get("FLEET_ASSET_CENSUS_REPO_ROOTS", "")
        for p in extra.split(":"):
            p = p.strip()
            if p and Path(p).is_dir():
                repo_roots.append(Path(p))

        for repo_root in repo_roots:
            self._scan_repo_tests(repo_root)

    def _scan_repo_tests(self, repo_root: Path) -> None:
        repo_name = repo_root.name
        tests_dir = repo_root / "tests"
        workflows_dir = repo_root / ".github" / "workflows"
        workflow_text = ""
        if workflows_dir.is_dir():
            try:
                for wf in sorted(workflows_dir.iterdir()):
                    if wf.is_file() and wf.suffix in (".yml", ".yaml"):
                        workflow_text += wf.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass

        test_patterns = ("*.test.sh", "*.test.py", "*_test.py", "test_*.py", "*.spec.*")
        if tests_dir.is_dir():
            for pat in test_patterns:
                for p in sorted(tests_dir.rglob(pat)):
                    if not p.is_file():
                        continue
                    self._record_test_suite(p, repo_name, repo_root, workflow_text)
        # Top-level test files too
        for pat in ("*.test.sh", "*.test.py", "*_test.py", "test_*.py"):
            for p in sorted(repo_root.glob(pat)):
                if not p.is_file():
                    continue
                self._record_test_suite(p, repo_name, repo_root, workflow_text)

    def _record_test_suite(self, p: Path, repo_name: str, repo_root: Path, workflow_text: str) -> None:
        rel = str(p.relative_to(repo_root))
        file_id = f"test-suite:{repo_name}:{rel}"
        guarded_by = []
        for wf_name in (rel, p.name, f"tests/{p.name}"):
            if wf_name in workflow_text:
                # Find which workflow file(s) reference it
                guarded_by.append(f".github/workflows (ref: {wf_name})")
                break
        self.add(
            {
                "id": file_id,
                "class": "test-suite",
                "name": rel,
                "source": f"{repo_name}",
                "details": {"repo": repo_name, "path": rel, "guarded_by": guarded_by},
            }
        )
        self._extract_test_claims(p, repo_name, repo_root, file_id)

    def _extract_test_claims(self, p: Path, repo_name: str, repo_root: Path, suite_id: str) -> None:
        rel = str(p.relative_to(repo_root))
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return
        # Gather the leading comment block
        comments: list[str] = []
        in_block = True
        for line in text.splitlines():
            stripped = line.strip()
            if p.suffix in (".py",):
                if stripped.startswith("#"):
                    comments.append(stripped.lstrip("#").strip())
                elif stripped.startswith('"""') or stripped.startswith("'''"):
                    # simplistic: stop at first docstring close; skip
                    break
                else:
                    break
            else:
                if stripped.startswith("#"):
                    comments.append(stripped.lstrip("#").strip())
                elif in_block and not stripped:
                    continue
                else:
                    break
            if stripped:
                in_block = False

        joined = "\n".join(comments)
        claims: list[str] = []
        # "does NOT exercise ..." style
        for m in re.finditer(
            r"(?:does\s+not|doesn't|doesnt|does NOT)\s+(?:exercise|test|cover|run)\s+([^\n.]+)",
            joined,
            re.I,
        ):
            claims.append(m.group(0))
        for m in re.finditer(r"(?:exercises?|tests?|covers?)\s+([^\n.]+)", joined, re.I):
            claims.append(m.group(0))
        for m in re.finditer(
            r"(?:not\s+(?:exercised|tested|covered)|no\s+(?:sign\-in|login|auth))[^\n.]*",
            joined,
            re.I,
        ):
            claims.append(m.group(0))

        for claim in claims:
            slug = re.sub(r"[^a-z0-9]+", "-", claim.lower()).strip("-")[:60]
            if not slug:
                continue
            self.add(
                {
                    "id": f"{suite_id}:claim:{slug}",
                    "class": "test-header-claim",
                    "name": claim[:120],
                    "source": f"{repo_name}:{rel}",
                    "details": {"repo": repo_name, "path": rel, "claim": claim},
                }
            )


def _load_intake_repos(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, dict):
        return []
    return data.get("repos") or []


# ---------------------------------------------------------------------------
# Guard map diff
# ---------------------------------------------------------------------------


def load_map(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("guard map root must be an object")
    return data


def validate_map(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if "version" not in data:
        errors.append("missing version")
    if not isinstance(data.get("classes"), dict):
        errors.append("classes must be an object")
    else:
        for cls, entry in data["classes"].items():
            if not isinstance(entry, dict):
                errors.append(f"classes[{cls}] must be an object")
                continue
            if not entry.get("guard"):
                errors.append(f"classes[{cls}] missing guard")
            if not entry.get("proof"):
                errors.append(f"classes[{cls}] missing proof")
    if not isinstance(data.get("assets"), list):
        errors.append("assets must be a list")
    else:
        for i, a in enumerate(data["assets"]):
            if not isinstance(a, dict):
                errors.append(f"assets[{i}] must be an object")
                continue
            if not a.get("id"):
                errors.append(f"assets[{i}] missing id")
            if not a.get("guard"):
                errors.append(f"assets[{i}] missing guard")
    return errors


def guard_for(asset: dict[str, Any], data: dict[str, Any]) -> dict[str, Any] | None:
    """Return the guard entry for an asset, or None if unguarded."""
    aid = str(asset.get("id", ""))
    aclass = str(asset.get("class", ""))
    for a in data.get("assets") or []:
        if a.get("id") == aid:
            return a
    classes = data.get("classes") or {}
    if aclass in classes:
        return classes[aclass]
    return None


def diff_census(
    report: dict[str, Any],
    map_data: dict[str, Any],
    previous: dict[str, Any] | None,
) -> dict[str, Any]:
    assets = report.get("assets", [])
    current_ids = {a["id"] for a in assets}
    previous_ids = {a["id"] for a in (previous.get("assets") or [])} if previous else set()

    unguarded: list[dict[str, Any]] = []
    new_assets: list[dict[str, Any]] = []
    stale_map: list[dict[str, Any]] = []
    covered = 0
    by_class: dict[str, int] = defaultdict(int)

    map_asset_ids = {a.get("id") for a in (map_data.get("assets") or [])}

    for a in assets:
        aclass = a.get("class", "unknown")
        by_class[aclass] = by_class.get(aclass, 0) + 1
        g = guard_for(a, map_data)
        if g is None:
            unguarded.append({**a, "proposed_guard": "", "signal": SIGNAL_FMT.format(id=a["id"])})
        else:
            covered += 1
            a["guard"] = g.get("guard")
            a["proof"] = g.get("proof")
            a["issue"] = g.get("issue")
        if a["id"] not in previous_ids and a["id"] not in map_asset_ids:
            new_assets.append(a)

    for a in map_data.get("assets") or []:
        if a.get("id") not in current_ids:
            stale_map.append(a)

    return {
        "version": VERSION,
        "generated_at": now_iso(),
        "map_version": map_data.get("version"),
        "asset_count": len(assets),
        "covered_count": covered,
        "unguarded_count": len(unguarded),
        "new_count": len(new_assets),
        "stale_map_count": len(stale_map),
        "unguarded": sorted(unguarded, key=lambda x: x["id"]),
        "new_assets": sorted(new_assets, key=lambda x: x["id"]),
        "stale_map": sorted(stale_map, key=lambda x: x.get("id", "")),
        "by_class": dict(by_class),
    }


# ---------------------------------------------------------------------------
# Issue rendering / filing
# ---------------------------------------------------------------------------


def issue_title(item: dict[str, Any]) -> str:
    short = item.get("name") or item.get("id") or "unknown"
    if len(short) > 70:
        short = short[:67] + "..."
    return f"unguarded asset: {short}"


def issue_body(item: dict[str, Any]) -> str:
    aid = item.get("id", "unknown")
    aclass = item.get("class", "unknown")
    source = item.get("source", "unknown")
    signal = item.get("signal") or SIGNAL_FMT.format(id=aid)
    return (
        "The asset census (fleet-ops#1149) found an asset with no guard mapping.\n\n"
        f"- asset id: `{aid}`\n"
        f"- class: `{aclass}`\n"
        f"- source: `{source}`\n"
        "- required: add a class guard in `config/asset-guard-map.json` "
        "or an explicit per-asset guard, plus a real enforcer (canary, "
        "workflow, systemd unit, or documented manual check).\n\n"
        f"{signal}\n"
    )


def file_unguarded_issues(cfg: Config, unguarded: list[dict[str, Any]], cap: int) -> int:
    if not cfg.file_issues or not unguarded:
        return 0
    if not shutil.which(cfg.gh):
        log("file-issues: gh not available, skipping")
        return 0
    if not Path(cfg.issue_file).is_file():
        log("file-issues: fleet-issue-file not found at %s, falling back to gh issue create", cfg.issue_file)
        issue_file = "gh"
    else:
        issue_file = cfg.issue_file

    filed = 0
    for item in unguarded:
        if filed >= cap:
            log("file-issues: cap reached (%s)", cap)
            break
        title = issue_title(item)
        body = issue_body(item)
        if cfg.dry_run:
            log("file-issues: dry-run would file: %s", title)
            filed += 1
            continue
        if issue_file == "gh":
            proc = subprocess.run(
                [
                    cfg.gh,
                    "issue",
                    "create",
                    "-R",
                    cfg.issue_repo,
                    "--title",
                    title,
                    "--body",
                    body,
                    "--label",
                    "agent-ready",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
        else:
            proc = subprocess.run(
                [
                    issue_file,
                    "file",
                    "-R",
                    cfg.issue_repo,
                    "--title",
                    title,
                    "--body",
                    body,
                    "--label",
                    "agent-ready",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
        if proc.returncode == 0:
            filed += 1
            log("file-issues: filed %s -> %s", item["id"], (proc.stdout or "").strip().split()[-1] if proc.stdout else "ok")
        else:
            log("file-issues: failed to file %s (rc=%s): %s", item["id"], proc.returncode, (proc.stderr or "")[:200])
    return filed


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


def prom_label(s: str) -> str:
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def write_metrics(path: Path, diff: dict[str, Any]) -> None:
    # Organ heartbeat (fleet-ops#1010 standing pattern, required by fleet-ops#1149
    # item 4): a fresh timestamp on every successful diff so absent() can fire
    # when the weekly census stops running. Written even when the diff finds
    # unguarded assets — a finding is a healthy run, not a dead organ.
    now_epoch = int(datetime.now(timezone.utc).timestamp())
    lines = [
        "# HELP fleet_asset_census_last_run_seconds Epoch seconds of the last successful asset-census diff. absent() fires when the weekly timer stops running.",
        "# TYPE fleet_asset_census_last_run_seconds gauge",
        f"fleet_asset_census_last_run_seconds {now_epoch}",
        "",
        "# HELP fleet_asset_census_total Total assets enumerated by class.",
        "# TYPE fleet_asset_census_total gauge",
    ]
    for cls, n in (diff.get("by_class") or {}).items():
        lines.append(f'fleet_asset_census_total{{class="{prom_label(cls)}"}} {n}')
    lines.extend(
        [
            "",
            "# HELP fleet_asset_census_unguarded_total Assets outside the guard map.",
            "# TYPE fleet_asset_census_unguarded_total gauge",
            f'fleet_asset_census_unguarded_total {diff.get("unguarded_count", 0)}',
            "",
            "# HELP fleet_asset_census_new_total Assets new since the previous census.",
            "# TYPE fleet_asset_census_new_total gauge",
            f'fleet_asset_census_new_total {diff.get("new_count", 0)}',
            "",
            "# HELP fleet_asset_census_stale_map_total Mapped assets no longer present.",
            "# TYPE fleet_asset_census_stale_map_total gauge",
            f'fleet_asset_census_stale_map_total {diff.get("stale_map_count", 0)}',
            "",
            "# HELP fleet_asset_census_covered_total Assets with a guard mapping.",
            "# TYPE fleet_asset_census_covered_total gauge",
            f'fleet_asset_census_covered_total {diff.get("covered_count", 0)}',
        ]
    )
    text = "\n".join(lines) + "\n"
    atomic_write(path, text)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def cmd_census(args: argparse.Namespace) -> int:
    cfg = Config(args)
    report = CensusTaker(cfg).run()
    if args.output_json:
        path = Path(args.output_json)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    else:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    cfg = Config(args)
    map_data = load_map(Path(args.map))
    errors = validate_map(map_data)
    if errors:
        for e in errors:
            log("validate-map: %s", e)
        return 2

    previous: dict[str, Any] | None = None
    if cfg.census_file.is_file():
        try:
            previous = json.loads(cfg.census_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            log("WARN: could not read previous census: %s", exc)

    report = CensusTaker(cfg).run()
    diff = diff_census(report, map_data, previous)

    # Save current census as the next previous.
    if not cfg.dry_run:
        cfg.state_dir.mkdir(parents=True, exist_ok=True)
        atomic_write(cfg.census_file, json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    if diff.get("metrics_file") is None:
        pass
    if args.metrics:
        write_metrics(Path(args.metrics), diff)
    elif not cfg.dry_run:
        write_metrics(cfg.metrics_file, diff)

    cap = int(map_data.get("auto_file_cap_per_tick", 5))
    if args.file_issues:
        file_unguarded_issues(cfg, diff.get("unguarded", []), cap)

    if args.output_json:
        Path(args.output_json).write_text(json.dumps(diff, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    else:
        print(json.dumps(diff, indent=2, ensure_ascii=False))

    return 1 if diff.get("unguarded_count", 0) > 0 else 0


def cmd_validate_map(args: argparse.Namespace) -> int:
    try:
        data = load_map(Path(args.map))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        log("FATAL: %s", exc)
        return 2
    errors = validate_map(data)
    if errors:
        for e in errors:
            log("validate-map: %s", e)
        return 1
    print(f"OK: map valid ({len(data.get('classes') or {})} classes, {len(data.get('assets') or [])} explicit assets)")
    return 0


def cmd_issue_title(args: argparse.Namespace) -> int:
    item = json.loads(args.json)
    sys.stdout.write(issue_title(item) + "\n")
    return 0


def cmd_issue_body(args: argparse.Namespace) -> int:
    item = json.loads(args.json)
    body = issue_body(item)
    sys.stdout.write(body)
    if not body.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_set_subscriptions(args: argparse.Namespace) -> int:
    cfg = Config(args)
    if cfg.skip_live or not shutil.which(cfg.gh):
        log("set-subscriptions: skip-live or gh missing")
        return 2
    # Enumerate and correct subscriptions; used by canary, but exposed for manual runs.
    taker = CensusTaker(cfg)
    # Trigger github repo enumeration, which will correct subscriptions if set_subscriptions is set.
    old = os.environ.get("FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS", "")
    os.environ["FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS"] = "0" if cfg.dry_run else "1"
    taker.github_repos()
    if old:
        os.environ["FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS"] = old
    else:
        os.environ.pop("FLEET_ASSET_CENSUS_SET_SUBSCRIPTIONS", None)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fleet-ops-repo", default=None, help="path to fleet-ops checkout")
    parser.add_argument("--state-dir", default=None, help="state directory")
    parser.add_argument("--map", default=None, help="guard map JSON path")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_census = sub.add_parser("census", help="enumerate live assets")
    p_census.add_argument("--output-json", default=None)
    p_census.set_defaults(func=cmd_census)

    p_diff = sub.add_parser("diff", help="diff census against guard map")
    p_diff.add_argument("--map", required=True)
    p_diff.add_argument("--output-json", default=None)
    p_diff.add_argument("--metrics", default=None)
    p_diff.add_argument("--file-issues", action="store_true")
    p_diff.add_argument("--dry-run", action="store_true")
    p_diff.set_defaults(func=cmd_diff)

    p_val = sub.add_parser("validate-map", help="validate guard map JSON")
    p_val.add_argument("--map", required=True)
    p_val.set_defaults(func=cmd_validate_map)

    p_title = sub.add_parser("issue-title", help="render auto-file title")
    p_title.add_argument("--json", required=True)
    p_title.set_defaults(func=cmd_issue_title)

    p_body = sub.add_parser("issue-body", help="render auto-file body")
    p_body.add_argument("--json", required=True)
    p_body.set_defaults(func=cmd_issue_body)

    p_sub = sub.add_parser("set-subscriptions", help="correct GitHub notification subscriptions")
    p_sub.add_argument("--dry-run", action="store_true")
    p_sub.set_defaults(func=cmd_set_subscriptions)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
