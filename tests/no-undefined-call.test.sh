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
shopt caller return break continue""".split())
# jq builtin language (the fleet one-liner jq programs are single-quoted
# strings whose clause-parts scan as bare calls) + awk builtins with
# lowercase names (NR/NF/etc are ALL-CAPS, skipped by the constant rule)
BUILTINS |= {"to_entries", "from_entries", "group_by", "sort_by", "ascii_downcase",
             "ascii_upcase", "with_entries", "map_values", "map", "select", "keys",
             "keys_unsorted", "add", "any", "all", "flatten", "unique", "unique_by",
             "min_by", "max_by", "tonumber", "tostring", "tojson", "fromjson", "test",
             "capture", "match", "scan", "split", "join", "ltrimstr", "rtrimstr",
             "startswith", "endswith", "gsub", "recurse", "paths", "getpath",
             "setpath", "delpaths", "del", "input", "inputs", "env", "error",
             "range", "limit", "first", "last", "until", "reduce", "splits",
             "combinations", "leaf_paths", "min", "max", "floor", "ceil", "round",
             "fabs", "sqrt", "pow", "log", "exp", "length", "utf8bytelength",
             "explode", "implode", "ascii", "tostream", "fromstream",
             "truncate_stream", "isnan", "isinfinite", "halt", "halt_error", "debug",
             # awk: the lowercase builtins (uppercase specials are ALL-CAPS-skipped)
             "gsub", "substr", "index", "split", "print", "printf", "sprintf",
             "getline", "close", "sin", "cos", "atan2", "exp", "sqrt", "int",
             "rand", "srand", "compl", "lshift", "rshift", "xor", "strtonum",
             "todate", "strftime", "systime", "mktime", "reset"}
BUILTINS |= {"[", "]]", "coproc", "function", "select"}

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

def defined_names(text):
    # `name() {` / `function name()` / 0-arg python `def f():` — the extra
    # accepted forms only ever remove noise; the planted fixture (a bare
    # call of a name defined nowhere) still goes red, which is the acceptance.
    return set(re.findall(r"(?m)^\s*(?:(?:function|def)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)", text))

# variable/assignment targets: `local -a arr`, `local a b=2 c`, `x=1`, so a
# variable used at clause-head (arithmetic, ${x} word) is not flagged.Vars are
# not functions, but adding them only masks noise; the fixture stays red.
ASSIGN = re.compile(r"(?m)^\s*(?:local|declare|export|readonly|printf[ \t]+-v[ \t]+|read[ \t]+-r?[ \t]+)?"
                    r"([A-Za-z_][A-Za-z0-9_]*)([+]?=|\s|$)")

def assigned_names(text):
    out = set()
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^(?:local|declare|export|readonly)\s+(.+)$", s)
        if m:
            for tok in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1).split("#")[0]):
                out.add(tok)
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)[+]?=", s)
        if m:
            out.add(m.group(1))
    return out

SH = re.compile(r"([A-Za-z0-9._-]+\.sh)")


def sourced_targets(text, script_dir, root):
    targets = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        # source statements: bare, after ; then do else && || — the #2661
        # comeback-release shape is `if [[ -f $X ]]; then source "$X"; fi`,
        # where the source sits AFTER then on the same line
        for m in re.finditer(r"(?:^|;|&&|\|\||then|do|else)\s*(?:source|\.)\s+(\S+)", s):
            # chop the rest of the clause: `source "$X" || true` -> "$X"
            raw = re.split(r"(?=\))|(?<=[\"'])(?=\s)|(?<=[\"'])$", m.group(1), 1)[0].strip()
            if not raw:
                raw = m.group(1).strip()
            arg = raw
            repofb = re.search(r"/lib/([A-Za-z0-9._-]+\.sh)", arg)
            if repofb:
                targets.append(os.path.join(root, "lib", repofb.group(1)))
            if "$" not in arg:
                targets.append(os.path.normpath(os.path.join(script_dir, arg.strip("\"'"))))
            # Bare-variable form (source "$SEAT_LIB"): the variable is assigned
            # in the same file, typically SEAT_LIB="${PI_PACKET_SEAT_LIB:-$HOME
            # /.local/lib/pi-packet/litellm-seat.sh}". Take every *.sh token of
            # that assignment's value (the ${DEFAULT:-...} fallback carries the
            # real name) and resolve it against the repo's own lib/ and bin/.
            # The #5993 caller class sources exactly this way; without this
            # resolution its closure is empty and every helper reads undefined.
            vm = re.match(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$", arg.strip().strip("\"'"))
            if vm:
                am2 = re.search(r'(?m)^\s*' + vm.group(1) + r'="([^"]*)"', text)
                if am2:
                    for name in SH.findall(am2.group(1)):
                        for base in ("lib", "bin"):
                            cand = os.path.join(root, base, name)
                            if os.path.isfile(cand):
                                targets.append(cand)
            # variable-hosted forms (source "$LIB_DIR/x.sh"): resolve the
            # trailing *.sh names against the repo's own lib/ and bin/ — the
            # #5993 caller class sources through variables the scanner
            # cannot statically expand
            for name in SH.findall(arg):
                for base in ("lib", "bin"):
                    cand = os.path.join(root, base, name)
                    if os.path.isfile(cand):
                        targets.append(cand)
                here = os.path.normpath(os.path.join(script_dir, name))
                if os.path.isfile(here):
                    targets.append(here)
    return targets

HEREDOC = re.compile(r'<<(-?)([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')

def clauses(text):
    """Yield (lineno, clause_text) for each non-heredoc bash line.

    Tracks heredoc bodies by their terminator, carries quote state across
    lines (embedded python/awk programs hide), joins backslash continuations,
    strips comments outside quotes.
    """
    lines = text.splitlines()
    i = 0
    term = None
    quote = ""
    while i < len(lines):
        if term is not None:
            if lines[i].strip() == term:
                term = None
            i += 1
            continue
        # a top-level `exec python3` prologue (blocked-reconcile polyglot):
        # everything after it is python, not bash — yield nothing further
        if re.match(r"^exec\s+python3\b", lines[i]):
            break
        # backslash continuations join into one logical line
        start = i
        buf = lines[i]
        while buf.endswith("\\") and not buf.endswith("\\\\") and start + (len(buf.split("\n")) - 1) < len(lines):
            nxt = start + len(buf.split("\n"))  # 0-based index of next physical line
            if nxt >= len(lines):
                break
            buf = buf[:-1] + " " + lines[nxt]
            if not (buf.endswith("\\") and not buf.endswith("\\\\")):
                start = nxt
                break
            start = nxt
        i = start + 1
        seg = []
        if quote:
            # the line continues a multi-line string: mark the clause so its
            # leading jq-key/python-assignment words are not read as calls
            seg.append("~")
        k = 0
        n = len(buf)
        while k < n:
            c = buf[k]
            if quote:
                if c == quote:
                    quote = ""
                else:
                    seg.append(c)
                k += 1
                continue
            if c in "'\"":
                quote = c
                k += 1
                continue
            if c == "\\" and k + 1 < n:
                seg.append(buf[k:k + 2])
                k += 2
                continue
            if c == "#" and (k == 0 or buf[k - 1] in " \t;|&({"):
                break
            if c == "<" and k + 1 < n and buf[k + 1] == "<":
                m = HEREDOC.match(buf, k)
                if m:
                    term = m.group(3)
                    k = m.end()
                    continue
            seg.append(c)
            k += 1
        yield (start + 1, "".join(seg))

SEP = re.compile(r"(\$\(|\(|\)|\|\||&&|;|\|)")

def clause_firsts(clause):
    """First words of every clause, with subshell/$(()/case-label awareness.

    Parenthesboth ways: depth>0 means we are inside $( or ( — a token there is
    a real call; a ) at depth 0 closes a case-branch label, so the label word
    is not a call. Single-char words are loop vars / short patterns, never
    fleet functions.
    """
    depth = 0
    parts = []

    # Split the clause at the separators; the TEXT between them is the part.
    # A ( at any depth opens a subshell/$((); a ) at depth>0 closes it, so the
    # part keeps no parenthesis; a ) at depth 0 ends a case-branch label, so
    # the label keeps its ) for the peel below. Without this accumulation
    # every part was the empty string and the scan proved nothing — the bug
    # the planted fixture now proves loud.
    prev = 0
    for m in SEP.finditer(clause):
        tok_txt = clause[m.start():m.end()]
        if tok_txt == "(":
            parts.append(clause[prev:m.start()])
            depth += 1
        elif tok_txt == ")":
            if depth > 0:
                parts.append(clause[prev:m.start()])
                depth -= 1
            else:
                parts.append(clause[prev:m.start()] + ")")
        else:
            parts.append(clause[prev:m.start()])
        prev = m.end()
    parts.append(clause[prev:])

    for idx, part in enumerate(parts):
        part = part.strip()
        if not part:
            continue
        # a case-branch label: the part kept its `)`, so peel it. A part that
        # lost its `)` (depth>0 close) is a subshell/$(() inner word — a real
        # call — and must NOT be peeled.
        m2 = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\)(?:\s|$)", part)
        if m2 and not clause[:clause.find(part)].rstrip().endswith(("(", "$(")):
            # label — still scan the BODY after the )
            part = part[m2.end():]
            if not part.strip():
                continue
        # condition/loop keywords sit BETWEEN the keyword and its command;
        # `if helper_running; then` must yield helper_running, not just if
        part = re.sub(r"^(then|do|else|elif|if|while|until)\s+", "", part)
        while part:
            am = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)[+]?=(\S*\s+)?", part)
            if am:
                part = part[am.end():].strip()  # env-prefix: next word is the call
                if not part:
                    break
                continue
            break
        m3 = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", part)
        if not m3:
            continue
        name = m3.group(1)
        # fleet function convention is snake_case (seat_log, model_cap,
        # precedence_band_phase); bare words are prose/jq/label vocabulary the
        # #5993 class never produced, so they are not calls this gate owns.
        # ALL-CAPS words are constants, not functions.
        if len(name) < 2 or "_" not in name or (name.upper() == name):
            continue
        yield name

missing = []
for path in bash_files():
    text = open(path, errors="replace").read()
    script_dir = os.path.dirname(path)
    defined = defined_names(text)
    defined |= assigned_names(text)
    seen = {path}
    stack = [(t, 0) for t in reversed(sourced_targets(text, script_dir, root))]
    while stack:
        t, depth = stack.pop()
        if t in seen or depth > 4 or not os.path.isfile(t):
            continue
        seen.add(t)
        ttext = open(t, errors="replace").read()
        defined |= defined_names(ttext)
        defined |= assigned_names(ttext)
        if depth < 4:
            stack.extend((x, depth + 1) for x in reversed(sourced_targets(ttext, os.path.dirname(t), root)))
    for ln, clause in clauses(text):
        for name in clause_firsts(clause):
            if name in BUILTINS or name in defined:
                continue
            missing.append((os.path.relpath(path, root), ln, name))

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
    out2="$(bash "$here/no-undefined-call.test.sh" "$fixdir" 2>&1)" || true
    if grep -q "planted-miss.*not_defined_anywhere_xyz" <<<"$out2"; then
        echo "OK: planted undefined call turns the gate red (not_defined_anywhere_xyz caught)"
    else
        fail "planted-undefined fixture did not go red (gate acceptance #6032)"
    fi
fi
exit $rc
