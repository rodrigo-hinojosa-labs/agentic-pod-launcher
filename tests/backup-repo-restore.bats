#!/usr/bin/env bats
#
# 046: la restauracion de un agente desde su repositorio (setup.sh restore_from_fork,
# con el alias --restore-from-repo).
#
# Contrato: specs/046-agent-backup-repo/contracts/restore.md (R1 a R8) y la seccion 8
# de data-model.md. Lo que significa cada prueba: seccion V2 de
# specs/046-agent-backup-repo/contracts/evidence.md (TR01 a TR14).
#
# El origen de cada prueba se arma corriendo las unidades reales contra el servidor de
# prueba; la restauracion lee la ruta en disco del repositorio bare, como cuando el
# operador la corre con sus credenciales. Toda prueba corre con un HOME propio y vacio:
# "sin llave" quiere decir sin RESTORE_IDENTITY_KEY y sin llaves por defecto ahi.
# setup.sh se carga dentro del cuerpo de cada prueba.

load helper
load helper-backup-repo

setup_file() {
  br_require || return 1
  br_start_server
}

teardown_file() { br_stop_server; }

setup() {
  br_require
  br_tools_path
  br_sentinels
  br_keys
  br_server_token "$BR_TOKEN"
  br_server_mode
  unset BR_PAT RESTORE_IDENTITY_KEY
  TR_DEST="$BATS_TEST_TMPDIR/restored"
  TR_HOME="$BATS_TEST_TMPDIR/restore-home"
  mkdir -p "$TR_HOME"
}

# _tr_origin NOMBRE [sensitive]: un agente con todo lo que se respalda, y sus cinco
# unidades corridas contra un repositorio nuevo. Deja TR_BARE con la ruta en disco.
_tr_origin() {
  br_workspace
  local url
  url=$(br_new_repo "$1")
  br_set_repo "$url"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  yq -i '.backup.extra_paths = [".custom", ".state/extra-data"]' "$BR_WS/agent.yml"
  [ "${2:-}" = "sensitive" ] && yq -i '.backup.sensitive = true' "$BR_WS/agent.yml"
  mkdir -p "$BR_WS/.claude/skills/registro" "$BR_WS/.state/extra-data"
  printf '# skill %s\n' "$BR_SENT_PERSONA" > "$BR_WS/.claude/skills/registro/SKILL.md"
  printf 'services: {}\n' > "$BR_WS/docker-compose.override.yml"
  printf 'state extra %s\n' "$BR_SENT_EXTRA" > "$BR_WS/.state/extra-data/f.txt"
  # Un .jsonl cuya ultima linea esta a medio escribir.
  printf '{"line":"half' >> "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
  local u
  for u in config identity vault memory history; do
    br_unit "$u" > /dev/null
  done
  TR_BARE=$(br_bare "$1")
}

# _tr_restore [ARGS DE ENTORNO...]: restore_from_fork del origen hacia TR_DEST, con
# un HOME vacio. Imprime la salida.
_tr_restore() {
  ( _tr_key="${RESTORE_IDENTITY_KEY:-}"
    export HOME="$TR_HOME" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    # shellcheck source=/dev/null
    source "$REPO_ROOT/setup.sh" > /dev/null 2>&1 || true
    # setup.sh pone RESTORE_IDENTITY_KEY en vacio al cargarse, como parse_args espera.
    RESTORE_IDENTITY_KEY="$_tr_key"
    restore_from_fork "$TR_BARE" "$TR_DEST" )
}

_tr_same() {  # ORIGEN RESTAURADO
  [ -f "$2" ] || { echo "missing restored file $2" >&2; return 1; }
  [ "$(br_sha256 "$1")" = "$(br_sha256 "$2")" ] || { echo "content differs: $2" >&2; return 1; }
}

# El SHA-256 y el tamano de lo capturado, segun backup_store.py digest --list.
_tr_captured() {  # LOGICA ORIGEN -> "<tamano> <sha256>"
  printf '%s\0%s\0' "$1" "$2" > "$BATS_TEST_TMPDIR/cap.map"
  python3 "$REPO_ROOT/docker/scripts/backup_store.py" digest --map "$BATS_TEST_TMPDIR/cap.map" \
    --snapshot-dir "$BATS_TEST_TMPDIR/cap.snap" --list | awk -F '\t' '{print $2, $3}'
}

_tr_restored_sig() {  # ARCHIVO -> "<tamano> <sha256>"
  printf '%s %s\n' "$(wc -c < "$1" | tr -d ' ')" "$(br_sha256 "$1")"
}

@test "TR01: a full restore with the key puts every file in its place, equal to its origin or to what was captured" {
  _tr_origin tr01
  local db_sig jsonl_sig
  db_sig=$(_tr_captured claude-mem/claude-mem.db "$BR_WS/.state/.claude-mem/claude-mem.db")
  jsonl_sig=$(_tr_captured projects/-workspace/0000-session.jsonl "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl")
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  local w="$BR_WS" d="$TR_DEST"
  _tr_same "$w/agent.yml" "$d/agent.yml"
  _tr_same "$w/CLAUDE.md" "$d/CLAUDE.md"
  _tr_same "$w/personas/repo-bot.md" "$d/personas/repo-bot.md"
  _tr_same "$w/docker-compose.override.yml" "$d/docker-compose.override.yml"
  _tr_same "$w/.claude/skills/registro/SKILL.md" "$d/.claude/skills/registro/SKILL.md"
  _tr_same "$w/.state/.claude.json" "$d/.state/.claude.json"
  _tr_same "$w/.state/.claude/settings.json" "$d/.state/.claude/settings.json"
  _tr_same "$BR_SECRETS_FILE" "$d/${BR_SECRETS_FILE##*/}"
  _tr_same "$w/.state/.vault/wiki/concepts/page.md" "$d/.state/.vault/wiki/concepts/page.md"
  _tr_same "$w/.state/.claude/projects/-workspace/memory/MEMORY.md" "$d/.state/.claude/projects/-workspace/memory/MEMORY.md"
  _tr_same "$w/.custom/data.txt" "$d/.custom/data.txt"
  _tr_same "$w/.state/extra-data/f.txt" "$d/.state/extra-data/f.txt"
  [ "$(_tr_restored_sig "$d/.state/.claude-mem/claude-mem.db")" = "$db_sig" ]
  [ "$(_tr_restored_sig "$d/.state/.claude/projects/-workspace/0000-session.jsonl")" = "$jsonl_sig" ]
  grep -qF 'restore: memory restored into' <<< "$output"
  grep -qF 'restore: history restored into' <<< "$output"
}

@test "TR02: without the backup/history branch the other four are restored and the output names the missing one" {
  _tr_origin tr02
  _br_git -C "$TR_BARE" update-ref -d refs/heads/backup/history
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF "restore: no backup/history branch at $TR_BARE — skipping" <<< "$output"
  [ -f "$TR_DEST/agent.yml" ]
  [ -f "$TR_DEST/.state/.claude.json" ]
  [ -f "$TR_DEST/.state/.vault/wiki/concepts/page.md" ]
  [ -f "$TR_DEST/.state/.claude-mem/claude-mem.db" ]
  [ ! -e "$TR_DEST/.state/.claude/projects/-workspace/0000-session.jsonl" ]
}

@test "TR03: without a key the encrypted pieces are skipped with their line and the plaintext ones are restored" {
  _tr_origin tr03
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/history is encrypted and no usable key was found (pass --identity-key <path>) — skipped' <<< "$output"
  [ -f "$TR_DEST/agent.yml" ]
  [ -f "$TR_DEST/personas/repo-bot.md" ]
  [ -f "$TR_DEST/.state/.claude.json" ]
  [ -f "$TR_DEST/.state/.vault/wiki/concepts/page.md" ]
  [ -f "$TR_DEST/.state/.claude/projects/-workspace/memory/MEMORY.md" ]
  [ ! -e "$TR_DEST/.state/.claude-mem/claude-mem.db" ]
  [ ! -e "$TR_DEST/.state/.claude/projects/-workspace/0000-session.jsonl" ]
  [ ! -e "$TR_DEST/${BR_SECRETS_FILE##*/}" ]
}

@test "TR04: without python3 on the PATH what comes in store/ is skipped with its line and the rest is restored" {
  _tr_origin tr04
  # Un PATH armado para la prueba: todo lo del PATH actual salvo python3.
  local nopy="$BATS_TEST_TMPDIR/nopy" dir f
  mkdir -p "$nopy"
  local IFS=':'
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      case "${f##*/}" in python3*|python) continue ;; esac
      [ -x "$f" ] && [ ! -e "$nopy/${f##*/}" ] && ln -s "$f" "$nopy/${f##*/}"
    done
  done
  unset IFS
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run env PATH="$nopy" bash -c 'export HOME="$1" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null
    source "$2/setup.sh" > /dev/null 2>&1 || true
    RESTORE_IDENTITY_KEY="$5"
    restore_from_fork "$3" "$4"' _ "$TR_HOME" "$REPO_ROOT" "$TR_BARE" "$TR_DEST" "$BR_KEY_A"
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/history needs python3 and age on this host — skipped' <<< "$output"
  grep -qF 'restore: backup/memory needs python3 and age on this host — skipped' <<< "$output"
  [ -f "$TR_DEST/agent.yml" ]
  [ -f "$TR_DEST/.state/.claude.json" ]
  [ -f "$TR_DEST/${BR_SECRETS_FILE##*/}" ]
  [ -f "$TR_DEST/.state/.claude/projects/-workspace/memory/MEMORY.md" ]
  [ ! -e "$TR_DEST/.state/.claude-mem/claude-mem.db" ]
}

# _tr_forge_block NOMBRE RAMA: reemplaza un bloque del almacen de la rama por otro
# contenido cifrado de forma valida para su recipient, en un commit nuevo.
_tr_forge_block() {
  local clone="$BATS_TEST_TMPDIR/forge-${2//\//-}"
  br_clone_branch "$1" "$2" "$clone"
  local block
  block=$(find "$clone/store/blocks" -type f -name '*.age' | LC_ALL=C sort | head -n 1)
  printf 'forged\n' | gzip -n | age -r "$(cat "$clone/store/recipient")" -o "$block"
  _br_git -C "$clone" add -A
  _br_git -C "$clone" commit -q -m forged
  _br_git -C "$clone" push -q origin "HEAD:refs/heads/$2"
}

# _tr_forge_manifest NOMBRE RAMA FILTRO_JQ: reescribe el manifiesto del almacen de la
# rama con FILTRO_JQ y lo cifra de forma valida para su recipient, en un commit nuevo:
# lo que puede hacer cualquiera que escriba en el repositorio (age no autentica).
_tr_forge_manifest() {
  local clone="$BATS_TEST_TMPDIR/forge-m-$RANDOM-${2//\//-}"
  br_clone_branch "$1" "$2" "$clone"
  age -d -i "$BR_KEY_A" -o "$clone.key" "$clone/store/key.age"
  age -d -i "$clone.key" -o "$clone.m.json" "$clone/store/manifest.json.age"
  jq "$3" "$clone.m.json" > "$clone.m2.json"
  age -r "$(cat "$clone/store/recipient")" -o "$clone/store/manifest.json.age" "$clone.m2.json"
  _br_git -C "$clone" commit -q -am forged
  _br_git -C "$clone" push -q origin "HEAD:refs/heads/$2"
}

@test "TR05: an altered block in backup/memory writes nothing for that unit, and the other units are restored" {
  _tr_origin tr05
  _tr_forge_block tr05 backup/memory
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/memory failed its integrity check — nothing was written for this unit' <<< "$output"
  [ ! -e "$TR_DEST/.state/.claude-mem" ]
  [ ! -e "$TR_DEST/.custom" ]
  [ ! -e "$TR_DEST/.state/.claude/projects/-workspace/memory/MEMORY.md" ]
  [ -f "$TR_DEST/agent.yml" ]
  [ -f "$TR_DEST/.state/.vault/wiki/concepts/page.md" ]
  [ -f "$TR_DEST/.state/.claude/projects/-workspace/0000-session.jsonl" ]
  [ ! -e "$TR_DEST/.restore-tmp" ]
}

@test "TR06: a restore from a three-branch fork gives the output of main" {
  # El fork de tests/restore-unified.bats, armado igual.
  local bare="$BATS_TEST_TMPDIR/fork.git" seed="$BATS_TEST_TMPDIR/seed"
  _br_git init -q --bare "$bare"
  _br_git init -q "$seed"
  _br_git -C "$seed" checkout -q --orphan backup/config
  printf 'agent:\n  name: restored-agent\n  display_name: "Restored Agent"\nscaffold:\n  fork:\n    url: dummy\nvault:\n  enabled: true\n  path: .state/notes\n' > "$seed/agent.yml"
  _br_git -C "$seed" add -A
  _br_git -C "$seed" commit -q -m "config seed"
  _br_git -C "$seed" push -q "$bare" HEAD:refs/heads/backup/config
  _br_git -C "$seed" checkout -q --orphan backup/identity
  rm -f "$seed/agent.yml"
  mkdir -p "$seed/.claude/channels/telegram" "$seed/.claude/plugins/config"
  echo '{"userID":"u1"}' > "$seed/.claude.json"
  echo '{"permissions":{"defaultMode":"auto"}}' > "$seed/.claude/settings.json"
  echo '{"allowFrom":["987"]}' > "$seed/.claude/channels/telegram/access.json"
  _br_git -C "$seed" add -A
  _br_git -C "$seed" commit -q -m "identity seed"
  _br_git -C "$seed" push -q "$bare" HEAD:refs/heads/backup/identity
  _br_git -C "$seed" checkout -q --orphan backup/vault
  rm -rf "$seed/.claude" "$seed/.claude.json"
  mkdir -p "$seed/wiki/summaries"
  echo "# Index" > "$seed/index.md"
  echo "# Memex" > "$seed/wiki/summaries/memex.md"
  _br_git -C "$seed" add -A
  _br_git -C "$seed" commit -q -m "vault seed"
  _br_git -C "$seed" push -q "$bare" HEAD:refs/heads/backup/vault
  TR_BARE="$bare"
  run _tr_restore
  [ "$status" -eq 0 ]
  local got="$BATS_TEST_TMPDIR/restore.out"
  printf '%s\n' "$output" | sed -e "s|$TR_DEST|<DEST>|g" -e "s|$bare|<FORK>|g" > "$got"
  diff -u "$BR_FIXTURES/restore-fork-output.golden" "$got"
}

@test "TR07: --restore-from-repo sets the same RESTORE_FORK_URL as --restore-from-fork, and shows in --help" {
  run bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true; parse_args --restore-from-repo https://github.com/o/r; printf "%s\n" "$RESTORE_FORK_URL"' _ "$REPO_ROOT"
  [ "$(tail -n 1 <<< "$output")" = "https://github.com/o/r" ]
  run bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true; parse_args --restore-from-fork https://github.com/o/f; printf "%s\n" "$RESTORE_FORK_URL"' _ "$REPO_ROOT"
  [ "$(tail -n 1 <<< "$output")" = "https://github.com/o/f" ]
  run "$REPO_ROOT/setup.sh" --help
  grep -qF -- '--restore-from-repo' <<< "$output"
}

@test "TR08: a vault backed up with the sensitive mark is restored into vault.path, with its markdown" {
  _tr_origin tr08 sensitive
  br_branch_files tr08 backup/vault | grep -q '^store/'
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/.state/.vault/wiki/concepts/page.md" "$TR_DEST/.state/.vault/wiki/concepts/page.md"
  # The encrypted vault brings back markdown only, as the plaintext one: a manifest
  # that adds other files writes none of them.
  local copy='(.files[] | select(.path == "wiki/concepts/page.md"))'
  _tr_forge_manifest tr08 backup/vault ".files += [($copy | .path = \"evil.sh\"), ($copy | .path = \"wiki/run.py\")]"
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/.state/.vault/wiki/concepts/page.md" "$TR_DEST/.state/.vault/wiki/concepts/page.md"
  [ ! -e "$TR_DEST/.state/.vault/evil.sh" ]
  [ ! -e "$TR_DEST/.state/.vault/wiki/run.py" ]
  # A vault.path that leaves the workspace is not followed: the vault goes to
  # .state/.vault, with a line that says so.
  br_seed_branch tr08 backup/config KEEP agent.yml "$(yq '.vault.path = "../outside-vault"' "$BR_WS/agent.yml")"
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside-vault" ]
  grep -qF "restore: vault.path '../outside-vault' leaves the workspace — restoring into .state/.vault" <<< "$output"
  _tr_same "$BR_WS/.state/.vault/wiki/concepts/page.md" "$TR_DEST/.state/.vault/wiki/concepts/page.md"
  # Nor one under the workspace's .git.
  br_seed_branch tr08 backup/config KEEP agent.yml "$(yq '.vault.path = ".git/notes"' "$BR_WS/agent.yml")"
  rm -rf "$TR_DEST"
  _br_git init -q "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  [ ! -e "$TR_DEST/.git/notes" ]
  grep -qF "restore: vault.path '.git/notes' leaves the workspace — restoring into .state/.vault" <<< "$output"
  # Without the key the encrypted vault is skipped, and the output never says that
  # it was restored.
  unset RESTORE_IDENTITY_KEY
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/vault is encrypted and no usable key was found (pass --identity-key <path>) — skipped' <<< "$output"
  if grep -qF 'restore: vault restored into' <<< "$output"; then false; fi
}

@test "TR09: a restore brings the content of memory and history, never the mark or the data key files" {
  _tr_origin tr09
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  [ -f "$TR_DEST/.state/.claude-mem/claude-mem.db" ]
  [ -f "$TR_DEST/.state/.claude/projects/-workspace/0000-session.jsonl" ]
  [ -z "$(find "$TR_DEST" \( -name .agentic-pod-backup.json -o -name key.age -o -name recipient -o -name operator \) -print)" ]
}

@test "TR10: the restored secrets file lands in the root with mode 600, and the token notice shows only without a token" {
  _tr_origin tr10
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  local f="$TR_DEST/${BR_SECRETS_FILE##*/}"
  _tr_same "$BR_SECRETS_FILE" "$f"
  [ "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$f")" = "600" ]
  grep -qF 'restore: no Claude token in the restored secrets file — run /login after the first boot' <<< "$output"
  # Con un token con valor, el aviso no sale.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=tr-test-token-value\n' >> "$BR_SECRETS_FILE"
  br_unit identity > /dev/null
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  if grep -qF 'no Claude token' <<< "$output"; then false; fi
  if grep -qF 'tr-test-token-value' <<< "$output"; then false; fi
}

@test "TR11: the project .claude/ directory is restored at the root" {
  _tr_origin tr11
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/.claude/skills/registro/SKILL.md" "$TR_DEST/.claude/skills/registro/SKILL.md"
  # Branches written by someone else: a symlink in place of personas/ and of the
  # history directory, and a .claude/ path outside the closed list. None of them
  # lands, and nothing is written through a link.
  local out="$BATS_TEST_TMPDIR/outside" out2="$BATS_TEST_TMPDIR/outside2" clone
  mkdir -p "$out" "$out2"
  clone="$BATS_TEST_TMPDIR/sym-config"
  br_clone_branch tr11 backup/config "$clone"
  rm -rf "$clone/personas"
  ln -s "$out" "$clone/personas"
  mkdir -p "$clone/.claude/other"
  printf 'other\n' > "$clone/.claude/other/x.md"
  _br_git -C "$clone" add -A
  _br_git -C "$clone" commit -q -m forged
  _br_git -C "$clone" push -q origin HEAD:refs/heads/backup/config
  clone="$BATS_TEST_TMPDIR/sym-identity"
  br_clone_branch tr11 backup/identity "$clone"
  ln -s "$out2" "$clone/.claude/projects"
  _br_git -C "$clone" add -A
  _br_git -C "$clone" commit -q -m forged
  _br_git -C "$clone" push -q origin HEAD:refs/heads/backup/identity
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  [ ! -L "$TR_DEST/personas" ]
  [ ! -L "$TR_DEST/.state/.claude/projects" ]
  [ -z "$(ls -A "$out")" ]
  [ -z "$(ls -A "$out2")" ]
  [ ! -e "$TR_DEST/.claude/other" ]
  _tr_same "$BR_WS/.claude/skills/registro/SKILL.md" "$TR_DEST/.claude/skills/registro/SKILL.md"
  _tr_same "$BR_WS/.state/.claude/projects/-workspace/memory/MEMORY.md" "$TR_DEST/.state/.claude/projects/-workspace/memory/MEMORY.md"
  # A symlink that is already in the destination is not written through either.
  rm -rf "$TR_DEST"
  mkdir -p "$TR_DEST"
  ln -s "$out" "$TR_DEST/.claude"
  run _tr_restore
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$out")" ]
}

@test "TR12: extra paths come back to their path, also under .state/, and a logical path with .. writes nothing outside" {
  _tr_origin tr12
  # The scaffold runs git init before the restore, as setup.sh does.
  _br_git init -q "$TR_DEST"
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/.custom/data.txt" "$TR_DEST/.custom/data.txt"
  _tr_same "$BR_WS/.state/extra-data/f.txt" "$TR_DEST/.state/extra-data/f.txt"
  # An extra path restored outside .state/ travelled encrypted, so it stays out of
  # the workspace's git; .state/ is ignored already.
  grep -qxF '/.custom' "$TR_DEST/.git/info/exclude"
  if grep -qF 'extra-data' "$TR_DEST/.git/info/exclude"; then false; fi
  # Someone who writes the repository declares launcher paths in agent.yml and adds
  # them to the encrypted manifest, with the login file and an undeclared path: only
  # the declared, allowed extra paths come back.
  local login=".credentials.json" copy='(.files[] | select(.path == "extra/.custom/data.txt"))'
  br_seed_branch tr12 backup/config KEEP agent.yml \
    "$(yq '.backup.extra_paths += ["scripts", "setup.sh"]' "$BR_WS/agent.yml")"
  _tr_forge_manifest tr12 backup/memory ".files += [($copy | .path = \"extra/scripts/lib/render.sh\"), ($copy | .path = \"extra/setup.sh\"), ($copy | .path = \"extra/.state/extra-data/$login\"), ($copy | .path = \"extra/.other/x.txt\")]"
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/.custom/data.txt" "$TR_DEST/.custom/data.txt"
  [ ! -e "$TR_DEST/scripts/lib/render.sh" ]
  [ ! -e "$TR_DEST/setup.sh" ]
  [ ! -e "$TR_DEST/.state/extra-data/$login" ]
  [ ! -e "$TR_DEST/.other" ]
  # A .git segment makes the whole unit fail its integrity check: a hook never lands.
  _tr_forge_manifest tr12 backup/memory ".files += [($copy | .path = \"extra/.git/hooks/pre-commit\" | .mode = \"755\")]"
  rm -rf "$TR_DEST"
  _br_git init -q "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/memory failed its integrity check — nothing was written for this unit' <<< "$output"
  [ ! -e "$TR_DEST/.git/hooks/pre-commit" ]
  # One traversal entry: duplicate paths or the previous .git entry must not reject
  # the unit before the path guard under test. A later restore filter is insufficient:
  # unpack itself must reject the unit, including writes inside its temporary tree.
  _tr_forge_manifest tr12 backup/memory ".files = [($copy | .path = \"extra/../../fuera\")]"
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  grep -qF 'restore: backup/memory failed its integrity check — nothing was written for this unit' <<< "$output"
  [ ! -e "$BATS_TEST_TMPDIR/fuera" ]
  [ ! -e "$TR_DEST/fuera" ]
  [ ! -e "$TR_DEST/../fuera" ]
  [ ! -e "$TR_DEST/.custom" ]
}

@test "TR13: the encrypted config of a sensitive agent comes back whole with the key, and only agent.yml without it" {
  _tr_origin tr13 sensitive
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/agent.yml" "$TR_DEST/agent.yml"
  _tr_same "$BR_WS/personas/repo-bot.md" "$TR_DEST/personas/repo-bot.md"
  _tr_same "$BR_WS/CLAUDE.md" "$TR_DEST/CLAUDE.md"
  _tr_same "$BR_WS/.claude/skills/registro/SKILL.md" "$TR_DEST/.claude/skills/registro/SKILL.md"
  unset RESTORE_IDENTITY_KEY
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/agent.yml" "$TR_DEST/agent.yml"
  [ ! -e "$TR_DEST/personas/repo-bot.md" ]
  grep -qF 'restore: backup/config is partly encrypted and no usable key was found — only agent.yml was restored' <<< "$output"
  # The encrypted config brings back its closed list only: a manifest that adds
  # launcher files or another .claude/ path writes none of them.
  local copy='(.files[] | select(.path == "personas/repo-bot.md"))'
  _tr_forge_manifest tr13 backup/config ".files += [($copy | .path = \"scripts/evil.sh\"), ($copy | .path = \"setup.sh\"), ($copy | .path = \".claude/other/x.md\")]"
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  rm -rf "$TR_DEST"
  run _tr_restore
  [ "$status" -eq 0 ]
  _tr_same "$BR_WS/personas/repo-bot.md" "$TR_DEST/personas/repo-bot.md"
  [ ! -e "$TR_DEST/scripts/evil.sh" ]
  [ ! -e "$TR_DEST/setup.sh" ]
  [ ! -e "$TR_DEST/.claude/other" ]
}

@test "TR14: a mixed unit without a key restores its plaintext part, no temporary dir is left, and an override leaves its notice" {
  _tr_origin tr14
  run _tr_restore
  [ "$status" -eq 0 ]
  [ -f "$TR_DEST/.state/.claude/projects/-workspace/memory/MEMORY.md" ]
  grep -qF 'restore: backup/memory is encrypted and no usable key was found (pass --identity-key <path>) — skipped' <<< "$output"
  [ ! -e "$TR_DEST/.restore-tmp" ]
  grep -qF 'restore: docker-compose.override.yml was restored — review it before the first boot' <<< "$output"
  # Tras la falla de integridad de TR05 tampoco queda el temporal.
  _tr_forge_block tr14 backup/history
  export RESTORE_IDENTITY_KEY="$BR_KEY_A"
  rm -rf "$TR_DEST"
  run _tr_restore
  grep -qF 'restore: backup/history failed its integrity check — nothing was written for this unit' <<< "$output"
  [ ! -e "$TR_DEST/.restore-tmp" ]
}
