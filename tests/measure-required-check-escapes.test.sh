#!/usr/bin/env bash
# Synthetic unit cases based on the timestamp shape of fleet-ops#7348.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
[[ -f "$root/lib/required-check-escapes.sh" ]] || { echo 'FAIL: missing required-check detector'; exit 1; }
cat > "$scratch/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
endpoint = sys.argv[2]
case = os.environ.get('CASE', 'escape')
if case == 'api-error':
    print('HTTP 403: test denied', file=sys.stderr)
    sys.exit(1)
if '/branches/' in endpoint:
    print(json.dumps({'protection': {'enabled': True, 'required_status_checks': {
        'enforcement_level': 'everyone' if case == 'admins-on' else 'non_admins',
        'contexts': ['gate-integrity / gate-integrity'],
        'checks': [{'context': 'gate-integrity / gate-integrity', 'app_id': 15368}]}}}))
elif '/pulls?' in endpoint:
    print(json.dumps([{'number': 7348, 'merged_at': '2026-09-17T11:46:46Z',
                      'updated_at': '2026-09-17T12:00:00Z',
                      'head': {'sha': '83d9bdf0e1d2bc720a096aee2cc48bb91b8567e0'},
                      'base': {'ref': 'main'}}]))
elif '/check-runs?' in endpoint:
    row = {'id': 1, 'name': 'gate-integrity / gate-integrity', 'app': {'id': 15368},
           'started_at': '2026-09-17T11:46:18Z', 'completed_at': '2026-09-17T11:46:21Z',
           'status': 'completed', 'conclusion': 'failure'}
    if case == 'late': row['completed_at'] = '2026-09-17T11:47:00Z'
    if case == 'cancelled': row['conclusion'] = 'cancelled'
    if case == 'optional': row['name'] = 'optional'
    if case == 'wrong-app': row['app']['id'] = 9
    rows = [row]
    if case in ('rerun-green', 'rerun-late', 'rerun-pending'):
        rows.append(dict(row, id=2, started_at='2026-09-17T11:46:50Z' if case == 'rerun-late' else '2026-09-17T11:46:30Z',
                         completed_at='2026-09-17T11:46:40Z' if case == 'rerun-green' else '2026-09-17T11:47:00Z',
                         conclusion='success' if case != 'rerun-pending' else None,
                         status='completed' if case != 'rerun-pending' else 'in_progress'))
    print(json.dumps([{'check_runs': rows}]))
elif '/statuses?' in endpoint:
    print('[[]]')
else:
    raise SystemExit('unexpected endpoint: ' + endpoint)
PY
chmod +x "$scratch/gh"
export PATH="$scratch:$PATH" REQUIRED_CHECK_ESCAPES_NOW=2026-09-17T18:05:00Z
# shellcheck disable=SC1091
source "$root/lib/required-check-escapes.sh"
for case in escape cancelled admins-on rerun-late; do
    out=$(CASE="$case" required_check_escapes_line Nishfleet/fleet-ops)
    grep -Fq 'gate-escapes-24h: 1' <<< "$out"
    grep -Fq 'LOUD required-check-escape: Nishfleet/fleet-ops#7348' <<< "$out"
    grep -Fq 'gap_seconds=25' <<< "$out"
done
for case in late optional wrong-app rerun-green rerun-pending; do
    out=$(CASE="$case" required_check_escapes_line Nishfleet/fleet-ops)
    grep -Fq 'gate-escapes-24h: 0' <<< "$out"
    if grep -q '^LOUD required-check-escape:' <<< "$out"; then exit 1; fi
done
out=$(CASE=api-error required_check_escapes_line Nishfleet/fleet-ops)
grep -q 'UNAVAILABLE' <<< "$out"
grep -q 'LOUD.*failed' <<< "$out"
grep -q 'required_check_escapes_line' "$root/measure.sh"
echo 'PASS: required-check escapes, timing, reruns, app identity, API failure and wiring'
