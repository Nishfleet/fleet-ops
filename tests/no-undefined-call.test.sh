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
# External host binaries the fleet scripts shell out to (snake_case names, so
# they would otherwise read as undefined fleet functions). Each verified as a
# real executable on the host (fleet-restore-drill:403).
EXTERNAL = {"pg_config"}

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
    names = set(re.findall(r"(?m)^\s*(?:(?:function|def)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)", text))
    # `declare -f name` guards: the caller proves the function may not exist
    # and branches on that, so the guarded call is safe by construction.
    names |= set(re.findall(r"declare\s+-f\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    return names

# variable/assignment targets: `local -a arr`, `local a b=2 c`, `x=1`, so a
# variable used at clause-head (arithmetic, ${x} word) is not flagged.Vars are
# not functions, but adding them only masks noise; the fixture stays red.
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
    # shellcheck source hints: `# shellcheck source=../lib/x.sh` — the fleet
    # convention for runtime-resolved sources (stop-escalation-dispatch:91).
    for m in re.finditer(r"(?m)^\s*#\s*shellcheck\s+.*?\bsource=([^\s]+)", text):
        arg = m.group(1)
        if arg == "/dev/null":
            continue
        if "$" not in arg:
            targets.append(os.path.normpath(os.path.join(script_dir, arg.strip("\"'"))))
        for name in SH.findall(arg):
            for base in ("lib", "bin"):
                cand = os.path.join(root, base, name)
                if os.path.isfile(cand):
                    targets.append(cand)
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
            # Bare-variable form (source "$SEAT_LIB"): EVERY assignment of that
            # variable is a candidate (the first may be the empty default,
            # the second the real repo path — fleet-review-arm-check shape).
            vm = re.match(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$", arg.strip().strip("\"'"))
            if vm:
                for am2 in re.finditer(r'(?m)^\s*' + vm.group(1) + r'="([^"]*)"', text):
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

HEREDOC = re.compile(r'<<(-?)([\'\"]?)([A-Za-z_][A-Za-z0-9_]*)\2')
IDENT = re.compile(r"^[A-Za-z0-9_.*:?\[\]/-]+$")

def clauses(text):
    """Yield (lineno, seg) per bash line. seg keeps ONLY characters that sit
    in COMMAND context; everything else (plain quotes, heredoc bodies,
    $((arithmetic)) becomes spaces. #6032: the #5993 fallout hid inside
    multiline quoted jq/awk programs and case-alternation labels, which a
    line-local tokenizer reads as calls — one carried state machine fixes all
    three.

    State: quote (', "), stack of contexts (cmdsubst/subshell/arith), heredoc
    terminator, and a line-local seg. A $( or backtick anywhere — even inside
    a double quote — enters command context until its closer; a bare ( at
    depth 0 is a subshell (both parens emitted so case labels still peel);
    a ) at depth 0 is a case-label terminator (emitted); case ALTERNATION
    branches (quota_bench|rate_limited) are absorbed into the label's skip
    set by clause_firsts.
    """
    lines = text.splitlines()
    quote = ""
    stack = []          # 'c' = $( / backtick, 's' = bare subshell, 'a' = arithmetic
    heredoc = None      # terminator line content (stripped) while inside a heredoc
    i = 0
    while i < len(lines):
        raw = lines[i]
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            yield (i + 1, " ")
            i += 1
            continue
        # backslash continuations join into one logical line
        start = i
        buf = raw
        j = i
        while buf.endswith("\\") and not buf.endswith("\\\\") and j + 1 < len(lines):
            j += 1
            buf = buf[:-1] + " " + lines[j]
        # a top-level `exec python3` prologue (blocked-reconcile polyglot):
        # everything after it is python, not bash — yield nothing further
        if not stack and not quote and re.match(r"^exec\s+python3\b", buf):
            break
        seg = []
        emit = seg.append
        k = 0
        n = len(buf)

        def emit_data(upto):
            # everything in buf[k:upto] is data (quote/arith continuation)
            seg.append(" " * (upto - k))

        while k < n:
            # continuation of a carried quote: consume till its closer
            if quote:
                closer = buf.find(quote, k)
                if closer == -1:
                    if quote == '"':
                        # escaped quotes: skip \" pairs while scanning
                        p = k
                        while True:
                            closer = buf.find('"', p)
                            if closer == -1 or closer == 0 or buf[closer - 1] != "\\":
                                break
                            p = closer + 1
                    if closer == -1:
                        emit_data(n)
                        k = n
                        continue
                # (re)found: data through the closer, then command context
                emit_data(closer + 1 - k)
                k = closer + 1
                quote = ""
                continue
            # continuation of carried arithmetic: scan for the closing ))
            if stack and stack[-1] == "a":
                e = buf.find("))", k)
                if e == -1:
                    emit_data(n)
                    k = n
                    continue
                emit_data(e + 2 - k)
                k = e + 2
                stack.pop()
                continue
            # carried command-substitution / subshell: its lines ARE commands
            c = buf[k]
            if c == "\\" and k + 1 < n:
                emit(" " if _in_quoteless_data(buf, k, n) else " ")
                k += 2
                continue
            if c == "'":
                e = buf.find("'", k + 1)
                emit(" ")
                if e == -1:
                    quote = "'"
                    k = n
                else:
                    k = e + 1
                continue
            if c == '"':
                # double quote: data until close, but $() / backticks inside
                # are commands — scan segmentwise
                p = k + 1
                while p < n:
                    if buf[p] == "\\":
                        p += 2
                        continue
                    if buf[p] == '"':
                        break
                    if buf[p] == "$" and p + 1 < n and buf[p + 1] == "(":
                        # command substitution inside the double quote
                        depth = 1
                        q = p + 2
                        while q < n and depth:
                            if buf[q] == "(":
                                depth += 1
                            elif buf[q] == ")":
                                depth -= 1
                            elif buf[q] == "'":
                                e2 = buf.find("'", q + 1)
                                q = (e2 if e2 != -1 else n)
                                q += 1 if e2 != -1 else 0
                                continue
                            elif buf[q] == '"':
                                e2 = buf.find('"', q + 1)
                                q = (e2 if e2 != -1 else n)
                                q += 1 if e2 != -1 else 0
                                continue
                            elif buf[q] == "<" and q + 1 < n and buf[q + 1] == "<":
                                m = HEREDOC.match(buf, q)
                                if m:
                                    # heredoc inside the substitution: the
                                    # body is data; the closer ) returns AFTER
                                    # the terminator — keep the $() context
                                    # open across it via the outer loop
                                    heredoc = m.group(3)
                                    break
                            q += 1
                        if heredoc is not None:
                            # heredoc inside "$(... <<'EOS' ... EOS)": BOTH the
                            # closing ) and the closing " of this double quote
                            # sit AFTER the terminator. Skip the rest of the
                            # line as data and carry the open quote: the outer
                            # heredoc branch skips the body, then the `)"`
                            # terminator line closes quote-then-nothing. Without
                            # the carried quote the `"` later reads as an
                            # OPENING one — the phantom then rides every
                            # following line (unquoted words become blanks, $vars
                            # survive, the NEXT <<'EOS' marker dies unseen
                            # inside it) — exactly the #6032 cutoff_utc*
                            # six-phantom-UNDEFINED class. (fleet-ops#6032)
                            # NOTE: k = n AND p = n, so the post-break
                            # `k = p + 1` rewinds INTO the consumed `$(...`
                            # head and would re-scan it (double push + the
                            # heredoc-again), which is what stranded the state.
                            quote = '"'
                            p = n
                            emit(" ")
                            k = n
                            break
                        seg.extend(_cmd(buf[p + 2:q - 1] if depth == 0 else buf[p + 2:q]))
                        emit(" ")
                        p = q
                        continue
                    if buf[p] == "`":
                        e2 = buf.find("`", p + 1)
                        seg.extend(_cmd(buf[p + 1:e2 if e2 != -1 else n]))
                        emit(" ")
                        p = (e2 + 1) if e2 != -1 else n
                        continue
                    p += 1
                else:
                    # closing " not found: quote carries to the next line
                    quote = '"'
                    k = n
                    continue
                if p >= n:
                    continue
                # the heredoc-break also breaks here via continue above
                k = p + 1
                continue
            if c == "$" and k + 1 < n and buf[k + 1] == "(":
                if k + 2 < n and buf[k + 1:k + 3] == "((":
                    # $((arithmetic)) — data context
                    e = buf.find("))", k + 3)
                    if e == -1:
                        stack.append("a")
                        emit(" ")
                        k = n
                    else:
                        emit(" ")
                        k = e + 2
                    continue
                depth = 1
                q = k + 2
                in_q = ""
                while q < n and depth:
                    if buf[q] == "(":
                        depth += 1
                    elif buf[q] == ")":
                        depth -= 1
                    elif buf[q] == "'":
                        e2 = buf.find("'", q + 1)
                        if e2 == -1:
                            in_q = "'"
                        q = (e2 if e2 != -1 else n)
                        q += 1 if e2 != -1 else 0
                        continue
                    elif buf[q] == '"':
                        e2 = buf.find('"', q + 1)
                        if e2 == -1:
                            in_q = '"'
                        q = (e2 if e2 != -1 else n)
                        q += 1 if e2 != -1 else 0
                        continue
                    elif buf[q] == "<" and q + 1 < n and buf[q + 1] == "<":
                        m = HEREDOC.match(buf, q)
                        if m:
                            # result=$(python3 - <<'PY' ... PY ...): body is
                            # data; remember a pending cmdsubst closer
                            heredoc = m.group(3)
                            break
                    q += 1
                if heredoc is not None or depth > 0:
                    # the substitution (or a quoted program inside it) spans
                    # past this line: carry BOTH the command context and, if
                    # the scan ended inside a quote, the quote — so the
                    # continuation lines' jq/awk words stay data (#6032)
                    stack.append("c")
                    if in_q:
                        quote = in_q
                    emit(" ")
                    k = n
                    continue
                emit(" ")
                seg.extend(_cmd(buf[k + 2:q - 1]))
                k = q
                continue
            if c == "`":
                e = buf.find("`", k + 1)
                emit(" ")
                if e == -1:
                    # rare: unterminated backtick — treat rest as data
                    k = n
                else:
                    seg.extend(_cmd(buf[k + 1:e]))
                    k = e + 1
                continue
            if c == "<" and k + 1 < n and buf[k + 1] == "<":
                m = HEREDOC.match(buf, k)
                if m:
                    heredoc = m.group(3)
                    emit(" ")
                    k = n
                    continue
                emit(c)
                k += 1
                continue
            if c == "#":
                # comment: only when it starts a word (fleet convention)
                if k == 0 or buf[k - 1] in " \t;|&({":
                    k = n
                    continue
                emit(c)
                k += 1
                continue
            if c == "(":
                if k + 1 < n and buf[k + 1] == "(":
                    # ((arithmetic)) — data until ))
                    e = buf.find("))", k + 2)
                    if e == -1:
                        stack.append("a")
                        emit(" ")
                        k = n
                    else:
                        emit(" ")
                        k = e + 2
                    continue
                stack.append("s")
                emit(c)
                k += 1
                continue
            if c == ")":
                if stack:
                    top = stack.pop()
                    if top == "s":
                        emit(c)   # bare subshell closer: keep for SEP balance
                    # cmdsubst/arith closers: their ( was never emitted
                else:
                    emit(c)       # depth-0 ) = case-label terminator
                k += 1
                continue
            emit(c)
            k += 1
        yield (start + 1, "".join(seg))
        # the continuation-join above consumed lines i+1..j into this logical
        # line: advance past them (a for-loop re-parsed each consumed line as
        # a fresh clause, leaking its first word as a phantom call — #6032)
        i = j + 1
    return

def _in_quoteless_data(buf, k, n):
    return True

def _cmd(body):
    """Tokenize an extracted command-substitution body through the same
    state machine (fresh state: the extraction bounds are quote-balanced)."""
    return [seg for _ln, seg in clauses(body)]

SEP = re.compile(r"(\$\(|\(|\)|\|\||&&|;|\|)")

def clause_firsts(clause):
    """First words of every part. Case labels: a part carrying `)` at depth 0
    (the #6032 walk only emits those) is a case-branch label — peel it, then
    absorb the alternation branches BEFORE it (walking back until the `;;`
    boundary, which the #6032 walk leaves as an empty part) into a skip set,
    so `quota_bench|rate_limited) return 1` yields only the body. Words in the
    skip set are not yielded; everything else (env-prefix, keyword, assignment)
    resolves to the clause's first call-ish word.
    """
    depth = 0
    parts = []
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

    label_skip = set()
    for idx, part in enumerate(parts):
        stripped = part.strip()
        m2 = re.match(r"^([A-Za-z_][A-Za-z0-9_.-]*)\)(?=(?:\s|$))", part)
        if not m2:
            continue
        # alternation branches: walk back over bare pattern-words until the
        # `;;` boundary (an empty part) or a non-plain token
        j = idx - 1
        while j >= 0:
            ps = parts[j].strip()
            if ps == "":
                break
            if not IDENT.match(ps):
                break
            for w in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", ps):
                label_skip.add(w)
            j -= 1

    for part in parts:
        part = part.strip()
        if not part:
            continue
        # case-branch label: peel `name)` and continue with the body
        m2 = re.match(r"^([A-Za-z_][A-Za-z0-9_.-]*)\)(?=(?:\s|$))", part)
        if m2:
            part = part[m2.end():].strip()
            if not part:
                continue
        part = re.sub(r"^(then|do|else|elif|if|while|until)\s+", "", part)
        while part:
            am = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)[+]?=(\S*\s+)?", part)
            if am:
                part = part[am.end():].strip()
                if not part:
                    break
                continue
            break
        m3 = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)", part)
        if not m3:
            continue
        name = m3.group(1)
        if name in label_skip:
            continue
        # fleet function convention is snake_case; ALL-CAPS = constants
        if len(name) < 2 or "_" not in name or (name.upper() == name):
            continue
        yield name

missing = []
sentinel_found = False
yielded = 0
for path in bash_files():
    text = open(path, errors="replace").read()
    script_dir = os.path.dirname(path)
    defined = defined_names(text)
    defined |= assigned_names(text)
    # `command -v name` guards: the same safe-by-construction proof as the
    # declare -f guard in defined_names — the caller probes the function and
    # branches, so an absent definition resolves as the intended false
    # (fleet-gap-closure-conference's poison probe, #6032). Same-file only:
    # every guard seen so far wraps its own call.
    defined |= set(re.findall(r"command\s+-v\s+([A-Za-z_][A-Za-z0-9_]*)", text))
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
            yielded += 1
            if name == "seat_log":
                sentinel_found = True
            if name in BUILTINS or name in EXTERNAL or name in defined:
                continue
            missing.append((os.path.relpath(path, root), ln, name))

# #6032: the gate must not pass VACUOUSLY. A parser regression (stuck quote
# state, heredoc-terminator miss) yields nothing and prints OK — the #5993
# silent-127 class again. Minimum-volume + sentinel (seat_log is called by
# every litellm-seat consumer and defined in lib/litellm-seat.sh) prove the
# scan actually read the fleet.
if not planted:
    if yielded < 500:
        print(f"FAIL: scanner yielded only {yielded} call words (parser regression — expected 500+)"); sys.exit(1)
    if not sentinel_found:
        print("FAIL: sentinel seat_log not found — source resolution regression"); sys.exit(1)

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
