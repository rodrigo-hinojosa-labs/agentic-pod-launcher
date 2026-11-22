#!/usr/bin/env python3
"""Local smart-HTTP git server with Basic auth, for the 046 tests (agent backup repository).

Contract: specs/046-agent-backup-repo/contracts/evidence.md, section V1. Derived from the
prototype of research M3.

It relays every request to `git http-backend` (CGI) after checking the password against
the content of GIT_TEST_TOKEN_FILE. The token and the modes are read on EVERY request, so a
test can change them without restarting the server.

Environment:
  GIT_TEST_ROOT       directory with the bare repositories it serves (required)
  GIT_TEST_TOKEN_FILE file whose content is the only password accepted (required)
  GIT_TEST_MODE_FILE  file with zero or more words (optional; see MODES)
  GIT_TEST_PORT_FILE  where the ephemeral port is written, atomically (required)
  GIT_TEST_LOG        one line per request (required); never the credential
  GIT_TEST_BIND       address to listen on (default 127.0.0.1)

MODES (words in GIT_TEST_MODE_FILE):
  anon-read        serves reads without a credential (a "public" repository); pushes still
                   need it
  anon-error-once  answers 500 to the NEXT request without a credential, then forgets it
  stall-anon-once  accepts the NEXT request without a credential and does not answer it
  deny-push        answers 403 to every push, even an authenticated one
  stall-auth       accepts every authenticated request and does not answer it
  stall-push       accepts every authenticated push and does not answer it
  protected-main   (048) the repositories' pre-receive hook rejects updates of
                   refs/heads/main with GitHub's GH006 text (br_new_repo installs it)
  inject-once      (048) consumed by the NEXT authenticated push request (the POST to
                   git-receive-pack): before relaying it, a foreign commit touching
                   README-work.md is created on main in the target repository, so the
                   push being relayed is no longer a fast-forward. One word, one commit.

Partial clones (048): the backend runs with uploadpack.allowFilter and
uploadpack.allowAnySHA1InWant, as GitHub does.

The two -once modes exist because of how git talks: every authenticated operation starts
with an unauthenticated request that the server rejects with 401 (measured on 14-11-2026
with git 2.53.0). A permanent mode on unauthenticated requests would also break the
authenticated query. A stalled request is released by itself after 300 seconds.

Log line: "<code> <method> <path> service=<upload-pack|receive-pack|-> auth=<ok|bad|none|anon>".

It never calls HTTPServer.server_bind (its getfqdn() took ~35 s on the macOS CI runner).
ASCII only, standard library only, Python 3.9 compatible.
"""
import base64
import os
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler

ROOT = os.environ.get("GIT_TEST_ROOT", "")
TOKEN_FILE = os.environ.get("GIT_TEST_TOKEN_FILE", "")
MODE_FILE = os.environ.get("GIT_TEST_MODE_FILE", "")
PORT_FILE = os.environ.get("GIT_TEST_PORT_FILE", "")
LOG_FILE = os.environ.get("GIT_TEST_LOG", "")
BIND = os.environ.get("GIT_TEST_BIND", "127.0.0.1")
STALL_SECONDS = 300

for name, value in (("GIT_TEST_ROOT", ROOT), ("GIT_TEST_TOKEN_FILE", TOKEN_FILE),
                    ("GIT_TEST_PORT_FILE", PORT_FILE), ("GIT_TEST_LOG", LOG_FILE)):
    if not value:
        sys.stderr.write("git-auth-server: %s is required\n" % name)
        sys.exit(2)

BACKEND = os.environ.get("GIT_HTTP_BACKEND") or os.path.join(
    subprocess.check_output(["git", "--exec-path"], universal_newlines=True).strip(),
    "git-http-backend")

LOCK = threading.Lock()


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def modes():
    return read_file(MODE_FILE).split() if MODE_FILE else []


def consume_once(word):
    """Remove one occurrence of a -once mode. Returns True if it was there."""
    if not MODE_FILE:
        return False
    with LOCK:
        words = read_file(MODE_FILE).split()
        if word not in words:
            return False
        words.remove(word)
        tmp = MODE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(" ".join(words) + ("\n" if words else ""))
        os.replace(tmp, MODE_FILE)
        return True


def inject_foreign_commit(bare):
    """Creates a commit on refs/heads/main of BARE that changes README-work.md (048)."""
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
               GIT_INDEX_FILE=os.path.join(bare, "inject.index"),
               GIT_AUTHOR_NAME="someone", GIT_AUTHOR_EMAIL="someone@example.invalid",
               GIT_COMMITTER_NAME="someone", GIT_COMMITTER_EMAIL="someone@example.invalid")

    def git(*args, data=None):
        return subprocess.run(["git", "-C", bare] + list(args), input=data, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True).stdout.decode().strip()
    head = git("rev-parse", "refs/heads/main")
    git("read-tree", head)
    blob = git("hash-object", "-w", "--stdin", data=("foreign %f\n" % time.time()).encode())
    git("update-index", "--add", "--cacheinfo", "100644,%s,README-work.md" % blob)
    tree = git("write-tree")
    commit = git("commit-tree", tree, "-p", head, "-m", "foreign work on main")
    git("update-ref", "refs/heads/main", commit, head)
    os.remove(os.path.join(bare, "inject.index"))
    return commit


def push_refs(body):
    """The ref names a receive-pack request updates (pkt-lines up to the flush)."""
    names, i = [], 0
    while i + 4 <= len(body):
        try:
            n = int(body[i:i + 4], 16)
        except ValueError:
            break
        if n == 0:
            break
        line = body[i + 4:i + n].split(b"\0")[0].decode("latin-1").strip()
        parts = line.split(" ")
        if len(parts) >= 3:
            names.append(parts[2])
        i += n
    return names


def log(line):
    with LOCK:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):  # silence the default stderr access log
        pass

    def _auth(self):
        """Returns 'ok', 'bad' or 'none'."""
        header = self.headers.get("Authorization", "")
        if not header:
            return "none"
        if not header.startswith("Basic "):
            return "bad"
        try:
            _user, _, password = base64.b64decode(header[6:]).decode("utf-8").partition(":")
        except Exception:
            return "bad"
        token = read_file(TOKEN_FILE).strip()
        return "ok" if token and password == token else "bad"

    def _body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def _empty(self, status, extra=None):
        self.send_response(status)
        for name, value in (extra or []):
            self.send_header(name, value)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _stall(self, line):
        log(line + " stalled")
        time.sleep(STALL_SECONDS)
        try:
            self._empty(504)
        except OSError:
            pass

    def _serve(self):
        path, _, query = self.path.partition("?")
        is_push = "git-receive-pack" in path or "service=git-receive-pack" in query
        service = "receive-pack" if is_push else (
            "upload-pack" if ("git-upload-pack" in path or "service=git-upload-pack" in query) else "-")
        auth = self._auth()
        active = modes()
        where = "%s %s service=%s" % (self.command, path, service)

        if auth != "ok":
            if auth == "none" and consume_once("anon-error-once"):
                log("500 %s auth=none" % where)
                self._empty(500)
                return
            if auth == "none" and consume_once("stall-anon-once"):
                self._stall("000 %s auth=none" % where)
                return
            if not ("anon-read" in active and not is_push):
                log("401 %s auth=%s" % (where, auth))
                self._empty(401, [("WWW-Authenticate", 'Basic realm="git"')])
                return
            auth = "anon"
        else:
            if "stall-auth" in active or (is_push and "stall-push" in active):
                self._stall("000 %s auth=ok" % where)
                return
            if is_push and "deny-push" in active:
                log("403 %s auth=ok" % where)
                self._empty(403)
                return

        body = self._body() if self.command == "POST" else b""
        if is_push and self.command == "POST":
            log("push-refs %s %s" % (path.split("/git-receive-pack")[0].lstrip("/"), " ".join(push_refs(body))))
        if is_push and self.command == "POST" and consume_once("inject-once"):
            repo = path.split("/git-receive-pack")[0].lstrip("/")
            commit = inject_foreign_commit(os.path.join(ROOT, repo))
            log("inject %s %s" % (repo, commit))
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GIT_PROJECT_ROOT": ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_USER": "agent" if auth == "ok" else "",
            "REMOTE_ADDR": "127.0.0.1",
            "GIT_HTTP_MAX_REQUEST_BUFFER": "200m",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "uploadpack.allowFilter", "GIT_CONFIG_VALUE_0": "true",
            "GIT_CONFIG_KEY_1": "uploadpack.allowAnySHA1InWant", "GIT_CONFIG_VALUE_1": "true",
        }
        if "protected-main" in active:
            env["GIT_TEST_PROTECT_MAIN"] = "1"
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run([BACKEND], input=body, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for raw in head.split(b"\r\n"):
            name, _, value = raw.decode("latin-1").partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name:
                headers.append((name, value.strip()))
        log("%d %s auth=%s" % (status, where, auth))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _serve
    do_POST = _serve


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server((BIND, 0), Handler) as httpd:
    tmp = PORT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(str(httpd.server_address[1]))
    os.replace(tmp, PORT_FILE)
    httpd.serve_forever()
