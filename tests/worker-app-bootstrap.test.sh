#!/usr/bin/env bash
# tests/worker-app-bootstrap.test.sh
#
# fleet-ops#409: the live bootstrap listener.
#   1. A failed GitHub conversion logs HTTP status + body on stderr
#      (silenced-seam class, same as fleet-ops#342).
#   2. The conversion POST is empty-bodied — GitHub's documented handshake
#      is POST /app-manifests/{code}/conversions with no JSON body. A body
#      of {"code":...} is what failed the live run while curl (empty POST)
#      returned 201.
#   3. PUBLIC_URL / --serve rewrites redirect_url and callback_urls so
#      GitHub sends the one-time code to the tailscale URL, not 127.0.0.1.
#   4. The wrapper prints the tailscale serve command.
#
# Wraps the existing bin/worker-app-bootstrap listener (GitHub App manifest
# flow). No new scheduler, no substitute for gh/GitHub's own handshake.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
server_py="$repo_root/bin/_worker-app-bootstrap-server.py"
wrapper="$repo_root/bin/worker-app-bootstrap"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$server_py" ]] || fail "missing $server_py"
[[ -x "$wrapper" ]] || fail "not executable: $wrapper"

scratch="$(mktemp -d -t worker-app-bootstrap.XXXXXX)"
pids=()
cleanup() {
  local p
  for p in "${pids[@]+"${pids[@]}"}"; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_http() {
  local url="$1" n=0
  while (( n < 50 )); do
    if curl -sf -o /dev/null "$url"; then
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

cat >"$scratch/mock_github.py" <<'PY'
#!/usr/bin/env python3
"""Local stand-in for api.github.com conversion. Never logs secrets."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

log_path, mode, port_s = sys.argv[1], sys.argv[2], sys.argv[3]
port = int(port_s)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(log_path, "w", encoding="utf-8") as f:
            f.write("path=%s\nlen=%d\nbody=%s\n" % (
                self.path, n, body.decode("utf-8", "replace")))
        if mode == "fail":
            self.send_response(422)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"message":"fixture-exchange-rejected"}')
            return
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({
            "id": 4728578,
            "client_id": "Iv1.test",
            "client_secret": "secret",
            "webhook_secret": "hook",
            "pem": "TEST_ONLY_NOT_A_KEY",
            "slug": "nishfleet-worker",
            "html_url": "https://github.com/apps/nishfleet-worker",
            "name": "nishfleet-worker",
            "owner": {"login": "Nishfleet"},
        }).encode("utf-8"))


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

start_bootstrap() {
  local listen_port="$1"
  local api_origin="$2"
  local public_url="${3:-}"
  local creds="$scratch/creds.env"
  : >"$creds"
  LISTEN_ADDR=127.0.0.1 \
    PORT="$listen_port" \
    TIMEOUT_S=20 \
    MANIFEST_PATH="$repo_root/credentials/app-manifest.json" \
    BOOTSTRAP_PATH="$repo_root/credentials/bootstrap.html" \
    CREDS_FILE="$creds" \
    GITHUB_API_ORIGIN="$api_origin" \
    PUBLIC_URL="$public_url" \
    python3 "$server_py" >"$scratch/boot.out" 2>"$scratch/boot.err" &
  pids+=($!)
  wait_http "http://127.0.0.1:${listen_port}/" \
    || fail "bootstrap server did not start: $(cat "$scratch/boot.err")"
}

# --- 1. failed exchange logs status + body --------------------------------
mock_port="$(free_port)"
python3 "$scratch/mock_github.py" "$scratch/mock.log" fail "$mock_port" &
pids+=($!)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -X POST "http://127.0.0.1:${mock_port}/ping" && break
  sleep 0.1
done

boot_port="$(free_port)"
start_bootstrap "$boot_port" "http://127.0.0.1:${mock_port}"

set +e
cb_out="$(curl -sS -w '\n%{http_code}' "http://127.0.0.1:${boot_port}/callback?code=test-code")"
set -e
cb_code="${cb_out##*$'\n'}"
[[ "$cb_code" == "502" ]] || fail "failed exchange must return 502, got $cb_code ($cb_out)"
grep -q 'exchange HTTP 422' "$scratch/boot.err" \
  || fail "stderr must contain HTTP status, got: $(cat "$scratch/boot.err")"
grep -q 'fixture-exchange-rejected' "$scratch/boot.err" \
  || fail "stderr must contain GitHub error body, got: $(cat "$scratch/boot.err")"
[[ -f "$scratch/mock.log" ]] || fail "mock github was not hit"
grep -q '^len=0$' "$scratch/mock.log" \
  || fail "conversion POST must be empty-bodied, got: $(cat "$scratch/mock.log")"
ok "failed exchange logs HTTP 422 + body; POST body is empty"

# --- 2. successful empty POST writes creds --------------------------------
kill "${pids[0]}" 2>/dev/null || true   # mock (fail)
kill "${pids[1]}" 2>/dev/null || true   # bootstrap
sleep 0.2
pids=()

mock_port="$(free_port)"
python3 "$scratch/mock_github.py" "$scratch/mock-ok.log" ok "$mock_port" &
pids+=($!)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -X POST "http://127.0.0.1:${mock_port}/ping" && break
  sleep 0.1
done

boot_port="$(free_port)"
start_bootstrap "$boot_port" "http://127.0.0.1:${mock_port}"

set +e
ok_out="$(curl -sS -w '\n%{http_code}' "http://127.0.0.1:${boot_port}/callback?code=good-code")"
set -e
ok_code="${ok_out##*$'\n'}"
[[ "$ok_code" == "200" ]] || fail "successful exchange must return 200, got $ok_code ($ok_out)"
grep -q 'NISHFLEET_WORKER_APP_ID=4728578' "$scratch/creds.env" \
  || fail "creds file missing APP_ID, got: $(cat "$scratch/creds.env")"
perm="$(stat -c '%a' "$scratch/creds.env")"
[[ "$perm" == "600" ]] || fail "creds file must be 0600, got $perm"
grep -q '^len=0$' "$scratch/mock-ok.log" \
  || fail "successful conversion POST must also be empty, got: $(cat "$scratch/mock-ok.log")"
ok "empty POST conversion writes 0600 creds"

# --- 3. --serve / PUBLIC_URL rewrites redirect_url ------------------------
kill "${pids[0]}" 2>/dev/null || true
kill "${pids[1]}" 2>/dev/null || true
sleep 0.2
pids=()

boot_port="$(free_port)"
start_bootstrap "$boot_port" "http://127.0.0.1:9" "https://box.tailnet.ts.net"

served="$(curl -sS "http://127.0.0.1:${boot_port}/app-manifest.json")"
echo "$served" | jq -e '.redirect_url == "https://box.tailnet.ts.net/callback"' >/dev/null \
  || fail "served redirect_url must be the public callback, got: $served"
echo "$served" | jq -e '.callback_urls == ["https://box.tailnet.ts.net/callback"]' >/dev/null \
  || fail "served callback_urls must be the public callback, got: $served"
echo "$served" | jq -e 'has("hook_attributes") | not' >/dev/null \
  || fail "served manifest must omit hook_attributes when webhook is off"
echo "$served" | jq -e 'has("default_callback_url") | not' >/dev/null \
  || fail "served manifest must not use pre-2026 default_callback_url"
echo "$served" | jq -e 'has("permissions") | not' >/dev/null \
  || fail "served manifest must use default_permissions, not permissions"
echo "$served" | jq -e 'has("events") | not' >/dev/null \
  || fail "served manifest must not have top-level events"
ok "PUBLIC_URL rewrites redirect_url; stale schema keys are absent"

# --- 4. wrapper documents tailscale serve --------------------------------
grep -q 'tailscale serve' "$wrapper" \
  || fail "worker-app-bootstrap must document tailscale serve"
timeout --preserve-status 3 env \
  WORKER_APP_BOOTSTRAP_PORT="$(free_port)" \
  WORKER_APP_BOOTSTRAP_TIMEOUT_S=1 \
  WORKER_APP_CREDS_FILE="$scratch/wrapper.env" \
  "$wrapper" --serve https://box.tailnet.ts.net >"$scratch/wrap.out" 2>"$scratch/wrap.err" || true
grep -q 'tailscale serve --bg' "$scratch/wrap.err" \
  || fail "wrapper --serve must print tailscale serve command, got: $(cat "$scratch/wrap.err")"
grep -q 'https://box.tailnet.ts.net/?org=Nishfleet' "$scratch/wrap.err" \
  || fail "wrapper --serve must print the public open URL, got: $(cat "$scratch/wrap.err")"
ok "wrapper --serve prints tailscale serve + public URL"

echo "OK: worker-app-bootstrap exchange logging, empty POST, and --serve"
