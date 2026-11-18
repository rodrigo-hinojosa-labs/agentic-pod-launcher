#!/usr/bin/env bash
# Explicit, isolated CI gate. Sourcing only defines functions; it never starts
# a service, calls sudo, creates namespaces, or installs traps.

hc_integration_validate_report() {
  python3 - "$1" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    required=('head','hash','ImageOS','ImageVersion','kernel','systemd','ss','flock','sync','timeout')
    assert data['schema']==1 and data['cleanup'] is True
    uid=data['probe_uid']
    assert type(uid) is int and uid>0
    assert all(isinstance(data['source'][k],str) and data['source'][k] for k in required)
    rows=data['scenarios']
    assert [r['id'] for r in rows]==[f'L{i:02}' for i in range(1,11)]
    assert all(r['status']=='pass' for r in rows)
    for row in rows:
        probes=row['probes']
        assert isinstance(probes,list) and probes
        for probe in probes:
            assert type(probe['uid']) is int and probe['uid']==uid
            assert type(probe['rc']) is int and probe['rc'] in (0,1,2)
            assert probe['health']=={0:'OK',1:'WARN',2:'DEGRADED'}[probe['rc']]
    assert set(rows[5]['variants'])=={'listener','remote4430'}
    assert set(rows[7]['variants'])=={'disappear','birth'}
    assert {'listener','remote4430'} <= {p['tag'] for p in rows[5]['probes']}
    assert {'disappear','birth'} <= {p['tag'] for p in rows[7]['probes']}
except (OSError,ValueError,KeyError,TypeError,AssertionError):
    print('047 integration invalid: incomplete, failed, skipped or unclean gate',file=sys.stderr)
    sys.exit(1)
print('047 integration summary: total=10 executed=10 skipped=0 failed=0')
PY
}

_hci_wait_file() {
  local file="$1" seconds="${2:-8}"
  timeout -k 1 "$seconds" bash -c 'while [ ! -f "$1" ]; do sleep 0.02; done' _ "$file"
}

_hci_properties() {
  systemctl show "$1" -p ActiveState -p ControlGroup -p InvocationID -p MainPID -p User
}

_hci_start() {
  local unit="$1" delegate="$2" loaded runtime=120
  shift 2
  loaded=$(systemctl show "$unit" -p LoadState --value 2>/dev/null) || true
  [ "$loaded" = not-found ] || return 1
  case "$unit" in "$HCI_PREFIX"-listen*) runtime=540 ;; esac
  HCI_UNITS+=("$unit")
  HCI_CASE_UNITS+=("$unit")
  timeout -k 1 10 sudo -n systemd-run --quiet --unit "$unit" \
    --property="User=$HCI_USER" --property="NetworkNamespacePath=/run/netns/$HCI_NETNS" \
    --property="RuntimeMaxSec=$runtime" --property=TimeoutStopSec=5 --property=NoNewPrivileges=yes \
    --property=Slice=system.slice \
    --property="Delegate=$delegate" \
    --setenv="PATH=$HCI_BIN:/usr/bin:/bin" \
    --setenv=LC_ALL=C --setenv="HCI_CASE=$HCI_CASE" \
    --setenv="HCI_FIXTURES=$HCI_ROOT/tools" \
    --setenv="HCI_REAL_SS=$HCI_REAL_SS" --setenv="HCI_REAL_FLOCK=$HCI_REAL_FLOCK" \
    --setenv="HCI_REAL_SYNC=$HCI_REAL_SYNC" "$@"
}

_hci_group_empty() {
  local group="/sys/fs/cgroup/system.slice/$1" events
  [ -r /sys/fs/cgroup/system.slice ] && [ -x /sys/fs/cgroup/system.slice ] || return 1
  [ -d "$group" ] || return 0
  events=$(timeout -k 1 5 cat "$group/cgroup.events" 2>/dev/null) || return 1
  case "$events" in *'populated 0'*) return 0 ;; *) return 1 ;; esac
}

_hci_unit_stopped() {
  local properties rc line loaded='' active='' pid=''
  properties=$(timeout -k 1 5 systemctl show "$1" -p LoadState -p ActiveState -p MainPID 2>/dev/null)
  rc=$?
  while IFS= read -r line; do
    case "$line" in LoadState=*) loaded=${line#*=} ;; ActiveState=*) active=${line#*=} ;; MainPID=*) pid=${line#*=} ;; esac
  done <<< "$properties"
  if [ "$loaded" != not-found ]; then
    [ "$rc" -eq 0 ] && [ "$active" = inactive ] && [ "$pid" = 0 ] || return 1
  fi
  _hci_group_empty "$1"
}

_hci_stop_case() {
  local unit failed=0
  for unit in "${HCI_CASE_UNITS[@]}"; do
    timeout -k 1 8 sudo -n systemctl stop "$unit" >/dev/null 2>&1 || true
    timeout -k 1 5 sudo -n systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    _hci_unit_stopped "$unit" || failed=1
  done
  HCI_CASE_UNITS=()
  return "$failed"
}

_hci_finish() {
  local rc="$1" failed=0 unit pids
  trap - EXIT INT TERM
  for unit in "${HCI_UNITS[@]}"; do
    timeout -k 1 8 sudo -n systemctl stop "$unit" >/dev/null 2>&1 || true
    timeout -k 1 5 sudo -n systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    _hci_unit_stopped "$unit" || failed=1
  done
  if [ -n "$HCI_NETNS" ]; then
    pids=$(timeout -k 1 5 sudo -n ip netns pids "$HCI_NETNS" 2>/dev/null)
    if [ "$?" -eq 0 ] && [ -z "$pids" ]; then
      timeout -k 1 8 sudo -n ip netns delete "$HCI_NETNS" >/dev/null 2>&1 || failed=1
      if [ -e "/run/netns/$HCI_NETNS" ]; then failed=1; fi
    else failed=1; fi
  fi
  if [ -n "$HCI_ROOT" ] && [ "$failed" -eq 0 ]; then
    case "$HCI_ROOT" in "$RUNNER_TEMP"/apl047.*) rm -rf "$HCI_ROOT" || failed=1 ;; *) failed=1 ;; esac
    [ ! -e "$HCI_ROOT" ] || failed=1
  fi
  if [ -n "$HCI_REPORT" ] && [ -f "$HCI_REPORT" ]; then
    python3 - "$HCI_REPORT" "$failed" <<'PY'
import json,sys
p=sys.argv[1];data=json.load(open(p));data['cleanup']=sys.argv[2]=='0'
with open(p,'w') as out:json.dump(data,out,indent=2)
PY
    [ "$?" -eq 0 ] || failed=1
    if ! hc_integration_validate_report "$HCI_REPORT"; then failed=1; fi
  else failed=1; fi
  [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ] || exit 1
  exit 0
}

_hci_install_wrappers() {
  mkdir -p "$HCI_BIN" || return 1
  cat > "$HCI_BIN/ss" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
umask 077
capture=$(mktemp "$HCI_CASE/ss.XXXXXX") || exit 1
trap 'rm -f "$capture"' EXIT
"$HCI_REAL_SS" "$@" > "$capture"
rc=$?
awk '{for(i=1;i<=NF;i++)if($i~/^ino:[0-9]+$/)print substr($i,5)}' "$capture" >> "$HCI_CASE/ss-inodes.log"
if [ "$rc" -eq 0 ] && [ -f "$HCI_CASE/ss-barrier" ] && mkdir "$HCI_CASE/ss-claimed" 2>/dev/null; then
  : > "$HCI_CASE/ss-ready"
  timeout -k 0.2 2 bash -c 'while [ ! -f "$1/ss-release" ]; do sleep 0.01; done' _ "$HCI_CASE" || exit 1
  : > "$HCI_CASE/ss-returned"
fi
cat "$capture"
exit "$rc"
SH
  cat > "$HCI_BIN/flock" <<'SH'
#!/usr/bin/env bash
"$HCI_REAL_FLOCK" "$@"
rc=$?
printf 'flock\t%s\t%s\n' "${1:-}" "$rc" >> "$HCI_CASE/operations.tsv"
exit "$rc"
SH
  cat > "$HCI_BIN/sync" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] || exit 97
if [ "$1" = --version ]; then exec "$HCI_REAL_SYNC" --version; fi
kind=file
[ ! -d "$1" ] || kind=directory
"$HCI_REAL_SYNC" "$@"
rc=$?
printf 'sync\t%s\t%s\n' "$kind" "$rc" >> "$HCI_CASE/operations.tsv"
exit "$rc"
SH
  cp "$HCI_REPO/tests/fixtures/local-healthcheck/linux-curl" "$HCI_BIN/curl" || return 1
  chmod +x "$HCI_BIN/ss" "$HCI_BIN/flock" "$HCI_BIN/sync" "$HCI_BIN/curl"
}

_hci_case_begin() {
  local id="$1"
  _hci_stop_case || return 1
  HCI_CASE="$HCI_ROOT/$id"
  HCI_AGENT="$HCI_PREFIX-l${id#L}"
  HCI_TARGET="agent-$HCI_AGENT.service"
  HCI_WS="$HCI_CASE/workspace"
  mkdir -p "$HCI_WS/.state/.claude" "$HCI_WS/scripts/local" "$HCI_WS/scripts/lib" || return 1
  printf '#!/bin/sh\nexit 0\n' > "$HCI_CASE/claude-fictional"
  chmod +x "$HCI_CASE/claude-fictional"
  cat > "$HCI_WS/agent.yml" <<YML
version: 1
agent: {name: "$HCI_AGENT"}
deployment: {mode: local, workspace: "$HCI_WS", install_service: false, claude_cli: "$HCI_CASE/claude-fictional"}
YML
  # shellcheck source=/dev/null
  . "$HCI_REPO/scripts/lib/render.sh"
  render_load_context "$HCI_WS/agent.yml" >/dev/null || return 1
  render_to_file "$HCI_REPO/modules/local-healthcheck.sh.tpl" "$HCI_WS/scripts/local/agent-healthcheck.sh" || return 1
  render_to_file "$HCI_REPO/modules/local-healthcheck-lib.sh.tpl" "$HCI_WS/scripts/local/agent-healthcheck-lib.sh" || return 1
  cp "$HCI_REPO/scripts/lib/env_file.sh" "$HCI_WS/scripts/lib/" || return 1
  python3 - "$HCI_WS" <<'PY'
import json,time,sys
from pathlib import Path
ws=Path(sys.argv[1]);now=int(time.time()*1000)
(ws/'.state/.claude/.credentials.json').write_text(json.dumps({'claudeAiOauth':{
'accessToken':'fictional-access','refreshToken':'fictional-refresh','expiresAt':now+3600000,'refreshTokenExpiresAt':now+2592000000}}))
PY
  chmod +x "$HCI_WS/scripts/local/agent-healthcheck.sh"
  cat > "$HCI_CASE/target.sh" <<'SH'
#!/usr/bin/env bash
read -r mode < "$HCI_CASE/mode"
case "$mode" in principal|child|grandchild|subgroup|none|wrong-port|listener) ;; *) exit 97 ;; esac
exec python3 "$HCI_FIXTURES/linux-service.py" --root "$HCI_CASE" --name target --mode "$mode" --listen-host 127.0.0.2
SH
  cat > "$HCI_CASE/probe.sh" <<'SH'
#!/usr/bin/env bash
umask 077
tag="$1"
id -u > "$HCI_CASE/$tag.uid"
[ "$(id -u)" -ne 0 ] || exit 91
"$HCI_CASE/workspace/scripts/local/agent-healthcheck.sh" > "$HCI_CASE/$tag.out" 2> "$HCI_CASE/$tag.err"
rc=$?
printf '%s\n' "$rc" > "$HCI_CASE/$tag.rc"
exit 0
SH
  chmod +x "$HCI_CASE/target.sh" "$HCI_CASE/probe.sh"
}

_hci_target() {
  local mode="$1" delegate=no
  [ "$mode" != subgroup ] || delegate=yes
  printf '%s\n' "$mode" > "$HCI_CASE/mode"
  _hci_start "$HCI_TARGET" "$delegate" "$HCI_CASE/target.sh" || return 1
  _hci_wait_file "$HCI_CASE/target.ready.json" || return 1
  _hci_properties "$HCI_TARGET" > "$HCI_CASE/target-$mode.properties"
}

_hci_probe_start() {
  local tag="$1"
  _hci_start "$HCI_PREFIX-probe-$HCI_PROBE_SEQ.service" no "$HCI_CASE/probe.sh" "$tag" || return 1
  HCI_PROBE_SEQ=$((HCI_PROBE_SEQ+1))
}

_hci_probe_wait() {
  local tag="$1" rc text expected
  _hci_wait_file "$HCI_CASE/$tag.rc" 65 || return 1
  [ "$(cat "$HCI_CASE/$tag.uid")" = "$HCI_UID" ] || return 1
  IFS= read -r rc < "$HCI_CASE/$tag.rc" || return 1
  case "$rc" in 0) expected=OK ;; 1) expected=WARN ;; 2) expected=DEGRADED ;; *) return 1 ;; esac
  text=$(cat "$HCI_CASE/$tag.out") || return 1
  case "$text" in *"healthcheck: $expected"*) return 0 ;; *) return 1 ;; esac
}

_hci_probe() { _hci_probe_start "$1" && _hci_probe_wait "$1"; }

_hci_expect() {
  local tag="$1" expected="$2" message="$3" rc text
  IFS= read -r rc < "$HCI_CASE/$tag.rc" || return 1
  text=$(cat "$HCI_CASE/$tag.out") || return 1
  [ "$rc" -eq "$expected" ] || return 1
  case "$text" in *"$message"*) return 0 ;; *) return 1 ;; esac
}

_hci_record() {
  python3 - "$HCI_REPORT" "$1" "$2" "${3:-}" "$HCI_CASE" <<'PY'
import json,sys,re
from pathlib import Path
p=sys.argv[1];data=json.load(open(p))
case=Path(sys.argv[5]);row={'id':sys.argv[2],'status':sys.argv[3],'variants':sys.argv[4].split(',') if sys.argv[4] else [],'probes':[]}
cases=[case]
if case.name=='L08-birth':cases.insert(0,case.parent/'L08')
for result in sorted(r for c in cases for r in c.glob('*.rc')):
 tag=result.stem
 try:
  out=(result.parent/(tag+'.out')).read_text();err=(result.parent/(tag+'.err')).read_text()
  health=re.search(r'healthcheck: (OK|WARN|DEGRADED)',out)
  probe={'tag':tag,'variant':result.parent.name,'rc':int(result.read_text()),'uid':int((result.parent/(tag+'.uid')).read_text()),'health':health.group(1) if health else 'invalid','notify_codes':re.findall(r'healthcheck notify: ([a-z_]+)',err)}
  row['probes'].append(probe)
  if probe['uid']!=data['probe_uid'] or probe['rc'] not in (0,1,2) or probe['health']!={0:'OK',1:'WARN',2:'DEGRADED'}.get(probe['rc']):row['status']='fail'
 except (OSError,ValueError):row['status']='fail'
row['properties']={}
for props in (p for c in cases for p in c.glob('*.properties')):
 allowed={'ActiveState','ControlGroup','InvocationID','MainPID','User'}
 row['properties'][props.parent.name+'/'+props.name]={k:v for k,sep,v in (line.partition('=') for line in props.read_text().splitlines()) if sep and k in allowed}
row['processes']=[]
for ready in sorted(p for c in cases for p in c.glob('*.ready.json')):
 try:row['processes'].append(json.loads(ready.read_text()))
 except (OSError,ValueError):row['status']='fail'
row['socket_inodes']=sorted({int(s) for c in cases for inode_file in [c/'ss-inodes.log'] if inode_file.exists() for s in inode_file.read_text().splitlines() if s.isdecimal()})
data['scenarios'].append(row)
with open(p,'w') as out:json.dump(data,out,indent=2)
PY
}

_hci_simple() {
  local mode="$1" tag="$2" rc="$3" text="$4"
  _hci_target "$mode" && _hci_probe "$tag" && _hci_expect "$tag" "$rc" "$text"
}

_hci_l01() { _hci_simple principal principal 0 'healthcheck: OK'; }
_hci_l02() {
  _hci_simple child child 0 'healthcheck: OK' || return 1
  python3 - "$HCI_CASE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);parent=json.loads((p/'target.ready.json').read_text());child=json.loads((p/'target-child.ready.json').read_text())
assert parent['pid']!=child['pid'] and child['pid'] in parent['children']
PY
}
_hci_l03() {
  _hci_simple grandchild grandchild 0 'healthcheck: OK' || return 1
  python3 - "$HCI_CASE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);a=json.loads((p/'target.ready.json').read_text());b=json.loads((p/'target-child.ready.json').read_text());c=json.loads((p/'target-child-child.ready.json').read_text())
assert b['pid'] in a['children'] and c['pid'] in b['children'] and len({a['pid'],b['pid'],c['pid']})==3
PY
}
_hci_l04() {
  local child group actual
  _hci_simple subgroup subgroup 0 'healthcheck: OK' || return 1
  child=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$HCI_CASE/target-child.ready.json") || return 1
  group=$(systemctl show "$HCI_TARGET" -p ControlGroup --value) || return 1
  actual=$(cat "/proc/$child/cgroup") || return 1
  [ "$actual" = "0::$group/worker" ] || return 1
  printf 'ControlGroup=%s/worker\n' "$group" > "$HCI_CASE/subgroup.properties"
}
_hci_l05() {
  _hci_target none || return 1
  _hci_start "$HCI_TARGET-foreign.service" no python3 "$HCI_ROOT/tools/linux-service.py" --root "$HCI_CASE" --name foreign --mode principal || return 1
  _hci_wait_file "$HCI_CASE/foreign.ready.json" || return 1
  _hci_probe unrelated && _hci_expect unrelated 1 'no live relay connection'
}
_hci_l06() {
  _hci_simple listener listener 1 'no live relay connection' || return 1
  _hci_stop_case || return 1
  # A new target name avoids reusing an already-loaded transient definition.
  HCI_TARGET="agent-$HCI_AGENT-port.service"
  HCI_AGENT="$HCI_AGENT-port"
  HCI_AGENT="$HCI_AGENT" yq -i '.agent.name=strenv(HCI_AGENT)' "$HCI_WS/agent.yml" || return 1
  render_load_context "$HCI_WS/agent.yml" >/dev/null || return 1
  render_to_file "$HCI_REPO/modules/local-healthcheck.sh.tpl" "$HCI_WS/scripts/local/agent-healthcheck.sh" || return 1
  cp "$HCI_CASE/target.ready.json" "$HCI_CASE/listener.ready.json" || return 1
  rm -f "$HCI_CASE/target.ready.json"
  _hci_simple wrong-port remote4430 1 'no live relay connection'
}
_hci_l07() {
  _hci_target principal || return 1
  # Keep a failed transient unit loaded, with no process, for a verifiable
  # inactive state rather than racing manager garbage collection.
  sudo -n systemctl kill --signal=KILL "$HCI_TARGET" || return 1
  timeout -k 1 8 bash -c 'while systemctl is-active --quiet "$1"; do sleep 0.02; done' _ "$HCI_TARGET" || return 1
  _hci_start "$HCI_PREFIX-l07-alien.service" no python3 "$HCI_ROOT/tools/linux-service.py" --root "$HCI_CASE" --name alien --mode principal || return 1
  _hci_wait_file "$HCI_CASE/alien.ready.json" || return 1
  _hci_probe inactive && _hci_expect inactive 2 'unit not active'
}

_hci_barrier() {
  local mode="$1" tag="$2"
  _hci_target "$mode" || return 1
  : > "$HCI_CASE/ss-barrier"
  _hci_probe_start "$tag" || return 1
  _hci_wait_file "$HCI_CASE/ss-ready" 4
}

_hci_release() {
  : > "$HCI_CASE/ss-release"
  _hci_wait_file "$HCI_CASE/ss-returned" 2 && _hci_probe_wait "$1"
}

_hci_connection_warn() {
  local text
  [ "$(cat "$HCI_CASE/$1.rc")" -eq 1 ] || return 1
  text=$(cat "$HCI_CASE/$1.out") || return 1
  case "$text" in *'no live relay connection'*|*'cannot verify connection'*) return 0 ;; *) return 1 ;; esac
}

_hci_l08() {
  local child before after rc text
  _hci_barrier child disappear || return 1
  before=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  child=$(python3 - "$HCI_CASE/target-child.ready.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['pid'])
PY
  ) || return 1
  kill "$child" || return 1
  timeout -k 0.2 1 bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.01; done' _ "$child" || return 1
  after=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  [ "$before" = "$after" ] || return 1
  _hci_release disappear || return 1
  _hci_connection_warn disappear || return 1
  _hci_case_begin L08-birth || return 1
  _hci_barrier wrong-port birth || return 1
  before=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  : > "$HCI_CASE/target.spawn"
  _hci_wait_file "$HCI_CASE/target.spawned" 1 || return 1
  after=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  [ "$before" = "$after" ] || return 1
  _hci_release birth || return 1
  IFS= read -r rc < "$HCI_CASE/birth.rc" || return 1
  text=$(cat "$HCI_CASE/birth.out") || return 1
  case "$rc" in
    0) case "$text" in *'healthcheck: OK'*) return 0 ;; esac ;;
    1) case "$text" in *'cannot verify connection'*) return 0 ;; esac ;;
  esac
  return 1
}

_hci_l09() {
  local before after
  _hci_barrier principal restart || return 1
  before=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  printf 'none\n' > "$HCI_CASE/mode"
  rm -f "$HCI_CASE/target.ready.json"
  sudo -n systemctl restart "$HCI_TARGET" || return 1
  _hci_wait_file "$HCI_CASE/target.ready.json" 1 || return 1
  after=$(systemctl show "$HCI_TARGET" -p InvocationID --value) || return 1
  [ "$before" != "$after" ] && [ -n "$after" ] || return 1
  _hci_release restart || return 1
  _hci_properties "$HCI_TARGET" > "$HCI_CASE/restarted.properties"
  _hci_connection_warn restart
}

_hci_l10() {
  local state="$HCI_WS/.state/local-healthcheck.json" before
  _hci_target principal || return 1
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' > "$HCI_WS/.state/.claude/.credentials.json"
  printf 'NOTIFY_BOT_TOKEN=fictional-notify-token\nNOTIFY_CHAT_ID=fictional-chat\n' > "$HCI_WS/.env"
  chmod 600 "$HCI_WS/.env" || return 1
  _hci_start "$HCI_PREFIX-notify.service" no python3 "$HCI_ROOT/tools/linux-notify.py" --root "$HCI_CASE" --state "$state" || return 1
  _hci_wait_file "$HCI_CASE/http-ready" || return 1
  _hci_probe_start first || return 1
  _hci_wait_file "$HCI_CASE/received" 12 || return 1
  jq -e '.pending.phase=="inflight" and .pending.retry_remaining_s==1800' "$state" >/dev/null || return 1
  before=$(sha256sum "$state") || return 1
  _hci_probe busy && _hci_expect busy 2 'login unavailable' || return 1
  grep -F 'notify_busy' "$HCI_CASE/busy.err" >/dev/null || return 1
  [ "$(sha256sum "$state")" = "$before" ] || return 1
  : > "$HCI_CASE/release"
  _hci_probe_wait first && _hci_expect first 2 'login unavailable' || return 1
  grep -F 'notify: confirmed' "$HCI_CASE/first.err" >/dev/null || return 1
  jq -e '.pending==null and .episode.notified==true' "$state" >/dev/null || return 1
  _hci_probe repeated && _hci_expect repeated 2 'login unavailable' || return 1
  [ "$(stat -c %a "$state")" = 600 ] || return 1
  [ "$(stat -c %a "$HCI_WS/.state/.local-healthcheck.lock")" = 600 ] || return 1
  python3 - "$HCI_CASE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); rows=[json.loads(x) for x in (p/'receipts.jsonl').read_text().splitlines()]
assert len(rows)==1 and rows[0]['inflight_visible'] is True
ops=[line.split('\t') for line in (p/'operations.tsv').read_text().splitlines()]
assert any(row==['flock','-n','1'] for row in ops)
assert sum(row==['flock','-n','0'] for row in ops)==2
assert sum(row==['flock','-u','0'] for row in ops)==2
flush=[row for row in ops if row[0]=='sync']
assert len(flush)==6
assert all(flush[i]==['sync','file','0'] and flush[i+1]==['sync','directory','0'] for i in (0,2,4))
PY
}

hc_integration_main() {
  set -uo pipefail
  export LC_ALL=C
  umask 077
  HCI_UNITS=(); HCI_CASE_UNITS=()
  HCI_ROOT=''; HCI_REPORT=''; HCI_NETNS=''; HCI_CASE=''; HCI_PROBE_SEQ=1
  trap '_hci_finish $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_OS:-}" = Linux ] && [ -n "${RUNNER_TEMP:-}" ] || return 1
  HCI_UID=$(id -u); HCI_USER=$(id -un)
  [ "$HCI_UID" -ne 0 ] || return 1
  local tool version pid1 requested_ns id fn status variants
  for tool in systemctl systemd-run ss ip python3 jq curl flock sync timeout sudo yq git perl awk; do
    command -v "$tool" >/dev/null 2>&1 || return 1
  done
  IFS= read -r pid1 < /proc/1/comm || return 1
  [ "$pid1" = systemd ] && [ -f /sys/fs/cgroup/cgroup.controllers ] || return 1
  sudo -n true && systemctl show -p Version >/dev/null || return 1
  for tool in timeout sync; do
    version=$("$tool" --version) || return 1
    case "$version" in *'GNU coreutils'*) ;; *) return 1 ;; esac
  done
  version=$(flock --version) || return 1
  case "$version" in *util-linux*) ;; *) return 1 ;; esac
  HCI_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  HCI_ROOT=$(mktemp -d "$RUNNER_TEMP/apl047.XXXXXX") || return 1
  HCI_EVIDENCE=$(mktemp -d "$RUNNER_TEMP/apl047-evidence.XXXXXX") || return 1
  HCI_REPORT="$HCI_EVIDENCE/report.json"
  [ -z "${GITHUB_ENV:-}" ] || printf 'APL047_EVIDENCE=%s\n' "$HCI_EVIDENCE" >> "$GITHUB_ENV"
  HCI_PREFIX="apl047-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}-${BASHPID:-$$}-$RANDOM"
  HCI_BIN="$HCI_ROOT/bin"
  HCI_REAL_SS=$(command -v ss); HCI_REAL_SYNC=$(command -v sync); HCI_REAL_FLOCK=$(command -v flock)
  mkdir "$HCI_ROOT/tools" || return 1
  cp "$HCI_REPO/tests/fixtures/local-healthcheck/linux-service.py" "$HCI_REPO/tests/fixtures/local-healthcheck/linux-notify.py" "$HCI_ROOT/tools/" || return 1
  _hci_install_wrappers || return 1
  python3 - "$HCI_REPORT" "$HCI_REPO" "$HCI_UID" <<'PY'
import hashlib,json,os,subprocess,sys
from pathlib import Path
repo=Path(sys.argv[2])
def capture(*args):
 r=subprocess.run(args,cwd=repo,check=True,capture_output=True,text=True)
 return r.stdout.splitlines()[0]
source={k:os.environ.get(k,'unknown') for k in ('ImageOS','ImageVersion')}
source.update(head=capture('git','rev-parse','HEAD'),kernel=capture('uname','-r'))
for tool in ('systemd','ss','flock','sync','timeout'):
 source[tool]=capture('systemctl' if tool=='systemd' else tool,'--version')
digest=hashlib.sha256()
for name in ('modules/local-healthcheck.sh.tpl','modules/local-healthcheck-lib.sh.tpl','scripts/lib/env_file.sh','tests/fixtures/local-healthcheck/linux-service.py','.github/scripts/local-healthcheck-integration.sh'):
 digest.update(name.encode()+b'\0'+(repo/name).read_bytes())
source['hash']=digest.hexdigest()
json.dump({'schema':1,'source':source,'probe_uid':int(sys.argv[3]),'scenarios':[],'cleanup':False},open(sys.argv[1],'w'),indent=2)
PY
  [ "$?" -eq 0 ] || return 1
  requested_ns="$HCI_PREFIX-net"
  sudo -n ip netns add "$requested_ns" || return 1
  HCI_NETNS="$requested_ns"
  sudo -n ip -n "$HCI_NETNS" link set lo up || return 1
  sudo -n ip netns exec "$HCI_NETNS" sysctl -q -w net.ipv4.ip_unprivileged_port_start=0 || return 1
  local routes
  routes=$(sudo -n ip -n "$HCI_NETNS" route show default) || return 1
  [ -z "$routes" ] || return 1
  HCI_CASE="$HCI_ROOT/listeners"; mkdir "$HCI_CASE" || return 1
  _hci_start "$HCI_PREFIX-listen443.service" no python3 "$HCI_ROOT/tools/linux-service.py" --root "$HCI_CASE" --name listener443 --mode listener --port 443 || return 1
  _hci_start "$HCI_PREFIX-listen4430.service" no python3 "$HCI_ROOT/tools/linux-service.py" --root "$HCI_CASE" --name listener4430 --mode listener --port 4430 || return 1
  _hci_wait_file "$HCI_CASE/listener443.ready.json" && _hci_wait_file "$HCI_CASE/listener4430.ready.json" || return 1
  HCI_CASE_UNITS=()
  for id in L01 L02 L03 L04 L05 L06 L07 L08 L09 L10; do
    _hci_case_begin "$id" || return 1
    fn="_hci_l${id#L}"; status=pass; variants=''
    "$fn" || status=fail
    case "$id" in L06) variants=listener,remote4430 ;; L08) variants=disappear,birth ;; esac
    _hci_record "$id" "$status" "$variants" || return 1
    printf '047 integration %s: %s\n' "$id" "$status"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hc_integration_main
fi
