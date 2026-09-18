#!/usr/bin/env bash
# tests/prometheus-retention-40d.test.sh
#
# fleet-ops#1235: Prometheus storageRetention was 15d, too short for the
# fleet-ops#1151 baseline-delta job (needs a trailing 4-week window ≈ 35d
# of samples). This locks the SHAPE of the repo-tracked retention override
#
# Sections 2-5 exercised bin/fleet-ops-deploy + install.sh --system, both
# deleted 2026-09-18 with the rest of the copy-then-detect-drift deploy
# cluster. /etc/default/prometheus is a hand-applied root copy now (README
# "The exceptions: files that must stay COPIES"); retention is a start-time
# flag, so applying a change there is `sudo -n install -D ... && sudo -n
# systemctl restart prometheus`, not a reload.
#
# What it proves:
#   1. config/etc-default-prometheus exists and ARGS carries
#      --storage.tsdb.retention.time=40d as a single token (>=35d + 5d
#      margin). No size cap (min(time,size) would silently shorten the
#      window). No stale 15d. Loopback bind + config path preserved.
#
# The live end-to-end proof (real `systemctl restart prometheus` +
# /api/v1/status/runtimeinfo reporting storageRetention=40d + query_range
# over 35d) is operator-side and recorded in the PR body; CI has no
# prometheus unit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

env_file="$repo_root/config/etc-default-prometheus"

# --- 1. config shape ---------------------------------------------------------
[[ -f "$env_file" ]] || fail "missing: $env_file"
ok "config/etc-default-prometheus exists"

# ARGS carries --storage.tsdb.retention.time=40d as a single argv token
# (whitespace boundary on both sides so IFS word-splitting keeps it whole).
if ! grep -E '^ARGS=".*--storage\.tsdb\.retention\.time=40d([[:space:]]|")' "$env_file" >/dev/null; then
  fail "ARGS must contain --storage.tsdb.retention.time=40d as a single token (got: $(grep -E '^ARGS=' "$env_file" || echo '<missing>'))"
fi
ok "ARGS carries --storage.tsdb.retention.time=40d as a single token"

# Defence-in-depth: no size cap (min(time,size) would silently shorten 40d).
if grep -E -- '--storage\.tsdb\.retention\.size' "$env_file" >/dev/null; then
  fail "must not set --storage.tsdb.retention.size (size cap would silently shorten the 40d window)"
fi
ok "no size cap: --storage.tsdb.retention.size is absent"

# Must NOT retain the stale 15d the issue is dropping.
if grep -E -- '--storage\.tsdb\.retention\.time=15d' "$env_file" >/dev/null; then
  fail "still references 15d (stale value; the issue is to drop it)"
fi
ok "no stale 15d"

# Loopback bind + config path preserved (the issue asked only to change retention).
grep -Eq -- '--web\.listen-address=127\.0\.0\.1:9090' "$env_file" \
  || fail "--web.listen-address must stay 127.0.0.1:9090 (loopback only)"
ok "loopback bind preserved: 127.0.0.1:9090"
grep -Eq -- '--config\.file=/etc/prometheus/prometheus\.yml' "$env_file" \
  || fail "--config.file must stay /etc/prometheus/prometheus.yml"
ok "config path preserved: /etc/prometheus/prometheus.yml"


echo "PASS: prometheus retention 40d config shape locked"
