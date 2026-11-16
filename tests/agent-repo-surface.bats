#!/usr/bin/env bats
#
# 046: la superficie del repositorio del agente. Las claves nuevas de
# agent.yml (backup.repo, backup.sensitive, backup.extra_paths y las unidades
# memory e history), el paso del wizard, los avisos de --regenerate, el
# CLAUDE.md, NEXT_STEPS.md, el doctor, el clon de trabajo y la llave del
# operador.
#
# Contratos: specs/046-agent-backup-repo/contracts/agent-surface.md (A1 a A8)
# y data-model.md (seccion 1). Lo que significa cada prueba esta en la seccion
# V2 de specs/046-agent-backup-repo/contracts/evidence.md.
#
# Reglas para escribir estas pruebas (tasks.md de 046):
#   - ningun [[ ]] ni ! intermedio: se usa [ ], grep -q o `if cmd; then false; fi`;
#   - setup.sh se carga dentro del cuerpo de la prueba, nunca en setup();
#   - el agent.yml de partida se escribe aqui, sin las claves nuevas: la CI
#     clona sin historia y no puede sacarlo de git show;
#   - un criterio nombra pruebas enteras.

load helper
load helper-backup-repo

# Un servidor git de prueba para el clon de trabajo (TA10 a TA12 y TA19). Si faltan
# sus dependencias, esas pruebas se saltan (o fallan con CI) en su br_require.
setup_file() {
  if command -v python3 > /dev/null 2>&1 && [ -x "$(git --exec-path)/git-http-backend" ]; then
    br_start_server
  fi
}

teardown_file() { br_stop_server; }

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  unset BACKUP_DEST_ALLOW_HTTP
}

teardown() { teardown_tmp_dir; }

# Un agent.yml de modo docker, valido para el esquema, SIN ninguna clave de 046
# (molde: _write_agent_yml de tests/mcp-handshake-timeout.bats).
_ta_write_agent_yml() {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
agent:
  name: repo-bot
  display_name: "Repo"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/tmp/repo-bot"
  install_service: false
  mode: docker
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
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
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
plugins:
  - telegram@claude-plugins-official
EOF
}

# ── TA04: --regenerate completa las claves nuevas sin pisar lo del operador ──

@test "TA04: --regenerate backfills the 046 keys with their defaults and never overwrites an operator value" {
  cd "$TMP_TEST_DIR"
  _ta_write_agent_yml
  [ "$(yq -r '(.backup // {}) | has("repo")' agent.yml)" = "false" ]

  # Pierna 1: sin las claves, regenerar las completa con los valores por defecto.
  echo 'n' | ./setup.sh --regenerate > /dev/null
  [ "$(yq -r '.backup.repo.url' agent.yml)" = "" ]
  [ "$(yq -r '.backup.repo.url | type' agent.yml)" = "!!str" ]
  [ "$(yq -r '.backup.repo.allow_unverified' agent.yml)" = "false" ]
  [ "$(yq -r '.backup.sensitive' agent.yml)" = "false" ]
  [ "$(yq -r '.backup.extra_paths | type' agent.yml)" = "!!seq" ]
  [ "$(yq -r '.backup.extra_paths | length' agent.yml)" = "0" ]
  [ "$(yq -r '.features.memory_backup.enabled' agent.yml)" = "true" ]
  [ "$(yq -r '.features.memory_backup.schedule' agent.yml)" = "40 3 * * *" ]
  [ "$(yq -r '.features.history_backup.enabled' agent.yml)" = "true" ]
  [ "$(yq -r '.features.history_backup.schedule' agent.yml)" = "50 3 * * *" ]

  # Pierna 2: lo que escribio el operador sobrevive a un --regenerate.
  yq -i '.features.memory_backup.enabled = false' agent.yml
  yq -i '.backup.sensitive = true' agent.yml
  yq -i '.backup.repo.allow_unverified = true' agent.yml
  yq -i '.backup.extra_paths = [".custom"]' agent.yml
  echo 'n' | ./setup.sh --regenerate > /dev/null 2>&1
  [ "$(yq -r '.features.memory_backup.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.backup.sensitive' agent.yml)" = "true" ]
  [ "$(yq -r '.backup.repo.allow_unverified' agent.yml)" = "true" ]
  [ "$(yq -r '.backup.extra_paths | length' agent.yml)" = "1" ]
  [ "$(yq -r '.backup.extra_paths[0]' agent.yml)" = ".custom" ]

  # Pierna 3: dos regeneraciones seguidas dejan el mismo agent.yml, salvo
  # meta.regenerated_at.
  echo 'n' | ./setup.sh --regenerate > /dev/null 2>&1
  yq 'del(.meta.regenerated_at)' agent.yml > first.yml
  echo 'n' | ./setup.sh --regenerate > /dev/null 2>&1
  yq 'del(.meta.regenerated_at)' agent.yml > second.yml
  cmp -s first.yml second.yml
}

# ── TA05: el esquema valida los tipos y la regla de la URL ──────────────────

@test "TA05: agent_yml_validate rejects a non-boolean in each new boolean key and enforces the backup.repo.url rule" {
  load_lib schema
  _ta_write_agent_yml
  local f="$TMP_TEST_DIR/agent.yml" key err

  # Cada clave booleana nueva rechaza un valor que no es booleano, y la nombra.
  for key in .backup.repo.allow_unverified .backup.sensitive \
             .features.memory_backup.enabled .features.history_backup.enabled; do
    _ta_write_agent_yml
    yq -i "${key} = \"yes\"" "$f"
    err="$TMP_TEST_DIR/err.txt"
    if agent_yml_validate "$f" 2> "$err"; then
      echo "accepted a non-boolean in $key" >&2
      false
    fi
    grep -qF -- "$key" "$err"
  done

  # La regla de la URL, fila por fila de la tabla compartida con TD11.
  local seam url expected rows=0
  while IFS=$'\t' read -r seam url expected; do
    case "$seam" in ''|'#'*) continue ;; esac
    [ "$url" = "<empty>" ] && url=""
    rows=$((rows + 1))
    _ta_write_agent_yml
    yq -i ".backup.repo.url = \"${url}\"" "$f"
    if [ "$seam" = "on" ]; then export BACKUP_DEST_ALLOW_HTTP=1; else unset BACKUP_DEST_ALLOW_HTTP; fi
    if agent_yml_validate "$f" 2> "$TMP_TEST_DIR/err.txt"; then
      if [ "$expected" != "accept" ]; then
        echo "accepted [$url] with seam $seam" >&2
        false
      fi
    else
      if [ "$expected" != "reject" ]; then
        echo "rejected [$url] with seam $seam" >&2
        cat "$TMP_TEST_DIR/err.txt" >&2
        false
      fi
      grep -qF '.backup.repo.url' "$TMP_TEST_DIR/err.txt"
    fi
  done < "$REPO_ROOT/tests/fixtures/backup-repo/url-cases.tsv"
  unset BACKUP_DEST_ALLOW_HTTP
  [ "$rows" -ge 15 ]
}

# ── TA17: backup.extra_paths es una lista ───────────────────────────────────

@test "TA17: backup.extra_paths must be a list, and is backfilled as an empty list when absent" {
  cd "$TMP_TEST_DIR"
  load_lib schema
  _ta_write_agent_yml

  # Un texto en vez de una lista se rechaza, y el error nombra la clave.
  yq -i '.backup.extra_paths = ".custom"' agent.yml
  if agent_yml_validate agent.yml 2> err.txt; then
    echo "accepted a string as backup.extra_paths" >&2
    false
  fi
  grep -qF '.backup.extra_paths' err.txt

  # Una lista de textos se acepta.
  yq -i '.backup.extra_paths = [".custom", "data/notes"]' agent.yml
  agent_yml_validate agent.yml

  # Ausente, --regenerate la completa con una lista vacia.
  _ta_write_agent_yml
  echo 'n' | ./setup.sh --regenerate > /dev/null
  [ "$(yq -r '.backup.extra_paths | type' agent.yml)" = "!!seq" ]
  [ "$(yq -r '.backup.extra_paths | length' agent.yml)" = "0" ]
}

# ── US4: el paso del wizard (A1) ────────────────────────────────────────────
#
# Sin terminal, `read -p` no imprime su pregunta, asi que las pruebas reconocen el
# paso por su encabezado, que el wizard escribe con echo.

_ta_heading='▸ Agent repository (private backup + the agent'"'"'s own work)'

@test "TA01: in docker mode the wizard shows the agent repository step; answering no leaves no repository and no GITHUB_PAT" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=repo-bot display=RepoBot > answers.txt
  run ./setup.sh --destination "$TMP_TEST_DIR/ws" < answers.txt
  [ "$status" -eq 0 ]
  grep -qF "$_ta_heading" <<< "$output"
  [ "$(yq -r '.backup.repo.url' ws/agent.yml)" = "" ]
  [ "$(yq -r '.backup.sensitive' ws/agent.yml)" = "false" ]
  if grep -q '^GITHUB_PAT=' "ws/.env"; then false; fi
}

@test "TA02: answering yes, with a valid URL and sensitive data, asks for the token and writes the three values" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=repo-bot display=RepoBot repo=https://github.com/example/repo-bot-agent \
    sensitive=on repo_pat=ta02-test-token > answers.txt
  run ./setup.sh --destination "$TMP_TEST_DIR/ws" < answers.txt
  [ "$status" -eq 0 ]
  grep -qF '  The agent repository needs a GitHub token to push.' <<< "$output"
  [ "$(yq -r '.backup.repo.url' ws/agent.yml)" = "https://github.com/example/repo-bot-agent" ]
  [ "$(yq -r '.backup.sensitive' ws/agent.yml)" = "true" ]
  grep -qx 'GITHUB_PAT=ta02-test-token' "ws/.env"
  # El resumen trae los tres items nuevos, el del token sin su valor.
  grep -qF ' 24) Agent repository:  https://github.com/example/repo-bot-agent' <<< "$output"
  grep -qF ' 25) Sensitive data:    true' <<< "$output"
  grep -qF ' 26) Repository token:  set' <<< "$output"
  if grep -qF 'ta02-test-token' <<< "$output"; then false; fi
}

@test "TA03: an invalid URL without a terminal ends the wizard with exit 1 and the rule, and the validator follows the URL table" {
  br_tools_path
  cd "$TMP_TEST_DIR"
  wizard_answers name=repo-bot display=RepoBot repo=http://gitlab.example/o/r > answers.txt
  run timeout 20 ./setup.sh --destination "$TMP_TEST_DIR/ws" < answers.txt
  [ "$status" -eq 1 ]
  grep -qF 'The repository URL must be https://github.com/<owner>/<name>' <<< "$output"
  # El validador del wizard sigue la misma tabla que la libreria y el esquema.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/wizard-validators.sh"
  local seam url expected rows=0
  while IFS=$'\t' read -r seam url expected; do
    case "$seam" in ''|'#'*) continue ;; esac
    [ "$url" = "<empty>" ] && url=""
    rows=$((rows + 1))
    if [ "$seam" = "on" ]; then export BACKUP_DEST_ALLOW_HTTP=1; else unset BACKUP_DEST_ALLOW_HTTP; fi
    if validate_backup_repo_url "$url" 2> /dev/null; then
      [ "$expected" = "accept" ] || { echo "validator accepted [$url] ($seam)" >&2; false; }
    else
      [ "$expected" = "reject" ] || { echo "validator rejected [$url] ($seam)" >&2; false; }
    fi
  done < "$REPO_ROOT/tests/fixtures/backup-repo/url-cases.tsv"
  unset BACKUP_DEST_ALLOW_HTTP
  [ "$rows" -ge 15 ]
}

# Un agent.yml de modo local, valido, con el claude de prueba.
_ta_local() {
  _ta_write_agent_yml
  local stub
  stub=$(install_claude_stub)
  # Otro nombre que repo-bot: las unidades locales se llaman agent-<nombre>, y
  # agent-repo-bot contiene la cadena agent-repo que TA14 busca.
  yq -i ".agent.name = \"local-bot\" | .deployment.mode = \"local\" | .deployment.claude_cli = \"$stub\"" "$TMP_TEST_DIR/agent.yml"
}

@test "TA16: in local mode the wizard has no repository step and regenerate warns that the repository and the sensitive mark are docker-only" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=local-bot display=LocalBot deployment_mode=local > answers.txt
  run ./setup.sh --destination "$TMP_TEST_DIR/ws" < answers.txt
  if grep -qF "$_ta_heading" <<< "$output"; then false; fi
  [ -f ws/agent.yml ]
  [ "$(yq -r '.backup.repo.url' ws/agent.yml)" = "" ]
  [ "$(yq -r '.features.memory_backup.enabled' ws/agent.yml)" = "true" ]
  # Segunda pierna: una URL en un agente local.
  _ta_local
  yq -i '.backup.repo.url = "https://github.com/example/local-bot"' agent.yml
  run bash -c 'echo n | ./setup.sh --regenerate 2>&1 >/dev/null'
  grep -qxF 'WARN: backup.repo is docker-only - ignored in local mode' <<< "$output"
  if grep -qF '## Your repository' CLAUDE.md; then false; fi
  # Tercera pierna: la marca de datos sensibles en un agente local.
  yq -i '.backup.repo.url = "" | .backup.sensitive = true' agent.yml
  run bash -c 'echo n | ./setup.sh --regenerate 2>&1 >/dev/null'
  grep -qxF 'WARN: backup.sensitive is docker-only - the local vault backup stays in plaintext' <<< "$output"
}

@test "TA18: in docker mode regenerate warns about a missing key and a missing GITHUB_PAT, never prints the token, and is silent without a repository" {
  cd "$TMP_TEST_DIR"
  _ta_write_agent_yml
  yq -i '.backup.repo.url = "https://github.com/example/repo-bot"' agent.yml
  run bash -c 'echo n | ./setup.sh --regenerate 2>&1 >/dev/null'
  grep -qxF 'WARN: backup.repo is set but there is no encryption key - encrypted backups will not run. Set one with: docker exec -u agent repo-bot heartbeatctl backup-identity --configure-key "<public key>"' <<< "$output"
  grep -qxF 'WARN: backup.repo is set but GITHUB_PAT is missing in .env - backups cannot push' <<< "$output"
  [ "$(yq -r '.backup.identity.recipient // ""' agent.yml)" = "" ]
  # Con un GITHUB_PAT presente, no hay aviso de la credencial ni rastro del valor.
  printf 'GITHUB_PAT=ta18-sentinel-token\n' > .env
  run bash -c 'echo n | ./setup.sh --regenerate 2>&1'
  if grep -qF 'GITHUB_PAT is missing' <<< "$output"; then false; fi
  if grep -qF 'ta18-sentinel-token' <<< "$output"; then false; fi
  # Sin repositorio, ningun aviso de 046.
  yq -i '.backup.repo.url = ""' agent.yml
  run bash -c 'echo n | ./setup.sh --regenerate 2>&1 >/dev/null'
  if grep -qF 'WARN: backup.' <<< "$output"; then false; fi
}

# ── US4: la llave del operador en el scaffold (A2) ──────────────────────────

@test "TA09: without a fork, the scaffold takes the key of the repository owner and prints its fingerprint and comment" {
  br_require
  br_keys
  local keys="$BATS_TEST_TMPDIR/keys"
  mkdir -p "$keys"
  printf '%s\n' "$BR_KEY_A_PUB" > "$keys/example.keys"
  _ta_write_agent_yml
  yq -i '.backup.repo.url = "https://github.com/example/repo-bot"' "$TMP_TEST_DIR/agent.yml"
  local fp
  fp=$(ssh-keygen -lf "$BR_KEY_A.pub" | awk '{print $2}')
  run bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true
    SSH_KEYS_URL_TEMPLATE="file://$2/%s.keys" configure_identity_backup "$3"' _ "$REPO_ROOT" "$keys" "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.backup.identity.recipient' "$TMP_TEST_DIR/agent.yml")" = "$BR_KEY_A_PUB" ]
  grep -qF "$fp  br-operator-a" <<< "$output"
  grep -qF 'heartbeatctl backup-identity --configure-key <path|pubkey>' <<< "$output"
  # Sin fork y sin repositorio, la salida es la de hoy.
  _ta_write_agent_yml
  run bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true
    SSH_KEYS_URL_TEMPLATE="file://$2/%s.keys" configure_identity_backup "$3"' _ "$REPO_ROOT" "$keys" "$TMP_TEST_DIR/agent.yml"
  [ "$output" = "▸ Identity backup: skipping (no scaffold.fork.owner — fork-less agent)" ]
}

# ── US4: el contexto del agente y los archivos derivados (A3, A8) ───────────

_ta_regen() { echo 'n' | ./setup.sh --regenerate > /dev/null 2>&1; }

_ta_next_steps() {  # deja NEXT_STEPS.md en TMP_TEST_DIR, como lo escribe el wizard
  bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true; render_next_steps "$1" quiet' _ "$TMP_TEST_DIR"
}

# El ejemplo de secretos que renderiza --regenerate.
_ta_example() { printf '%s/.env.example\n' "$TMP_TEST_DIR"; }

@test "TA06: without a repository the Backups section of CLAUDE.md is byte-identical to main and nothing of 046 shows" {
  cd "$TMP_TEST_DIR"
  cp "$REPO_ROOT/tests/fixtures/sample-agent.yml" agent.yml
  _ta_regen
  awk '/^## Backups \(what actually survives\)$/ { on = 1; print; next }
       on && /^## / { exit }
       on { print }' CLAUDE.md > section.md
  cmp -s section.md "$REPO_ROOT/tests/fixtures/backup-repo/claude-md-backups-section.golden"
  local s
  for s in 'Your repository' 'agent-repo' 'backup-memory' 'backup-history'; do
    if grep -qF "$s" CLAUDE.md; then echo "found [$s] in CLAUDE.md" >&2; false; fi
  done
}

@test "TA07: with a repository CLAUDE.md lists the five branches, adds Your repository and the Not covered point" {
  cd "$TMP_TEST_DIR"
  _ta_write_agent_yml
  yq -i '.backup.repo.url = "https://github.com/example/repo-bot"' agent.yml
  _ta_regen
  local b
  for b in backup/identity backup/vault backup/config backup/memory backup/history; do
    grep -qF "| \`$b\` |" CLAUDE.md
  done
  grep -qx '## Your repository' CLAUDE.md
  grep -qF '**Not covered**' CLAUDE.md
  grep -qF 'backup.extra_paths' CLAUDE.md
  if grep -qF 'Backups exist only if' CLAUDE.md; then false; fi
}

@test "TA08: with a repository the URL and /workspace/agent-repo reach CLAUDE.md and NEXT_STEPS.md" {
  cd "$TMP_TEST_DIR"
  _ta_write_agent_yml
  yq -i '.backup.repo.url = "https://github.com/example/repo-bot"' agent.yml
  _ta_regen
  _ta_next_steps
  local f
  for f in CLAUDE.md NEXT_STEPS.md; do
    grep -qF 'https://github.com/example/repo-bot' "$f"
    grep -qF '/workspace/agent-repo' "$f"
    if grep -qF '{{' "$f"; then echo "unrendered marker in $f" >&2; false; fi
  done
}

@test "TA13: the launcher .gitignore ignores /agent-repo/" {
  grep -qx '/agent-repo/' "$REPO_ROOT/.gitignore"
}

@test "TA14: in local mode, with or without a repository URL, no derived file mentions the agent repository" {
  cd "$TMP_TEST_DIR"
  local url s f
  for url in "" "https://github.com/example/local-bot"; do
    _ta_local
    yq -i ".backup.repo.url = \"$url\"" agent.yml
    touch "$TMP_TEST_DIR/.stamp"
    sleep 1
    _ta_regen
    while IFS= read -r f; do
      case "$f" in ./agent.yml|./.stamp) continue ;; esac
      for s in 'agent-repo' 'backup-memory' 'backup-history' 'BACKUP_REPO'; do
        if grep -qF "$s" "$f"; then echo "found [$s] in $f (url [$url])" >&2; false; fi
      done
    done < <(find . -type f -newer "$TMP_TEST_DIR/.stamp")
  done
}

@test "TA15: NEXT_STEPS names the repository and its commands only with a repository, and the secrets example needs GITHUB_PAT for it" {
  cd "$TMP_TEST_DIR"
  _ta_write_agent_yml
  yq -i '.backup.repo.url = "https://github.com/example/repo-bot"' agent.yml
  _ta_regen
  _ta_next_steps
  local s
  for s in 'https://github.com/example/repo-bot' 'heartbeatctl backup-memory' 'heartbeatctl backup-history' 'heartbeatctl backup-status'; do
    grep -qF "$s" NEXT_STEPS.md
  done
  grep -qx 'GITHUB_PAT=' "$(_ta_example)"
  # Sin repositorio ni MCP de GitHub: ninguna de esas cadenas y ningun GITHUB_PAT.
  _ta_write_agent_yml
  _ta_regen
  _ta_next_steps
  for s in 'heartbeatctl backup-memory' 'heartbeatctl backup-history' 'heartbeatctl backup-status' 'agent-repo'; do
    if grep -qF "$s" NEXT_STEPS.md; then echo "found [$s]" >&2; false; fi
  done
  if grep -q '^GITHUB_PAT=' "$(_ta_example)"; then false; fi
}

# ── US4: el clon de trabajo (A4, A5) ────────────────────────────────────────

# _ta_clone_env URL: carga las dos librerias y deja un agent.yml con ese repositorio.
_ta_clone_env() {
  br_require
  br_tools_path
  br_sentinels
  br_server_token "$BR_TOKEN"
  br_server_mode
  export GITHUB_PAT="$BR_TOKEN" BACKUP_DEST_ALLOW_HTTP=1
  export AGENT_REPO_DIR="$BATS_TEST_TMPDIR/agent-repo"
  export AGENT_REPO_CREDENTIAL_HELPER="$REPO_ROOT/docker/scripts/git-credential-agent.sh"
  export AGENT_REPO_LOG="$BATS_TEST_TMPDIR/agent-repo.log"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  _ta_write_agent_yml
  yq -i ".backup.repo.url = \"$1\"" "$TMP_TEST_DIR/agent.yml"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/backup_dest.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/agent_repo.sh"
}

_ta_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$AGENT_REPO_DIR" "$@"; }

@test "TA10: agent_repo_ensure clones the default work branch, excludes backup/* and configures the helper for that server only" {
  local url
  url=$(br_new_repo ta10)
  _ta_clone_env "$url"
  br_seed_branch ta10 backup/config '{"schema":1,"agent":"repo-bot","unit":"config"}' agent.yml "x"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git branch --show-current)" = "main" ]
  [ -f "$AGENT_REPO_DIR/README.md" ]
  _ta_git config --get-all remote.origin.fetch | grep -qxF '^refs/heads/backup/*'
  [ "$(_ta_git config --get "credential.$BR_BASE_URL.helper")" = "$AGENT_REPO_CREDENTIAL_HELPER" ]
  [ -z "$(_ta_git config --get credential.helper || true)" ]
  [ -z "$(_ta_git for-each-ref refs/remotes/origin/backup/)" ]
}

@test "TA11: an existing repository only gets the two settings, a non-repository is left alone with a log line, and fork or none do nothing" {
  local url
  url=$(br_new_repo ta11)
  _ta_clone_env "$url"
  # Un repositorio que ya existe, con su rama y su archivo.
  mkdir -p "$AGENT_REPO_DIR"
  _ta_git init -q
  _ta_git checkout -q -b mine
  printf 'local work\n' > "$AGENT_REPO_DIR/mine.txt"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git branch --show-current)" = "mine" ]
  [ -f "$AGENT_REPO_DIR/mine.txt" ]
  _ta_git config --get-all remote.origin.fetch | grep -qxF '^refs/heads/backup/*'
  [ "$(_ta_git config --get "credential.$BR_BASE_URL.helper")" = "$AGENT_REPO_CREDENTIAL_HELPER" ]
  # Un directorio que no es un repositorio.
  rm -rf "$AGENT_REPO_DIR"
  mkdir -p "$AGENT_REPO_DIR"
  printf 'not git\n' > "$AGENT_REPO_DIR/file"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ ! -d "$AGENT_REPO_DIR/.git" ]
  grep -qF 'is not a git repository' "$AGENT_REPO_LOG"
  # Con fork o sin destino, nada y ningun log.
  rm -rf "$AGENT_REPO_DIR" "$AGENT_REPO_LOG"
  yq -i '.backup.repo.url = "" | .scaffold.fork.url = "https://github.com/example/f.git"' "$TMP_TEST_DIR/agent.yml"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ ! -e "$AGENT_REPO_DIR" ]
  [ ! -e "$AGENT_REPO_LOG" ]
  # Ultima pierna: sin la costura, heartbeatctl backup-config lo crea en <workspace>/agent-repo.
  br_workspace
  br_set_repo "$url"
  unset AGENT_REPO_DIR AGENT_REPO_LOG
  local out rc=0
  out=$(env -u AGENT_REPO_DIR HOME="$HOME" HEARTBEATCTL_WORKSPACE="$BR_WS" HEARTBEATCTL_LIB_DIR="$REPO_ROOT/docker/scripts/lib" \
    IDENTITY_STATE_DIR="$BR_WS/.state" CONFIG_BACKUP_CACHE_DIR="$BR_CACHE/agent-backup" \
    BACKUP_ASKPASS_OVERRIDE="$REPO_ROOT/docker/scripts/git-askpass-agent.sh" \
    BACKUP_STORE_PY="$REPO_ROOT/docker/scripts/backup_store.py" \
    AGENT_REPO_CREDENTIAL_HELPER="$AGENT_REPO_CREDENTIAL_HELPER" GITHUB_PAT="$BR_TOKEN" \
    bash "$REPO_ROOT/docker/scripts/heartbeatctl" backup-config 2>&1) || rc=$?
  [ "$rc" -eq 0 ]
  [ -d "$BR_WS/agent-repo/.git" ]
  [ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$BR_WS/agent-repo" branch --show-current)" = "main" ]
}

@test "TA12: from the work clone a plain git push works without asking, and the credential never lands in its config" {
  local url
  url=$(br_new_repo ta12)
  _ta_clone_env "$url"
  br_argv_spy
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  # I2: creating the clone runs git through timeout, and the token is in no argument.
  grep -qF 'ls-remote' "$BR_ARGV_LOG"
  if grep -qF -- "$BR_TOKEN" "$BR_ARGV_LOG"; then false; fi
  _ta_git checkout -q -b feature-x
  printf 'feature\n' > "$AGENT_REPO_DIR/feature.txt"
  _ta_git add feature.txt
  _ta_git -c user.name=t -c user.email=t@t commit -q -m feature
  GIT_TERMINAL_PROMPT=0 _ta_git push -q origin feature-x
  [ -n "$(br_branch_head ta12 feature-x)" ]
  if grep -qF -- "$BR_TOKEN" "$AGENT_REPO_DIR/.git/config"; then false; fi
  [ "$(_ta_git remote get-url origin)" = "$url" ]
  # A helper inherited from the global config (store) is not consulted: the push of
  # the agent leaves no credential file in its home.
  printf '[credential]\n\thelper = store\n' > "$HOME/.gitconfig"
  printf 'more\n' >> "$AGENT_REPO_DIR/feature.txt"
  _ta_git -c user.name=t -c user.email=t@t commit -q -am more
  # The system config stays out (on a Mac it can name the keychain helper).
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 git -C "$AGENT_REPO_DIR" push -q origin feature-x
  [ ! -e "$HOME/.git-credentials" ]
}

@test "TA19: the work clone never checks out a backup branch, whatever the remote holds" {
  local url
  # Un repositorio vacio: una rama main local sin commits.
  url=$(br_new_repo ta19a --empty)
  _ta_clone_env "$url"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git symbolic-ref --short HEAD)" = "main" ]
  if _ta_git rev-parse --verify -q HEAD > /dev/null; then false; fi
  # Solo ramas backup/*: lo mismo.
  url=$(br_new_repo ta19b --empty)
  br_seed_branch ta19b backup/memory '{"schema":1,"agent":"repo-bot","unit":"memory"}' m.txt "m"
  rm -rf "$AGENT_REPO_DIR"
  yq -i ".backup.repo.url = \"$url\"" "$TMP_TEST_DIR/agent.yml"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git symbolic-ref --short HEAD)" = "main" ]
  [ -z "$(_ta_git for-each-ref refs/remotes/origin/backup/)" ]
  # La rama por defecto es trunk.
  url=$(br_new_repo ta19c --empty)
  br_seed_branch ta19c trunk NONE t.txt "t"
  _br_git -C "$(br_bare ta19c)" symbolic-ref HEAD refs/heads/trunk
  rm -rf "$AGENT_REPO_DIR"
  yq -i ".backup.repo.url = \"$url\"" "$TMP_TEST_DIR/agent.yml"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git branch --show-current)" = "trunk" ]
  # La rama por defecto es backup/config y hay main: queda main.
  url=$(br_new_repo ta19d)
  br_seed_branch ta19d backup/config '{"schema":1,"agent":"repo-bot","unit":"config"}' agent.yml "c"
  _br_git -C "$(br_bare ta19d)" symbolic-ref HEAD refs/heads/backup/config
  rm -rf "$AGENT_REPO_DIR"
  yq -i ".backup.repo.url = \"$url\"" "$TMP_TEST_DIR/agent.yml"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ "$(_ta_git branch --show-current)" = "main" ]
  case "$(_ta_git branch --show-current)" in backup/*) false ;; esac
}

# ── US4: --uninstall --nuke avisa por el trabajo sin publicar (A8) ──────────

# _ta_nuke_ws: un workspace scaffoldeado en una copia propia, con su clon de trabajo
# opcional. Deja TA_NUKE con su ruta.
_ta_nuke_ws() {
  TA_NUKE="$BATS_TEST_TMPDIR/nuke-ws-$1"
  rm -rf "$TA_NUKE"
  mkdir -p "$TA_NUKE"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TA_NUKE/"
  cp "$REPO_ROOT/setup.sh" "$TA_NUKE/"
  cp "$TMP_TEST_DIR/agent.yml" "$TA_NUKE/agent.yml"
  : > "$TA_NUKE/.env"
  ( cd "$TA_NUKE" && ./setup.sh --non-interactive > /dev/null 2>&1 ) || true
}

@test "TA20: --uninstall --nuke warns about unpublished commits and uncommitted files in agent-repo before deleting" {
  _ta_write_agent_yml
  local bare="$BATS_TEST_TMPDIR/remote.git"
  _br_git init -q --bare "$bare"
  # Con un commit que no esta en el remoto y un archivo sin commitear.
  _ta_nuke_ws a
  _br_git clone -q "$bare" "$TA_NUKE/agent-repo" 2> /dev/null
  printf 'x\n' > "$TA_NUKE/agent-repo/a.txt"
  _br_git -C "$TA_NUKE/agent-repo" add a.txt
  _br_git -C "$TA_NUKE/agent-repo" commit -q -m local
  printf 'y\n' > "$TA_NUKE/agent-repo/b.txt"
  run bash -c 'cd "$1" && ./setup.sh --uninstall --nuke --yes' _ "$TA_NUKE"
  [ "$status" -eq 0 ]
  grep -qF 'WARN: agent-repo has 1 commit(s) not on any remote branch and 1 uncommitted file(s)' <<< "$output"
  [ ! -d "$TA_NUKE" ]
  # Con todo publicado: sin aviso.
  _ta_nuke_ws b
  _br_git clone -q "$bare" "$TA_NUKE/agent-repo" 2> /dev/null
  printf 'x\n' > "$TA_NUKE/agent-repo/a.txt"
  _br_git -C "$TA_NUKE/agent-repo" add a.txt
  _br_git -C "$TA_NUKE/agent-repo" commit -q -m published
  _br_git -C "$TA_NUKE/agent-repo" push -q origin HEAD:refs/heads/main
  run bash -c 'cd "$1" && ./setup.sh --uninstall --nuke --yes' _ "$TA_NUKE"
  [ "$status" -eq 0 ]
  if grep -qF 'WARN: agent-repo' <<< "$output"; then false; fi
  # Sin agent-repo: sin aviso.
  _ta_nuke_ws c
  run bash -c 'cd "$1" && ./setup.sh --uninstall --nuke --yes' _ "$TA_NUKE"
  [ "$status" -eq 0 ]
  if grep -qF 'WARN: agent-repo' <<< "$output"; then false; fi
}
