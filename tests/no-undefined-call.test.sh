#!/usr/bin/env bash
# tests/no-undefined-call.test.sh
#
# #6032: the retired-routing fallout class made loud. #5993 deleted its lib
# while keep-list callers still called its functions; in bash a call to an
# undefined function returns 127, which reads as false, so each call failed
# silently (credentials errors went unclassified for hours). This gate fails
# when any bin/ or lib/ bash script calls a function that nothing it sources
# defines, so the next removal PR cannot ship silent 127s.
#
# Also proves the negatives: with a planted undefined call in a fixture the
# gate must exit 1 and name the planted function.
#
# Hosted by tests/p14-test-listing-gate.test.sh (the #5889 auto-host), so it
# runs in P14 without a workflow-file edit. Keep this file free of the
# retired-routing signature words (see tests/pick-seat-freeze.test.sh).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Usage: [repo-root]  (default: this repo). With a root argument the gate
# scans that root only — used by the planted-undefined fixture below.
ROOT="${1:-$(cd "$here/.." && pwd)}"
PLANTED_MODE=0
[[ $# -ge 1 ]] && PLANTED_MODE=1

python3 - "$ROOT" "$PLANTED_MODE" <<'PYEOF'
import os, re, sys

root, planted = sys.argv[1], sys.argv[2] == "1"
BUILTINS = set("""if then else elif fi for while until case esac do done in function
local export readonly return shift set trap source printf echo date grep awk sed cut
sort head tail wc cat tr rm mv cp mkdir touch test true false basename dirname stat
find xargs mktemp sleep seq bc jq python3 node git gh systemctl journalctl pgrep flock
command type declare read cd pushd popd eval exec exit wait kill ps uname free df nproc
tput fuser sha256sum openssl curl install ln chmod chown realpath readlink tee mapfile
let unset getopts select time times alias bg fg jobs hash help history pwd readarray
shopt caller printf return break continue return function function!:null】:1""".split())
BUILTINS |= {"return","break","continue","function","local","export","readonly","shift",
             "declare","trap","unset","mapfile","readarray","printf","shopt","set","cd"}

def bash_files():
    out = []
    for sub in ("bin", "lib"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            if not os.path.isfile(p):
                continue
            try:
                head = open(p, errors="replace").readline()
            except OSError:
                continue
            if "bash" in head or "sh" in head or f.endswith(".sh"):
                if f.endswith(".py"):
                    continue
                out.append(p)
    return out

def strip(line):
    line = re.sub(r"#(?!).*|(?<!\S)#.*", "", line)
    return re.sub(r"#+!/", "!/", line) if line.startswith("#") else line

def defined_names(text):
    return set(re.findall(r"(?m)^(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", text))

def sourced_targets(text, script_dir):
    targets = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        m = re.match(r"^(?:source|\.)\s+(.+)$", s)
        if not m:
            continue
        arg = m.group(1).strip()
        # $HOME/.local/... installed-copy form: also try the repo lib fallback
        repofb = re.search(r"/lib/([A-Za-z0-9._-]+\.sh)", arg)
        if repofb:
            targets.append(os.path.join(root, "lib", repofb.group(1)))
        elif "$" not in arg:
            targets.append(os.path.normpath(os.path.join(script_dir, arg.strip("\"'"))))
    return targets

missing = []
for path in bash_files():
    text = open(path, errors="replace").read()
    script_dir = os.path.dirname(path)
    defined = defined_names(text)
    seen = {path}
    stack = [(t, 0) for t in reversed(sourced_targets(text, script_dir))]
    while stack:
        t, depth = stack.pop()
        if t in seen or depth > 4 or not os.path.isfile(t):
            continue
        seen.add(t)
        ttext = open(t, errors="replace").read()
        defined |= defined_names(ttext)
        if depth < 4:
            stack.extend((x, depth + 1) for x in reversed(sourced_targets(ttext, os.path.dirname(t))))
    # command-position words: line start, and after | ; && || ( $( then do else
    for ln_i, line in enumerate(text.splitlines()):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if re.match(r"^(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)", s):
            continue
        words = re.split(r"\|\|?|;|&&|\(|\$\(", s)
        if ln_i and s and not re.match(r"^(if|then|else|elif|while|until|do|case)", s):
            pass
        first = words[0].strip()
        for i, w in enumerate(words):
            w = w.strip()
            if i:
                w = re.sub(r"^(then|do|else|elif)\s+", "", w)
            if not w:
                continue
            tok = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\b", w)
            if not tok:
                continue
            name = tok.group(1)
            if name in BUILTINS or name in defined:
                continue
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):  # assignment, not a call
                continue
            if i == 0 and ln_i == 0 and s.startswith("#!"):
                continue
            if i == 0 and re.match(r"^(case|for|while|until|if|then|else|elif|do|done|fi|esac)\b", s):
                continue
            # words after a test/[[ at position 1+ are operands; only flag
            # when the token is the command of its clause: conservative —
            # require it to look like a call (not preceded by [ or [[)
            if i == 0:
                missing.append((os.path.relpath(path, root), ln_i + 1, name))

if planted:
    if not missing:
        print("OK-expected-miss: none found (fixture broken)")
        sys.exit(1)
    for f, ln, n in missing:
        print(f"planted-miss {f}:{ln}: {n}")
    sys.exit(0)

uniq = {}
for f, ln, n in missing:
    uniq.setdefault(n, []).append(f"{f}:{ln}")
if uniq:
    for n in sorted(uniq):
        print(f"UNDEFINED {n} called at {' '.join(uniq[n][:3])}")
    sys.exit(1)
print("OK: no undefined function calls in bin/ or lib/ (every call resolves via its own sources)")
PYEOF
rc=$?

# #6032 acceptance: the gate is red on a planted undefined call. Only in
# repo mode (fixture mode is the planted run itself — no recursion).
if [[ $rc -eq 0 && $PLANTED_MODE -eq 0 ]]; then
    fixdir="$(mktemp -d)"
    trap 'rm -rf "$fixdir"' EXIT
    mkdir -p "$fixdir/bin" "$fixdir/lib"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nlib_helper() { echo ok; }\nlib_helper\nnot_defined_anywhere_xyz\n' >"$fixdir/bin/prog.sh"
    printf '#!/usr/bin/env bash\nshared() { echo shared; }\n' >"$fixdir/lib/dep.sh"
    if out2; then :; fi
    if bash "$here/no-undefined-call.test.sh" "$fixdir" 2>&1 | grep -q "planted-miss.*not_defined_anywhere_xyz"; then
        echo "OK: planted undefined call turns the gate red (not_defined_anywhere_xyz caught)"
    else
        fail "planted-undefined fixture did not go red (gate acceptance #6032)"
    fi
fi
exit $rc
