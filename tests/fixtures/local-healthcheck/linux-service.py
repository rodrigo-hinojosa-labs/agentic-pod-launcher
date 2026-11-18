#!/usr/bin/env python3
"""Owned Linux service fixture; all sockets and files are explicitly supplied."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--mode", choices=("principal", "child", "grandchild", "subgroup", "none", "wrong-port", "holder", "parent", "listener"), required=True)
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--cgroup", type=Path)
    parser.add_argument("--listen-host", default="127.0.0.1")
    args = parser.parse_args()
    if not args.name.replace("-", "").isalnum():
        parser.error("invalid fixture name")
    args.root.mkdir(parents=True, exist_ok=True)
    if args.cgroup:
        # Only a delegated descendant of this process's own unit may be used.
        own = next(line[3:] for line in Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0::"))
        parent = Path("/sys/fs/cgroup") / own.lstrip("/")
        if args.cgroup.parent.resolve() != parent.resolve():
            raise RuntimeError("subgroup is outside the fixture unit")
        args.cgroup.mkdir(exist_ok=True)
        (args.cgroup / "cgroup.procs").write_text(str(os.getpid()))
    children = []
    sockets = []
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def spawn(mode, suffix, group=None):
        command = [sys.executable, str(Path(__file__).resolve()), "--root", str(args.root), "--name", args.name + suffix, "--mode", mode, "--port", str(args.port)]
        if group:
            command += ["--cgroup", str(group)]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(child)
        deadline = time.monotonic() + 5
        ready = args.root / (args.name + suffix + ".ready.json")
        while time.monotonic() < deadline and not ready.exists():
            if child.poll() is not None:
                raise RuntimeError("fixture child exited before readiness")
            time.sleep(0.01)
        if not ready.exists():
            raise RuntimeError("fixture child readiness deadline")
        return child.pid

    try:
        if args.mode == "listener":
            sock = socket.socket()
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((args.listen_host, args.port))
            sock.listen(16)
            sock.settimeout(0.02)
            sockets.append(sock)
        elif args.mode in ("principal", "holder", "wrong-port"):
            sock = socket.socket()
            sock.settimeout(3)
            sock.connect(("127.0.0.1", 4430 if args.mode == "wrong-port" else args.port))
            sockets.append(sock)
        elif args.mode in ("child", "parent"):
            spawn("holder", "-child")
        elif args.mode == "grandchild":
            spawn("parent", "-child")
        elif args.mode == "subgroup":
            own = next(line[3:] for line in Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0::"))
            spawn("holder", "-child", Path("/sys/fs/cgroup") / own.lstrip("/") / "worker")
        ready = {"pid": os.getpid(), "children": [p.pid for p in children], "mode": args.mode}
        (args.root / (args.name + ".ready.json")).write_text(json.dumps(ready))
        spawned = False
        while not stopping:
            for child in children:
                child.poll()  # Reap a child deliberately terminated by L08.
            if args.mode == "listener":
                try:
                    connection, _address = sockets[0].accept()
                    sockets.append(connection)
                except socket.timeout:
                    pass
            # L08 birth happens only after the controller crosses the ss barrier.
            if not spawned and (args.root / (args.name + ".spawn")).exists():
                args.port = 443
                spawn("holder", "-newborn")
                spawned = True
                (args.root / (args.name + ".spawned")).write_text("ready\n")
            time.sleep(0.02)
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for sock in sockets:
            sock.close()


if __name__ == "__main__":
    main()
