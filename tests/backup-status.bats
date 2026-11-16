#!/usr/bin/env bats
#
# 046: el estado de los respaldos (heartbeatctl backup-status) y lo que muestra el
# diagnostico (agentctl doctor) con un repositorio asociado.
#
# Contrato: specs/046-agent-backup-repo/contracts/agent-surface.md (A6, A7). Lo que
# significa cada prueba: seccion V2 de specs/046-agent-backup-repo/contracts/evidence.md
# (TB01 a TB10). Ninguna toca la red: backup-status solo lee archivos.

load helper
load helper-backup-repo

AGENTCTL="$REPO_ROOT/scripts/agentctl"

setup() {
  br_require
  br_tools_path
  br_sentinels
  br_keys
  unset BR_PAT
  br_workspace
}

_tb_iso_ago() {  # SEGUNDOS -> fecha ISO de hace ese tiempo
  local then=$(( $(date -u +%s) - $1 ))
  date -u -d "@$then" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -r "$then" +%Y-%m-%dT%H:%M:%SZ
}

_tb_state() {  # UNIDAD JSON
  printf '%s\n' "$2" > "$BR_WS/scripts/heartbeat/$1-backup.json"
}

_tb_repo() {
  br_set_repo "https://github.com/example/repo-bot"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
}

@test "TB01: with a repository backup-status --json gives destination, credential, key, extra paths, the five units, caches and the work clone" {
  _tb_repo
  run br_ctl backup-status --json
  [ "$status" -eq 0 ]
  jq -e . <<< "$output" > /dev/null
  [ "$(jq -r '.destination.kind' <<< "$output")" = "repo" ]
  [ "$(jq -r '.destination.url' <<< "$output")" = "https://github.com/example/repo-bot" ]
  [ "$(jq -r '.credential' <<< "$output")" = "present" ]
  [ "$(jq -r '.sensitive' <<< "$output")" = "false" ]
  [ "$(jq -r '.recipient.configured' <<< "$output")" = "true" ]
  [ "$(jq -r '.recipient.type' <<< "$output")" = "ssh-ed25519" ]
  [ "$(jq -r '.recipient.fingerprint' <<< "$output")" = "$(ssh-keygen -lf "$BR_KEY_A.pub" | awk '{print $2}')" ]
  [ "$(jq -r '.recipient.comment' <<< "$output")" = "br-operator-a" ]
  [ "$(jq -r '.extra_paths.declared' <<< "$output")" = "0" ]
  [ "$(jq -r '[.units[].unit] | join(" ")' <<< "$output")" = "identity vault config memory history" ]
  [ "$(jq -r '[.units[].max_age_hours] | map(tostring) | join(" ")' <<< "$output")" = "48 25 192 49 49" ]
  [ "$(jq -r '[.units[] | has("cache_bytes")] | all' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("cache_bytes_total")' <<< "$output")" = "true" ]
  [ "$(jq -r '.work_clone.path' <<< "$output")" = "$BR_WS/agent-repo" ]
}

@test "TB02: with a fork, and without a destination, it gives the destination and the three units of today, without the work clone" {
  yq -i '.scaffold.fork.url = "https://github.com/example/f.git"' "$BR_WS/agent.yml"
  run br_ctl backup-status --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.destination.kind' <<< "$output")" = "fork" ]
  [ "$(jq -r '[.units[].unit] | join(" ")' <<< "$output")" = "identity vault config" ]
  [ "$(jq -r 'has("work_clone")' <<< "$output")" = "false" ]
  yq -i '.scaffold.fork.url = ""' "$BR_WS/agent.yml"
  run br_ctl backup-status --json
  [ "$(jq -r '.destination.kind' <<< "$output")" = "none" ]
  [ "$(jq -r '[.units[].unit] | join(" ")' <<< "$output")" = "identity vault config" ]
}

@test "TB03: a unit whose last push is older than its threshold shows as stale in the readable output" {
  _tb_repo
  _tb_state vault "{\"hash\":\"h\",\"last_push\":\"$(_tb_iso_ago 200000)\",\"last_result\":\"ok\"}"
  _tb_state identity "{\"hash\":\"h\",\"last_push\":\"$(_tb_iso_ago 60)\",\"last_result\":\"ok\"}"
  run br_ctl backup-status
  [ "$status" -eq 0 ]
  grep -E '^vault ' <<< "$output" | grep -qF 'stale (>25h)'
  if grep -E '^identity ' <<< "$output" | grep -qF 'stale'; then false; fi
}

@test "TB04: a unit whose last attempt failed shows that result and its last good push" {
  _tb_repo
  local good
  good=$(_tb_iso_ago 7200)
  _tb_state history "{\"hash\":\"h\",\"last_push\":\"$good\",\"last_result\":\"push-failed\",\"last_attempt\":\"$(_tb_iso_ago 60)\"}"
  run br_ctl backup-status --json
  [ "$(jq -r '.units[] | select(.unit == "history") | .last_result' <<< "$output")" = "push-failed" ]
  [ "$(jq -r '.units[] | select(.unit == "history") | .last_push' <<< "$output")" = "$good" ]
  run br_ctl backup-status
  grep -E '^history ' <<< "$output" | grep -qF 'push-failed'
  grep -E '^history ' <<< "$output" | grep -qF "$good"
  # The last-result column already contains push-failed. Require the status to
  # carry the failed attempt too, rather than accepting a misleading bare "ok".
  grep -E '^history ' <<< "$output" | grep -qE 'ok, last attempt push-failed$'
}

@test "TB05: a work clone with 2 unpublished commits and 1 uncommitted file is counted" {
  _tb_repo
  local bare="$BATS_TEST_TMPDIR/remote.git"
  _br_git init -q --bare "$bare"
  _br_git clone -q "$bare" "$BR_WS/agent-repo" 2> /dev/null
  local i
  for i in 1 2; do
    printf '%s\n' "$i" > "$BR_WS/agent-repo/f$i"
    _br_git -C "$BR_WS/agent-repo" add "f$i"
    _br_git -C "$BR_WS/agent-repo" commit -q -m "c$i"
  done
  printf 'dirty\n' > "$BR_WS/agent-repo/dirty.txt"
  run br_ctl backup-status --json
  [ "$(jq -r '.work_clone.present' <<< "$output")" = "true" ]
  [ "$(jq -r '.work_clone.unpublished_commits' <<< "$output")" = "2" ]
  [ "$(jq -r '.work_clone.dirty_files' <<< "$output")" = "1" ]
}

@test "TB06: the credential sentinel never shows, with or without --json, and credential is present or missing" {
  _tb_repo
  run br_ctl backup-status --json
  [ "$(jq -r '.credential' <<< "$output")" = "present" ]
  if grep -qF -- "$BR_TOKEN" <<< "$output"; then false; fi
  run br_ctl backup-status
  if grep -qF -- "$BR_TOKEN" <<< "$output"; then false; fi
  BR_PAT=""
  run br_ctl backup-status --json
  unset BR_PAT
  [ "$(jq -r '.credential' <<< "$output")" = "missing" ]
}

@test "TB09: with two extra paths declared and one missing, declared is 2 and missing names it" {
  _tb_repo
  yq -i '.backup.extra_paths = [".custom", "not-there"]' "$BR_WS/agent.yml"
  run br_ctl backup-status --json
  [ "$(jq -r '.extra_paths.declared' <<< "$output")" = "2" ]
  [ "$(jq -r '.extra_paths.missing | join(" ")' <<< "$output")" = "not-there" ]
  [ "$(jq -r '.extra_paths.bytes' <<< "$output")" -gt 0 ]
}

# ── El diagnostico, con un doble de docker ──────────────────────────────────

# _tb_docker JSON|FAIL: un docker que responde "sano" (molde de
# tests/agentctl-doctor-freshness.bats), anota sus llamadas y responde a
# `exec ... heartbeatctl backup-status --json` con el JSON elegido, o falla.
_tb_docker() {
  local bin="$BATS_TEST_TMPDIR/docker-bin"
  mkdir -p "$bin"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/status.json"
  cat > "$bin/docker" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/docker-calls.log"
case "\$*" in
  *"heartbeatctl backup-status --json"*)
    if [ "\$(cat "$BATS_TEST_TMPDIR/status.json")" = "FAIL" ]; then exit 1; fi
    cat "$BATS_TEST_TMPDIR/status.json"; exit 0 ;;
esac
case "\$1" in
  info)    exit 0 ;;
  ps)      echo "abc123def456"; exit 0 ;;
  inspect) echo "running"; exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$bin/docker"
  PATH="$bin:$PATH"
  export PATH
}

_tb_doctor() {
  ( cd "$BR_WS" && AGENT_NAME=repo-bot "$AGENTCTL" doctor 2>&1 )
}

# Un estado de backup-status como el que entrega heartbeatctl.
_tb_status_json() {
  jq -n --arg old "$(_tb_iso_ago 300000)" --arg new "$(_tb_iso_ago 3600)" '{
    destination: {kind: "repo", url: "https://github.com/example/repo-bot", verdict: "unverified", checked_at: $new},
    credential: "missing", sensitive: false,
    recipient: {configured: false, type: "", fingerprint: "", comment: ""},
    extra_paths: {declared: 2, missing: [".custom"], bytes: 10},
    units: [
      {unit: "identity", enabled: true, last_push: $new, last_attempt: $new, last_result: "ok", max_age_hours: 48, cache_bytes: 1},
      {unit: "vault", enabled: true, last_push: $old, last_attempt: $new, last_result: "ok", max_age_hours: 25, cache_bytes: 1},
      {unit: "config", enabled: true, last_push: $new, last_attempt: $new, last_result: "ok", max_age_hours: 192, cache_bytes: 1},
      {unit: "memory", enabled: true, last_push: "", last_attempt: "", last_result: "", max_age_hours: 49, cache_bytes: 0},
      {unit: "history", enabled: true, last_push: $new, last_attempt: $new, last_result: "push-failed", max_age_hours: 49, cache_bytes: 1}],
    cache_bytes_total: 3,
    work_clone: {path: "/workspace/agent-repo", present: true, unpublished_commits: 2, dirty_files: 1}}'
}

@test "TB07: with a repository the doctor reads backup-status through docker exec -u agent and warns for every A7 situation" {
  _tb_repo
  _tb_docker "$(_tb_status_json)"
  run _tb_doctor
  grep -qF 'exec -u agent repo-bot heartbeatctl backup-status --json' "$BATS_TEST_TMPDIR/docker-calls.log"
  grep -qF 'Backup destination: repo https://github.com/example/repo-bot (unverified' <<< "$output"
  grep -F 'Backup destination' <<< "$output" | grep -qF '⚠'
  grep -qF 'Backup identity: pushed' <<< "$output"
  grep -qF 'Backup vault: pushed' <<< "$output"
  grep -F 'Backup vault' <<< "$output" | grep -qF 'stale'
  grep -qF 'Backup history: last attempt failed (push-failed); last good push' <<< "$output"
  grep -qF 'Backup memory: never pushed yet' <<< "$output"
  grep -qF 'Backup credential: GITHUB_PAT is missing' <<< "$output"
  grep -qF 'Backup encryption key: not configured' <<< "$output"
  grep -qF 'Backup extra paths: 1 of 2 declared paths is missing (.custom)' <<< "$output"
  grep -qF 'Agent repository clone: 2 unpublished commits, 1 uncommitted file' <<< "$output"
}

@test "TB08: without a repository the doctor never calls backup-status and shows exactly the three backup lines of today" {
  _tb_docker FAIL
  run _tb_doctor
  if grep -qF 'backup-status' "$BATS_TEST_TMPDIR/docker-calls.log"; then false; fi
  grep -qF 'Backup identity: never pushed yet' <<< "$output"
  grep -qF 'Backup vault: never pushed yet' <<< "$output"
  grep -qF 'Backup config: never pushed yet' <<< "$output"
  local s
  for s in 'Backup memory' 'Backup history' 'Backup destination' 'Backup size' 'Agent repository clone'; do
    if grep -qF "$s" <<< "$output"; then echo "found [$s]" >&2; false; fi
  done
}

@test "TB10: cache sizes are reported, a missing clone is present false, and the doctor warns on size, on a missing clone and falls back to the state files" {
  _tb_repo
  mkdir -p "$BR_CACHE/agent-backup/memory-repo"
  dd if=/dev/zero of="$BR_CACHE/agent-backup/memory-repo/blob" bs=1024 count=2048 2> /dev/null
  run br_ctl backup-status --json
  [ "$(jq -r '.units[] | select(.unit == "memory") | .cache_bytes' <<< "$output")" -gt 0 ]
  [ "$(jq -r '.cache_bytes_total' <<< "$output")" -gt 0 ]
  [ "$(jq -r '.work_clone.present' <<< "$output")" = "false" ]
  local json
  json="$output"
  # El diagnostico, con el JSON real y un umbral de 1 MB.
  _tb_docker "$(jq '.work_clone.present = false | .work_clone.path = "/workspace/agent-repo"' <<< "$json")"
  DOCTOR_BACKUP_CACHE_MAX_MB=1 run _tb_doctor
  grep -qF 'Backup size:' <<< "$output"
  grep -qF 'Agent repository clone: missing at /workspace/agent-repo' <<< "$output"
  # Si backup-status falla con el contenedor arriba, las lineas salen de los archivos de estado.
  _tb_state memory "{\"hash\":\"h\",\"last_push\":\"$(_tb_iso_ago 60)\",\"last_result\":\"ok\"}"
  _tb_docker FAIL
  run _tb_doctor
  grep -qF 'Backup memory: pushed' <<< "$output"
  grep -qF 'Backup history: never pushed yet' <<< "$output"
}
