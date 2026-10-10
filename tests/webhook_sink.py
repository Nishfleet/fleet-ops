"""Webhook sink for the grafana-boot reload drill (fleet-ops#9445).

Answers 200 to every POST and appends the request's Authorization header to the
log file, one `AUTH <value>` line per delivery, so the drill can see which token
Grafana's webhook contact point sent.

usage: webhook_sink.py PORT LOG_FILE
"""
import http.server
import sys

PORT, LOG_FILE = int(sys.argv[1]), sys.argv[2]


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(LOG_FILE, "a") as f:
            f.write(f"AUTH {self.headers.get('authorization')}\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
