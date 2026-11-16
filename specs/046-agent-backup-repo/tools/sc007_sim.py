#!/usr/bin/env python3
"""SC-007 simulator (046, T039): how much the repository grows with the encrypted store.

It builds synthetic data the size of donna's (research M16 and the 13-11-2026 probe):
  - one .jsonl of 68.6 MiB, with lines of up to 5 MB;
  - 32.6 MB spread over 86 files;
  - one SQLite database of 13.9 MB.
Then it runs 30 cycles. In each one it appends about 2 MB to the .jsonl and changes rows
of the database, runs the REAL `backup_store.py pack` into a work tree, and commits that
tree to a local bare repository (no network, no GitHub).

It reports, as JSON on stdout: the repository size after cycle 1 and after cycle 30
(`du -sk` after `git gc`), the new blocks of every cycle and the duration of the first.

Everything lives in a temporary directory that is removed at the end. It needs git, age,
age-keygen and ssh-keygen on the PATH. Python 3.9+, standard library only. ASCII only.

usage: sc007_sim.py [--cycles N] [--keep]
"""
import argparse
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STORE_PY = os.path.normpath(os.path.join(HERE, "..", "..", "..", "docker", "scripts", "backup_store.py"))
GIT_ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def git(*args, cwd=None):
    subprocess.run(["git"] + list(args), cwd=cwd, env=GIT_ENV, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def words(rng, n):
    vocab = ["agent", "vault", "backup", "store", "block", "commit", "session", "memory", "turn",
             "tool", "result", "user", "assistant", "token", "repository", "branch", "cycle"]
    return " ".join(rng.choice(vocab) for _ in range(n))


def make_jsonl(path, rng, target_bytes):
    with open(path, "w", encoding="ascii") as fh:
        size = 0
        i = 0
        while size < target_bytes:
            if i % 50 == 0:
                body = words(rng, rng.randint(200000, 700000))[:5000000]
            else:
                body = words(rng, rng.randint(20, 400))
            line = json.dumps({"turn": i, "text": body}) + "\n"
            fh.write(line)
            size += len(line)
            i += 1
    return i


def append_jsonl(path, rng, nbytes, start):
    with open(path, "a", encoding="ascii") as fh:
        size = 0
        i = start
        while size < nbytes:
            line = json.dumps({"turn": i, "text": words(rng, rng.randint(100, 3000))}) + "\n"
            fh.write(line)
            size += len(line)
            i += 1
    return i


def du_k(path):
    out = subprocess.run(["du", "-sk", path], stdout=subprocess.PIPE, universal_newlines=True, check=True)
    return int(out.stdout.split()[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cycles", type=int, default=30)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    rng = random.Random(46)
    tmp = tempfile.mkdtemp(prefix="sc007-")
    try:
        src = os.path.join(tmp, "src")
        os.makedirs(os.path.join(src, "files"))
        jsonl = os.path.join(src, "session.jsonl")
        turns = make_jsonl(jsonl, rng, int(68.6 * 1048576))
        for n in range(86):
            with open(os.path.join(src, "files", "f%02d.md" % n), "w", encoding="ascii") as fh:
                fh.write(words(rng, int(32.6e6 / 86 / 7)))
        db = os.path.join(src, "claude-mem.db")
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE obs (id INTEGER PRIMARY KEY, body TEXT)")
        while os.path.getsize(db) < 13.9e6:
            con.executemany("INSERT INTO obs (body) VALUES (?)", [(words(rng, 60),) for _ in range(2000)])
            con.commit()
        rows = con.execute("SELECT max(id) FROM obs").fetchone()[0]

        keydir = os.path.join(tmp, "keys")
        os.makedirs(keydir)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", os.path.join(keydir, "op")],
                       check=True)
        recips = os.path.join(keydir, "op.pub")

        mapfile = os.path.join(tmp, "map")
        with open(mapfile, "wb") as fh:
            entries = [("projects/-workspace/session.jsonl", jsonl), ("claude-mem/claude-mem.db", db)]
            entries += [("extra/files/" + n, os.path.join(src, "files", n))
                        for n in sorted(os.listdir(os.path.join(src, "files")))]
            for logical, path in entries:
                fh.write(logical.encode() + b"\0" + path.encode() + b"\0")

        bare = os.path.join(tmp, "repo.git")
        git("init", "-q", "--bare", bare)
        work = os.path.join(tmp, "work")
        git("init", "-q", work)
        git("symbolic-ref", "HEAD", "refs/heads/backup/history", cwd=work)
        git("remote", "add", "origin", bare, cwd=work)

        report = {"cycles": [], "data": {
            "jsonl_bytes": os.path.getsize(jsonl),
            "files_bytes": sum(os.path.getsize(os.path.join(src, "files", n))
                               for n in os.listdir(os.path.join(src, "files"))),
            "files": 86, "db_bytes": os.path.getsize(db)}}
        for cycle in range(1, a.cycles + 1):
            if cycle > 1:
                turns = append_jsonl(jsonl, rng, 2 * 1048576, turns)
                for _ in range(200):
                    con.execute("UPDATE obs SET body = ? WHERE id = ?", (words(rng, 60), rng.randint(1, rows)))
                con.executemany("INSERT INTO obs (body) VALUES (?)", [(words(rng, 60),) for _ in range(300)])
                con.commit()
            t0 = time.time()
            out = subprocess.run([sys.executable, STORE_PY, "pack", "--unit", "history", "--map", mapfile,
                                  "--store", os.path.join(work, "store"), "--recipients", recips,
                                  "--snapshot-dir", os.path.join(tmp, "snap"),
                                  # The block map lives outside the committed tree, as in heartbeatctl.
                                  "--block-map", os.path.join(tmp, "blockmap")],
                                 stdout=subprocess.PIPE, universal_newlines=True, check=True)
            packed = json.loads(out.stdout)
            git("add", "-A", cwd=work)
            git("-c", "user.email=sim@localhost", "-c", "user.name=sim", "commit", "-q", "-m",
                "cycle %d" % cycle, cwd=work)
            git("push", "-q", "origin", "HEAD:refs/heads/backup/history", cwd=work)
            took = time.time() - t0
            entry = {"cycle": cycle, "new_blocks": packed["new_blocks"], "blocks": packed["blocks"],
                     "new_bytes": packed["new_bytes"], "seconds": round(took, 1)}
            if cycle in (1, a.cycles):
                git("gc", "-q", cwd=bare)
                entry["repo_kb_after_gc"] = du_k(bare)
            report["cycles"].append(entry)
            sys.stderr.write("cycle %d: %s\n" % (cycle, json.dumps(entry)))
        con.close()
        first = report["cycles"][0]
        last = report["cycles"][-1]
        report["summary"] = {
            "repo_mb_after_cycle_1": round(first["repo_kb_after_gc"] / 1024.0, 1),
            "repo_mb_after_last_cycle": round(last["repo_kb_after_gc"] / 1024.0, 1),
            "first_cycle_seconds": first["seconds"],
            "under_1_gb": last["repo_kb_after_gc"] < 1024 * 1024,
        }
        print(json.dumps(report, indent=1))
        return 0
    finally:
        if a.keep:
            sys.stderr.write("kept: %s\n" % tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
