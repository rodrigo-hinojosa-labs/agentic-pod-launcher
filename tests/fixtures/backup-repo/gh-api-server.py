#!/usr/bin/env python3
"""A tiny stand-in for the GitHub REST API, for the 048 pull-request path tests.

Contract: specs/048-fleet-backup-main/contracts/pr-fallback.md (P1 to P3).

Endpoints (the repository path is the part of the git URL after the host, without
.git, so a test repository served at /name.git is /repos/name):
  POST  /repos/<repo>/pulls               -> 201 {"number": N}
  PUT   /repos/<repo>/pulls/<n>/merge     -> 200 {"merged": true, "sha": ...} in mode
                                             merge-ok (main of the bare repository is
                                             moved to the pull request head when main
                                             is its ancestor, else 405); 405 in mode
                                             merge-405
  PATCH /repos/<repo>/pulls/<n>           -> 200 (state=closed is recorded)
  GET   /repos/<repo>                     -> 200 {"size": 4321} (the size in KB)

Environment:
  GH_API_ROOT       directory with the bare repositories (the git server's)
  GH_API_MODE_FILE  file with the mode word: merge-ok (default) or merge-405
  GH_API_PORT_FILE  where the ephemeral port is written, atomically
  GH_API_LOG        one line per request: "<code> <method> <path> auth=<ok|none>"
  GH_API_TOKEN_FILE file whose content is the only bearer token accepted

It never logs the token and never calls HTTPServer.server_bind (getfqdn() was slow
on the macOS CI runner). ASCII only, standard library only.
"""
import json
import os
import socketserver
import subprocess
import threading
from http.server import BaseHTTPRequestHandler

ROOT = os.environ["GH_API_ROOT"]
MODE_FILE = os.environ.get("GH_API_MODE_FILE", "")
PORT_FILE = os.environ["GH_API_PORT_FILE"]
LOG_FILE = os.environ["GH_API_LOG"]
TOKEN_FILE = os.environ["GH_API_TOKEN_FILE"]
LOCK = threading.Lock()
PULLS = {}


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def log(line):
    with LOCK:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def git(bare, *args):
    return subprocess.run(["git", "-C", bare] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,
                          env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def _reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        auth = "ok" if self.headers.get("Authorization", "") == "Bearer " + read(TOKEN_FILE) else "none"
        parts = self.path.strip("/").split("/")
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length) or b"{}") if length else {}
        code, body = 404, {"message": "Not Found"}
        if auth != "ok":
            code, body = 401, {"message": "Bad credentials"}
        elif self.command == "GET" and len(parts) == 2 and parts[0] == "repos":
            code, body = 200, {"size": 4321, "private": True}
        elif len(parts) >= 3 and parts[0] == "repos" and parts[2] == "pulls":
            repo = parts[1]
            bare = os.path.join(ROOT, repo + ".git")
            if self.command == "POST" and len(parts) == 3:
                n = len(PULLS) + 1
                PULLS[n] = {"head": payload.get("head", ""), "base": payload.get("base", ""), "state": "open", "repo": repo}
                code, body = 201, {"number": n}
            elif self.command == "PUT" and len(parts) == 5 and parts[4] == "merge":
                n = int(parts[3])
                pr = PULLS.get(n)
                mode = read(MODE_FILE) or "merge-ok"
                if pr is None:
                    code, body = 404, {"message": "Not Found"}
                elif mode == "merge-405":
                    code, body = 405, {"message": "Pull Request is not mergeable"}
                else:
                    if mode == "merge-moved":
                        # Someone moves the pull request branch before the merge.
                        cur = git(bare, "rev-parse", "refs/heads/" + pr["head"]).stdout.decode().strip()
                        tree = git(bare, "rev-parse", cur + "^{tree}").stdout.decode().strip()
                        moved = subprocess.run(["git", "-C", bare, "commit-tree", tree, "-p", cur, "-m", "moved"],
                                               stdout=subprocess.PIPE, env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null",
                                               GIT_AUTHOR_NAME="x", GIT_AUTHOR_EMAIL="x@x", GIT_COMMITTER_NAME="x",
                                               GIT_COMMITTER_EMAIL="x@x")).stdout.decode().strip()
                        git(bare, "update-ref", "refs/heads/" + pr["head"], moved, cur)
                    head = git(bare, "rev-parse", "refs/heads/" + pr["head"]).stdout.decode().strip()
                    if payload.get("sha") and payload["sha"] != head:
                        code, body = 409, {"message": "Head branch was modified. Review and try the merge again."}
                        log("%d %s %s auth=%s" % (code, self.command, self.path, auth))
                        self._reply(code, body)
                        return
                    main = git(bare, "rev-parse", "refs/heads/main").stdout.decode().strip()
                    if git(bare, "merge-base", "--is-ancestor", main, head).returncode == 0:
                        git(bare, "update-ref", "refs/heads/main", head, main)
                        pr["state"] = "merged"
                        code, body = 200, {"merged": True, "sha": head}
                    else:
                        code, body = 405, {"message": "Pull Request is not mergeable"}
            elif self.command == "PATCH" and len(parts) == 4:
                n = int(parts[3])
                if n in PULLS:
                    PULLS[n]["state"] = payload.get("state", PULLS[n]["state"])
                    code, body = 200, {"number": n, "state": PULLS[n]["state"]}
        log("%d %s %s auth=%s%s" % (code, self.command, self.path, auth,
                                     (" state=" + payload["state"]) if isinstance(payload, dict) and "state" in payload else ""))
        self._reply(code, body)

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", 0), Handler) as httpd:
    tmp = PORT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(str(httpd.server_address[1]))
    os.replace(tmp, PORT_FILE)
    httpd.serve_forever()
