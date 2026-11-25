#!/usr/bin/env python3
"""Serves this directory and writes each POST /result body to results-<n>.json."""
import http.server, sys, itertools, os
counter = itertools.count()
class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        name = f"results-{next(counter)}-{self.headers.get('User-Agent','')[:20].replace('/','_').replace(' ','_')}.json"
        open(name, "wb").write(body)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
