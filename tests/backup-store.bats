#!/usr/bin/env bats
#
# 046: la herramienta del almacen cifrado por bloques (docker/scripts/backup_store.py).
#
# Contrato: specs/046-agent-backup-repo/contracts/block-store.md (S1 a S6) y la
# seccion 6 de data-model.md. Lo que significa cada prueba: seccion V2 de
# specs/046-agent-backup-repo/contracts/evidence.md (TS01 a TS22).
#
# Toda prueba corre con un HOME propio y vacio. Las llaves del operador son pares
# ssh-ed25519 de prueba (br_keys), nunca las del operador.

load helper
load helper-backup-repo

setup() {
  br_require
  br_keys
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  BS="$REPO_ROOT/docker/scripts/backup_store.py"
  T="$BATS_TEST_TMPDIR"
  printf '%s\n' "$BR_KEY_A_PUB" > "$T/recips-a"
  printf '%s\n' "$BR_KEY_B_PUB" > "$T/recips-b"
  SENT="ts-sentinel-${BATS_TEST_NUMBER}-$$-$RANDOM"
  mkdir -p "$T/src" "$T/store" "$T/dest"
}

# _ts_map ARCHIVO LOGICA ORIGEN [LOGICA ORIGEN...]: el mapa separado por bytes nulos.
_ts_map() {
  local out="$1"
  shift
  : > "$out"
  while [ $# -gt 0 ]; do
    printf '%s\0%s\0' "$1" "$2" >> "$out"
    shift 2
  done
}

_ts_pack() {  # [--recipients ARCHIVO] y el resto de opciones de pack
  python3 "$BS" pack --unit test --map "$T/map" --store "$T/store" --snapshot-dir "$T/snap" \
    --block-map "$T/blockmap" "$@"
}

_ts_unpack() {  # LLAVE [DESTINO]
  python3 "$BS" unpack --store "$T/store" --dest "${2:-$T/dest}" --identity "$1"
}

_ts_json() { jq -r ".$1" <<< "$2"; }

_ts_is_age() { [ "$(head -c 21 "$1")" = "age-encryption.org/v1" ]; }

# El conteo de archivos de bloques del almacen.
_ts_block_files() { find "$T/store/blocks" -type f -name '*.age' 2> /dev/null | wc -l | tr -d ' '; }

# ── S6 I1: ida y vuelta ─────────────────────────────────────────────────────

@test "TS01: a text file goes and comes back byte for byte" {
  printf 'hello %s\nsecond line\n' "$SENT" > "$T/src/a.txt"
  _ts_map "$T/map" notes/a.txt "$T/src/a.txt"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json files "$output")" = "1" ]
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 0 ]
  cmp -s "$T/src/a.txt" "$T/dest/notes/a.txt"
}

@test "TS02: a binary file of several blocks goes and comes back byte for byte" {
  python3 -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(4096*3+1234))' "$T/src/bin.dat"
  _ts_map "$T/map" bin.dat "$T/src/bin.dat"
  run _ts_pack --recipients "$T/recips-a" --block-size 4096
  [ "$status" -eq 0 ]
  [ "$(_ts_json blocks "$output")" = "4" ]
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 0 ]
  cmp -s "$T/src/bin.dat" "$T/dest/bin.dat"
}

@test "TS03: an empty file goes and comes back, with size 0 and no blocks" {
  : > "$T/src/empty"
  _ts_map "$T/map" empty "$T/src/empty"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json blocks "$output")" = "0" ]
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 0 ]
  [ -f "$T/dest/empty" ]
  [ ! -s "$T/dest/empty" ]
  run python3 "$BS" digest --map "$T/map" --list
  [ "$(cut -f2 <<< "$output")" = "0" ]
}

@test "TS04: many files with nested paths and spaces go and come back" {
  local i args=()
  for i in $(seq 1 30); do
    mkdir -p "$T/src/dir $((i % 3))/sub dir"
    printf 'file %s %s\n' "$i" "$SENT" > "$T/src/dir $((i % 3))/sub dir/file $i.txt"
    args+=("tree/dir $((i % 3))/sub dir/file $i.txt" "$T/src/dir $((i % 3))/sub dir/file $i.txt")
  done
  _ts_map "$T/map" "${args[@]}"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json files "$output")" = "30" ]
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 0 ]
  for i in $(seq 1 30); do
    cmp -s "$T/src/dir $((i % 3))/sub dir/file $i.txt" "$T/dest/tree/dir $((i % 3))/sub dir/file $i.txt"
  done
  # A mode with setuid in the manifest comes back without the special bits.
  _ts_data_key
  age -d -i "$T/data.key" -o "$T/manifest.json" "$T/store/manifest.json.age"
  jq '.files[0].mode = "4755"' "$T/manifest.json" > "$T/manifest.mode.json"
  age -r "$(cat "$T/store/recipient")" -o "$T/store/manifest.json.age" "$T/manifest.mode.json"
  run _ts_unpack "$BR_KEY_A" "$T/dest-mode"
  [ "$status" -eq 0 ]
  local first
  first=$(jq -r '.files[0].path' "$T/manifest.json")
  [ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$T/dest-mode/$first")" = "755" ]
}

# ── S6 I2 a I4: reutilizacion y limpieza ────────────────────────────────────

@test "TS05: a second pack of the same files writes no block and does not rotate" {
  printf 'stable %s\n' "$SENT" > "$T/src/a.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json new_blocks "$output")" = "0" ]
  [ "$(_ts_json rotated "$output")" = "" ]
}

@test "TS06: a file that only grows writes the previous last block and the new ones" {
  python3 -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(4096*3+100))' "$T/src/log.bin"
  _ts_map "$T/map" log.bin "$T/src/log.bin"
  _ts_pack --recipients "$T/recips-a" --block-size 4096 > /dev/null
  python3 -c 'import os,sys; open(sys.argv[1],"ab").write(os.urandom(5000))' "$T/src/log.bin"
  run _ts_pack --recipients "$T/recips-a" --block-size 4096
  [ "$status" -eq 0 ]
  [ "$(_ts_json new_blocks "$output")" -le 2 ]
  [ "$(_ts_json new_blocks "$output")" -ge 1 ]
  [ "$(_ts_json blocks "$output")" = "5" ]
}

@test "TS07: blocks that the new manifest no longer names are deleted" {
  printf 'one %s\n' "$SENT" > "$T/src/one"
  printf 'two %s\n' "$SENT" > "$T/src/two"
  _ts_map "$T/map" one "$T/src/one" two "$T/src/two"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  [ "$(_ts_block_files)" = "2" ]
  _ts_map "$T/map" one "$T/src/one"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_block_files)" = "1" ]
  [ "$(_ts_json blocks "$output")" = "1" ]
}

# ── S6 I5: nada en claro ────────────────────────────────────────────────────

@test "TS08: the store holds no plaintext, except recipient and operator" {
  printf 'secret %s\n' "$SENT" > "$T/src/a.txt"
  python3 -c 'import sys; open(sys.argv[1],"w").write((sys.argv[2]+"\n")*5000)' "$T/src/big.txt" "$SENT"
  _ts_map "$T/map" a.txt "$T/src/a.txt" big.txt "$T/src/big.txt"
  _ts_pack --recipients "$T/recips-a" --block-size 8192 > /dev/null
  if grep -rqF -- "$SENT" "$T/store"; then false; fi
  local f n=0
  while IFS= read -r f; do
    case "${f##*/}" in recipient|operator) continue ;; esac
    _ts_is_age "$f"
    n=$((n + 1))
  done < <(find "$T/store" -type f)
  [ "$n" -ge 3 ]
  grep -qE '^age1[0-9a-z]+$' "$T/store/recipient"
  grep -qE '^SHA256:[A-Za-z0-9+/]+$' "$T/store/operator"
  # A block name reveals nothing of its content: it is the SHA-256 of the encrypted
  # file, never the one of the plaintext block (a.txt is a single block).
  [ -z "$(find "$T/store/blocks" -name "$(br_sha256 "$T/src/a.txt").age")" ]
  local b name m=0
  while IFS= read -r b; do
    name="${b##*/}"
    [ "${name%.age}" = "$(br_sha256 "$b")" ]
    m=$((m + 1))
  done < <(find "$T/store/blocks" -type f -name '*.age')
  [ "$m" -ge 2 ]
}

@test "TS09: the manifest is encrypted and does not show the logical paths" {
  printf 'x\n' > "$T/src/a.txt"
  _ts_map "$T/map" "very/visible/logical-path.txt" "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  _ts_is_age "$T/store/manifest.json.age"
  if grep -qF 'logical-path' "$T/store/manifest.json.age"; then false; fi
}

# ── S6 I6: lo que falla no escribe nada ─────────────────────────────────────

@test "TS10: with a key that does not match, unpack exits 4 and writes nothing" {
  printf 'x %s\n' "$SENT" > "$T/src/a.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  run _ts_unpack "$BR_KEY_B" "$T/dest-b"
  [ "$status" -eq 4 ]
  [ -z "$(find "$T/dest-b" -type f 2> /dev/null)" ]
  if grep -qF -- "$SENT" <<< "$output"; then false; fi
}

# _ts_data_key: descifra key.age con la llave A y deja la llave de datos en un
# archivo de la prueba (solo lo hace la prueba, para fabricar un ataque).
_ts_data_key() {
  age -d -i "$BR_KEY_A" -o "$T/data.key" "$T/store/key.age"
}

@test "TS11: a block replaced by validly encrypted foreign content makes unpack exit 5 and write nothing" {
  printf 'genuine %s\n' "$SENT" > "$T/src/a.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  local block
  block=$(find "$T/store/blocks" -type f -name '*.age' | head -n 1)
  printf 'forged content\n' | gzip -n | age -r "$(cat "$T/store/recipient")" -o "$block"
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 5 ]
  [ -z "$(find "$T/dest" -type f)" ]
  # With the right key, a damaged manifest is an integrity failure (5), not a key
  # that does not open (4): a restore must not go on trying other keys.
  printf 'not an age file\n' > "$T/store/manifest.json.age"
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 5 ]
  [ -z "$(find "$T/dest" -type f)" ]
  # Another encryption of the same plaintext does not match its name either: the
  # store holds exactly the files its manifest names (I14).
  rm -rf "$T/store" "$T/blockmap"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  _ts_data_key
  block=$(find "$T/store/blocks" -type f -name '*.age' | head -n 1)
  age -d -i "$T/data.key" "$block" | age -r "$(cat "$T/store/recipient")" -o "$block.new"
  mv "$block.new" "$block"
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 5 ]
  [ -z "$(find "$T/dest" -type f)" ]
}

@test "TS12: a manifest with an absolute or .. path makes unpack exit 5 and write nothing" {
  printf 'x\n' > "$T/src/a.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  _ts_data_key
  local bad
  age -d -i "$T/data.key" -o "$T/manifest.json" "$T/store/manifest.json.age"
  for bad in "../escaped.txt" "/abs/escaped.txt" "ok/../../escaped.txt" \
             "extra/.git/hooks/pre-commit" ".git/config" "a/.GIT/config"; do
    jq --arg p "$bad" '.files[0].path = $p' "$T/manifest.json" > "$T/manifest.bad.json"
    age -r "$(cat "$T/store/recipient")" -o "$T/store/manifest.json.age" "$T/manifest.bad.json"
    run _ts_unpack "$BR_KEY_A"
    [ "$status" -eq 5 ]
    [ -z "$(find "$T/dest" -type f)" ]
    [ ! -e "$T/escaped.txt" ]
  done
}

# ── S6 I7: un .jsonl hasta su ultimo salto de linea ─────────────────────────

@test "TS13: a .jsonl whose last line is incomplete is packed without that line" {
  printf '{"a":1}\n{"b":2}\n{"c":3' > "$T/src/s.jsonl"
  _ts_map "$T/map" projects/p/s.jsonl "$T/src/s.jsonl"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  _ts_unpack "$BR_KEY_A" > /dev/null
  [ "$(cat "$T/dest/projects/p/s.jsonl")" = "$(printf '{"a":1}\n{"b":2}')" ]
  [ "$(wc -c < "$T/dest/projects/p/s.jsonl" | tr -d ' ')" = "16" ]
  run python3 "$BS" digest --map "$T/map" --list
  [ "$(cut -f2 <<< "$output")" = "16" ]
  # Sin ningun salto de linea, se omite en ese ciclo.
  printf '{"partial":' > "$T/src/s.jsonl"
  run python3 "$BS" digest --map "$T/map" --list
  [ "$output" = "" ]
}

# ── SQLite ──────────────────────────────────────────────────────────────────

@test "TS14: the copy of a SQLite database with writes in progress passes its integrity check and holds what was committed" {
  run python3 - "$BS" "$T" << 'PY'
import glob, os, sqlite3, subprocess, sys
bs, t = sys.argv[1], sys.argv[2]
src = os.path.join(t, "live.db")
w = sqlite3.connect(src)
w.execute("PRAGMA journal_mode=wal")
w.execute("CREATE TABLE obs (id INTEGER PRIMARY KEY, body TEXT)")
w.executemany("INSERT INTO obs (body) VALUES (?)", [("row %d" % i,) for i in range(100)])
w.commit()
w.execute("BEGIN")
w.executemany("INSERT INTO obs (body) VALUES (?)", [("pending",) for _ in range(50)])
dst = os.path.join(t, "copy.db")
out = subprocess.run([sys.executable, bs, "sqlite-snapshot", src, dst], stdout=subprocess.PIPE,
                     universal_newlines=True)
print("rc", out.returncode, out.stdout.strip())
c = sqlite3.connect(dst)
print("rows", c.execute("SELECT count(*) FROM obs").fetchone()[0])
print("check", c.execute("PRAGMA integrity_check").fetchone()[0])
# The unit's capture path must also select sqlite_snapshot; exercising only the
# standalone sqlite-snapshot command cannot detect a raw copy inside capture().
mapping = os.path.join(t, "wal.map")
snapshots = os.path.join(t, "wal.snapshots")
with open(mapping, "wb") as f:
    f.write(b"live.db\0" + os.fsencode(src) + b"\0")
captured = subprocess.run([sys.executable, bs, "digest", "--map", mapping,
                          "--snapshot-dir", snapshots, "--list"],
                         stdout=subprocess.PIPE, universal_newlines=True)
print("capture_rc", captured.returncode)
copies = glob.glob(os.path.join(snapshots, "*.db"))
print("captured_rows", sqlite3.connect(copies[0]).execute("SELECT count(*) FROM obs").fetchone()[0]
      if len(copies) == 1 else "none")
w.rollback()
# A database whose path holds the URI characters ?, # and %.
weird = os.path.join(t, "we?ird #dir%25")
os.makedirs(weird)
src2 = os.path.join(weird, "live.db")
w2 = sqlite3.connect(src2)
w2.execute("CREATE TABLE a (x)")
w2.execute("INSERT INTO a VALUES (1)")
w2.commit()
w2.close()
copy2 = os.path.join(t, "copy2.db")
out2 = subprocess.run([sys.executable, bs, "sqlite-snapshot", src2, copy2],
                      stdout=subprocess.PIPE, universal_newlines=True)
print("rc2", out2.returncode, out2.stdout.strip())
# The copy holds the row: a URI cut at the ? opens another, empty database.
try:
    print("rows2", sqlite3.connect(copy2).execute("SELECT count(*) FROM a").fetchone()[0])
except sqlite3.Error:
    print("rows2 none")
print("stray", os.path.exists(os.path.join(t, "we")))
PY
  [ "$status" -eq 0 ]
  grep -qx 'rc 0 ok' <<< "$output"
  grep -qx 'rows 100' <<< "$output"
  grep -qx 'capture_rc 0' <<< "$output"
  grep -qx 'captured_rows 100' <<< "$output"
  grep -qx 'check ok' <<< "$output"
  grep -qx 'rc2 0 ok' <<< "$output"
  grep -qx 'rows2 1' <<< "$output"
  grep -qx 'stray False' <<< "$output"
}

@test "TS15: the digest of digest equals the one of pack, and changes with --extra" {
  printf 'a %s\n' "$SENT" > "$T/src/a.txt"
  printf 'b\n' > "$T/src/b.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt" b.txt "$T/src/b.txt"
  local d1 d2 p
  d1=$(python3 "$BS" digest --map "$T/map" --extra 'sensitive=false ssh-ed25519 X')
  p=$(_ts_pack --recipients "$T/recips-a" --extra 'sensitive=false ssh-ed25519 X')
  [ "$(_ts_json digest "$p")" = "$d1" ]
  d2=$(python3 "$BS" digest --map "$T/map" --extra 'sensitive=true ssh-ed25519 X')
  [ "$d2" != "$d1" ]
  [ "$(python3 "$BS" digest --map "$T/map")" != "$d1" ]
}

@test "TS16: the fingerprint equals the one of ssh-keygen -lf" {
  local mine theirs
  mine=$(python3 "$BS" fingerprint "$BR_KEY_A_PUB")
  theirs=$(ssh-keygen -lf "$BR_KEY_A.pub" | awk '{print $2}')
  [ -n "$theirs" ]
  [ "$mine" = "$theirs" ]
  run python3 "$BS" fingerprint "not a key"
  [ "$status" -eq 2 ]
}

@test "TS17: the store tool compiles with the host Python" {
  echo "# host $(python3 --version 2>&1)" >&3
  run python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$BS" "$T/bs.pyc"
  [ "$status" -eq 0 ]
  python3 -c 'import sys; assert sys.version_info >= (3, 9)'
}

@test "TS18: pack and digest recognise a SQLite database by its header, pack the consistent copy, and skip -wal, -shm and -journal" {
  python3 - "$T/src/notes.dat" "$SENT" << 'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=wal")
c.execute("CREATE TABLE t (body TEXT)")
c.executemany("INSERT INTO t VALUES (?)", [(sys.argv[2],) for _ in range(200)])
c.commit()
PY
  printf 'wal bytes\n' > "$T/src/other-wal"
  printf 'shm bytes\n' > "$T/src/other-shm"
  printf 'journal bytes\n' > "$T/src/other-journal"
  _ts_map "$T/map" claude-mem/notes.dat "$T/src/notes.dat" claude-mem/notes.dat-wal "$T/src/other-wal" \
    claude-mem/x-shm "$T/src/other-shm" claude-mem/y-journal "$T/src/other-journal"
  local d1 d2
  d1=$(python3 "$BS" digest --map "$T/map" --snapshot-dir "$T/snap")
  # Un checkpoint que vacia el WAL no cambia el hash.
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA wal_checkpoint(TRUNCATE)"); c.close()' "$T/src/notes.dat"
  d2=$(python3 "$BS" digest --map "$T/map" --snapshot-dir "$T/snap")
  [ "$d1" = "$d2" ]
  run python3 "$BS" digest --map "$T/map" --snapshot-dir "$T/snap" --list
  [ "$(wc -l <<< "$output" | tr -d ' ')" = "1" ]
  grep -q '^claude-mem/notes.dat	' <<< "$output"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json digest "$output")" = "$d1" ]
  _ts_unpack "$BR_KEY_A" > /dev/null
  [ "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("PRAGMA integrity_check").fetchone()[0], c.execute("select count(*) from t").fetchone()[0])' "$T/dest/claude-mem/notes.dat")" = "ok 200" ]
  # Sin --snapshot-dir, una base es un error de uso.
  run python3 "$BS" digest --map "$T/map"
  [ "$status" -eq 2 ]
}

# ── S1: la llave de datos ───────────────────────────────────────────────────

@test "TS19: when the operator key changes, pack rotates: everything is re-encrypted and opens only with the new key" {
  printf 'a %s\n' "$SENT" > "$T/src/a.txt"
  printf 'b %s\n' "$SENT" > "$T/src/b.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt" b.txt "$T/src/b.txt"
  run _ts_pack --recipients "$T/recips-a"
  [ "$(_ts_json rotated "$output")" = "new" ]
  local r1
  r1=$(cat "$T/store/recipient")
  run _ts_pack --recipients "$T/recips-b"
  [ "$status" -eq 0 ]
  [ "$(_ts_json rotated "$output")" = "operator-changed" ]
  [ "$(_ts_json new_blocks "$output")" = "$(_ts_json blocks "$output")" ]
  [ "$(cat "$T/store/recipient")" != "$r1" ]
  [ "$(cat "$T/store/operator")" = "$(python3 "$BS" fingerprint "$BR_KEY_B_PUB")" ]
  run _ts_unpack "$BR_KEY_B" "$T/dest-b"
  [ "$status" -eq 0 ]
  cmp -s "$T/src/a.txt" "$T/dest-b/a.txt"
  run _ts_unpack "$BR_KEY_A" "$T/dest-a"
  [ "$status" -eq 4 ]
}

@test "TS20: unpack uses the operator key exactly once with more than 20 blocks, and no file keeps the data key in plaintext" {
  python3 -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(512*24+10))' "$T/src/many.bin"
  printf 'small %s\n' "$SENT" > "$T/src/small.txt"
  _ts_map "$T/map" many.bin "$T/src/many.bin" small.txt "$T/src/small.txt"
  mkdir -p "$T/spy"
  cat > "$T/spy/age" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/age-calls.log"
exec $(command -v age) "\$@"
EOF
  chmod +x "$T/spy/age"
  run env AGE_BIN="$T/spy/age" python3 "$BS" pack --unit test --map "$T/map" --store "$T/store" \
    --snapshot-dir "$T/snap" --recipients "$T/recips-a" --block-size 512
  [ "$status" -eq 0 ]
  [ "$(_ts_json blocks "$output")" -gt 20 ]
  : > "$T/age-calls.log"
  mkdir -p "$T/work"
  run env AGE_BIN="$T/spy/age" python3 "$BS" unpack --store "$T/store" --dest "$T/dest" \
    --identity "$BR_KEY_A" --work-dir "$T/work"
  [ "$status" -eq 0 ]
  [ "$(grep -cF -- "-i $BR_KEY_A" "$T/age-calls.log")" = "1" ]
  [ "$(wc -l < "$T/age-calls.log" | tr -d ' ')" -gt 20 ]
  cmp -s "$T/src/many.bin" "$T/dest/many.bin"
  local d
  for d in "$T/store" "$T/snap" "$T/work" "$T/dest"; do
    if [ -d "$d" ] && grep -rqF 'AGE-SECRET-KEY-' "$d"; then
      echo "a plaintext data key is left in $d" >&2
      false
    fi
  done
}

@test "TS21: with --expect-recipient of the original, a replaced store recipient makes pack rotate, and the foreign key opens nothing" {
  printf 'a %s\n' "$SENT" > "$T/src/a.txt"
  _ts_map "$T/map" a.txt "$T/src/a.txt"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  local r1 foreign
  r1=$(cat "$T/store/recipient")
  age-keygen -o "$T/foreign.key" 2> /dev/null
  foreign=$(age-keygen -y "$T/foreign.key")
  printf '%s\n' "$foreign" > "$T/store/recipient"
  run _ts_pack --recipients "$T/recips-a" --expect-recipient "$r1"
  [ "$status" -eq 0 ]
  [ "$(_ts_json rotated "$output")" = "recipient-mismatch" ]
  [ "$(cat "$T/store/recipient")" != "$foreign" ]
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    if age -d -i "$T/foreign.key" "$f" > /dev/null 2>&1; then
      echo "the foreign key opens $f" >&2
      false
    fi
  done < <(find "$T/store" -type f -name '*.age' ! -name key.age)
  [ "$n" -ge 2 ]
  run _ts_unpack "$BR_KEY_A"
  [ "$status" -eq 0 ]

  # Sin la opcion, pack confia en la recipient que encuentra y no rota.
  rm -rf "$T/store"
  _ts_pack --recipients "$T/recips-a" > /dev/null
  printf '%s\n' "$foreign" > "$T/store/recipient"
  run _ts_pack --recipients "$T/recips-a"
  [ "$status" -eq 0 ]
  [ "$(_ts_json rotated "$output")" = "" ]
}

@test "TS22: digest --list gives path, size and sha256 as captured, and matches what unpack rebuilds" {
  printf 'a %s\n' "$SENT" > "$T/src/a.txt"
  printf '{"x":1}\n{"y":' > "$T/src/h.jsonl"
  python3 -c 'import os,sys; open(sys.argv[1],"wb").write(os.urandom(9000))' "$T/src/c.bin"
  _ts_map "$T/map" z/a.txt "$T/src/a.txt" h.jsonl "$T/src/h.jsonl" b/c.bin "$T/src/c.bin"
  local list
  list=$(python3 "$BS" digest --map "$T/map" --list)
  [ "$(cut -f1 <<< "$list" | tr '\n' ' ')" = "b/c.bin h.jsonl z/a.txt " ]
  _ts_pack --recipients "$T/recips-a" --block-size 4096 > /dev/null
  _ts_unpack "$BR_KEY_A" > /dev/null
  local path size sha
  while IFS=$'\t' read -r path size sha; do
    [ "$(wc -c < "$T/dest/$path" | tr -d ' ')" = "$size" ]
    [ "$(br_sha256 "$T/dest/$path")" = "$sha" ]
  done <<< "$list"
}
