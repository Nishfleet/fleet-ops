#!/usr/bin/env python3
"""fleet-ops#7430: pins the active-learning labels table contract —
docs/jev-active-learning-labels.jsonl stays parseable, every row carries the
schema the benchmark doc names, jev_p stays inside the uncertain band the
queue comment selects on, the cohort marker keeps these rows separate from
the fixed bench7371 cohorts, and an abstention is null, never a false.
Run: python3 tests/jev-active-learning-labels.test.py
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / 'docs' / 'jev-active-learning-labels.jsonl'
FAILS = []

REQUIRED = ('ts', 'cohort', 'source_issue', 'site', 'ref', 'question',
            'question_type', 'jev_p', 'band_lo', 'band_hi', 'label',
            'label_reason', 'labelled_by', 'label_model', 'label_run',
            'labelled_at')


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


def main():
    check(TABLE.exists(), 'labels table exists at docs/jev-active-learning-labels.jsonl')
    if not TABLE.exists():
        sys.exit(1)
    rows = []
    for n, line in enumerate(TABLE.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception as exc:
            check(False, 'line %d parses as JSON (%s)' % (n, exc))
    check(len(rows) > 0, 'table holds at least one row (%d)' % len(rows))

    for n, r in enumerate(rows, 1):
        missing = [k for k in REQUIRED if k not in r]
        check(not missing, 'row %d carries the full schema (missing %s)' % (n, missing))
        check(r.get('cohort') == 'active-learning',
              'row %d cohort is active-learning, not a fixed benchmark cohort' % n)
        check(r.get('source_issue') == 'Nishfleet/fleet-ops#7430',
              'row %d names its source issue' % n)
        check(isinstance(r.get('jev_p'), (int, float))
              and not isinstance(r.get('jev_p'), bool)
              and 0.1 < r['jev_p'] < 0.9,
              'row %d jev_p inside the uncertain band 0.1<p<0.9 (got %r)' % (n, r.get('jev_p')))
        check(r.get('label') in (True, False, None),
              'row %d label is true/false or null-abstain (got %r)' % (n, r.get('label')))
        if r.get('label') is None:
            check('evidence' in (r.get('label_reason') or '')
                  or 'abstain' in (r.get('label_reason') or ''),
                  'row %d null label carries an abstention reason' % n)
        check(r.get('question_type') in ('boolean', 'choice', 'score'),
              'row %d question_type is a Jev question type' % n)
        check(isinstance(r.get('ref'), str) and len(r.get('ref') or '') > 0,
              'row %d carries a ref' % n)
        check(isinstance(r.get('label_model'), str) and '/' in (r.get('label_model') or ''),
              'row %d records the labelling model (got %r)' % (n, r.get('label_model')))

    sites = {r.get('site') for r in rows}
    check(all(isinstance(s, str) and s for s in sites),
          'every row names its site (%s)' % sorted(sites))
    dupes = len(rows) - len({(r.get('site'), r.get('ref'), r.get('question')) for r in rows})
    check(dupes == 0, 'no duplicate (site, ref, question) rows (%d dupes)' % dupes)

    if FAILS:
        print('FAILED: %d check(s)' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
