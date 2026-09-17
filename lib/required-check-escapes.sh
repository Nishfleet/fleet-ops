# shellcheck shell=bash
# Extends measure.sh's existing gate-escapes probe (#7501), no new timer.
# REST branch metadata exposes required contexts without Administration scope.
# REQUIRED_CHECK_ESCAPES_NOW and REQUIRED_CHECK_ESCAPES_DAYS support replay.
required_check_escapes_line() {
    python3 - "${REQUIRED_CHECK_ESCAPES_NOW:-$(date -u +%FT%TZ)}" \
        "${REQUIRED_CHECK_ESCAPES_DAYS:-1}" "$@" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timedelta


def timestamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def api(endpoint, paginate=False):
    args = ['gh', 'api', endpoint]
    if paginate:
        args += ['--paginate', '--slurp']
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'gh api {endpoint} failed: {result.stderr.strip()[:200]}')
    return json.loads(result.stdout)


def required_failures(pr, checks, statuses, requirements):
    merged = timestamp(pr['merged_at'])
    failures = []
    for requirement in requirements:
        context, app_id = requirement['context'], requirement.get('app_id')
        # Check runs and commit statuses are separate required sources. If both
        # exist with the same name GitHub requires both, so do not combine them.
        sources = [
            [(c['started_at'], c['completed_at'], c.get('conclusion'), c['id'])
             for c in checks if c['name'] == context
             and (app_id in (None, -1) or c['app']['id'] == app_id)
             and c.get('started_at')],
            [(c['created_at'], c['created_at'], c['state'], c['id'])
             for c in statuses if c['context'] == context],
        ]
        for rows in sources:
            before = [r for r in rows if timestamp(r[0]) <= merged]
            if not before:
                continue
            # Latest attempt started before merge wins. A later rerun cannot
            # erase an escape; a rerun pending at merge is not a red verdict.
            latest = max(before, key=lambda r: (timestamp(r[0]), r[3]))
            _, completed, conclusion, _ = latest
            if (conclusion not in ('failure', 'cancelled') or not completed
                    or timestamp(completed) > merged):
                continue
            failures.append((context, conclusion, int((merged - timestamp(completed)).total_seconds())))
    return failures


now = timestamp(sys.argv[1])
days = int(sys.argv[2])
cutoff = now - timedelta(days=days)
total = 0
unavailable = False
for repo in sys.argv[3:]:
    if repo not in ('Nishfleet/fleet-ops', 'Nishfleet/0509'):
        continue
    count = 0
    scanned = 0
    try:
        branch = api(f'repos/{repo}/branches/main')
        protection = branch.get('protection')
        if not protection or not protection.get('enabled'):
            raise RuntimeError('required-check policy unavailable or branch unprotected')
        policy = protection['required_status_checks']
        requirements = {c['context']: c for c in policy.get('checks', [])}
        for context in policy['contexts']:
            requirements.setdefault(context, {'context': context})
        enforcement = policy.get('enforcement_level', 'unknown')
        # This is observed policy, not a claim about historical configuration
        # or the merger's identity. Historical escapes need audit confirmation.
        for page in range(1, 10001):
            prs = api(f'repos/{repo}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100&page={page}')
            for pr in prs:
                if not pr.get('merged_at') or not cutoff <= timestamp(pr['merged_at']) <= now:
                    continue
                scanned += 1
                sha = pr['head']['sha']
                checks = [c for p in api(f'repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100', True)
                          for c in p['check_runs']]
                statuses = [c for p in api(f'repos/{repo}/commits/{sha}/statuses?per_page=100', True) for c in p]
                failures = required_failures(pr, checks, statuses, requirements.values())
                if failures:
                    count += 1
                for context, conclusion, gap in failures:
                    print(f'LOUD required-check-escape: {repo}#{pr["number"]} '
                          f'head={sha} check={json.dumps(context)} verdict={conclusion} '
                          f'gap_seconds={gap} merged_at={pr["merged_at"]} '
                          f'enforcement_now={enforcement} '
                          f'admin_bypass={"possible" if enforcement == "non_admins" else "unconfirmed"} '
                          'policy_at_merge=unverified')
            if len(prs) < 100 or timestamp(prs[-1]['updated_at']) < cutoff:
                break
        else:
            raise RuntimeError('PR pagination limit reached')
        total += count
        print(f'gate-escapes-{days * 24}h {repo.split("/")[-1]}: {count} '
              f'scanned={scanned} cutoff={cutoff.isoformat()} observed_at={now.isoformat()}')
    except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
        unavailable = True
        print(f'LOUD required-check-escapes: {repo} failed: {exc}')
        print(f'gate-escapes-{days * 24}h {repo.split("/")[-1]}: UNAVAILABLE:gh-error')
print(f'gate-escapes-{days * 24}h: {"UNAVAILABLE:gh-error" if unavailable else total}')
PY
}
