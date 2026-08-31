from http.server import BaseHTTPRequestHandler, HTTPServer
import base64

EXPECTED = "Basic " + base64.b64encode(b"vmalert:secret-v1").decode()
RULES = b"""groups:\n  - name: smoke\n    rules:\n      - alert: SmokeAlert\n        expr: vector(1)\n"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != EXPECTED:
            self.send_response(401)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/yaml")
        self.end_headers()
        self.wfile.write(RULES)

    def log_message(self, fmt, *args):
        pass

HTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
