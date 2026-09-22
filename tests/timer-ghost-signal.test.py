#!/usr/bin/env python3
"""fleet-ops#7711 — an emitter must never raise a timer-inventory signal
keyed on a unit that does not exist.

The issue's acceptance bullet: a test under tests/ asserts the emitter
never produces a timer-no-next or timer-manifest signal whose unit key
fails `systemctl --user cat <unit>` — ghost units are skipped, not
alarmed.

Both emitters are deleted — bin/fleet-heartbeat-tier1's TIMER-NO-NEXT
timer-arm pass went out in ca33faa96 and
bin/fleet-timer-manifest-drift-canary's TIMER-MANIFEST-DRIFT went out in
ada87b543 — so the emitter set is empty today and every check holds
vacuously. The test is the regression gate: if a timer-inventory alarm
ever returns it must resolve unit names against `systemctl --user
list-unit-files --type=timer` or `systemctl cat` before alarming, and no
emitter may name a literal unit that does not resolve on this host.

Run: python3 tests/timer-ghost-signal.test.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAILS = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        FAILS.append(msg)
        print('FAIL: %s' % msg, file=sys.stderr)


# Files carrying the retired signal names. Historical reports under docs/,
# fixtures under tests/, generated corpora under .fleet/ and credentials/
# legitimately quote them and are not emitters.
SIGNAL_RE = re.compile(r'timer-no-next|TIMER-NO-NEXT|timer-manifest|TIMER-MANIFEST')
SCAN_DIRS = ('bin', 'libexec', 'systemd', 'template', 'config', 'prompts', 'etc', '.github')
SCAN_FILES = ('AGENTS.md', 'README.md', 'MANIFEST')

# The issue's required behaviour: an emitting pass must resolve timer
# names against the real unit list and skip-with-log the ones that do not
# exist, so ghost names leave the signal stream.
RESOLVE_RE = re.compile(r'list-unit-files|systemctl\b[^\n]*\bcat\b')

# Literal unit keys an emitter could alarm on. '@' stays in the class so
# an instance name (pi-intake@0509.timer) is checked whole — harvesting
# the post-'@' substring is how the reconciler minted the ghost keys
# 0509.timer / fleet-ops.timer this issue is about.
UNIT_RE = re.compile(r'[A-Za-z0-9_@][A-Za-z0-9_@.-]*\.timer')


def _read(p):
    try:
        return p.read_text(errors='replace')
    except OSError:
        return ''


def emitters():
    found = []
    for d in SCAN_DIRS:
        base = ROOT / d
        if base.is_dir():
            found.extend(p for p in sorted(base.rglob('*'))
                         if p.is_file() and SIGNAL_RE.search(_read(p)))
    found.extend(ROOT / name for name in SCAN_FILES
                 if (ROOT / name).is_file()
                 and SIGNAL_RE.search(_read(ROOT / name)))
    return found


def _cat(unit):
    try:
        return subprocess.run(
            ['systemctl', '--user', 'cat', unit],
            capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    files = emitters()
    names = ', '.join(str(p.relative_to(ROOT)) for p in files) or 'none'
    check(True, 'emitter scan: %d file(s) carry timer-no-next/'
          'timer-manifest signal names (%s)' % (len(files), names))

    bus = _cat('systemd-tmpfiles-clean.timer')
    if not bus:
        print('ok: no user systemd bus — literal unit-key resolution '
              'skipped; the resolve-before-alarm check still applies')

    for p in files:
        rel = p.relative_to(ROOT)
        text = _read(p)
        check(RESOLVE_RE.search(text) is not None,
              '%s resolves unit names against systemctl before emitting '
              'timer-inventory signals' % rel)
        if not bus:
            continue
        for u in sorted(set(UNIT_RE.findall(text))):
            if u.endswith('@.timer'):
                continue  # unit templates need an instance; not cat-able
            check(_cat(u), '%s names %s, which resolves via '
                  'systemctl --user cat (not a ghost unit)' % (rel, u))

    if FAILS:
        print('FAIL: timer-ghost-signal (%d failed check(s))' % len(FAILS),
              file=sys.stderr)
        return 1
    print('PASS: timer-ghost-signal')
    return 0


if __name__ == '__main__':
    sys.exit(main())
