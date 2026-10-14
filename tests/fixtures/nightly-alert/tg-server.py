#!/usr/bin/env python3
"""Local stand-in for the Telegram Bot API (040-nightly-red-alert, amendment 1).

Contract: specs/040-nightly-red-alert/contracts/alert-oracle.md section 6.

tests/nightly-alert.bats starts this server so the REAL curl of the script under
test talks to a real HTTP server. What a fake curl could not tell is exactly what
can break here: the grammar of the curl config file, the encoding of text@file and
the write-out of the status code.

Environment (all required):
  TG_DIR      directory for the control and log files below
  EVENTS_LOG  file that gets one "tg" line per request; the order against the lines
              the gh fake writes there is how the tests check "after the issue"

Control files, read on every request:
  tg-token    the token the server accepts
  tg-chat     the chat_id the server accepts
  tg-mode     ok (default) | ok-false | unauthorized | chat-not-found | rate-limit |
              server-error | echo-token | hang

Written:
  tg-port            the port, once the server is listening (written atomically)
  tg-requests.jsonl  one JSON object per request: method, path, token,
                     content_type and fields (the decoded form fields)

Decision order for each request, as Telegram does it: a token that is not shaped
like a token is a 404; then a mode other than ok answers as the mode says (so a test
can force any failure with the right token); in ok mode a different token is a 401, a
different chat is a 400, and anything else is a 200 with {"ok": true, ...}.

ASCII only, standard library only, Python 3.9 compatible.
"""
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

TG_DIR = os.environ.get("TG_DIR", "")
EVENTS_LOG = os.environ.get("EVENTS_LOG", "")
if not TG_DIR:
    sys.stderr.write("tg-server: TG_DIR is required\n")
    sys.exit(2)

PATH_RE = re.compile(r"^/bot([^/]+)/sendMessage$")
TOKEN_SHAPE = re.compile(r"^[0-9]+:[A-Za-z0-9_-]+$")
SEEN = [0]


def control(name, default=""):
    try:
        with open(os.path.join(TG_DIR, name), "r") as fh:
            return fh.read().strip()
    except OSError:
        return default


def append(path, line):
    if path:
        with open(path, "a") as fh:
            fh.write(line + "\n")


def failure(code, description, extra=None):
    body = {"ok": False, "error_code": code, "description": description}
    if extra:
        body["parameters"] = extra
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        pass

    def reply(self, status, payload, ctype="application/json"):
        text = payload if isinstance(payload, str) else json.dumps(payload)
        data = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        fields = dict((k, v[0]) for k, v in parse_qs(raw, keep_blank_values=True).items())
        match = PATH_RE.match(self.path)
        token = match.group(1) if match else ""
        SEEN[0] += 1
        record = {
            "method": self.command,
            "path": self.path,
            "token": token,
            "content_type": self.headers.get("Content-Type", ""),
            "fields": fields,
        }
        append(os.path.join(TG_DIR, "tg-requests.jsonl"), json.dumps(record, sort_keys=True))
        append(EVENTS_LOG, "tg")

        if not match or not TOKEN_SHAPE.match(token):
            return self.reply(404, failure(404, "Not Found"))
        mode = control("tg-mode", "ok")
        if mode == "unauthorized":
            return self.reply(401, failure(401, "Unauthorized"))
        if mode == "chat-not-found":
            return self.reply(400, failure(400, "Bad Request: chat not found"))
        if mode == "rate-limit":
            return self.reply(429, failure(429, "Too Many Requests: retry after 5", {"retry_after": 5}))
        if mode == "server-error":
            return self.reply(500, "Internal Server Error", "text/plain")
        if mode == "ok-false":
            return self.reply(200, failure(400, "Bad Request: message is too long"))
        if mode == "echo-token":
            # an error description that quotes the request path, as some gateways do: the bot
            # token travels in that path, so a script that prints the description as it came
            # would print the token. The padding puts the token across the 120-character cut the
            # script applies to a description, which catches a redaction done AFTER the cut.
            return self.reply(400, failure(400, "Bad Request: bad path " + "x" * 70 + self.path))
        if mode == "hang":
            time.sleep(120)
            return None
        if token != control("tg-token"):
            return self.reply(401, failure(401, "Unauthorized"))
        if fields.get("chat_id", "") != control("tg-chat"):
            return self.reply(400, failure(400, "Bad Request: chat not found"))
        return self.reply(200, {
            "ok": True,
            "result": {
                "message_id": SEEN[0],
                "date": int(time.time()),
                "chat": {"id": fields.get("chat_id", "")},
            },
        })

    do_POST = handle_any
    do_GET = handle_any


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    tmp = os.path.join(TG_DIR, "tg-port.tmp")
    with open(tmp, "w") as fh:
        fh.write(str(port) + "\n")
    os.rename(tmp, os.path.join(TG_DIR, "tg-port"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
