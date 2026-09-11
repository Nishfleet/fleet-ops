#!/usr/bin/env bash
# tests/fleet-visitor-probe.test.sh
#
# fleet-ops#5417: bin/fleet-visitor-probe emits the judges' outside-in
# `visitor:` line. Hermetic — curl and gh are stubs on PATH (bin seams
# VISITOR_CURL_BIN / VISITOR_GH_BIN point at the stubs):
#   1. All-good fixture -> 301 redirect, edge HIT, manifest 200, 0 dups,
#      0 leaks.
#   2. The regressed shape the external review found -> https_redirect=NONE,
#      home_edge=NONE, manifest=404, dup_routes counts served-200 variants,
#      public_repo_leaks counts unique internal-pattern + personal-email
#      paths (a file matching two emails counts once).
#   3. No curl -> whole line UNAVAILABLE:no-curl.
#   4. curl transport failure -> ERR fields, leak count still real.
#   5. No gh -> public_repo_leaks=UNAVAILABLE:no-gh (site fields still real).
#   6. gh failure -> public_repo_leaks=ERR, never a fabricated 0.
#   7. --help documents the line and the issue.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/bin/fleet-visitor-probe"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$probe" ]] || fail "bin/fleet-visitor-probe missing or not executable"

scratch="$(mktemp -d -t visitor-probe.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
stub="$scratch/stub"
mkdir -p "$stub"

# --- fake curl -------------------------------------------------------------
# Reads STUB_CURL_TABLE: lines of "urlpat|code|redir|ttfb|edge".
# Emits the -w expansions the probe uses; honours -D by dumping a header file.
cat > "$stub/curl" <<'EOF'
#!/usr/bin/env bash
wfmt=""; dump=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) wfmt="$2"; shift 2;;
        -D) dump="$2"; shift 2;;
        -o) shift 2;;
        --max-time) shift 2;;
        -*) shift;;
        *) url="$1"; shift;;
    esac
done
[ "${STUB_CURL_FAIL:-0}" = "1" ] && exit 7
code="000"; redir=""; ttfb="0.010"; edge=""
while IFS="|" read -r pat c r t e; do
    [ -z "${pat:-}" ] && continue
    case "$url" in
        *"$pat"*) code="$c"; redir="$r"; ttfb="$t"; edge="$e"; break;;
    esac
done < "${STUB_CURL_TABLE:-/dev/null}"
if [ -n "$dump" ]; then
    printf 'HTTP/2 %s\r\n' "$code" > "$dump"
    [ -n "$edge" ] && printf 'cf-cache-status: %s\r\n' "$edge" >> "$dump"
fi
out="$wfmt"
out="${out//%{http_code\}/$code}"
out="${out//%{redirect_url\}/$redir}"
out="${out//%{time_starttransfer\}/$ttfb}"
printf '%s' "$out"
exit 0
EOF

# --- fake gh ---------------------------------------------------------------
# `gh api repos/<r>/git/trees/HEAD?recursive=1 --jq ...` -> STUB_GH_TREE_FILE
# `gh api -X GET search/code -f q='repo:<r> "<email>"' --jq ...` ->
#   STUB_GH_SEARCH_DIR/<email>.txt
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_GH_FAIL:-0}" = "1" ] && exit 1
args="$*"
case "$args" in
    *git/trees*)
        cat "${STUB_GH_TREE_FILE:-/dev/null}"
        exit 0;;
    *search/code*)
        q=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "-f" ]; then
                case "$a" in q=*) q="${a#q=}";; esac
            fi
            prev="$a"
        done
        email="$(printf '%s' "$q" | sed -n 's/.*"\([^"]*\)".*/\1/p')"
        f="${STUB_GH_SEARCH_DIR:-/dev/null}/$email.txt"
        [ -f "$f" ] && cat "$f"
        exit 0;;
    *) exit 1;;
esac
EOF
chmod +x "$stub/curl" "$stub/gh"

BASE="https://fixture.0509.test"
run_probe() {
    VISITOR_BASE_URL="$BASE" \
    VISITOR_CURL_BIN="${VISITOR_CURL_BIN:-$stub/curl}" \
    VISITOR_GH_BIN="${VISITOR_GH_BIN:-$stub/gh}" \
    STUB_CURL_TABLE="$scratch/curl-table.tsv" \
    STUB_GH_TREE_FILE="$scratch/tree.txt" \
    STUB_GH_SEARCH_DIR="$scratch/search" \
        bash "$probe" 2>/dev/null
}
mkdir -p "$scratch/search"

# ---------------------------------------------------------------------------
# 1. All-good fixture. Rows are url-glob matches tried in order — the
#    dup-variant rows must precede the broad /search and / rows.
cat > "$scratch/curl-table.tsv" <<EOF
http://fixture.0509.test/|301|https://fixture.0509.test/|0.050|
$BASE/site.webmanifest|200||0.020|
$BASE/Pricing|301|https://fixture.0509.test/pricing|0.010|
$BASE/pricing/|301|https://fixture.0509.test/pricing|0.010|
$BASE/Search|301|https://fixture.0509.test/search|0.010|
$BASE/search/|301|https://fixture.0509.test/search|0.010|
$BASE/search|200||0.900|miss
$BASE/|200||0.400|hit
EOF
cat > "$scratch/tree.txt" <<EOF
app/index.ts
docs/roadmap.md
README.md
EOF
line="$(run_probe)"
grep -q '^visitor: ' <<<"$line" || fail "case 1: no visitor line, got: $line"
grep -q 'https_redirect=301' <<<"$line" || fail "case 1: redirect, got: $line"
grep -q 'home_ttfb_ms=400' <<<"$line" || fail "case 1: home ttfb, got: $line"
grep -q 'home_edge=HIT' <<<"$line" || fail "case 1: edge, got: $line"
grep -q 'search_ttfb_ms=900' <<<"$line" || fail "case 1: search ttfb, got: $line"
grep -q 'manifest=200' <<<"$line" || fail "case 1: manifest, got: $line"
grep -q 'dup_routes=0' <<<"$line" || fail "case 1: dup_routes, got: $line"
grep -q 'public_repo_leaks=0' <<<"$line" || fail "case 1: leaks, got: $line"
ok "case 1: all-good line shape"

# ---------------------------------------------------------------------------
# 2. The regressed shape the external review found.
cat > "$scratch/curl-table.tsv" <<EOF
http://fixture.0509.test/|200||0.030|
$BASE/site.webmanifest|404||0.020|
$BASE/Pricing|200||0.010|
$BASE/pricing/|200||0.010|
$BASE/Search|200||0.010|
$BASE/search/|200||0.010|
$BASE/search|200||4.500|
$BASE/|200||1.100|
EOF
cat > "$scratch/tree.txt" <<EOF
MEMORY.md
agent-state/0509-transformation/discovery-panel-coverage.md
design-qa.md
design-qa-wave1.md
docs/search-relevance-audit.md
app/index.ts
EOF
printf 'docs/ops-backup-uptime.md\ndocs/ga-incident-runbook.md\n' \
    > "$scratch/search/me@inish.in.txt"
printf 'docs/ops-backup-uptime.md\n' > "$scratch/search/nishant345@gmail.com.txt"
line="$(run_probe)"
grep -q 'https_redirect=NONE' <<<"$line" || fail "case 2: redirect, got: $line"
grep -q 'home_edge=NONE' <<<"$line" || fail "case 2: edge, got: $line"
grep -q 'manifest=404' <<<"$line" || fail "case 2: manifest, got: $line"
grep -q 'dup_routes=4' <<<"$line" || fail "case 2: dup_routes, got: $line"
# 5 internal-pattern paths + 2 unique email files (ops-backup-uptime.md
# matches BOTH emails but is one leaky path).
grep -q 'public_repo_leaks=7' <<<"$line" || fail "case 2: leaks, got: $line"
ok "case 2: regressed shape detected"

# ---------------------------------------------------------------------------
# 3. No curl -> whole line unavailable, still one line.
line="$(VISITOR_CURL_BIN="$stub/no-such-curl" bash "$probe" 2>/dev/null)"
[[ "$line" == "visitor: UNAVAILABLE:no-curl" ]] \
    || fail "case 3: expected UNAVAILABLE:no-curl, got: $line"
ok "case 3: no-curl posture"

# ---------------------------------------------------------------------------
# 4. curl transport failure -> ERR site fields, leak count still real.
line="$(STUB_CURL_FAIL=1 run_probe)"
grep -q 'https_redirect=ERR' <<<"$line" || fail "case 4: redirect ERR, got: $line"
grep -q 'home_ttfb_ms=ERR' <<<"$line" || fail "case 4: ttfb ERR, got: $line"
grep -q 'home_edge=ERR' <<<"$line" || fail "case 4: edge ERR, got: $line"
grep -q 'manifest=ERR' <<<"$line" || fail "case 4: manifest ERR, got: $line"
grep -q 'dup_routes=ERR' <<<"$line" || fail "case 4: dup ERR, got: $line"
grep -q 'public_repo_leaks=7' <<<"$line" || fail "case 4: leaks real, got: $line"
ok "case 4: transport-failure posture"

# ---------------------------------------------------------------------------
# 5. No gh -> leaks unreadable, site fields still real.
line="$(VISITOR_GH_BIN="$stub/no-such-gh" run_probe)"
grep -q 'public_repo_leaks=UNAVAILABLE:no-gh' <<<"$line" \
    || fail "case 5: no-gh label, got: $line"
grep -q 'manifest=404' <<<"$line" || fail "case 5: manifest still real, got: $line"
ok "case 5: no-gh posture"

# ---------------------------------------------------------------------------
# 6. gh failure -> leaks ERR, never a fabricated 0.
line="$(STUB_GH_FAIL=1 run_probe)"
grep -q 'public_repo_leaks=ERR' <<<"$line" || fail "case 6: ERR, got: $line"
grep -q 'manifest=404' <<<"$line" || fail "case 6: manifest real, got: $line"
ok "case 6: gh-failure posture"

# ---------------------------------------------------------------------------
# 7. --help names the line and the issue.
help_out="$(bash "$probe" --help)"
grep -q 'visitor:' <<<"$help_out" || fail "case 7: --help must name the line"
grep -q 'fleet-ops#5417' <<<"$help_out" || fail "case 7: --help must cite the issue"
grep -q 'public_repo_leaks' <<<"$help_out" \
    || fail "case 7: --help must document public_repo_leaks"
ok "case 7: --help receipt"

ok "fleet-visitor-probe: all 7 cases pass"
