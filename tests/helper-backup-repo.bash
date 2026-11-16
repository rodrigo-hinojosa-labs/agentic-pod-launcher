#!/usr/bin/env bash
# 046: arnes compartido de las suites del repositorio del agente.
#
# Contrato: specs/046-agent-backup-repo/contracts/evidence.md, seccion V1.
# Lo cargan, despues de `load helper`:
#   tests/backup-dest.bats, tests/backup-repo-units.bats, tests/backup-store.bats,
#   tests/backup-repo-restore.bats, tests/agent-repo-surface.bats, tests/backup-status.bats
#
# Reglas que este arnes hace cumplir:
#   - el servidor de prueba se lanza cerrando los descriptores de bats (3>&- 4>&-)
#     y se mata al terminar el archivo;
#   - los comandos de git del propio arnes corren con una configuracion global y de
#     sistema vacias; las unidades que lanza br_unit NO heredan esas variables, sino
#     un HOME propio y vacio, para que TU38 pruebe el aislamiento de produccion;
#   - una dependencia que falta salta la prueba con su motivo en un equipo de
#     desarrollo y la hace FALLAR con la variable CI definida;
#   - cada prueba tiene un centinela propio para la credencial y otro por cada
#     fuente de datos.

BR_FIXTURES="$REPO_ROOT/tests/fixtures/backup-repo"
BR_SERVER_PY="$BR_FIXTURES/git-auth-server.py"
BR_HEARTBEATCTL="$REPO_ROOT/docker/scripts/heartbeatctl"
BR_LIB_DIR="$REPO_ROOT/docker/scripts/lib"

# git del arnes, sin la configuracion del operador ni la del sistema.
_br_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git -c user.name=br-test -c user.email=br-test@localhost -c init.defaultBranch=main "$@"
}

# ── Dependencias ────────────────────────────────────────────────────────────

br_require() {
  local missing="" tool
  if [ ! -x "$(git --exec-path 2>/dev/null)/git-http-backend" ]; then
    missing="$missing git-http-backend"
  fi
  for tool in age age-keygen python3 ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] && return 0
  if [ -n "${CI:-}" ]; then
    echo "046: missing dependencies on a CI runner:$missing" >&2
    return 1
  fi
  skip "046: missing dependencies:$missing"
}

# Pone al comienzo del PATH un directorio con los dobles de timeout y flock, solo si
# el host no tiene los suyos (el Mac no tiene ninguno de los dos).
br_tools_path() {
  local dir="${BATS_FILE_TMPDIR:-$BATS_TEST_TMPDIR}/br-tools"
  mkdir -p "$dir"
  local tool
  for tool in timeout flock; do
    if [ ! -e "$dir/$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
      ln -s "$BR_FIXTURES/bin/$tool" "$dir/$tool"
    fi
  done
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
  export PATH
}

# br_argv_spy: pone delante del PATH un timeout que anota sus argumentos en
# BR_ARGV_LOG y corre el timeout que habia (el del host o el doble). Todo git de
# las unidades y del clon de trabajo pasa por timeout, y sus argumentos incluyen los
# de env y de git: I2 se afirma buscando el centinela de la credencial en ese log.
# Va despues de br_tools_path. br_ctl no usa timeout, asi que el log no ve sus
# propias variables.
br_argv_spy() {
  local dir="$BATS_TEST_TMPDIR/argv-spy" real
  real=$(command -v timeout) || return 1
  mkdir -p "$dir"
  BR_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
  : > "$BR_ARGV_LOG"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$BR_ARGV_LOG" "$real" > "$dir/timeout"
  chmod +x "$dir/timeout"
  PATH="$dir:$PATH"
  export PATH BR_ARGV_LOG
}

# ── Servidor de prueba ──────────────────────────────────────────────────────

# br_start_server: uno por archivo (se llama desde setup_file). Exporta BR_SRV_DIR,
# BR_PORT, BR_BASE_URL, BR_SRV_LOG, BR_TOKEN_FILE y BR_MODE_FILE.
br_start_server() {
  BR_SRV_DIR="${BATS_FILE_TMPDIR:?}/br-server"
  mkdir -p "$BR_SRV_DIR/repos"
  BR_SRV_LOG="$BR_SRV_DIR/requests.log"
  BR_TOKEN_FILE="$BR_SRV_DIR/token"
  BR_MODE_FILE="$BR_SRV_DIR/modes"
  : > "$BR_SRV_LOG"
  : > "$BR_MODE_FILE"
  printf 'br-token-initial\n' > "$BR_TOKEN_FILE"
  rm -f "$BR_SRV_DIR/port"
  GIT_TEST_ROOT="$BR_SRV_DIR/repos" \
  GIT_TEST_TOKEN_FILE="$BR_TOKEN_FILE" \
  GIT_TEST_MODE_FILE="$BR_MODE_FILE" \
  GIT_TEST_PORT_FILE="$BR_SRV_DIR/port" \
  GIT_TEST_LOG="$BR_SRV_LOG" \
    python3 "$BR_SERVER_PY" > "$BR_SRV_DIR/server.out" 2>&1 3>&- 4>&- &
  printf '%s\n' "$!" > "$BR_SRV_DIR/pid"
  local i
  for i in $(seq 1 100); do
    [ -s "$BR_SRV_DIR/port" ] && break
    sleep 0.1
  done
  if [ ! -s "$BR_SRV_DIR/port" ]; then
    echo "046: the test git server did not start in 10 s" >&2
    cat "$BR_SRV_DIR/server.out" >&2
    return 1
  fi
  BR_PORT=$(cat "$BR_SRV_DIR/port")
  BR_BASE_URL="http://127.0.0.1:$BR_PORT"
  export BR_SRV_DIR BR_SRV_LOG BR_TOKEN_FILE BR_MODE_FILE BR_PORT BR_BASE_URL
}

br_stop_server() {
  local pid
  [ -n "${BR_SRV_DIR:-}" ] && [ -f "$BR_SRV_DIR/pid" ] || return 0
  pid=$(cat "$BR_SRV_DIR/pid")
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$BR_SRV_DIR/pid"
}

# br_server_mode [PALABRA...]: reemplaza los modos (sin palabras, los vacia).
br_server_mode() {
  printf '%s\n' "$*" > "$BR_MODE_FILE"
}

# br_server_token VALOR: la unica credencial que el servidor acepta desde ahora.
br_server_token() {
  printf '%s\n' "$1" > "$BR_TOKEN_FILE"
}

# br_log_count PATRON: cuantas lineas del log del servidor coinciden (grep -E).
br_log_count() {
  local n
  n=$(grep -cE -- "$1" "$BR_SRV_LOG" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

# ── Repositorios ────────────────────────────────────────────────────────────

# br_new_repo NOMBRE [--empty]: un repositorio bare servido por el servidor. Sin
# --empty trae una rama de trabajo main con un commit. stdout: su URL.
br_new_repo() {
  local name="$1" empty="${2:-}"
  local bare="$BR_SRV_DIR/repos/$name.git"
  rm -rf "$bare"
  _br_git init -q --bare "$bare"
  _br_git -C "$bare" symbolic-ref HEAD refs/heads/main
  if [ "$empty" != "--empty" ]; then
    local seed="$BATS_TEST_TMPDIR/seed-$name"
    rm -rf "$seed"
    _br_git init -q "$seed"
    printf 'work repository of the agent (%s)\n' "$name" > "$seed/README.md"
    _br_git -C "$seed" add README.md
    _br_git -C "$seed" commit -q -m "initial commit on main"
    _br_git -C "$seed" push -q "$bare" HEAD:refs/heads/main
    rm -rf "$seed"
  fi
  printf '%s/%s.git\n' "$BR_BASE_URL" "$name"
}

# br_bare NOMBRE: la ruta en disco del repositorio bare.
br_bare() {
  printf '%s/repos/%s.git\n' "$BR_SRV_DIR" "$1"
}

# br_work_heads NOMBRE: "<ref> <sha>" de cada rama que no empieza con backup/.
br_work_heads() {
  _br_git -C "$(br_bare "$1")" for-each-ref --format='%(refname) %(objectname)' refs/heads \
    | grep -v '^refs/heads/backup/' || true
}

# br_backup_refs NOMBRE: las referencias de respaldo que hay en el repositorio.
br_backup_refs() {
  _br_git -C "$(br_bare "$1")" for-each-ref --format='%(refname)' refs/heads/backup/ || true
}

# br_branch_head NOMBRE RAMA: el commit de refs/heads/RAMA, o vacio.
br_branch_head() {
  _br_git -C "$(br_bare "$1")" rev-parse --verify --quiet "refs/heads/$2" 2>/dev/null || true
}

# br_branch_commits NOMBRE RAMA: cuantos commits tiene la rama (0 si no existe).
br_branch_commits() {
  if [ -z "$(br_branch_head "$1" "$2")" ]; then
    echo 0
    return 0
  fi
  _br_git -C "$(br_bare "$1")" rev-list --count "refs/heads/$2"
}

# br_branch_files NOMBRE RAMA: los archivos del arbol de la cabeza de la rama.
br_branch_files() {
  _br_git -C "$(br_bare "$1")" ls-tree -r --name-only "refs/heads/$2" 2>/dev/null || true
}

# br_branch_show NOMBRE RAMA RUTA: el contenido de un archivo en la cabeza.
br_branch_show() {
  _br_git -C "$(br_bare "$1")" show "refs/heads/$2:$3" 2>/dev/null
}

# br_branch_has NOMBRE RAMA TEXTO: 0 si TEXTO aparece en algun blob de algun commit
# de la rama (no solo en la cabeza).
br_branch_has() {
  local bare commit
  bare="$(br_bare "$1")"
  _br_git -C "$bare" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 || return 1
  for commit in $(_br_git -C "$bare" rev-list "refs/heads/$2"); do
    if _br_git -C "$bare" grep -a -q -F -e "$3" "$commit" -- 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# br_head_has NOMBRE RAMA TEXTO: 0 si TEXTO aparece en algun blob de la cabeza.
br_head_has() {
  local bare
  bare="$(br_bare "$1")"
  _br_git -C "$bare" rev-parse --verify --quiet "refs/heads/$2" > /dev/null 2>&1 || return 1
  _br_git -C "$bare" grep -a -q -F -e "$3" "refs/heads/$2" -- 2> /dev/null
}

# br_clone_branch NOMBRE RAMA DIR: un clon de solo esa rama, para abrir su almacen.
br_clone_branch() {
  rm -rf "$3"
  _br_git clone -q --single-branch --branch "$2" "$(br_bare "$1")" "$3" 2> /dev/null
}

# br_unpack NOMBRE RAMA LLAVE DESTINO: abre el store/ de la cabeza de la rama.
br_unpack() {
  local clone="$BATS_TEST_TMPDIR/unpack-clone-$$-$RANDOM"
  br_clone_branch "$1" "$2" "$clone"
  python3 "$REPO_ROOT/docker/scripts/backup_store.py" unpack --store "$clone/store" \
    --dest "$4" --identity "$3" > /dev/null
}

# br_seed_branch NOMBRE RAMA MARCA [ARCHIVO CONTENIDO]: empuja al repositorio bare un
# commit en RAMA, encima de su cabeza si existe. MARCA es el JSON de la marca de
# pertenencia, KEEP para conservar la que haya, o NONE para que el arbol no la traiga.
br_seed_branch() {
  local name="$1" branch="$2" mark="$3" file="${4:-intruder.txt}" content="${5:-not a launcher backup}"
  local bare seed
  bare="$(br_bare "$name")"
  seed="$BATS_TEST_TMPDIR/seed-branch-$$-$RANDOM"
  rm -rf "$seed"
  if _br_git -C "$bare" rev-parse --verify --quiet "refs/heads/$branch" > /dev/null 2>&1; then
    _br_git clone -q --branch "$branch" "$bare" "$seed" 2> /dev/null
  else
    _br_git init -q "$seed"
    _br_git -C "$seed" checkout -q --orphan "$branch"
  fi
  case "$mark" in
    KEEP) ;;
    NONE) rm -f "$seed/.agentic-pod-backup.json" ;;
    *) printf '%s\n' "$mark" > "$seed/.agentic-pod-backup.json" ;;
  esac
  mkdir -p "$(dirname "$seed/$file")"
  printf '%s\n' "$content" > "$seed/$file"
  _br_git -C "$seed" add -A
  _br_git -C "$seed" commit -q -m "seeded by the test"
  _br_git -C "$seed" push -q "$bare" "HEAD:refs/heads/$branch"
  rm -rf "$seed"
}

# br_sha256 ARCHIVO: el sha256 hex del archivo (sha256sum o shasum).
br_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── Llaves del operador ─────────────────────────────────────────────────────

# br_keys: dos pares ssh-ed25519 de prueba, A y B (una vez por archivo).
# Exporta BR_KEY_A, BR_KEY_A_PUB (la linea publica), BR_KEY_B y BR_KEY_B_PUB.
br_keys() {
  local dir="${BATS_FILE_TMPDIR:-$BATS_TEST_TMPDIR}/br-keys"
  mkdir -p "$dir"
  local k
  for k in a b; do
    if [ ! -f "$dir/$k" ]; then
      ssh-keygen -q -t ed25519 -N '' -C "br-operator-$k" -f "$dir/$k" >/dev/null
    fi
  done
  BR_KEY_A="$dir/a"
  BR_KEY_B="$dir/b"
  BR_KEY_A_PUB=$(cat "$dir/a.pub")
  BR_KEY_B_PUB=$(cat "$dir/b.pub")
  export BR_KEY_A BR_KEY_B BR_KEY_A_PUB BR_KEY_B_PUB
}

# ── Workspace del agente ────────────────────────────────────────────────────

# br_sentinels: un valor propio por prueba para la credencial y cada fuente.
br_sentinels() {
  local tag="t${BATS_TEST_NUMBER:-0}x$$x${RANDOM}"
  BR_TOKEN="br-token-$tag"
  BR_SENT_SECRETS="br-secret-$tag"
  BR_SENT_VAULT="br-vault-$tag"
  BR_SENT_PERSONA="br-persona-$tag"
  BR_SENT_AUTOMEM="br-automem-$tag"
  BR_SENT_CLAUDEMEM="br-claudemem-$tag"
  BR_SENT_HISTORY="br-history-$tag"
  BR_SENT_EXTRA="br-extra-$tag"
  BR_SENT_IDENTITY="br-identity-$tag"
  export BR_TOKEN BR_SENT_SECRETS BR_SENT_VAULT BR_SENT_PERSONA BR_SENT_AUTOMEM \
         BR_SENT_CLAUDEMEM BR_SENT_HISTORY BR_SENT_EXTRA BR_SENT_IDENTITY
}

# br_workspace [AGENTE]: un workspace con la disposicion real de un agente docker. El
# archivo de secretos esta en la raiz y NO en .state/. Exporta BR_WS y BR_CACHE.
br_workspace() {
  local agent="${1:-repo-bot}"
  BR_WS="$BATS_TEST_TMPDIR/ws"
  BR_CACHE="$BATS_TEST_TMPDIR/cache"
  rm -rf "$BR_WS" "$BR_CACHE"
  mkdir -p "$BR_WS/scripts/heartbeat/logs" "$BR_WS/personas" "$BR_CACHE" \
           "$BR_WS/.state/.claude/channels/telegram" "$BR_WS/.state/.claude/plugins/config" \
           "$BR_WS/.state/.vault/wiki/concepts" \
           "$BR_WS/.state/.claude/projects/-workspace/memory" "$BR_WS/.state/.claude-mem" \
           "$BR_WS/.custom"
  cat > "$BR_WS/agent.yml" << EOF
version: 1
agent:
  name: $agent
  display_name: "Repo Bot"
  role: "r"
  vibe: "v"
  use_default_principles: true
  role_file: personas/$agent.md
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/workspace"
  install_service: false
  mode: docker
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.24.1"
claude:
  config_dir: "/home/agent/.claude"
  profile_new: true
scaffold:
  template_url: "https://github.com/example/agentic-pod-launcher"
  fork:
    enabled: false
    owner: ""
    name: ""
    private: false
    url: ""
notifications:
  channel: none
features:
  heartbeat:
    enabled: false
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
  identity_backup:
    enabled: true
    schedule: "30 3 * * *"
  config_backup:
    enabled: true
    schedule: "30 3 * * *"
  memory_backup:
    enabled: true
    schedule: "40 3 * * *"
  history_backup:
    enabled: true
    schedule: "50 3 * * *"
backup:
  identity:
    recipient: null
  repo:
    url: ""
    allow_unverified: false
  sensitive: false
  extra_paths: []
vault:
  enabled: true
  path: .state/.vault
mcps:
  atlassian: []
  github:
    enabled: true
plugins:
  - telegram@claude-plugins-official
EOF
  # El archivo de secretos de un agente real vive en la raiz del workspace. Las
  # pruebas lo nombran por BR_SECRETS_FILE, y su copia cifrada en la rama por
  # BR_SECRETS_AGE.
  BR_SECRETS_FILE="$BR_WS/.env"
  BR_SECRETS_AGE=".env.age"
  printf 'GITHUB_PAT=placeholder-not-read\nAGENT_SECRET=%s\n' "$BR_SENT_SECRETS" > "$BR_SECRETS_FILE"
  chmod 600 "$BR_SECRETS_FILE"
  export BR_SECRETS_FILE BR_SECRETS_AGE
  printf '{"identity":"%s"}\n' "$BR_SENT_IDENTITY" > "$BR_WS/.state/.claude.json"
  printf '{"permissions":{"defaultMode":"auto"}}\n' > "$BR_WS/.state/.claude/settings.json"
  printf '{"allowFrom":["1"]}\n' > "$BR_WS/.state/.claude/channels/telegram/access.json"
  printf 'plugin config\n' > "$BR_WS/.state/.claude/plugins/config/plugin.json"
  printf '# Concept\n\n%s\n' "$BR_SENT_VAULT" > "$BR_WS/.state/.vault/wiki/concepts/page.md"
  printf '# Persona of %s\n\n%s\n' "$agent" "$BR_SENT_PERSONA" > "$BR_WS/personas/$agent.md"
  printf '# CLAUDE.md of %s\n' "$agent" > "$BR_WS/CLAUDE.md"
  printf '%s\n' "$BR_SENT_AUTOMEM" > "$BR_WS/.state/.claude/projects/-workspace/memory/MEMORY.md"
  printf '{"type":"user","text":"%s"}\n' "$BR_SENT_HISTORY" \
    > "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
  printf '%s\n' "$BR_SENT_EXTRA" > "$BR_WS/.custom/data.txt"
  python3 - "$BR_WS/.state/.claude-mem/claude-mem.db" "$BR_SENT_CLAUDEMEM" << 'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table if not exists obs (id integer primary key, text text)")
con.execute("insert into obs (text) values (?)", (sys.argv[2],))
con.commit()
con.close()
PY
  export BR_WS BR_CACHE
}

# br_set_repo URL: asocia el repositorio en el agent.yml del workspace.
br_set_repo() {
  yq -i ".backup.repo.url = \"$1\"" "$BR_WS/agent.yml"
}

# ── Correr una unidad ───────────────────────────────────────────────────────

# br_unit UNIDAD [ARGS...]: corre `heartbeatctl backup-<unidad>` contra el workspace
# del arnes, con todas las costuras. Las variables de git del arnes NO pasan: la
# unidad corre con un HOME propio y vacio. GITHUB_PAT vale BR_PAT si esta definida
# (aunque sea vacia) y, si no, BR_TOKEN.
br_unit() {
  local unit="$1"
  shift
  br_ctl "backup-$unit" "$@"
}

# br_ctl SUBCOMANDO [ARGS...]: cualquier subcomando de heartbeatctl, con las mismas
# costuras que br_unit.
br_ctl() {
  local sub="$1"
  shift
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM -u GIT_DIR -u GIT_WORK_TREE \
    HOME="$home" \
    HEARTBEATCTL_WORKSPACE="$BR_WS" \
    HEARTBEATCTL_LIB_DIR="$BR_LIB_DIR" \
    HEARTBEATCTL_CRONTAB_FILE="$BR_WS/crontab.out" \
    IDENTITY_STATE_DIR="$BR_WS/.state" \
    IDENTITY_BACKUP_CACHE_DIR="$BR_CACHE/identity" \
    VAULT_BACKUP_CACHE_DIR="$BR_CACHE/agent-backup" \
    CONFIG_BACKUP_CACHE_DIR="$BR_CACHE/agent-backup" \
    MEMORY_BACKUP_CACHE_DIR="$BR_CACHE/agent-backup" \
    HISTORY_BACKUP_CACHE_DIR="$BR_CACHE/agent-backup" \
    VAULT_BACKUP_DIR="${BR_VAULT_DIR-$BR_WS/.state/.vault}" \
    BACKUP_DEST_ALLOW_HTTP=1 \
    BACKUP_ASKPASS_OVERRIDE="$REPO_ROOT/docker/scripts/git-askpass-agent.sh" \
    BACKUP_STORE_PY="$REPO_ROOT/docker/scripts/backup_store.py" \
    AGENT_REPO_DIR="$BR_WS/agent-repo" \
    AGENT_REPO_CREDENTIAL_HELPER="$REPO_ROOT/docker/scripts/git-credential-agent.sh" \
    GITHUB_PAT="${BR_PAT-$BR_TOKEN}" \
    bash "$BR_HEARTBEATCTL" "$sub" "$@"
}

# br_state UNIDAD CAMPO: un campo del archivo de estado de la unidad.
br_state() {
  jq -r ".$2 // \"\"" "$BR_WS/scripts/heartbeat/$1-backup.json" 2>/dev/null || true
}

# br_dest_field CAMPO: un campo del registro del destino.
br_dest_field() {
  jq -r ".$1 // \"\"" "$BR_WS/scripts/heartbeat/backup-dest.json" 2>/dev/null || true
}
