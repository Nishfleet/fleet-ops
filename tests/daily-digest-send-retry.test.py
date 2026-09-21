#!/usr/bin/env python3
# fleet-ops#7635: the daily-digest send must survive the transient Telegram
# timeout that lost the 2026-09-18 digest. The prompt now ships a bounded
# retry loop (3 attempts, stop on "ok":true). These are content assertions on
# prompts/daily-digest.md plus functional runs of the extracted send block
# with a stubbed curl; no network and no credentials are involved.
#
# The functional drivers run under `set -euo pipefail`, so a conditional that
# fails out of the loop (the review finding on the first push) aborts the
# block and the case fails — the hard-down path must still print and tee its
# error.
#
# Run: python3 tests/daily-digest-send-retry.test.py
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = os.path.join(ROOT, 'prompts', 'daily-digest.md')
failures = []


def check(cond, msg):
    if cond:
        print('ok: %s' % msg)
    else:
        failures.append(msg)
        print('FAIL: %s' % msg)


def extract_block():
    lines = open(PROMPT).read().splitlines()
    send = next(i for i, l in enumerate(lines) if l.startswith('## Send —'))
    rest = lines[send:]
    start = next(i for i, l in enumerate(rest) if l == '```bash')
    end = next(i for i, l in enumerate(rest[start + 1:]) if l == '```')
    return rest[start + 1:start + 1 + end]


def run_case(tmp, block_path, case):
    counter = os.path.join(tmp, 'counter-%s' % case)
    open(counter, 'w').write('0')
    teecap = os.path.join(tmp, 'teecap-%s.json' % case)
    if os.path.exists(teecap):
        os.unlink(teecap)
    driver = os.path.join(tmp, 'driver-%s.sh' % case)
    with open(driver, 'w') as f:
        f.write(
            'set -euo pipefail\n'
            'counter=%s\n'
            'teecap=%s\n'
            'curl() {\n'
            '  c=$(cat "$counter"); c=$((c+1)); echo "$c" > "$counter"\n'
            '  case %s in\n'
            '    fail-fail-ok) if [ "$c" -lt 3 ]; then printf \'{"ok":false,"description":"Timed out"}\'; '
            'else printf \'{"ok":true,"result":{"message_id":42}}\'; fi ;;\n'
            '    ok-first) printf \'{"ok":true,"result":{"message_id":43}}\' ;;\n'
            '    hard-down) printf \'{"ok":false,"description":"Bad Request"}\' ;;\n'
            '  esac\n'
            '}\n'
            'sleep() { :; }\n'
            'tee() { c=$(cat); printf \'%%s\\n\' "$c" >> "$teecap"; printf \'%%s\\n\' "$c"; }\n'
            'body="test digest"; TELEGRAM_BOT_TOKEN=stub; TELEGRAM_CHAT_ID=stub\n'
            '. %s\n' % (counter, teecap, case, block_path))
    r = subprocess.run(['bash', driver], capture_output=True, text=True, timeout=60)
    calls = int(open(counter).read().strip() or '0')
    teed = open(teecap).read() if os.path.exists(teecap) else ''
    return r, calls, teed


def main():
    block = extract_block()

    # 1. The send block carries the retry loop and its bounds.
    joined = '\n'.join(block)
    check(any('for attempt in 1 2 3' in l for l in block), 'retry loop 1 2 3 present')
    check(any('grep' in l and '"ok":true' in l for l in block), 'ok:true break present')
    check(any(l.strip().startswith('if printf') and 'grep -q' in l for l in block),
          'ok-break is an if-form, safe under set -e')
    check(any('sleep 5' in l for l in block), 'inter-attempt pause present')
    check(any(l.strip().startswith('if [') and 'sleep 5' in l for l in block),
          'pause is an if-form, safe under set -e')
    check(not any('&& break' in l or '&& sleep 5' in l for l in block),
          'no && conditional left to fail out of a set -e shell')
    check(any('tee /tmp/daily-digest-send.json' in l for l in block),
          'journal proof tee present')
    check(any('--max-time 20' in l for l in block), 'per-attempt curl timeout present')
    check(any('${TELEGRAM_BOT_TOKEN}' in l for l in block),
          'token comes from the env var, not a literal')
    check(not re.search(r'\d{8,}:AA[A-Za-z0-9_-]{20,}', joined),
          'no literal bot token in the block')

    tmp = tempfile.mkdtemp(prefix='daily-digest-send-')
    try:
        block_path = os.path.join(tmp, 'send-block.sh')
        open(block_path, 'w').write(joined + '\n')

        # 2. Functional run: fails twice, delivers on attempt 3.
        r, calls, teed = run_case(tmp, block_path, 'fail-fail-ok')
        check(r.returncode == 0, 'fail-fail-ok: block ran clean under set -e (rc=%d)' % r.returncode)
        check(calls == 3, 'fail-fail-ok: exactly 3 send attempts (got %d)' % calls)
        check('"ok":true' in r.stdout, 'fail-fail-ok: ok:true proof printed')
        check('"ok":true' in teed, 'fail-fail-ok: delivery proof reached the tee')
        check(r.stderr.count('not ok') == 2,
              'fail-fail-ok: 2 failure lines on stderr (got %d)' % r.stderr.count('not ok'))

        # 3. Functional run: delivered on attempt 1, no extra send, no noise.
        r, calls, teed = run_case(tmp, block_path, 'ok-first')
        check(r.returncode == 0, 'ok-first: block ran clean under set -e (rc=%d)' % r.returncode)
        check(calls == 1, 'ok-first: healthy path sends exactly once (got %d)' % calls)
        check('"ok":true' in teed, 'ok-first: delivery proof reached the tee')
        check(r.stderr.strip() == '', 'ok-first: no failure noise on stderr')

        # 4. Functional run: Telegram hard-down — capped, no false ok, and the
        #    full error still prints and reaches the tee even under set -e
        #    (the case the retry exists for must not lose its own error output).
        r, calls, teed = run_case(tmp, block_path, 'hard-down')
        check(r.returncode == 0, 'hard-down: block ran clean under set -e (rc=%d)' % r.returncode)
        check(calls == 3, 'hard-down: capped at 3 attempts (got %d)' % calls)
        check('"ok":true' not in r.stdout, 'hard-down: no false ok:true printed')
        check(r.stderr.count('not ok') == 3,
              'hard-down: 3 failure lines on stderr (got %d)' % r.stderr.count('not ok'))
        check('Bad Request' in teed and 'Bad Request' in r.stdout,
              'hard-down: full error response still reaches stdout and the tee')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 5. Prompt carries the precedent note tying the loop to the 2026-09-18
    #    loss and the duplicate-over-lost tradeoff.
    prompt = open(PROMPT).read()
    check('fleet-ops#7635' in prompt, 'precedent note (fleet-ops#7635) present')
    check('duplicate — a repeated digest is accepted over a lost one' in prompt,
          'duplicate-over-lost tradeoff stated')
    check('Never run the loop a second time' in prompt, 'no-second-loop guard present')

    if failures:
        print('%d FAILURES' % len(failures))
        return 1
    print('all daily-digest-send-retry cases passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
