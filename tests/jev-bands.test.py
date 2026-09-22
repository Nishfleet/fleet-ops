#!/usr/bin/env python3
"""fleet-ops#7439: config/jev-bands.json is the one act-threshold table —
every jev site helper reads its band edges from it and carries no local
threshold constants. This test pins the contract:

1. The table parses, has a top-level "sites" object, and every row carries
   numeric act_hi/review_lo in [0,1] with act_hi >= review_lo.
2. The table covers exactly the real site set — no site missing, no
   phantom row for a site that does not exist.
3. Every site literal emitted by a consumer has a row, and every row's
   site name appears in at least one consumer file.
4. No consumer re-embeds a local band constant (0.1/0.5/0.9 band edges).
5. docs/jev-bands.md documents every site row.

Run: python3 tests/jev-bands.test.py
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / 'config' / 'jev-bands.json'
DOC = ROOT / 'docs' / 'jev-bands.md'
CONSUMERS = [
    ROOT / 'bin' / 'am-executor-claim',
    ROOT / 'lib' / 'seat_fault.py',
    ROOT / 'prompts' / 'alert-repair.md',
    ROOT / 'prompts' / 'daily-digest.md',
    ROOT / 'prompts' / 'intake.md',
    ROOT / 'prompts' / 'scout.md',
    ROOT / 'prompts' / 'worker.md',
]
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


# The complete set of real jev sites. A site earns a row only when a
# consumer file emits a JSONL row under that site name (SITE constant,
# site= literal, or a parameterized argv like claim-check-%s /
# second-opinion). Adding or renaming a site updates BOTH sides here.
EXPECTED = {
    'alert-dispatch', 'alert-repair', 'alert-triage', 'auto-revert',
    'claim-check-pr', 'claim-check-report', 'dependency-pr-arm',
    'flaky-test-quarantine', 'gha-stuck-run-watch', 'hermes-digest',
    'intake-repair-seatfault', 'intake-seat-smoke', 'merge-queue-batches', 'merge-queue-enqueue',
    'reviewer-needs-review', 'scout', 'second-opinion',
    'second-opinion-reserved', 'worker-context',
}

# Patterns that name a site literal in a consumer file.
SITE_PATTERNS = [
    re.compile(r"SITE\s*=\s*'([a-z0-9-]+)'"),
    re.compile(r"site='([a-z0-9-]+)'"),
    re.compile(r'site="([a-z0-9-]+)"'),
    re.compile(r"'site':\s*'([a-z0-9-]+)'"),
    re.compile(r'site:"([a-z0-9-]+)"'),
]

# Local band-constant shapes that must not reappear in a consumer.
LOCAL_CONST_PATTERNS = [
    (re.compile(r"band_env\('(?:LO|HI)',\s*0\.[0-9]"), 'band_env literal default'),
    (re.compile(r'\bBANDS\s*=\s*\('), 'BANDS tuple constant'),
    (re.compile(r'\bDEFAULT_THRESHOLD\s*=\s*0\.'), 'DEFAULT_THRESHOLD constant'),
    (re.compile(r'\bp\s*>=?\s*0\.[0-9]'), 'p>=constant comparison'),
    (re.compile(r'\bp\s*<=?\s*0\.[0-9]'), 'p<=constant comparison'),
]


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def main():
    # 1. Table parses and every row is schema-valid.
    try:
        table = json.loads(TABLE.read_text())
    except Exception as exc:
        check(False, 'config/jev-bands.json parses (%s)' % exc)
        sys.exit(1)
    sites = table.get('sites')
    check(isinstance(sites, dict), 'top-level "sites" object present')
    if not isinstance(sites, dict):
        print('FAILED: no sites object', file=sys.stderr)
        sys.exit(1)

    for name, entry in sorted(sites.items()):
        check(isinstance(entry, dict), '%s: row is an object' % name)
        hi, lo = entry.get('act_hi'), entry.get('review_lo')
        check(is_num(hi) and 0 <= hi <= 1, '%s: act_hi numeric in [0,1]' % name)
        check(is_num(lo) and 0 <= lo <= 1, '%s: review_lo numeric in [0,1]' % name)
        if is_num(hi) and is_num(lo):
            check(hi >= lo, '%s: act_hi >= review_lo' % name)
        sens = entry.get('sensitivity')
        if sens is not None:
            check(isinstance(sens, list)
                  and all(is_num(x) and 0 <= x <= 1 for x in sens),
                  '%s: sensitivity is a list of numbers in [0,1]' % name)

    # 2. The table covers exactly the real site set.
    check(set(sites) == EXPECTED,
          'table covers exactly the real site set (extra=%s missing=%s)'
          % (sorted(set(sites) - EXPECTED), sorted(EXPECTED - set(sites))))

    # 3. Every site literal emitted by a consumer has a row, and every row
    #    names a site that a consumer actually emits.
    emitted = set()
    texts = {}
    for path in CONSUMERS:
        text = path.read_text()
        texts[path.name] = text
        for pat in SITE_PATTERNS:
            emitted.update(pat.findall(text))
    # Parameterized sites: claim-check-%s argv values and the second-opinion
    # argv sites are named in worker.md prose.
    for name in ('claim-check-pr', 'claim-check-report',
                 'second-opinion', 'second-opinion-reserved',
                 'reviewer-needs-review'):
        check(name in texts['worker.md'],
              'worker.md names parameterized site %s' % name)
    emitted.update({'claim-check-pr', 'claim-check-report',
                    'second-opinion', 'second-opinion-reserved',
                    'reviewer-needs-review'})
    check(emitted <= set(sites),
          'every emitted site literal has a table row (uncovered=%s)'
          % sorted(emitted - set(sites)))
    for name in sorted(sites):
        check(any(name in t for t in texts.values()),
              'table row %s names a site a consumer emits' % name)

    # 4. No consumer re-embeds a local band constant.
    for path in CONSUMERS:
        text = texts[path.name]
        for pat, label in LOCAL_CONST_PATTERNS:
            m = pat.search(text)
            check(m is None,
                  '%s: no %s%s' % (path.name, label,
                                   ' (found %r)' % m.group(0) if m else ''))

    # 5. docs/jev-bands.md documents every site row.
    doc = DOC.read_text()
    for name in sorted(sites):
        check(name in doc, 'docs/jev-bands.md documents %s' % name)

    if FAILS:
        print('FAILED: %d checks' % len(FAILS), file=sys.stderr)
        sys.exit(1)
    print('PASS: all checks')


if __name__ == '__main__':
    main()
