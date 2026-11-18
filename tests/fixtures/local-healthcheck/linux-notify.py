#!/usr/bin/env python3
"""Local HTTP acknowledgement with an inflight/readiness barrier; no payload logs."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import signal
import socketserver
import time


class LocalServer(HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind performs reverse DNS, which stalls on macOS.
        socketserver.TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 8192:
                self.send_error(413)
                return
            self.rfile.read(length)  # Never persist/print URL, body or token.
            try:
                state = json.loads(args.state.read_text())
                reserved = state["pending"]["phase"] == "inflight"
            except (OSError, ValueError, KeyError, TypeError):
                reserved = False
            with (args.root / "receipts.jsonl").open("a") as out:
                out.write(json.dumps({"inflight_visible": reserved}) + "\n")
            (args.root / "received").write_text("ready\n")
            deadline = time.monotonic() + 15
            while not (args.root / "release").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            accepted = reserved and (args.root / "release").exists()
            body = json.dumps({"ok": accepted}).encode()
            self.send_response(200 if accepted else 409)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = LocalServer(("127.0.0.1", args.port), Handler)
    server.timeout = 0.2
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    (args.root / "http-ready").write_text(str(server.server_port) + "\n")
    try:
        while not stopping:
            server.handle_request()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
