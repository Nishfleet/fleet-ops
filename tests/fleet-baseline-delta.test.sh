#!/usr/bin/env bash
# tests/fleet-baseline-delta.test.sh
#
# Proves fleet-ops#1151 week-over-week MAD strangeness pre-pass, offline:
#   1. --help exists and does not run a live query.
#   2. Fixture: a |z|>3 jump ranks first; MAD=0 constant-then-jump flags inf.
#   3. Cap: 25 flagged series → ranked 20.
#   4. Insufficient history is skipped, not flagged.
#   5. Heartbeat textfile is written (last_run + anomalies + scanned).
#   6. Fake Prometheus HTTP API path writes the same report shape.
#   7. Prometheus down fails loud and does not write the heartbeat.
#   8. MANIFEST + install.sh enable --now (fleet-ops#183).
#   9. Timer is Sunday 05:10 IST, Persistent, [Install], named reason.
#  10. Rule fragment has absent()+stale and no anomaly-value page.
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without
# a workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-baseline-delta.py"
svc="$repo_root/systemd/fleet-baseline-delta.service"
timer="$repo_root/systemd/fleet-baseline-delta.timer"
rule="$repo_root/config/fleet-baseline-delta.rule.yml"
install_sh="$repo_root/install.sh"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
[[ -f "$rule" ]] || fail "missing $rule"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t baseline-delta.XXXXXX)"
pids=()
cleanup() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

# --- 1. --help -------------------------------------------------------------
help_out="$("$bin" --help 2>&1)" || fail "--help must exit 0"
printf '%s\n' "$help_out" | grep -qi 'MAD\|strangeness\|Prometheus' \
  || fail "--help must name the job (MAD/strangeness/Prometheus)"
ok "1. --help exits 0 and describes the job"

# --- 2. fixture: jump ranks first; MAD=0 flags inf -------------------------
fix="$scratch/fixture.json"
cat >"$fix" <<'JSON'
{
  "now": 1787800000,
  "series": [
    {
      "metric": {"__name__": "fleet_ready_work"},
      "kind": "gauge",
      "weekly": [10, 11, 10, 12, 50]
    },
    {
      "metric": {"__name__": "fleet_test_alert"},
      "kind": "gauge",
      "weekly": [0, 0, 0, 0, 1]
    },
    {
      "metric": {"__name__": "node_load1"},
      "kind": "gauge",
      "weekly": [0.2, 0.21, 0.19, 0.22, 0.20]
    }
  ]
}
JSON
out1="$scratch/out1"
prom1="$scratch/h1.prom"
"$bin" --fixture "$fix" --out-dir "$out1" --prom-file "$prom1" --now 1787800000 \
  >/dev/null || fail "fixture run exited nonzero"
[[ -f "$out1/baseline-delta.md" ]] || fail "markdown report missing"
[[ -f "$out1/baseline-delta.json" ]] || fail "json report missing"
jq -e '.paging == false' "$out1/baseline-delta.json" >/dev/null \
  || fail "report must declare paging=false"
jq -e '.ranked[0].id == "fleet_test_alert" or .ranked[0].id == "fleet_ready_work"' \
  "$out1/baseline-delta.json" >/dev/null \
  || fail "a flagged series must rank first, got $(jq -c .ranked "$out1/baseline-delta.json")"
# MAD=0 constant 0 then 1 is infinite z and must be in the ranked list.
jq -e '.ranked[] | select(.id == "fleet_test_alert") | .z == "+inf"' \
  "$out1/baseline-delta.json" >/dev/null \
  || fail "MAD=0 jump must flag z=+inf, got $(jq -c .ranked "$out1/baseline-delta.json")"
# Quiet series must not be ranked.
jq -e '[.ranked[].id] | index("node_load1")' "$out1/baseline-delta.json" >/dev/null \
  && fail "quiet node_load1 must not be ranked"
ok "2. fixture ranks the jump; MAD=0 flags +inf; quiet series stay out"

# --- 3. cap at 20 ----------------------------------------------------------
python3 - "$scratch/cap.json" <<'PY'
import json, sys
series = []
for i in range(25):
    series.append({
        "metric": {"__name__": "fleet_cap", "i": str(i)},
        "kind": "gauge",
        "weekly": [1, 1, 1, 1, 100],
    })
json.dump({"now": 1787800000, "series": series}, open(sys.argv[1], "w"))
PY
out3="$scratch/out3"
"$bin" --fixture "$scratch/cap.json" --out-dir "$out3" --prom-file "$scratch/h3.prom" \
  --now 1787800000 >/dev/null || fail "cap fixture exited nonzero"
n="$(jq '.ranked | length' "$out3/baseline-delta.json")"
[[ "$n" == "20" ]] || fail "ranked cap must be 20, got $n"
flagged="$(jq '.flagged' "$out3/baseline-delta.json")"
[[ "$flagged" == "25" ]] || fail "flagged must stay 25, got $flagged"
ok "3. ranked list is capped at 20 (25 flagged)"

# --- 4. insufficient history is skipped -----------------------------------
cat >"$scratch/short.json" <<'JSON'
{
  "now": 1787800000,
  "series": [
    {"metric": {"__name__": "fleet_new"}, "kind": "gauge", "weekly": [3]}
  ]
}
JSON
out4="$scratch/out4"
"$bin" --fixture "$scratch/short.json" --out-dir "$out4" --prom-file "$scratch/h4.prom" \
  --now 1787800000 >/dev/null || fail "short fixture exited nonzero"
jq -e '.ranked_n == 0 and .scanned == 1 and .skipped == 1' "$out4/baseline-delta.json" >/dev/null \
  || fail "single-point series must be skipped, got $(cat "$out4/baseline-delta.json")"
ok "4. insufficient history is skipped, not flagged"

# --- 4b. short window: last day vs earlier days (live 15d-retention class) -
now=1787800000
python3 - "$scratch/shortdays.json" "$now" <<'PY'
import json, sys
now = int(sys.argv[2])
day = 86400
json.dump({
    "now": now,
    "series": [{
        "metric": {"__name__": "node_load1"},
        "kind": "gauge",
        "points": [
            [now - 3.5 * day, 0.2],
            [now - 2.5 * day, 0.2],
            [now - 1.5 * day, 0.2],
            [now - 0.5 * day, 5.0],
        ],
    }],
}, open(sys.argv[1], "w"))
PY
out4b="$scratch/out4b"
"$bin" --fixture "$scratch/shortdays.json" --out-dir "$out4b" --prom-file "$scratch/h4b.prom" \
  --now "$now" >/dev/null || fail "short-window fixture exited nonzero"
jq -e '.ranked_n == 1 and .ranked[0].id == "node_load1"' "$out4b/baseline-delta.json" >/dev/null \
  || fail "4-day window with a last-day spike must rank, got $(cat "$out4b/baseline-delta.json")"
ok "4b. short window splits last day vs earlier days"

# --- 5. heartbeat textfile -------------------------------------------------
grep -q '^fleet_baseline_delta_last_run_seconds ' "$prom1" \
  || fail "heartbeat missing last_run_seconds"
grep -q '^fleet_baseline_delta_anomalies ' "$prom1" \
  || fail "heartbeat missing anomalies"
grep -q '^fleet_baseline_delta_series_scanned ' "$prom1" \
  || fail "heartbeat missing series_scanned"
ok "5. heartbeat textfile carries last_run + anomalies + scanned"

# --- 6. fake Prometheus HTTP API ------------------------------------------
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$port" "$scratch/http.log" <<'PY' &
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
log_path = sys.argv[2]
now = 1787800000.0
week = 7 * 24 * 3600

def weekly_points(values):
    # oldest-first weekly medians as two samples per week
    out = []
    n = len(values)
    for i, val in enumerate(values):
        age = n - 1 - i
        ts0 = now - age * week - week + 60
        ts1 = now - age * week - 60
        out.append([ts0, str(val)])
        out.append([ts1, str(val)])
    return out

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write((fmt % args) + "\n")

    def _send(self, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _params(self):
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        if self.command == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8") if length else ""
            q.update(urllib.parse.parse_qs(raw))
        return parsed.path, {k: v[0] for k, v in q.items()}

    def do_GET(self):
        path, _ = self._params()
        if path == "/api/v1/label/__name__/values":
            self._send({"status": "success", "data": ["fleet_ready_work", "go_goroutines", "node_load1"]})
            return
        if path == "/api/v1/metadata":
            self._send({"status": "success", "data": {
                "fleet_ready_work": [{"type": "gauge", "help": "x", "unit": ""}],
                "node_load1": [{"type": "gauge", "help": "x", "unit": ""}],
            }})
            return
        self.send_error(404)

    def do_POST(self):
        path, params = self._params()
        if path != "/api/v1/query_range":
            self.send_error(404)
            return
        query = params.get("query", "")
        if query == "fleet_ready_work":
            values = weekly_points([10, 11, 10, 12, 50])
            metric = {"__name__": "fleet_ready_work", "job": "node"}
        elif query == "node_load1":
            values = weekly_points([0.2, 0.21, 0.19, 0.22, 0.20])
            metric = {"__name__": "node_load1", "job": "node"}
        else:
            self._send({"status": "success", "data": {"resultType": "matrix", "result": []}})
            return
        self._send({"status": "success", "data": {"resultType": "matrix", "result": [
            {"metric": metric, "values": values}
        ]}})

HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
pids+=($!)
python3 - "$port" <<'PY' || fail "fake prometheus did not start"
import socket, sys, time
port = int(sys.argv[1])
for _ in range(50):
    s = socket.socket()
    try:
        s.settimeout(0.1)
        s.connect(("127.0.0.1", port))
        s.close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.05)
raise SystemExit(1)
PY
out6="$scratch/out6"
"$bin" --prom-url "http://127.0.0.1:$port" --out-dir "$out6" \
  --prom-file "$scratch/h6.prom" --now 1787800000 --timeout 5 \
  >/dev/null || fail "HTTP path exited nonzero"
jq -e '.scanned >= 1 and .ranked_n >= 1' "$out6/baseline-delta.json" >/dev/null \
  || fail "HTTP path must rank the planted jump, got $(cat "$out6/baseline-delta.json")"
jq -e '.ranked[] | select(.id | startswith("fleet_ready_work"))' \
  "$out6/baseline-delta.json" >/dev/null \
  || fail "HTTP path must rank fleet_ready_work"
ok "6. fake Prometheus HTTP API path writes a ranked report"

# --- 7. prometheus down fails loud, no heartbeat ---------------------------
out7="$scratch/out7"
prom7="$scratch/h7.prom"
set +e
"$bin" --prom-url "http://127.0.0.1:1" --out-dir "$out7" --prom-file "$prom7" \
  --timeout 1 --now 1787800000 >/dev/null 2>"$scratch/down.err"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "unreachable prometheus must exit nonzero"
[[ ! -f "$prom7" ]] || fail "failed run must not write the heartbeat"
ok "7. prometheus down fails loud and skips the heartbeat"

# --- 8. MANIFEST + install.sh ----------------------------------------------
grep -Fxq "bin/fleet-baseline-delta.py /home/nish/.local/bin/fleet-baseline-delta" "$manifest" \
  || fail "MANIFEST missing bin/fleet-baseline-delta.py"
grep -Fxq "systemd/fleet-baseline-delta.service /home/nish/.config/systemd/user/fleet-baseline-delta.service" "$manifest" \
  || fail "MANIFEST missing service"
grep -Fxq "systemd/fleet-baseline-delta.timer /home/nish/.config/systemd/user/fleet-baseline-delta.timer" "$manifest" \
  || fail "MANIFEST missing timer"
grep -Fq -- '"$SYSTEMCTL" --user enable --now fleet-baseline-delta.timer' "$install_sh" \
  || fail "install.sh must enable --now fleet-baseline-delta.timer"
ok "8. MANIFEST + install.sh enable --now"

# --- 9. timer / service shape ----------------------------------------------
grep -q '^# Named reason' "$timer" \
  || fail "timer must carry a Named reason"
grep -q '^OnCalendar=Sun \*\-\*\-\* 05:10:00 Asia/Kolkata$' "$timer" \
  || fail "timer must fire Sunday 05:10 IST"
grep -q '^Persistent=true$' "$timer" || fail "timer must be Persistent"
grep -q '^\[Install\]$' "$timer" || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" || fail "timer [Install] must WantedBy=timers.target"
grep -q '^Type=oneshot$' "$svc" || fail "service must be oneshot"
grep -q '^Restart=no$' "$svc" || fail "service must Restart=no"
grep -q '^ExecStart=/usr/bin/python3 /home/nish/.local/bin/fleet-baseline-delta$' "$svc" \
  || fail "ExecStart must be /usr/bin/python3 fleet-baseline-delta (CI systemd-analyze stubs python3, not a new dest)"
ok "9. timer is Sunday 05:10 IST; service is oneshot Restart=no"

# --- 9b. CI class locks (shellcheck SC1071, systemd-analyze missing dest, semgrep urllib) ---
[[ "$bin" == *.py ]] || fail "source must be .py so CI shellcheck glob bin/!(*.py|*.ts) skips it"
grep -q 'nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected' "$bin" \
  || fail "source must carry the urllib nosemgrep audit comment"
grep -q 'def require_http_url' "$bin" || fail "source must reject non-http(s) prometheus URLs"
set +e
"$bin" --prom-url "file:///etc/passwd" --out-dir "$scratch/fileurl" \
  --prom-file "$scratch/h-file.prom" --timeout 1 --now 1787800000 \
  >/dev/null 2>"$scratch/fileurl.err"
file_rc=$?
set -e
[[ "$file_rc" != "0" ]] || fail "file:// prometheus URL must exit nonzero"
grep -q "http(s)" "$scratch/fileurl.err" || fail "file:// reject must name http(s): $(cat "$scratch/fileurl.err")"
[[ ! -f "$scratch/h-file.prom" ]] || fail "file:// reject must not write the heartbeat"
ok "9b. .py source, python3 ExecStart, nosemgrep, file:// rejected"

# --- 10. rule fragment: organ liveness only, no anomaly page ---------------
grep -q 'absent(fleet_baseline_delta_last_run_seconds)' "$rule" \
  || fail "rule fragment must contain absent(fleet_baseline_delta_last_run_seconds)"
grep -q 'FleetBaselineDeltaStale' "$rule" \
  || fail "rule fragment must contain FleetBaselineDeltaStale"
if grep -qiE 'z-score|z_score|anomaly.*>|baseline_delta_anomalies *[>=]' "$rule"; then
  fail "rule fragment must not page on anomaly values: $(grep -n . "$rule")"
fi
if command -v promtool >/dev/null 2>&1; then
  tmp_rules="$scratch/rules.yml"
  printf 'groups:\n  - name: test\n    rules:\n' >"$tmp_rules"
  sed -e 's/^/      /' "$rule" >>"$tmp_rules"
  promtool check rules "$tmp_rules" >/dev/null \
    || fail "promtool check rules failed on the fragment"
  ok "10. rule fragment is absent()+stale only; promtool clean"
else
  ok "10. rule fragment is absent()+stale only (promtool not installed)"
fi

# Nested CI host
grep -Fq 'bash "$here/fleet-baseline-delta.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file"
ok "contracts: nested CI host"

ok "fleet-baseline-delta: help, MAD fixture, cap-20, warmup skip, heartbeat, HTTP, fail-loud, MANIFEST, timer, rules"
