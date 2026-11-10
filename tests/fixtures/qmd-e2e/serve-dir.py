"""Serve a directory on 127.0.0.1 at a port the kernel picks (tests/qmd-embed-nightly.bats).

Usage: python3 -u serve-dir.py DIR. Prints "Serving HTTP on 127.0.0.1 port N" once it listens,
the line _http_up reads. It stands in for `python3 -m http.server 0 --bind 127.0.0.1`, whose
server_bind does a reverse DNS lookup (socket.getfqdn) that took about 35 seconds on the macOS
runner of the CI from the second server of a run on (measured 10-11-2026, PR 128).

ASCII only, standard library only, Python 3.9 compatible.
"""
import functools
import socketserver
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class LocalServer(ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main():
    handler = functools.partial(SimpleHTTPRequestHandler, directory=sys.argv[1])
    server = LocalServer(("127.0.0.1", 0), handler)
    print("Serving HTTP on 127.0.0.1 port %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
