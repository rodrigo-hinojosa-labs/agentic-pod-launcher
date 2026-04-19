#!/bin/bash
# Heartbeat — Lanza una nueva sesión de claude para ejecutar un prompt
# El nombre del agente se detecta automáticamente del workspace
# Uso directo: ./heartbeat.sh [--prompt "override"]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/heartbeat.conf"

# Detectar nombre del agente desde el path del workspace
# scripts/heartbeat/ está 2 niveles bajo el workspace del agente
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_NAME="$(basename "$WORKSPACE_DIR")"

# Directorios de logs persistentes
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
HISTORY_FILE="$LOG_DIR/heartbeat-history.log"
RUN_COUNT_FILE="$LOG_DIR/.run-count"

# Cargar config
if [ -f "$CONF_FILE" ]; then
  source "$CONF_FILE"
else
  echo "ERROR: $CONF_FILE no encontrado"
  exit 1
fi

# Defaults para nuevas variables (backwards compatible)
HEARTBEAT_TIMEOUT="${HEARTBEAT_TIMEOUT:-300}"
HEARTBEAT_RETRIES="${HEARTBEAT_RETRIES:-1}"
NOTIFY_SUCCESS_EVERY="${NOTIFY_SUCCESS_EVERY:-1}"

# Override por CLI
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) HEARTBEAT_PROMPT="$2"; shift 2 ;;
    *) echo "Uso: $0 [--prompt \"...\"]"; exit 1 ;;
  esac
done

# Variables de entorno del agente — leídas de agent.yml (con fallback al
# valor heredado para compatibilidad con agentes antiguos que no tienen la
# sección claude.*).
AGENT_YML="$WORKSPACE_DIR/agent.yml"
if [ -f "$AGENT_YML" ] && command -v yq &>/dev/null; then
  CLAUDE_CONFIG_DIR=$(yq '.claude.config_dir // ""' "$AGENT_YML")
  [ "$CLAUDE_CONFIG_DIR" = "null" ] && CLAUDE_CONFIG_DIR=""
fi
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-personal}"
CLAUDE_CONFIG_DIR=$(eval echo "$CLAUDE_CONFIG_DIR")
TELEGRAM_STATE_DIR="$CLAUDE_CONFIG_DIR/channels/telegram-${AGENT_NAME}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [heartbeat:${AGENT_NAME}] $*"
}

# ── Notifier dispatch ─────────────────────────────────────
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-log}"
NOTIFIER_FILE="$SCRIPT_DIR/notifiers/${NOTIFY_CHANNEL}.sh"
if [ -f "$NOTIFIER_FILE" ]; then
  source "$NOTIFIER_FILE"
else
  echo "WARN: notifier '$NOTIFY_CHANNEL' not found, falling back to log" >&2
  NOTIFY_CHANNEL="log"
  source "$SCRIPT_DIR/notifiers/log.sh"
fi

notify() {
  local msg="$1"
  "notify_${NOTIFY_CHANNEL}" "[Heartbeat:${AGENT_NAME}] $msg"
}

# Registrar ejecución en historial persistente
record_history() {
  local status="$1"    # ok, timeout, error, retry
  local duration="$2"  # segundos
  local attempt="$3"   # número de intento
  local prompt_short="${HEARTBEAT_PROMPT:0:60}"
  echo "$(date '+%Y-%m-%d %H:%M:%S')|${status}|${duration}s|attempt:${attempt}|${prompt_short}" >> "$HISTORY_FILE"

  # Rotar historial si supera 500 líneas
  if [ -f "$HISTORY_FILE" ]; then
    local lines
    lines=$(wc -l < "$HISTORY_FILE")
    if [ "$lines" -gt 500 ]; then
      tail -n 300 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
      mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
      log "Historial rotado (${lines} → 300 líneas)"
    fi
  fi
}

# Rate limiting: decidir si notificar éxito
should_notify_success() {
  if [ "${NOTIFY_SUCCESS_EVERY}" = "0" ]; then
    return 0  # siempre notificar
  fi

  local count=0
  if [ -f "$RUN_COUNT_FILE" ]; then
    count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 0)
  fi
  count=$((count + 1))
  echo "$count" > "$RUN_COUNT_FILE"

  if [ $((count % NOTIFY_SUCCESS_EVERY)) -eq 0 ]; then
    return 0  # notificar
  fi
  return 1  # no notificar
}

# Ejecutar una sesión de claude. Retorna 0 si éxito, 1 si fallo.
run_claude_session() {
  local attempt="$1"
  local hb_session="${AGENT_NAME}-hb-$(date +%s)-a${attempt}"
  local log_file="$LOG_DIR/${hb_session}.log"
  local start_time
  start_time=$(date +%s)

  log "Intento ${attempt}: sesión $hb_session"

  # Cleanup para esta sesión específica
  session_cleanup() {
    tmux kill-session -t "$hb_session" 2>/dev/null || true
  }

  # Verificar que claude esté disponible
  if ! command -v claude &>/dev/null; then
    log "ERROR: claude no encontrado en PATH"
    local elapsed
    elapsed=$(( $(date +%s) - start_time ))
    record_history "error" "$elapsed" "$attempt"
    return 1
  fi

  # Crear sesión tmux y ejecutar claude con el prompt
  tmux new-session -d -s "$hb_session" -c "$WORKSPACE_DIR" \
    "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR=$TELEGRAM_STATE_DIR claude --print \"$HEARTBEAT_PROMPT\" > \"$log_file\" 2>&1; echo HEARTBEAT_DONE >> \"$log_file\""

  log "Sesión $hb_session creada, esperando finalización (timeout: ${HEARTBEAT_TIMEOUT}s)..."

  # Esperar a que claude termine
  local elapsed_wait=0
  while [ $elapsed_wait -lt "$HEARTBEAT_TIMEOUT" ]; do
    if ! tmux has-session -t "$hb_session" 2>/dev/null; then
      log "Sesión terminó"
      break
    fi

    if [ -f "$log_file" ] && grep -q "HEARTBEAT_DONE" "$log_file" 2>/dev/null; then
      log "Claude terminó exitosamente"
      break
    fi

    sleep 5
    elapsed_wait=$((elapsed_wait + 5))
  done

  local total_elapsed=$(( $(date +%s) - start_time ))

  if [ $elapsed_wait -ge "$HEARTBEAT_TIMEOUT" ]; then
    log "WARN: timeout de ${HEARTBEAT_TIMEOUT}s alcanzado"
    session_cleanup
    record_history "timeout" "$total_elapsed" "$attempt"
    return 1
  fi

  # Verificar que HEARTBEAT_DONE esté en el log (éxito real)
  if [ -f "$log_file" ] && grep -q "HEARTBEAT_DONE" "$log_file" 2>/dev/null; then
    session_cleanup
    record_history "ok" "$total_elapsed" "$attempt"
    return 0
  fi

  # Sesión terminó pero sin HEARTBEAT_DONE → error
  session_cleanup
  record_history "error" "$total_elapsed" "$attempt"
  return 1
}

# ── Main ──────────────────────────────────────────────────

log "Iniciando heartbeat para agente '${AGENT_NAME}'"
log "Prompt: ${HEARTBEAT_PROMPT:0:80}..."
log "Config: timeout=${HEARTBEAT_TIMEOUT}s, retries=${HEARTBEAT_RETRIES}"

max_attempts=$((HEARTBEAT_RETRIES + 1))
success=false

for attempt in $(seq 1 "$max_attempts"); do
  if run_claude_session "$attempt"; then
    success=true
    break
  fi

  if [ "$attempt" -lt "$max_attempts" ]; then
    log "Reintentando en 10s... (intento $((attempt + 1))/${max_attempts})"
    notify "Intento ${attempt} falló — reintentando..."
    sleep 10
  fi
done

if $success; then
  log "Heartbeat ejecutado exitosamente"
  if should_notify_success; then
    notify "Heartbeat ejecutado para '${AGENT_NAME}'"
  fi
else
  log "ERROR: heartbeat falló después de ${max_attempts} intentos"
  notify "FALLÓ después de ${max_attempts} intentos — revisar logs"
fi

# Limpiar logs de sesiones antiguas (mantener últimos 20)
find "$LOG_DIR" -name "${AGENT_NAME}-hb-*.log" -type f | sort | head -n -20 | xargs rm -f 2>/dev/null || true
