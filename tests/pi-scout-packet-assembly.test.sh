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
repo_privacy() { echo "public"; }
packet_repo() { echo ""; }
pick_seat() {
    printf 'minimax\tMiniMax-M3\n'
    return 0
}
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

# --- fake category research -------------------------------------------------
printf '# 0509 transformation bets\n## BET 1 — digest ranking\nBuild.\n' >"$scratch/agent-state/0509-transformation/category-research.md"

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

source "$repo_root/lib/packet-assembly.sh"

packet="$scratch/packet.md"
packet_assemble_0509_scout "$repo_root/prompts/scout.md" 0509 "$packet" || fail "fresh signal must not make assembly fail"

[[ -f "$packet" ]] || fail "packet file was not written"

# 1. All four sections present.
grep -q '## Market signal' "$packet" || fail "packet missing market signal section"
grep -q '## Transformation campaign state' "$packet" || fail "packet missing category research section"
grep -q '## North-star rule' "$packet" || fail "packet missing north-star section"
grep -q '## Recent merged PR titles' "$packet" || fail "packet missing recent PRs section"
grep -q 'TARGET REPO: Nishfleet/0509' "$packet" || fail "packet missing TARGET line"
grep -q 'RESEARCH CONTEXT' "$packet" || fail "packet missing research context header"
ok "packet assembly includes all four research sections and TARGET line"

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

ok "0509 scout packet assembly: research-seeded, stale-fail-loud, pi-bound"
