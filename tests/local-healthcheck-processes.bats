#!/usr/bin/env bats

load helper
load helper-local-healthcheck

setup() { setup_tmp_dir; hc_fixture_setup; }
teardown() { hc_fixture_teardown; teardown_tmp_dir; }

connection_is() {
  run hc_fixture_call hc_connection_snapshot agent-test.service "$HC_PROC" "$HC_CGROUP" 1025000
  [ "$status" -eq 0 ] || return
  [ "$(printf '%s' "$output" | jq -r .connection)" = "$1" ]
}

no_sockets() { printf '[]\n' > "$HC_FIX/sockets.json"; }
members() { printf '%s\n' "$@" > "$HC_CGROUP/agent-test.service/cgroup.procs"; }

@test "047 C01: principal process has an established remote 443 socket" {
  connection_is present
}

@test "047 C02: socket belongs only to a child of the unit" {
  rm "$HC_PROC/1234/fd/5"
  hc_fixture_process 2345 18 /agent-test.service 7001
  members 1234 2345
  connection_is present
}

@test "047 C03: socket belongs only to a grandchild without PPID assumptions" {
  rm "$HC_PROC/1234/fd/5"
  hc_fixture_process 2345 18 /agent-test.service
  hc_fixture_process 3456 19 /agent-test.service 7001
  members 1234 2345 3456
  connection_is present
}

@test "047 C04: nested cgroup member owns the socket" {
  rm "$HC_PROC/1234/fd/5"
  mkdir -p "$HC_CGROUP/agent-test.service/sub/worker"
  printf '2345\n' > "$HC_CGROUP/agent-test.service/sub/worker/cgroup.procs"
  hc_fixture_process 2345 18 /agent-test.service/sub/worker 7001
  connection_is present
}

@test "047 C05: unrelated same-user process is not unit evidence" {
  rm "$HC_PROC/1234/fd/5"
  hc_fixture_process 2345 18 /unrelated.service 7001
  connection_is absent
}

@test "047 C06: cgroup path prefix without slash boundary is unrelated" {
  rm "$HC_PROC/1234/fd/5"
  hc_fixture_process 2345 18 /agent-test.service-foreign 7001
  members 1234 2345
  connection_is absent
}

@test "047 C07: listener local 443 and remote 4430 do not qualify" {
  no_sockets
  hc_fixture_socket 7001 listen 443 0
  hc_fixture_socket 7001 established 443 55000
  hc_fixture_socket 7001 established 55000 4430
  connection_is absent
}

@test "047 C08: inode matching uses whole decimal integers" {
  no_sockets
  hc_fixture_socket 70010 established 55000 443
  hc_fixture_socket 17001 established 55001 443
  connection_is absent
}

@test "047 C09: inactive unit cannot become healthy from unrelated sockets" {
  printf '%s\n' '{"ActiveState":"inactive","ControlGroup":"/agent-test.service","InvocationID":"invocation-one","MainPID":"0"}' > "$HC_FIX/unit.json"
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  [[ "$output" == *'unit not active'* ]] || return 1
}

@test "047 C10: missing tools and failed enumeration are unknown" {
  hc_fixture_setting ss_rc 1
  connection_is unknown
  hc_fixture_setting ss_rc 0
  mv "$HC_BIN/ss" "$HC_BIN/ss.hidden"
  connection_is unknown
  mv "$HC_BIN/ss.hidden" "$HC_BIN/ss"
  hc_fixture_setting systemctl_rc 1
  connection_is unknown
  hc_fixture_setting systemctl_rc 0
  # A readable path is not proof of a successful cgroup.procs read. Simulate
  # a partial read followed by an I/O error at that explicit library boundary.
  cat > "$HC_FIX/overrides.sh" <<'SH'
_hc_read_procs() { : > "$HC_FIX/procs-read-hit"; printf '1234\n'; return 1; }
SH
  connection_is unknown
  [ -f "$HC_FIX/procs-read-hit" ]
}

@test "047 C11: empty root or unsupported cgroup hierarchy stays unknown" {
  local group
  for group in '' / /../elsewhere; do
    jq --arg cg "$group" '.ControlGroup=$cg' "$HC_FIX/unit.json" > "$HC_FIX/next"
    mv "$HC_FIX/next" "$HC_FIX/unit.json"
    connection_is unknown || return
  done
  jq '.ControlGroup="/agent-test.service"' "$HC_FIX/unit.json" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$HC_FIX/unit.json"
  rm "$HC_CGROUP/cgroup.controllers"
  connection_is unknown
}

@test "047 C12: reused numeric PID cannot redirect an already pinned proc handle" {
  # A socket appears only in the replacement PID directory while ss runs.
  rm "$HC_PROC/1234/fd/5"
  ln -s 'socket:[9000]' "$HC_PROC/1234/fd/5"
  cat > "$HC_FIX/ss-hook" <<'SH'
if [ "$1" = 1 ]; then
  mv "$HC_PROC/1234" "$HC_PROC/old-process"
  mkdir -p "$HC_PROC/1234/fd"
  printf '1234 (replacement) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0\n' > "$HC_PROC/1234/stat"
  printf '0::/unrelated.service\n' > "$HC_PROC/1234/cgroup"
  ln -s 'socket:[7001]' "$HC_PROC/1234/fd/5"
fi
SH
  connection_is absent
  [ -d "$HC_PROC/old-process" ]
  # Synthetic identity collision: PID+starttime is not a directory handle.
  # This is an oracle for pinning, not a claim of real kernel PID reuse here.
  rm -rf "$HC_PROC/1234" "$HC_PROC/old-process"
  rm -f "$HC_FIX/ss-count"
  hc_fixture_process 1234 17 /agent-test.service 9000
  cat > "$HC_FIX/ss-hook" <<'SH'
if [ "$1" = 1 ]; then
  mv "$HC_PROC/1234" "$HC_PROC/old-process"
  mkdir -p "$HC_PROC/1234/fd"
  printf '1234 (replacement) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 17 0\n' > "$HC_PROC/1234/stat"
  printf '0::/agent-test.service\n' > "$HC_PROC/1234/cgroup"
  ln -s 'socket:[7001]' "$HC_PROC/1234/fd/5"
fi
SH
  connection_is absent
  [ -d "$HC_PROC/old-process" ]
}

@test "047 C13: disappearing candidate makes a negative incomplete" {
  no_sockets
  cat > "$HC_FIX/ss-hook" <<'SH'
rm -f "$HC_PROC/1234/stat" "$HC_PROC/1234/cgroup"
SH
  connection_is unknown
}

@test "047 C14: changed fd or membership invalidates a positive" {
  cat > "$HC_FIX/ss-hook" <<'SH'
rm -f "$HC_PROC/1234/fd/5"
ln -s 'socket:[9000]' "$HC_PROC/1234/fd/5"
SH
  connection_is absent
  rm "$HC_FIX/ss-hook" "$HC_PROC/1234/fd/5"
  ln -s 'socket:[7001]' "$HC_PROC/1234/fd/5"
  cat > "$HC_FIX/ss-hook" <<'SH'
printf '0::/unrelated.service\n' > "$HC_PROC/1234/cgroup"
SH
  connection_is absent
}

@test "047 C15: InvocationID changes require a fresh observation" {
  cat > "$HC_FIX/ss-hook" <<'SH'
if [ "$1" = 1 ]; then
  jq '.InvocationID="invocation-two"' "$HC_FIX/unit.json" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$HC_FIX/unit.json"
fi
SH
  connection_is present
  [ "$(cat "$HC_FIX/ss-count")" -ge 2 ]
}

@test "047 C16: newborn child with same invocation changes the final inventory" {
  rm "$HC_PROC/1234/fd/5"
  ln -s 'socket:[9000]' "$HC_PROC/1234/fd/5"
  hc_fixture_socket 9000 established 55000 4430
  cat > "$HC_FIX/ss-hook" <<'SH'
if [ "$1" = 1 ]; then
  mkdir -p "$HC_PROC/2345/fd"
  printf '2345 (new child) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 18 0\n' > "$HC_PROC/2345/stat"
  printf '0::/agent-test.service\n' > "$HC_PROC/2345/cgroup"
  ln -s 'socket:[7001]' "$HC_PROC/2345/fd/5"
  printf '1234\n2345\n' > "$HC_CGROUP/agent-test.service/cgroup.procs"
fi
SH
  connection_is present
  [ "$(cat "$HC_FIX/ss-count")" -ge 2 ]
}

@test "047 C17: a second unstable observation returns unknown" {
  cat > "$HC_FIX/ss-hook" <<'SH'
jq --arg n "$1" '.InvocationID=$n' "$HC_FIX/unit.json" > "$HC_FIX/next"
mv "$HC_FIX/next" "$HC_FIX/unit.json"
SH
  connection_is unknown
  [ "$(cat "$HC_FIX/ss-count")" -eq 2 ]
}

@test "047 C18: 1024 candidates are supported and 1025 are not truncated" {
  python3 - "$HC_PROC" "$HC_CGROUP" <<'PY'
from pathlib import Path
import sys
proc,cg=map(Path,sys.argv[1:]);ids=range(2000,3024)
for pid in ids:
 p=proc/str(pid);(p/'fd').mkdir(parents=True)
 (p/'stat').write_text(f'{pid} (worker) S '+'0 '*18+'17 0\n')
 (p/'cgroup').write_text('0::/agent-test.service\n')
(cg/'agent-test.service/cgroup.procs').write_text('\n'.join(map(str,ids))+'\n')
PY
  no_sockets
  connection_is absent
  printf '3024\n' >> "$HC_CGROUP/agent-test.service/cgroup.procs"
  connection_is unknown
  [[ "$output" == *'candidate_limit'* ]] || return 1
}

@test "047 C19: observation budget is shared and cannot erase a prior degradation" {
  cat > "$HC_FIX/ss-hook" <<'SH'
printf '1026.00 0\n' > "$HC_PROC/uptime"
SH
  connection_is unknown
  rm "$HC_FIX/ss-hook" "$HC_FIX/systemctl-count"
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  cat > "$HC_FIX/systemctl-hook" <<'SH'
if [ "$1" = 2 ]; then printf '1026.00 0\n' > "$HC_PROC/uptime"; fi
SH
  connection_is unknown
  rm "$HC_FIX/systemctl-hook"
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  printf '%s\n' '{"ActiveState":"inactive","ControlGroup":"/agent-test.service","InvocationID":"invocation-one","MainPID":"0"}' > "$HC_FIX/unit.json"
  cat > "$HC_FIX/journalctl-hook" <<'SH'
printf '1026.00 0\n' > "$HC_PROC/uptime"
SH
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  [[ "$output" == *'budget exhausted'* ]] || return 1
  rm "$HC_FIX/journalctl-hook"
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  printf '%s\n' '{"ActiveState":"active","ControlGroup":"/agent-test.service","InvocationID":"one","MainPID":"1234"}' > "$HC_FIX/unit.json"
  python3 - "$HC_FIX/sockets.json" <<'PY'
import json,sys
rows=[dict(inode=80000+i,state='established',local_port=55000,remote_port=443) for i in range(1000)]
rows.append(dict(inode=7001,state='established',local_port=55000,remote_port=443))
json.dump(rows,open(sys.argv[1],'w'))
PY
  cat > "$HC_FIX/overrides.sh" <<'SH'
hc_mono_ms() {
  local raw rest now
  read -r raw rest < "$HC_PROC/uptime"
  now=$(hc_uptime_ms "$raw") || return
  now=$((now+100))
  printf '%s.%03d 0\n' "$((now/1000))" "$((now%1000))" > "$HC_PROC/uptime"
  printf '%s\n' "$now"
}
SH
  connection_is unknown
}

@test "047 C20: a valid positive wins another incomplete candidate; a negative cannot" {
  members 1000 1234
  connection_is present
  no_sockets
  connection_is unknown
}
