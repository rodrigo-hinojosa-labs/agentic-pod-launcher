#!/usr/bin/env python3
"""backup_store.py: the encrypted block store of the agent backups (046).

Contract: specs/046-agent-backup-repo/contracts/block-store.md (S1 to S6). Format:
specs/046-agent-backup-repo/data-model.md, section 6.

Shared, NON-committing code (constitution, Principle V): it reads files and writes a
directory. It never talks to a repository, never stages a git tree and never commits.

Subcommands:
  digest   --map FILE [--extra TEXT] [--snapshot-dir DIR] [--list]
  pack     --unit NAME --map FILE --store DIR --recipients FILE
           [--expect-recipient TEXT] [--extra TEXT] [--block-size BYTES] [--snapshot-dir DIR]
           [--block-map FILE]
  unpack   --store DIR --dest DIR --identity FILE [--work-dir DIR]
  sqlite-snapshot SRC DST
  fingerprint "ssh-ed25519 AAAA... comment"

Every store has its own age data key (S1): store/key.age (the private part, encrypted for
the operator's ssh public key), store/recipient (the public part) and store/operator (the
fingerprint of the operator key key.age was encrypted for). Blocks and the manifest are
encrypted for store/recipient. The private part of the data key is never written in
plaintext to a file of the agent: age-keygen's output is read through a pipe and handed to
age on its standard input. unpack opens key.age with the operator key exactly once.

A block is named by the SHA-256 of its ENCRYPTED file, so a name reveals nothing about
the content (an attacker who reads the repository cannot confirm a guess about a small
file). The manifest, encrypted, keeps the SHA-256 of each plaintext block. Reusing a
block across runs needs to know which name holds which plaintext: that is the block map
(--block-map), a local file of the agent outside any committed tree, valid only for the
current store recipient. Without it, or after losing it, every block is encrypted again.

Exit codes (S4): 0 ok, 2 usage, 3 missing key file, 4 age/age-keygen failed (including a
private key that does not match key.age), 5 integrity (any failure after key.age opened:
a damaged manifest or block is not a key that does not match), 6 I/O. Error messages
never include file content or source paths: only logical paths.

Python 3.9 to 3.14, standard library only. ASCII only.
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile

BLOCK_SIZE = 1048576
SQLITE_HEADER = b"SQLite format 3\x00"
SKIP_SUFFIXES = ("-wal", "-shm", "-journal")
SCHEMA = 1


class StoreError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def err(code, message):
    raise StoreError(code, message)


def age_bin():
    return os.environ.get("AGE_BIN") or "age"


def age_keygen_bin():
    return os.environ.get("AGE_KEYGEN_BIN") or "age-keygen"


def run_age(args, data=None):
    """Run age with ARGS, feeding DATA on stdin. Returns stdout bytes."""
    try:
        proc = subprocess.run([age_bin()] + args, input=data, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
    except OSError:
        err(4, "age is not installed")
    if proc.returncode != 0:
        err(4, "age failed")
    return proc.stdout


# ── fingerprint ──────────────────────────────────────────────────────────────

def fingerprint(pubkey_line):
    parts = pubkey_line.strip().split()
    if len(parts) < 2 or parts[0] not in ("ssh-ed25519", "ssh-rsa"):
        err(2, "not an ssh-ed25519 or ssh-rsa public key")
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except Exception:
        err(2, "not a valid public key")
    digest = hashlib.sha256(blob).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


def read_recipients(path):
    if not os.path.isfile(path):
        err(3, "missing recipients file")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("ssh-ed25519 ") or line.startswith("ssh-rsa "):
                    return line
    except OSError:
        err(6, "cannot read the recipients file")
    err(3, "no ssh-ed25519 or ssh-rsa key in the recipients file")


# ── capture ──────────────────────────────────────────────────────────────────

def read_map(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        err(6, "cannot read the map file")
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    if len(parts) % 2 != 0:
        err(2, "the map file must hold logical/source pairs")
    pairs = []
    for i in range(0, len(parts), 2):
        logical = parts[i].decode("utf-8", "surrogateescape")
        source = parts[i + 1].decode("utf-8", "surrogateescape")
        check_logical(logical)
        pairs.append((logical, source))
    return pairs


def check_logical(path):
    if not path or path.startswith("/") or "\\" in path:
        err(2, "invalid logical path")
    for seg in path.split("/"):
        if seg in ("", ".", ".."):
            err(2, "invalid logical path")


def is_sqlite(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(16) == SQLITE_HEADER
    except OSError:
        return False


def sqlite_snapshot(src, dst):
    """Consistent copy with the SQLite backup API; integrity_check on the copy."""
    if os.path.exists(dst):
        os.remove(dst)
    try:
        # as_uri percent-encodes ?, # and %: a path that holds them must not cut the URI.
        s = sqlite3.connect(pathlib.Path(os.path.abspath(src)).as_uri() + "?mode=ro", uri=True)
        try:
            d = sqlite3.connect(dst)
            try:
                s.backup(d)
            finally:
                d.close()
        finally:
            s.close()
        chk = sqlite3.connect(dst)
        try:
            ok = chk.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            chk.close()
    except sqlite3.Error:
        err(5, "sqlite snapshot failed")
    if ok != "ok":
        err(5, "sqlite snapshot failed its integrity check")


def capture(logical, source, snapshot_dir):
    """Returns (bytes, mode) as captured, or None when the file is skipped."""
    base = logical.rsplit("/", 1)[-1]
    if base.endswith(SKIP_SUFFIXES) or source.endswith(SKIP_SUFFIXES):
        return None
    try:
        st = os.lstat(source)
    except OSError:
        return None  # a live session file can vanish while the backup runs
    if not stat.S_ISREG(st.st_mode):
        return None
    mode = "%o" % stat.S_IMODE(st.st_mode)
    if is_sqlite(source):
        if not snapshot_dir:
            err(2, "a SQLite database needs --snapshot-dir (%s)" % logical)
        os.makedirs(snapshot_dir, exist_ok=True)
        snap = os.path.join(snapshot_dir, hashlib.sha256(logical.encode("utf-8")).hexdigest()[:24] + ".db")
        sqlite_snapshot(source, snap)
        with open(snap, "rb") as fh:
            return fh.read(), mode
    try:
        with open(source, "rb") as fh:
            data = fh.read(st.st_size)
    except OSError:
        return None
    if logical.endswith(".jsonl"):
        cut = data.rfind(b"\n")
        if cut < 0:
            return None
        data = data[:cut + 1]
    return data, mode


def captured_files(pairs, snapshot_dir):
    files = {}
    for logical, source in pairs:
        got = capture(logical, source, snapshot_dir)
        if got is None:
            continue
        data, mode = got
        files[logical] = (data, mode)
    return files


def unit_digest(entries, extra):
    """entries: sorted list of (path, size, sha256)."""
    h = hashlib.sha256()
    for path, size, sha in entries:
        h.update(("%s\t%d\t%s\n" % (path, size, sha)).encode("utf-8", "surrogateescape"))
    if extra:
        h.update(extra.encode("utf-8", "surrogateescape"))
    return h.hexdigest()


# ── store ────────────────────────────────────────────────────────────────────

def atomic_write(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        err(6, "cannot write the store")


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def generate_data_key():
    """Returns (private_key_bytes, public_recipient). Only through pipes."""
    try:
        proc = subprocess.run([age_keygen_bin()], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        err(4, "age-keygen is not installed")
    if proc.returncode != 0:
        err(4, "age-keygen failed")
    private = None
    public = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith(b"AGE-SECRET-KEY-"):
            private = line
        elif line.startswith(b"# public key: "):
            public = line[len(b"# public key: "):].decode("ascii")
    if not private or not public:
        err(4, "age-keygen gave no key")
    return private + b"\n", public


def rotate(store, recipients_file, operator_fp):
    private, public = generate_data_key()
    enc = run_age(["-R", recipients_file], data=private)
    shutil.rmtree(os.path.join(store, "blocks"), ignore_errors=True)
    try:
        os.unlink(os.path.join(store, "manifest.json.age"))
    except OSError:
        pass
    atomic_write(os.path.join(store, "key.age"), enc)
    atomic_write(os.path.join(store, "recipient"), (public + "\n").encode("ascii"))
    atomic_write(os.path.join(store, "operator"), (operator_fp + "\n").encode("ascii"))
    return public


HEX = set("0123456789abcdef")


def is_hex64(value):
    return isinstance(value, str) and len(value) == 64 and set(value) <= HEX


def block_path(store, name):
    return os.path.join(store, "blocks", name[:2], name + ".age")


def load_block_map(path, recipient):
    """plain sha256 -> block name, only when the map belongs to RECIPIENT."""
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict) or data.get("schema") != SCHEMA or data.get("recipient") != recipient:
        return {}
    blocks = data.get("blocks")
    if not isinstance(blocks, dict):
        return {}
    return {k: v for k, v in blocks.items() if is_hex64(k) and is_hex64(v)}


def cmd_pack(a):
    recipients_line = read_recipients(a.recipients)
    operator_fp = fingerprint(recipients_line)
    store = a.store
    os.makedirs(store, exist_ok=True)
    block_size = a.block_size or BLOCK_SIZE
    if block_size < 1:
        err(2, "invalid --block-size")

    # S1: rotation, decided before reading any file.
    recipient = read_text(os.path.join(store, "recipient"))
    rotated = ""
    if not (os.path.isfile(os.path.join(store, "key.age")) and recipient
            and read_text(os.path.join(store, "operator"))):
        rotated = "new"
    elif read_text(os.path.join(store, "operator")) != operator_fp:
        rotated = "operator-changed"
    elif a.expect_recipient is not None and a.expect_recipient != recipient:
        rotated = "recipient-mismatch"
    if rotated:
        recipient = rotate(store, a.recipients, operator_fp)

    files = captured_files(read_map(a.map), a.snapshot_dir)
    bmap = load_block_map(a.block_map, recipient)
    used = {}
    manifest_files = []
    referenced = set()
    new_blocks = 0
    new_bytes = 0
    total_bytes = 0
    entries = []
    for path in sorted(files):
        data, mode = files[path]
        sha = hashlib.sha256(data).hexdigest()
        blocks = []
        for off in range(0, len(data), block_size):
            chunk = data[off:off + block_size]
            psha = hashlib.sha256(chunk).hexdigest()
            name = used.get(psha) or bmap.get(psha)
            if not name or not os.path.isfile(block_path(store, name)):
                enc = run_age(["-r", recipient], data=gzip.compress(chunk, mtime=0))
                name = hashlib.sha256(enc).hexdigest()
                atomic_write(block_path(store, name), enc)
                new_blocks += 1
                new_bytes += len(chunk)
            used[psha] = name
            blocks.append({"name": name, "sha256": psha})
            referenced.add(name)
        total_bytes += len(data)
        manifest_files.append({"path": path, "size": len(data), "mode": mode,
                               "sha256": sha, "blocks": blocks})
        entries.append((path, len(data), sha))

    # I4: exactly the blocks the manifest names.
    blocks_dir = os.path.join(store, "blocks")
    if os.path.isdir(blocks_dir):
        for sub in os.listdir(blocks_dir):
            subdir = os.path.join(blocks_dir, sub)
            if not os.path.isdir(subdir):
                continue
            for name in os.listdir(subdir):
                if not name.endswith(".age") or name[:-4] not in referenced:
                    try:
                        os.unlink(os.path.join(subdir, name))
                    except OSError:
                        pass
            try:
                os.rmdir(subdir)
            except OSError:
                pass

    manifest = {"schema": SCHEMA, "unit": a.unit, "block_size": block_size, "files": manifest_files}
    enc = run_age(["-r", recipient], data=json.dumps(manifest, sort_keys=True).encode("utf-8"))
    atomic_write(os.path.join(store, "manifest.json.age"), enc)
    if a.block_map:
        keep = {k: v for k, v in used.items() if v in referenced}
        atomic_write(a.block_map, json.dumps({"schema": SCHEMA, "recipient": recipient, "blocks": keep},
                                             sort_keys=True).encode("utf-8"))
    out = {"files": len(manifest_files), "blocks": len(referenced), "new_blocks": new_blocks,
           "bytes": total_bytes, "new_bytes": new_bytes, "digest": unit_digest(entries, a.extra),
           "recipient": recipient, "rotated": rotated}
    print(json.dumps(out, sort_keys=True))
    return 0


def cmd_digest(a):
    files = captured_files(read_map(a.map), a.snapshot_dir)
    entries = []
    for path in sorted(files):
        data, _mode = files[path]
        entries.append((path, len(data), hashlib.sha256(data).hexdigest()))
    if a.list:
        for path, size, sha in entries:
            sys.stdout.write("%s\t%d\t%s\n" % (path, size, sha))
        return 0
    print(unit_digest(entries, a.extra))
    return 0


def safe_target(dest, path):
    check_manifest_path(path)
    target = os.path.normpath(os.path.join(dest, path))
    root = os.path.normpath(dest)
    if os.path.commonpath([root, target]) != root:
        err(5, "manifest path outside the destination")
    return target


def check_manifest_path(path):
    if not isinstance(path, str) or not path or path.startswith("/") or "\\" in path:
        err(5, "invalid path in the manifest")
    for seg in path.split("/"):
        # .git in any case: on a case-insensitive file system .GIT is .git.
        if seg in ("", ".", "..") or seg.lower() == ".git":
            err(5, "invalid path in the manifest")


def run_age_data(args, data, what):
    """age after key.age opened: any failure is integrity (5), not a key that does not match."""
    try:
        return run_age(args, data=data)
    except StoreError:
        err(5, "%s does not decrypt" % what)


def cmd_unpack(a):
    store = a.store
    if not os.path.isfile(a.identity):
        err(3, "missing identity file")
    key_age = os.path.join(store, "key.age")
    if not os.path.isfile(key_age) or not os.path.isfile(os.path.join(store, "manifest.json.age")):
        err(6, "the store is incomplete")

    own_work = a.work_dir is None
    if own_work:
        work = tempfile.mkdtemp(prefix="backup-store-")
    else:
        work = a.work_dir
        os.makedirs(work, exist_ok=True)
    os.chmod(work, 0o700)
    keyfile = os.path.join(work, "data.key")
    stage = tempfile.mkdtemp(prefix="stage-", dir=work)
    try:
        # The only use of the operator key: one age invocation.
        private = run_age(["-d", "-i", a.identity, key_age])
        fd = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(private)
        private = None
        with open(os.path.join(store, "manifest.json.age"), "rb") as fh:
            manifest_raw = run_age_data(["-d", "-i", keyfile], fh.read(), "the manifest")
        try:
            manifest = json.loads(manifest_raw.decode("utf-8"))
        except ValueError:
            err(5, "the manifest is not valid")
        files = manifest.get("files")
        if manifest.get("schema") != SCHEMA or not isinstance(files, list):
            err(5, "the manifest is not valid")
        planned = []
        for entry in files:
            path = entry.get("path")
            check_manifest_path(path)
            target_rel = path
            data = bytearray()
            for block in entry.get("blocks") or []:
                name = block.get("name") if isinstance(block, dict) else None
                psha = block.get("sha256") if isinstance(block, dict) else None
                if not is_hex64(name) or not is_hex64(psha):
                    err(5, "invalid block name in the manifest (%s)" % path)
                bp = block_path(store, name)
                if not os.path.isfile(bp):
                    err(5, "missing block (%s)" % path)
                with open(bp, "rb") as fh:
                    raw = fh.read()
                # The name is the hash of the encrypted file: checked before age runs.
                if hashlib.sha256(raw).hexdigest() != name:
                    err(5, "a block does not match its name (%s)" % path)
                plain = run_age_data(["-d", "-i", keyfile], raw, "a block (%s)" % path)
                try:
                    chunk = gzip.decompress(plain)
                except Exception:
                    err(5, "a block does not decompress (%s)" % path)
                if hashlib.sha256(chunk).hexdigest() != psha:
                    err(5, "a block does not match the manifest (%s)" % path)
                data.extend(chunk)
            if len(data) != entry.get("size") or hashlib.sha256(bytes(data)).hexdigest() != entry.get("sha256"):
                err(5, "integrity check failed (%s)" % path)
            staged = os.path.join(stage, target_rel)
            os.makedirs(os.path.dirname(staged), exist_ok=True)
            with open(staged, "wb") as fh:
                fh.write(bytes(data))
            try:
                # No setuid, setgid or sticky bit ever comes back from a store.
                os.chmod(staged, int(str(entry.get("mode") or "600"), 8) & 0o777)
            except ValueError:
                os.chmod(staged, 0o600)
            planned.append(target_rel)
        # Everything verified: only now does anything reach --dest.
        os.makedirs(a.dest, exist_ok=True)
        for rel in planned:
            target = safe_target(a.dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            os.replace(os.path.join(stage, rel), target)
        print(json.dumps({"files": len(planned), "verified": len(planned)}, sort_keys=True))
        return 0
    finally:
        try:
            os.unlink(keyfile)
        except OSError:
            pass
        shutil.rmtree(stage, ignore_errors=True)
        if own_work:
            shutil.rmtree(work, ignore_errors=True)


def cmd_sqlite_snapshot(a):
    sqlite_snapshot(a.src, a.dst)
    print("ok")
    return 0


def cmd_fingerprint(a):
    print(fingerprint(a.key))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="backup_store.py")
    sub = p.add_subparsers(dest="cmd")

    d = sub.add_parser("digest")
    d.add_argument("--map", required=True)
    d.add_argument("--extra", default="")
    d.add_argument("--snapshot-dir", dest="snapshot_dir")
    d.add_argument("--list", action="store_true")

    k = sub.add_parser("pack")
    k.add_argument("--unit", required=True)
    k.add_argument("--map", required=True)
    k.add_argument("--store", required=True)
    k.add_argument("--recipients", required=True)
    k.add_argument("--expect-recipient", dest="expect_recipient")
    k.add_argument("--extra", default="")
    k.add_argument("--block-size", dest="block_size", type=int)
    k.add_argument("--snapshot-dir", dest="snapshot_dir")
    k.add_argument("--block-map", dest="block_map")

    u = sub.add_parser("unpack")
    u.add_argument("--store", required=True)
    u.add_argument("--dest", required=True)
    u.add_argument("--identity", required=True)
    u.add_argument("--work-dir", dest="work_dir")

    s = sub.add_parser("sqlite-snapshot")
    s.add_argument("src")
    s.add_argument("dst")

    f = sub.add_parser("fingerprint")
    f.add_argument("key")

    a = p.parse_args(argv)
    handlers = {"digest": cmd_digest, "pack": cmd_pack, "unpack": cmd_unpack,
                "sqlite-snapshot": cmd_sqlite_snapshot, "fingerprint": cmd_fingerprint}
    if a.cmd not in handlers:
        p.print_usage(sys.stderr)
        return 2
    try:
        return handlers[a.cmd](a)
    except StoreError as e:
        sys.stderr.write("backup_store: %s\n" % e.message)
        return e.code
    except KeyboardInterrupt:
        return 6


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
