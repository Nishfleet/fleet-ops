"""Webhook sink for the grafana-boot reload drill (fleet-ops#9445).

Answers 200 to every POST and appends, per delivery, an `AUTH <header>` line (which
token Grafana's webhook contact point sent) and a `BODY <path> <json>` line (what
the payload template rendered).

usage: webhook_sink.py PORT LOG_FILE
"""
import http.server
import sys

PORT, LOG_FILE = int(sys.argv[1]), sys.argv[2]


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(LOG_FILE, "a") as f:
            f.write(f"AUTH {self.headers.get('authorization')}\n")
            f.write(f"BODY {self.path} {' '.join(body.decode(errors='replace').split())}\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
