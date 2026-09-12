#!/usr/bin/env bash
# tests/pi-scout-packet-assembly.test.sh
#
# Proves the research-seeded 0509 scout packet is assembled correctly:
#   1. All four research sections are present.
#   2. Market-signal staleness (> 36h by default) makes assembly return 1.
#   3. pi-scout-run 0509 scout fails loud when the market signal is stale.
#   4. pi-scout-run 0509 scout passes the packet to pi when the signal is fresh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t scout-packet.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/agent-state/cron-output"
mkdir -p "$scratch/agent-state/0509-transformation"
mkdir -p "$scratch/tooling/nish-vault"

# Stub seat-lib with a deterministic pick_seat and no-op seat_log.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "light"; }
# fleet-ops#520: stub the privacy helpers the wrapper now calls. The stub
# returns "public" so the test's deterministic pick_seat path is unchanged;
# the privacy guard itself is drilled in tests/repo-privacy-guard.test.sh.
repo_privacy() { echo "public"; }
packet_repo() { echo ""; }
pick_seat() {
    printf 'minimax\tMiniMax-M3\n'
    return 0
}
# fleet-ops#4263 P3b: wrappers call litellm_pick_seat, not pick_seat.
litellm_pick_seat() { pick_seat; }
EOF

# Fake pi records args and stdin, then prints output.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'scout output\n'
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"

# --- fake market-signal file (fresh) ----------------------------------------
fresh_signal="$scratch/agent-state/cron-output/0509-daily-market-signal-$(date -u +%Y-%m-%d).md"
printf '# 0509-daily-market-signal fresh\n- Soft demand signal from SneakerPing.\n' >"$fresh_signal"

# --- fake category research (fleet-ops#4560: 3 transformation bets) ---------
cat >"$scratch/agent-state/0509-transformation/category-research.md" <<'EOF'
# 0509 transformation bets
## BET 1 — digest ranking
Build.
## BET 2 — country scope honesty
Build.
## BET 3 — pricing visibility
Build.
EOF

# --- fake north-star file ---------------------------------------------------
printf '# North star\nBeat customer edge AI.\n' >"$scratch/tooling/nish-vault/north-star.md"

# --- fake gh ----------------------------------------------------------------
fake_gh="$scratch/gh"
cat >"$fake_gh" <<'EOF'
#!/usr/bin/env bash
# Return canned merged PRs and empty open issues/PRs for any repo.
printf '[{"title":"feat: test merged PR"}]\n'
EOF
chmod +x "$fake_gh"

# --- assemble packet directly -----------------------------------------------
export HOME="$scratch"
export AGENT_STATE_DIR="$scratch/agent-state"
export PACKET_MARKET_SIGNAL_DIR="$scratch/agent-state/cron-output"
export PACKET_TRANSFORMATION_DIR="$scratch/agent-state/0509-transformation"
export PACKET_NORTH_STAR_FILE="$scratch/tooling/nish-vault/north-star.md"
export PACKET_GH="$fake_gh"

# Hermetic usage/walk seams (fleet-ops#3149): tests must not touch the real CF
# token, the network, or a browser. Each empty source must DROP, never fail
# assembly.
export PACKET_CF_FILE="$scratch/no-cf.env"
export PACKET_MONEY_PATH_WALK=0

source "$repo_root/lib/packet-assembly.sh"

packet="$scratch/packet.md"
packet_assemble_0509_scout "$repo_root/prompts/scout.md" 0509 "$packet" || fail "fresh signal must not make assembly fail"

[[ -f "$packet" ]] || fail "packet file was not written"

# 1. All four research sections present.
grep -q '## Market signal' "$packet" || fail "packet missing market signal section"
grep -q '## Transformation campaign state' "$packet" || fail "packet missing category research section"
grep -q '## North-star rule' "$packet" || fail "packet missing north-star section"
grep -q '## Recent merged PR titles' "$packet" || fail "packet missing recent PRs section"
grep -q 'TARGET REPO: Nishfleet/0509' "$packet" || fail "packet missing TARGET line"
grep -q 'RESEARCH CONTEXT' "$packet" || fail "packet missing research context header"
ok "packet assembly includes all four research sections and TARGET line"

# 1b. Usage block (fleet-ops#3149): header present; empty sources DROP with a
# marker and the all-empty NOTE, and never fail assembly.
grep -q '## Usage (live product telemetry' "$packet" || fail "packet missing usage block header"
grep -q '### Money-path walk: skipped (PACKET_MONEY_PATH_WALK=0)' "$packet" \
  || fail "walk must be skipped (not fail) when PACKET_MONEY_PATH_WALK=0"
grep -q 'no CF token file at' "$packet" || fail "missing CF token must leave a drop marker, not fail assembly"
grep -q 'every usage source is empty' "$packet" || fail "all-usage-empty NOTE must appear when every source drops"
ok "usage block assembles and drops empty sources without failing"

# 1c. Prompt contract (fleet-ops#3149): usage citation, money-path walk, and
# scout self-score must be present in the scout prompt.
grep -q 'scout-yield' "$repo_root/prompts/scout.md" || fail "scout prompt missing scout-yield self-score"
grep -q 'A.5 Money-path walk' "$repo_root/prompts/scout.md" || fail "scout prompt missing money-path walk subsection"
grep -q 'A.6 Usage citation' "$repo_root/prompts/scout.md" || fail "scout prompt missing usage citation rule"
ok "scout prompt carries usage citation, money-path walk, and scout-yield"

# 1c-b. Research floor under an all-empty/all-green Usage block (fleet-ops
# #4560): the assembled packet (all-green usage + 3 research bets) must
# INSTRUCT filing >= 1 research-cited candidate tagged usage-uncited, not
# dropping the whole set. This is the regression drill for the A.6 starve.
grep -q 'SCOUT_RESEARCH_FLOOR' "$packet" \
  || fail "packet must carry the SCOUT_RESEARCH_FLOOR research-floor instruction"
grep -q 'usage-uncited' "$packet" \
  || fail "packet must instruct the usage-uncited tag"
! grep -q 'drop every usage-uncited candidate' "$packet" \
  || fail "packet must no longer instruct dropping every usage-uncited candidate"
for bet in 'BET 1' 'BET 2' 'BET 3'; do
    grep -q "$bet" "$packet" || fail "packet missing research bet $bet"
done
grep -q 'transformation-bet ID (BET n)' "$repo_root/prompts/scout.md" \
  || fail "A.6 must name bet IDs as a valid research-floor citation"
ok "research floor: all-green usage + 3 bets => packet instructs filing research-cited candidates (fleet-ops#4560)"

# 1c-b2. Hard minimum + no-reconsider loop (fleet-ops#4850): the live scout
# on a weak seat (ollama/deepseek-v4-flash) read "up to 5" as "deliberate how
# many" and looped ~25x between deciding to file and reconsidering, filing 0
# and never printing the supply verdict line. The floor must be a hard
# MINIMUM ("at least 1"), and the prompt must forbid the reconsider loop and
# mandate the supply: line even when filed=0.
grep -q 'at least 1 and at most' "$packet" \
  || fail "packet NOTE must state the hard minimum 'at least 1 and at most', not 'up to' (fleet-ops#4850)"
grep -q 'at least 1 and at most' "$repo_root/prompts/scout.md" \
  || fail "A.6 research floor must state the hard minimum 'at least 1 and at most' (fleet-ops#4850)"
grep -q 'hard MINIMUM' "$repo_root/prompts/scout.md" \
  || fail "A.6 must call the floor a hard MINIMUM so a weak model can't read it as optional (fleet-ops#4850)"
grep -q 'No-reconsider loop' "$repo_root/prompts/scout.md" \
  || fail "A.6 must carry the No-reconsider loop directive (fleet-ops#4850)"
grep -q 'file it in the NEXT action' "$repo_root/prompts/scout.md" \
  || fail "A.6 must instruct filing in the next action, not looping (fleet-ops#4850)"
grep -q 'MANDATORY on every run' "$repo_root/prompts/scout.md" \
  || fail "Step 5 must mark the supply: line MANDATORY on every run including filed=0 (fleet-ops#4850)"
grep -q 'do not loop between deciding and filing' "$packet" \
  || fail "packet NOTE must carry the no-loop directive (fleet-ops#4850)"
ok "research floor: hard minimum + no-reconsider loop + mandatory supply line (fleet-ops#4850)"

# 1c-c. Acquisition-first intake weighting (fleet-ops#4657): 0509 scout
# candidates must name a funnel stage, else usage-uncited; while
# signups-30d == 0, acquisition-class ranks above fix/polish-class inside
# label_budget (the budget number itself is unchanged). Origin line and
# one worked example of each class must stay in the prompt.
grep -q 'funnel stage' "$repo_root/prompts/scout.md" \
  || fail "scout.md must carry the 0509 funnel-stage rule (fleet-ops#4657)"
grep -q 'funnel_stage:' "$repo_root/prompts/scout.md" \
  || fail "scout.md must require a funnel_stage: line on 0509 scout-candidates"
grep -qE 'usage-uncited.{0,2} instead of' "$repo_root/prompts/scout.md" \
  || fail "scout.md must send missing funnel-stage candidates to usage-uncited instead of scout-candidate"
grep -q 'acquisition-class' "$repo_root/prompts/scout.md" \
  || fail "scout.md must carry the 0509 acquisition-class ranking rule"
grep -q 'Origin: 2026-09-09 (fleet-ops#4657' "$repo_root/prompts/scout.md" \
  || fail "scout.md ranking rule must carry the dated origin line (fleet-ops#4657)"
grep -q 'must NOT block or freeze' "$repo_root/prompts/scout.md" \
  || fail "scout.md must not freeze fix/polish (0509#2122)"
grep -q 'Worked example — acquisition-class' "$repo_root/prompts/scout.md" \
  || fail "scout.md must carry a worked example of acquisition-class"
grep -q 'Worked example — fix/polish-class' "$repo_root/prompts/scout.md" \
  || fail "scout.md must carry a worked example of fix/polish-class"
! grep -qE 'Let `label_budget = [^8]' "$repo_root/prompts/scout.md" \
  || fail "scout.md must not change the default label_budget = 8"
ok "0509 acquisition-first intake weighting is in the scout prompt (fleet-ops#4657)"

# 1d. CF analytics source is OPTIONAL (fleet-ops#3172): when the sanctioned
# token lacks zone.analytics.read the GraphQL call returns a 403 authz error;
# the source logs a one-line `usage-source: cloudflare-analytics UNAVAILABLE
# (token scope)` marker and DROPS (returns 1) — it must never fail the scout
# run or drop the whole usage block.
cf_token_file="$scratch/cf-token.env"
printf 'CLOUDFLARE_API_TOKEN="fake-token"\n' >"$cf_token_file"
# Override curl so the GraphQL call returns the real 403 authz shape without
# touching the network.
cat >"$scratch/curl" <<'EOF'
#!/usr/bin/env bash
# Only the GraphQL call is faked; anything else (zone id) is not reached here.
printf '%s' '{"errors":[{"message":"Actor '"'"'com.cloudflare.api.token.abc'"'"' does not have permission '"'"'com.cloudflare.api.account.zone.analytics.read'"'"' for zone 0509"}]}'
EOF
chmod +x "$scratch/curl"
PATH="$scratch:$PATH" PACKET_CF_FILE="$cf_token_file" PACKET_CF_ZONE="0509" \
    bash -c 'source "$1"; packet_cf_analytics_usage 0509.io 7' _ "$repo_root/lib/packet-assembly.sh" \
    >"$scratch/cf-403.out" 2>&1 || true
grep -q 'usage-source: cloudflare-analytics UNAVAILABLE (token scope)' "$scratch/cf-403.out" \
  || fail "CF 403 must log the usage-source UNAVAILABLE line, got: $(cat "$scratch/cf-403.out")"
grep -q 'does not have permission' "$scratch/cf-403.out" \
  || fail "CF 403 must keep the visible drop marker"
ok "CF analytics source is optional: 403 logs usage-source UNAVAILABLE and drops, never fails the scout"

# 1e. Reader path for the working sources (fleet-ops#3172): lp_run_audit and
# /search query log dump dirs are read into the usage block when present, and
# a missing dump dir DROPS with a marker instead of failing.
usage_dir="$scratch/usage-dump"
mkdir -p "$usage_dir/lp" "$usage_dir/search"
printf '{"tag":"lp_run_audit","stage":"cta_extract","outcome":"ok"}\n' \
  >"$usage_dir/lp/audit-20260904.ndjson"
printf '{"q":"sneaker","hits":3}\n' >"$usage_dir/search/search-20260904.ndjson"
PACKET_LP_AUDIT_DIR="$usage_dir/lp" PACKET_SEARCH_LOG_DIR="$usage_dir/search" \
    bash -c 'source "$1"; packet_local_usage "lp_run_audit / landing-page telemetry" "$PACKET_LP_AUDIT_DIR" "*.ndjson"; packet_local_usage "/search query log" "$PACKET_SEARCH_LOG_DIR" "*.ndjson"' \
    _ "$repo_root/lib/packet-assembly.sh" >"$scratch/reader.out" 2>&1
grep -q 'lp_run_audit / landing-page telemetry (newest: audit-20260904.ndjson)' "$scratch/reader.out" \
  || fail "lp_run_audit dump must be read into the usage block, got: $(cat "$scratch/reader.out")"
grep -q '/search query log (newest: search-20260904.ndjson)' "$scratch/reader.out" \
  || fail "/search query log dump must be read into the usage block, got: $(cat "$scratch/reader.out")"
grep -q '"tag":"lp_run_audit"' "$scratch/reader.out" \
  || fail "lp_run_audit dump content must appear verbatim"
ok "reader path reads lp_run_audit and /search query log dumps into the usage block"

# 2. Stale market signal (> 36h) returns 1.
stale_dir="$scratch/stale-signal"
mkdir -p "$stale_dir"
stale_file="$stale_dir/0509-daily-market-signal-2000-01-01.md"
printf '# old signal\n' >"$stale_file"
# Touch it far in the past. mtime is what matters; use touch -d.
touch -d '2000-01-01' "$stale_file" 2>/dev/null || true

export PACKET_MARKET_SIGNAL_DIR="$stale_dir"
stale_packet="$scratch/stale-packet.md"
if packet_assemble_0509_scout "$repo_root/prompts/scout.md" 0509 "$stale_packet"; then
    fail "stale market signal must make packet_assemble_0509_scout return 1"
fi
grep -q '## Market signal (STALE' "$stale_packet" \
  || fail "stale packet must contain a STALE marker"
ok "stale market signal (> 36h) makes assembly fail with a STALE marker"

# 3. pi-scout-run 0509 scout fails loud when market signal is stale.
export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_PACKET_ASSEMBLY_LIB="$repo_root/lib/packet-assembly.sh"
export PI_BIN="$fake_pi"
export SCOUT_PROMPT_DIR="$repo_root/prompts"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"
export PACKET_MARKET_SIGNAL_DIR="$stale_dir"

rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-scout-run" 0509 scout 2>"$scratch/err.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "stale signal: pi-scout-run must exit 1, got $rc"
grep -q 'market signal stale or missing' "$scratch/err.log" \
  || fail "stale signal: pi-scout-run must fail loud on stderr, got: $(cat "$scratch/err.log")"
ok "pi-scout-run 0509 scout fails loud when market signal is stale"

# 4. pi-scout-run 0509 scout passes with fresh market signal.
export PACKET_MARKET_SIGNAL_DIR="$scratch/agent-state/cron-output"
rm -f "$record_args" "$record_stdin"
set +e
rc=$("$repo_root/bin/pi-scout-run" 0509 scout >/dev/null; echo $?)
set -e
[[ "$rc" == "0" ]] || fail "fresh signal: pi-scout-run must exit 0, got $rc"
grep -q 'TARGET REPO: Nishfleet/0509' "$record_stdin" \
  || fail "fresh signal: packet must contain TARGET line"
grep -q '## Market signal' "$record_stdin" \
  || fail "fresh signal: packet must contain market signal"
grep -q -- '--provider minimax' "$record_args" \
  || fail "fresh signal: pi must be called with --provider minimax"
grep -q -- '--model MiniMax-M3' "$record_args" \
  || fail "fresh signal: pi must be called with --model MiniMax-M3"
ok "pi-scout-run 0509 scout assembles research packet and runs pi when fresh"

# fleet-ops#454: P14 runs this file. Invoke the full green-and-empty
# drill here so CI covers the class without a workflow edit.
bash "$repo_root/tests/scout-futility.test.sh"

# fleet-ops#670: P14 runs this file. Host the token-efficiency debt drill
# so the three shipped assembler hits cannot return without a CI fail.
bash "$repo_root/tests/sr-token-efficiency-debt.test.sh"

# fleet-ops#4562: the RESEARCH CONTEXT Direction block (fed from the decisions
# ledger, `source: direction#4518`). Hosted here so P14 runs it without a
# workflow-file edit. Hermetic (fixture ledger).
bash "$repo_root/tests/packet-direction-block.test.sh"
bash "$repo_root/tests/packet-direction-live-metric.test.sh"

# fleet-ops#5781: App-GraphQL -> user-REST list fallback with credential/quota
# stamps (packet_gh_read). Hosted here so P14 runs it without a workflow-file
# edit. Hermetic (fake gh; simulates installation rate-limit exhaustion).
bash "$repo_root/tests/packet-assembly-graphql-fallback.test.sh"

ok "0509 scout packet assembly: research-seeded, stale-fail-loud, pi-bound"
