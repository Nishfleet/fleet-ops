#!/usr/bin/env python3
"""Inventory retained pi-issue-run journal records for #7444 (offline only).

Input: journalctl --user -t pi-issue-run -o json output saved to a file.
Output: one JSON object per exit, including successful exits for denominators.
These are wrapper observations, NOT classified deaths or per-seat run counts.
No network calls, session text export, live writes, or reclaim changes.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re


MARK = re.compile(r'pi-issue-run: (\S+) phase=(start|exit)(?: rc=(\d+) reason=(\S+))?$')


def epoch(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def join_journal(rows):
    starts, runs, seen = {}, [], set()
    for row in sorted(rows, key=lambda r: int(r['__REALTIME_TIMESTAMP'])):
        match = MARK.fullmatch(row.get('MESSAGE', ''))
        if not match:
            continue
        # A saved journal can contain duplicate rows after concatenating pages.
        identity = row.get('__CURSOR') or (
            row.get('_BOOT_ID'), row['__REALTIME_TIMESTAMP'], row['MESSAGE'])
        if identity in seen:
            continue
        seen.add(identity)
        unit, phase, rc, reason = match.groups()
        # systemd-cat has a fresh PID per message. Exit records may also lack
        # an invocation ID. A unit cannot have concurrent systemd activations.
        key = (unit, row.get('_BOOT_ID'))
        when = int(row['__REALTIME_TIMESTAMP']) / 1e6
        if phase == 'start':
            starts.setdefault(key, []).append(when)
            continue
        candidates = starts.pop(key, [])
        # Missing exits can leave multiple starts. Do not invent a pairing.
        start = candidates[0] if len(candidates) == 1 else None
        candidate = None if rc is None or reason == 'unknown' else (
            rc != '0' or reason == 'infra-death-requeue')
        runs.append({'unit': unit, 'start': start, 'end': when,
                     'rc': int(rc) if rc is not None else None, 'reason': reason,
                     'death_candidate': candidate,
                     'join_status': 'paired' if start is not None else (
                         'ambiguous_starts' if candidates else 'missing_start'),
                     'journal_ref': row.get('__CURSOR') or f'{unit}@{row["__REALTIME_TIMESTAMP"]}',
                     'elapsed_s': when - start if start is not None else None})
    return runs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--journal', type=Path, required=True)
    parser.add_argument('--since', help='Inclusive ISO exit timestamp')
    parser.add_argument('--until', help='Exclusive ISO exit timestamp')
    args = parser.parse_args()
    with args.journal.open() as source:
        rows = [json.loads(line) for line in source if line.strip()]
    since = epoch(args.since) if args.since else float('-inf')
    until = epoch(args.until) if args.until else float('inf')
    if until <= since:
        parser.error('--until must be later than --since')
    for run in join_journal(rows):
        if since <= run['end'] < until:
            print(json.dumps(run, allow_nan=False))


if __name__ == '__main__':
    main()
