# Synthetic-only harness for 047. Never fall through to a host service/tool.
# The caller loads helper.bash and owns setup_tmp_dir/teardown_tmp_dir.

hc_fixture_setup() {
  load_lib render
  HC_ORIGINAL_PATH="$PATH"
  HC_BASH=$(command -v bash)
  HC_PYTHON_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))') || return 1
  case "$HC_PYTHON_REAL" in /*) [ -x "$HC_PYTHON_REAL" ] || return 1 ;; *) return 1 ;; esac
  HC_FIX="$TMP_TEST_DIR/hc-fixture"
  HC_WS="$TMP_TEST_DIR/workspace"
  HC_PROC="$HC_FIX/proc"
  HC_CGROUP="$HC_FIX/cgroup"
  HC_BIN="$HC_FIX/bin"
  export HC_FIX HC_WS HC_PROC HC_CGROUP HC_BASH
  mkdir -p "$HC_BIN" "$HC_PROC" "$HC_CGROUP/agent-test.service" \
    "$HC_WS/.state/.claude" "$HC_WS/scripts/lib" "$HC_WS/scripts/local"
  # Preserve which bash the parent selected; do not put Homebrew before /bin.
  local tool target
  for tool in bash python3 perl jq yq git sed awk grep cat mkdir chmod stat \
    mktemp rm mv cp readlink find sort uniq wc date sleep kill env dirname \
    basename cmp cut tr head tail printf true false seq rmdir ln ls touch; do
    target=$(command -v "$tool") || continue
    if [ "$tool" = python3 ]; then target=$HC_PYTHON_REAL; fi
    case "$target" in /*) ;; *) target=$(type -P "$tool") || continue ;; esac
    case "$target" in /*) ln -s "$target" "$HC_BIN/$tool" ;; esac
  done
  ln -s "$HC_BASH" "$HC_BIN/bash-selected"
  export HC_REAL_JQ="$HC_BIN/jq.real"
  mv "$HC_BIN/jq" "$HC_REAL_JQ"
  python3 - "$HC_BIN" "$HC_FIX/real-tools.json" <<'PY'
import json,os,sys
from pathlib import Path
root=Path(sys.argv[1])
json.dump({p.name:os.readlink(p) for p in root.iterdir() if p.is_symlink()},open(sys.argv[2],'w'))
PY
  for tool in systemctl journalctl ss curl sync mv date jq cat chmod stat mktemp rm readlink find sort bash touch; do
    rm -f "$HC_BIN/$tool"
    ln -s "$REPO_ROOT/tests/fixtures/local-healthcheck/tool" "$HC_BIN/$tool"
  done
  ln -s "$REPO_ROOT/tests/fixtures/local-healthcheck/timeout" "$HC_BIN/timeout"
  target=$(command -v flock || true)
  if [ -n "$target" ]; then ln -s "$target" "$HC_BIN/flock"
  else ln -s "$REPO_ROOT/tests/fixtures/qmd-lock/flock" "$HC_BIN/flock"; fi
  export PATH="$HC_BIN"
  printf '1000.00 0.00\n' > "$HC_PROC/uptime"
  printf 'cpu\n' > "$HC_CGROUP/cgroup.controllers"
  printf '1234\n' > "$HC_CGROUP/agent-test.service/cgroup.procs"
  printf '%s\n' '{"ActiveState":"active","ControlGroup":"/agent-test.service","InvocationID":"invocation-one","MainPID":"1234"}' > "$HC_FIX/unit.json"
  printf '[]\n' > "$HC_FIX/settings.json"
  printf '[]\n' > "$HC_FIX/sockets.json"
  : > "$HC_FIX/journal"
  hc_fixture_process 1234 17 /agent-test.service 7001
  hc_fixture_socket 7001 established 55000 443
  hc_fixture_credentials 2000003600000 2001000000000
  cp "$REPO_ROOT/scripts/lib/env_file.sh" "$HC_WS/scripts/lib/"
  export AGENT_NAME=test DEPLOYMENT_WORKSPACE="$HC_WS"
  render_to_file "$REPO_ROOT/modules/local-healthcheck.sh.tpl" "$HC_WS/scripts/local/agent-healthcheck.sh"
  if [ -f "$REPO_ROOT/modules/local-healthcheck-lib.sh.tpl" ]; then
    render_to_file "$REPO_ROOT/modules/local-healthcheck-lib.sh.tpl" "$HC_WS/scripts/local/agent-healthcheck-lib.sh"
  fi
  chmod +x "$HC_WS/scripts/local/agent-healthcheck.sh"
}

hc_fixture_process() {
  local pid="$1" start="$2" group="$3" inode="${4:-}"
  mkdir -p "$HC_PROC/$pid/fd"
  # Linux /proc/PID/stat field 22 is starttime; comm deliberately has spaces.
  printf '%s (synthetic worker) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' \
    "$pid" "$start" > "$HC_PROC/$pid/stat"
  printf '0::%s\n' "$group" > "$HC_PROC/$pid/cgroup"
  if [ -n "$inode" ]; then ln -s "socket:[$inode]" "$HC_PROC/$pid/fd/5"; fi
}

hc_fixture_socket() {
  local v
  v=$(jq --argjson inode "$1" --arg state "$2" --argjson local_port "$3" \
    --argjson remote_port "$4" '. + [{inode:$inode,state:$state,local_port:$local_port,remote_port:$remote_port}]' "$HC_FIX/sockets.json") || return
  printf '%s\n' "$v" > "$HC_FIX/sockets.json"
}

hc_fixture_credentials() {
  printf '{"claudeAiOauth":{"accessToken":"fictional-access-sentinel","refreshToken":"fictional-refresh-sentinel","expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' \
    "$1" "$2" > "$HC_WS/.state/.claude/.credentials.json"
}

hc_fixture_setting() {
  local v
  v=$(jq --arg key "$1" --argjson value "$2" 'if type=="object" then . else {} end | .[$key]=$value' "$HC_FIX/settings.json") || return
  printf '%s\n' "$v" > "$HC_FIX/settings.json"
}

hc_fixture_call() {
  "$HC_BASH" -c '
    export HC_TRACE_CALL=product
    source "$1"
    shift
    hc_proc_root="$HC_PROC"
    if [ -f "$HC_FIX/overrides.sh" ]; then source "$HC_FIX/overrides.sh"; fi
    "$@"
  ' _ "$HC_WS/scripts/local/agent-healthcheck-lib.sh" "$@"
}

hc_fixture_cli() {
  # Full production dispatch with explicit fixture roots, without new public flags.
  "$HC_BASH" -c '
    export HC_TRACE_CALL=product
    source "$1"
    hc_main test "$2" "$3" "$4"
  ' _ "$HC_WS/scripts/local/agent-healthcheck.sh" "$HC_WS" "$HC_PROC" "$HC_CGROUP"
}

hc_fixture_notice() {
  printf 'NOTIFY_BOT_TOKEN=fictional-notify-token\nNOTIFY_CHAT_ID=fictional-chat\n' > "$HC_WS/.env"
  chmod 600 "$HC_WS/.env"
  hc_fixture_snapshot DEGRADED
}

hc_fixture_snapshot() {
  local health=OK auth=renewable reason='[]' ttl=null
  case "$1" in
    DEGRADED) health=DEGRADED; auth=login_lost; reason='["login_lost"]' ;;
    WARN_EXPIRY) health=WARN; auth=renewal_expiring; reason='["renewal_expiring"]'; ttl=60000 ;;
    WARN_OTHER) health=WARN; reason='["qmd_failed"]' ;;
  esac
  printf '{"health":"%s","auth_class":"%s","reason_codes":%s,"renewal_remaining_ms":%s,"connection":"present","unit_invocation":"synthetic","notice_identity":"%s"}\n' \
    "$health" "$auth" "$reason" "$ttl" "${1/WARN_OTHER/NONE}" > "$HC_FIX/snapshot.json"
}

hc_fixture_evaluate() {
  "$HC_BASH" -c '
    export HC_TRACE_CALL=product
    source "$HC_WS/scripts/local/agent-healthcheck-lib.sh"
    source "$1"
    hc_observe() { cat "$HC_FIX/snapshot.json"; }
    if [ -f "$HC_FIX/overrides.sh" ]; then source "$HC_FIX/overrides.sh"; fi
    hc_main test "$2" "$3" "$4"
  ' _ "$HC_WS/scripts/local/agent-healthcheck.sh" "$HC_WS" "$HC_PROC" "$HC_CGROUP"
}

hc_fixture_spawn() {
  # A direct process-group leader, not a background shell function wrapping the
  # controller. Teardown owns this group and any separately bounded children.
  perl -MPOSIX=setsid -e 'setsid() >= 0 or die; exec @ARGV; die "exec failed"' \
    "$HC_BASH" -c '
      export HC_TRACE_CALL=product
      source "$HC_WS/scripts/local/agent-healthcheck-lib.sh"
      source "$1"
      hc_observe() { cat "$HC_FIX/snapshot.json"; }
      if [ -f "$HC_FIX/overrides.sh" ]; then source "$HC_FIX/overrides.sh"; fi
      hc_main test "$HC_WS" "$HC_PROC" "$HC_CGROUP"
    ' _ "$HC_WS/scripts/local/agent-healthcheck.sh" > "$1" 2>&1 3>&- 4>&- &
  HC_SPAWN_PID=$!
  printf '%s\n' "$HC_SPAWN_PID" >> "$HC_FIX/owned-groups"
}

hc_fixture_write_fault() {
  cat > "$HC_FIX/overrides.sh" <<'SH'
_hc_state_write() { : > "$HC_FIX/write-fault-hit"; return 1; }
SH
}

hc_fixture_wait_gone() {
  local pid="$1" n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.01; n=$((n+1)); done
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
}

hc_fixture_teardown() {
  # Tests register only their own long-lived process IDs, never discover by name.
  local pid group supervisor marker
  if [ -f "$HC_FIX/owned-groups" ]; then
    while IFS= read -r group; do
      case "$group" in ''|*[!0-9]*|0) continue ;; esac
      kill -KILL -- "-$group" 2>/dev/null || true
      wait "$group" 2>/dev/null || true
    done < "$HC_FIX/owned-groups"
  fi
  for marker in "$HC_FIX"/timeout-active-*; do
    [ -f "$marker" ] || continue
    read -r group supervisor < "$marker" || continue
    case "$group$supervisor" in ''|*[!0-9]*) continue ;; esac
    [ "$group" -gt 0 ] && [ "$supervisor" -gt 0 ] || continue
    kill -KILL -- "-$group" 2>/dev/null || true
    kill -KILL "$supervisor" 2>/dev/null || true
    wait "$supervisor" 2>/dev/null || true
  done
  if [ -f "$HC_FIX/owned-pids" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done < "$HC_FIX/owned-pids"
  fi
  if [ -n "${HC_ORIGINAL_PATH:-}" ]; then
    export PATH="$HC_ORIGINAL_PATH"
    hash -r
  fi
}
