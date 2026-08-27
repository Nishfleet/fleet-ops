#!/usr/bin/env bash
# tests/aeo-probe.test.sh
#
# Proves fleet-ops#1236 AEO visibility probe:
#   (a) Phase A eval exists (build-vs-buy justification).
#   (b) MANIFEST ships timer, service, config, libexec (no new bin/).
#   (c) ExecStart is python3 libexec (help-first: agent-cron-run wraps
#       pi --print and would burn a seat to do urllib; fleet-metrics-export
#       is 5-min plumbing and must not grow LLM calls).
#   (d) timer has Named reason + Sunday 03:30 IST + [Install] + Persistent.
#   (e) install.sh enable --now the timer (fleet-ops#183 class).
#   (f) citation detector: host => cited, name => mentioned, 10509 is not 0509.
#   (g) missing API seats write engine_up=0, not a fake "uncited" baseline.
#   (h) WFR prompt reads the metric.
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without
# a workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/libexec/fleet-aeo-probe.py"
cfg="$repo_root/config/aeo-probe.json"
svc="$repo_root/systemd/fleet-aeo-probe.service"
timer="$repo_root/systemd/fleet-aeo-probe.timer"
eval_doc="$repo_root/docs/aeo-visibility-eval.md"
install_sh="$repo_root/install.sh"
manifest="$repo_root/MANIFEST"
wfr="$repo_root/prompts/weekly-fleet-review.md"
gates_lib="$repo_root/lib/role-quality-gates.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$probe" ]] || fail "missing $probe"
[[ -f "$cfg" ]] || fail "missing $cfg"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
[[ -f "$eval_doc" ]] || fail "missing $eval_doc"
[[ -f "$install_sh" ]] || fail "missing $install_sh"
[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$wfr" ]] || fail "missing $wfr"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# (a) Phase A
grep -q 'No free, proven tool' "$eval_doc" \
  || fail "eval must record the buy-vs-build verdict"
grep -q 'PromptWatch' "$eval_doc" \
  || fail "eval must name PromptWatch (the only free API candidate)"
grep -q 'Scrunch' "$eval_doc" \
  || fail "eval must record the card-wall skip"
ok "(a) Phase A eval is the written justification"

# (b) MANIFEST — no new bin/
grep -Fxq "systemd/fleet-aeo-probe.service /home/nish/.config/systemd/user/fleet-aeo-probe.service" "$manifest" \
  || fail "MANIFEST missing fleet-aeo-probe.service"
grep -Fxq "systemd/fleet-aeo-probe.timer /home/nish/.config/systemd/user/fleet-aeo-probe.timer" "$manifest" \
  || fail "MANIFEST missing fleet-aeo-probe.timer"
grep -Fxq "libexec/fleet-aeo-probe.py /home/nish/.local/libexec/fleet-aeo-probe.py" "$manifest" \
  || fail "MANIFEST missing fleet-aeo-probe.py"
grep -Fxq "config/aeo-probe.json /home/nish/.config/fleet-aeo/probe.json" "$manifest" \
  || fail "MANIFEST missing aeo-probe.json"
if grep -E '^bin/fleet-aeo' "$manifest"; then
  fail "must not add bin/fleet-aeo*; python3 libexec is the runner"
fi
ok "(b) MANIFEST ships units+libexec+config and no new bin/"

# (c) ExecStart
grep -q '^ExecStart=/usr/bin/python3 /home/nish/.local/libexec/fleet-aeo-probe.py --config /home/nish/.config/fleet-aeo/probe.json$' "$svc" \
  || fail "service ExecStart must invoke python3 libexec with the installed config"
if grep -q 'Restart=on-failure' "$svc"; then
  fail "probe must not Restart=on-failure (a 429 must not burn three weekly retries)"
fi
ok "(c) ExecStart is python3 libexec, no restart storm"

# (d) timer shape
grep -q '^# Named reason:' "$timer" \
  || fail "timer must carry a Named reason (fleet-unjustified-wait)"
grep -q '^OnCalendar=Sun \*\-\*\-\* 03:30:00 Asia/Kolkata$' "$timer" \
  || fail "timer must fire Sunday 03:30 IST (before WFR 04:30)"
grep -q '^\[Install\]$' "$timer" \
  || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer [Install] must WantedBy=timers.target"
grep -q '^Persistent=true$' "$timer" \
  || fail "timer must be Persistent so a missed Sunday still fires"
ok "(d) timer has Named reason, Sunday 03:30 IST, [Install]"

# (e) install enable
grep -Fq -- '"$SYSTEMCTL" --user enable --now fleet-aeo-probe.timer' "$install_sh" \
  || fail "install.sh must enable --now fleet-aeo-probe.timer"
ok "(e) install.sh enables the weekly timer"

# Plumbing skip so the role-gate auditor does not auto-file ungated-role
python3 - "$gates_lib" <<'PY' || fail "role-quality-gates missing fleet-aeo prefix"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("role_quality_gates", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if "fleet-aeo" not in mod.NON_ROLE_UNIT_PREFIXES:
    raise SystemExit("NON_ROLE_UNIT_PREFIXES missing fleet-aeo")
PY
ok "catalog: fleet-aeo-probe is plumbing, not a new judging role"

# (h) WFR
grep -q 'fleet_aeo_cited' "$wfr" \
  || fail "weekly-fleet-review.md must name fleet_aeo_cited"
grep -q 'aeo-probe/latest.json' "$wfr" \
  || fail "weekly-fleet-review.md must read the probe JSON log"
grep -q 'engine_up=0' "$wfr" \
  || fail "WFR must treat engine_up=0 as not-measured, not uncited"
ok "(h) WFR prompt consumes the probe"

# Config shape
jq -e '.query_class == "sneaker_money"' "$cfg" >/dev/null \
  || fail "query_class must be sneaker_money"
n_queries=$(jq '.queries | length' "$cfg")
[[ "$n_queries" -ge 10 && "$n_queries" -le 15 ]] \
  || fail "need 10-15 money-queries, got $n_queries"
ids=$(jq -r '.engines[].id' "$cfg" | tr '\n' ' ')
printf '%s' "$ids" | grep -qw chatgpt || fail "config must name chatgpt"
printf '%s' "$ids" | grep -qw perplexity || fail "config must name perplexity"
printf '%s' "$ids" | grep -qw claude || fail "config must name claude"
grep -q 'OPENROUTER' "$cfg" && fail "config must not wire metered OpenRouter by default"
ok "config: 10-15 queries, three engines, no OpenRouter"

# (f)(g) deliverable run
scratch=$(mktemp -d -t aeo-probe.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/fixture.json" <<'EOF'
{
  "chatgpt": {
    "best sneaker price tracker": "Try StockX. 0509.io also tracks sneaker prices.",
    "sneaker resale data site": "Five to Nine is a sneaker data site some people mention.",
    "StockX alternatives": "GOAT.com and StockX dominate. No other names.",
    "best sneaker resale tracker": "See sku 10509 in the warehouse list.",
    "sneaker price comparison site": "StockX.",
    "stockx alternative for sneaker data": "StockX.",
    "best site to track sneaker prices": "StockX.",
    "sneaker market data platform": "StockX.",
    "goat vs stockx alternative": "StockX.",
    "sneaker resale analytics": "StockX.",
    "best sneaker deal tracker": "StockX.",
    "sneaker price history site": "StockX.",
    "where to track sneaker resale prices": "StockX.",
    "sneaker inventory tracker": "StockX.",
    "best alternative to stockx for data": "StockX."
  }
}
EOF

python3 "$probe" \
  --config "$cfg" \
  --fixture "$scratch/fixture.json" \
  --prom "$scratch/fleet-aeo.prom" \
  --log "$scratch/latest.json" \
  --now 1700000000 \
  >"$scratch/out" 2>"$scratch/err" || fail "fixture run must exit 0 (err=$(cat "$scratch/err"))"

grep -q 'fleet_aeo_cited{engine="chatgpt",query_class="sneaker_money"} 1' "$scratch/fleet-aeo.prom" \
  || fail "chatgpt cited should be 1 (0509.io once), got: $(cat "$scratch/fleet-aeo.prom")"
grep -q 'fleet_aeo_mentioned{engine="chatgpt",query_class="sneaker_money"} 2' "$scratch/fleet-aeo.prom" \
  || fail "chatgpt mentioned should be 2 (host + five to nine); 10509 must not count"
grep -q 'fleet_aeo_engine_up{engine="chatgpt"} 1' "$scratch/fleet-aeo.prom" \
  || fail "chatgpt engine_up should be 1"
grep -q 'fleet_aeo_engine_up{engine="perplexity"} 0' "$scratch/fleet-aeo.prom" \
  || fail "perplexity not in fixture must be engine_up=0"
grep -q 'fleet_aeo_engine_up{engine="claude"} 0' "$scratch/fleet-aeo.prom" \
  || fail "claude not in fixture must be engine_up=0"
grep -q 'fleet_aeo_queries_total{engine="perplexity",query_class="sneaker_money",status="unavailable"} 15' "$scratch/fleet-aeo.prom" \
  || fail "skipped engine must still export query count with status=unavailable"
grep -q 'fleet_aeo_probe_last_run_seconds 1700000000' "$scratch/fleet-aeo.prom" \
  || fail "prom must record --now"

cited=$(jq -r '.engines.chatgpt.results[] | select(.query=="best sneaker price tracker") | .cited_0509' "$scratch/latest.json")
[[ "$cited" == "true" ]] || fail "0509.io row must be cited"
mention_10509=$(jq -r '.engines.chatgpt.results[] | select(.query=="best sneaker resale tracker") | .mentioned_0509' "$scratch/latest.json")
[[ "$mention_10509" == "false" ]] || fail "10509 must not count as 0509"
comps=$(jq -r '.engines.chatgpt.results[] | select(.query=="best sneaker price tracker") | .competitors_cited | join(",")' "$scratch/latest.json")
[[ "$comps" == *StockX* ]] || fail "StockX should be detected, got $comps"
ok "(f) citation detector: host cited, name mentioned, 10509 ignored"

# Live skip path (no keys, no fixture): unavailable, exit 0, no secrets
unset OPENAI_API_KEY PERPLEXITY_API_KEY ANTHROPIC_API_KEY || true
python3 "$probe" \
  --config "$cfg" \
  --prom "$scratch/skip.prom" \
  --log "$scratch/skip.json" \
  --now 1700000001 \
  >"$scratch/skip.out" 2>"$scratch/skip.err" || fail "no-key run must exit 0"

for engine in chatgpt perplexity claude; do
  grep -q "fleet_aeo_engine_up{engine=\"$engine\"} 0" "$scratch/skip.prom" \
    || fail "no-key $engine must be engine_up=0"
  grep -q "fleet_aeo_cited{engine=\"$engine\",query_class=\"sneaker_money\"} 0" "$scratch/skip.prom" \
    || fail "no-key $engine cited must be 0"
done
if grep -qiE 'sk-|api[_-]?key|Bearer ' "$scratch/skip.json" "$scratch/skip.prom" "$scratch/skip.err"; then
  fail "probe output leaked a key-shaped secret"
fi
ok "(g) missing seats skip with engine_up=0 and no secret leak"

# Nested CI host
grep -Fq 'bash "$here/aeo-probe.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file"
ok "contracts: nested CI host"

ok "aeo-probe: eval, MANIFEST, python3 runner, timer, install, citation, skip"
