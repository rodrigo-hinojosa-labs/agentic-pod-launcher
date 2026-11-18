# shellcheck shell=bash
# Local healthcheck library. Loading definitions never observes or mutates state.
# 047 interfaces are introduced before their behavioral implementations.
if declare -F _hc_library_marker >/dev/null; then return 0; fi

# Convert an uptime sample captured at CLI entry, before loading libraries/config.
hc_uptime_ms() {
  local sample="$1" whole fraction
  [[ "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  whole=${sample%%.*}
  [ "${#whole}" -le 12 ] || return 1
  case "$sample" in *.*) fraction=${sample#*.} ;; *) fraction=0 ;; esac
  fraction="${fraction}000"
  fraction=${fraction:0:3}
  printf '%s\n' "$((10#$whole * 1000 + 10#$fraction))"
}

hc_mono_ms() {
  local sample rest
  IFS=' ' read -r sample rest < "${hc_proc_root:-/proc}/uptime" 2>/dev/null || return 1
  hc_uptime_ms "$sample"
}

hc_format_duration() {
  local remaining="$1" unit suffix rounded
  case "$remaining" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#remaining}" -le 16 ] || return 1
  [ "$remaining" -gt 0 ] || return 1
  if [ "$remaining" -ge 86400000 ]; then unit=86400000; suffix=d
  elif [ "$remaining" -ge 3600000 ]; then unit=3600000; suffix=h
  else printf '<1h'; return; fi
  rounded=$((remaining/unit + (remaining%unit != 0)))
  printf '%s%s' "$rounded" "$suffix"
}

# Total cap includes TERM/KILL. The caller supplies an absolute shared deadline.
# Close fd9 in BOTH the caller's command substitution and this execution child.
_hc_timeout() {
  local deadline="$1" cap="$2" now remaining grace term grace_s term_s
  shift 2
  command -v timeout >/dev/null 2>&1 || return 125
  now=$(exec 9>&-; hc_mono_ms) || return 124
  remaining=$((deadline-now-50))
  [ "$remaining" -gt 50 ] || return 124
  [ "$cap" -le "$remaining" ] || cap=$remaining
  grace=1000
  [ "$cap" -lt 20000 ] || grace=2000
  [ "$grace" -lt "$cap" ] || grace=$((cap/4))
  [ "$grace" -gt 0 ] || return 124
  term=$((cap-grace))
  printf -v grace_s '%d.%03d' "$((grace/1000))" "$((grace%1000))"
  printf -v term_s '%d.%03d' "$((term/1000))" "$((term%1000))"
  timeout -k "$grace_s" "$term_s" "$@"
}
hc_bound() ( exec 9>&- 3>&- 4>&-; _hc_timeout "$@"; )
_hc_flock() ( exec 3>&- 4>&-; _hc_timeout "$1" 1000 flock "$2" 9; )

_hc_auth_unknown() {
  printf '{"auth_class":"incomplete","cause":"%s","renewal_remaining_ms":null}\n' "$1"
}

hc_auth_snapshot() {
  local file="$1" now_ms="$2" deadline result now
  if ! command -v jq >/dev/null 2>&1; then _hc_auth_unknown jq_missing; return; fi
  if [ ! -f "$file" ]; then _hc_auth_unknown file_unavailable; return; fi
  if [ ! -r "$file" ]; then _hc_auth_unknown file_unreadable; return; fi
  deadline=${hc_observation_deadline:-}
  if [ -z "$deadline" ]; then
    now=$(exec 9>&-; hc_mono_ms) || { _hc_auth_unknown clock_unavailable; return; }
    deadline=$((now+4000))
  fi
  # Tokens never leave this single jq process, including for the cleared shape.
  result=$(exec 9>&-; hc_bound "$deadline" 4000 jq -Rsc --argjson now "$now_ms" '
    def unknown($why): {auth_class:"incomplete",cause:$why,renewal_remaining_ms:null};
    def date_ok: if type=="number" then .>0 and .<=9007199254740991 and .==floor else false end;
    (try fromjson catch null) |
    if type!="object" then unknown("invalid_root")
    elif (.claudeAiOauth|type)!="object" then unknown("oauth_unavailable")
    else .claudeAiOauth as $o |
      if ($o|has("accessToken") and has("refreshToken") and has("expiresAt")) and
         $o.accessToken=="" and $o.refreshToken=="" and ($o.expiresAt|type)=="number" and $o.expiresAt==0
      then {auth_class:"login_lost",cause:"tokens_cleared",renewal_remaining_ms:null}
      elif ($o.accessToken|type)!="string" or ($o.refreshToken|type)!="string" then unknown("tokens_incomplete")
      elif ($o.accessToken|length)==0 or ($o.refreshToken|length)==0 then unknown("tokens_incomplete")
      elif (($o.expiresAt|date_ok) and ($o.refreshTokenExpiresAt|date_ok))|not then unknown("dates_invalid")
      else ($o.refreshTokenExpiresAt-$now) as $ttl |
        {auth_class:(if $ttl<=0 then "renewal_expired" elif $ttl<=604800000 then "renewal_expiring" else "renewable" end),
         cause:"verified",renewal_remaining_ms:$ttl}
      end
    end' "$file" 2>/dev/null)
  if [ "$?" -eq 0 ] && [ -n "$result" ]; then printf '%s\n' "$result"
  else _hc_auth_unknown read_failed; fi
}

_hc_journal_unknown() {
  printf '%s\n' '{"journal_class":"unknown","reason_codes":["journal_unknown"]}'
}

hc_journal_snapshot() (
  exec 9>&- 3>&- 4>&-
  local unit="$1" auth_class="$2" capture="$3" deadline="$4" line
  local terminal=false unknown_401=false refresh=false known=false class codes incomplete=false
  # auth_class is deliberately not a global exception for the entire journal.
  : "$auth_class"
  _hc_before "$deadline" || { _hc_journal_unknown; return; }
  if ! (umask 077; : > "$capture") 2>/dev/null; then _hc_journal_unknown; return; fi
  if ! hc_bound "$deadline" 4000 chmod 600 "$capture" 2>/dev/null; then
    hc_bound "${global_deadline:-$deadline}" 1000 rm -f "$capture" 2>/dev/null || true
    _hc_journal_unknown
    return
  fi
  if ! { exec 5>"$capture" 6<"$capture"; } 2>/dev/null; then _hc_journal_unknown; return; fi
  # Unlink before the potentially slow producer. Independent offsets allow
  # reading afterwards without a seek or external cleanup past the deadline.
  if ! hc_bound "$deadline" 1000 rm -f "$capture" 2>/dev/null; then
    exec 5>&- 6<&-
    _hc_journal_unknown
    return
  fi
  if ! hc_bound "$deadline" 4000 journalctl -u "$unit" --since '-10 min' -n 2000 --no-pager >&5 2>/dev/null; then
    exec 5>&- 6<&-
    _hc_journal_unknown
    return
  fi
  exec 5>&-
  if ! _hc_before "$deadline"; then
    exec 6<&-
    _hc_journal_unknown
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if ! _hc_before "$deadline"; then
      incomplete=true
      break
    fi
    case "$line" in
      *'Please run /login'*|*'You must be logged in to use Remote Control'*) terminal=true ;;
    esac
    known=false
    case "$line" in
      *'Authentication failed (401): OAuth access token has expired'*) known=true ;;
    esac
    case "$line" in
      *'API Error: 401'*) unknown_401=true ;;
      *'Authentication failed (401)'*) [ "$known" = true ] || unknown_401=true ;;
      *refresh*401*|*401*refresh*) [ "$known" = true ] || unknown_401=true ;;
    esac
    case "$line" in *'Failed to refresh session'*) [ "$known" = true ] || refresh=true ;; esac
  done <&6
  exec 6<&-
  class=clear; codes='[]'
  if [ "$terminal" = true ]; then class=terminal; codes='["journal_terminal"]'
  elif [ "$unknown_401" = true ]; then class=unclassified_401; codes='["journal_401"]'
  elif [ "$refresh" = true ]; then class=refresh_unverified; codes='["journal_refresh"]'; fi
  if [ "$incomplete" = true ]; then
    case "$class" in
      terminal|unclassified_401) codes="${codes%]},\"journal_unknown\"]" ;;
      *) _hc_journal_unknown; return ;;
    esac
  fi
  printf '{"journal_class":"%s","reason_codes":%s}\n' "$class" "$codes"
)

_hc_before() {
  local now
  now=$(exec 9>&-; hc_mono_ms) || return 1
  [ "$now" -lt "$1" ]
}

_hc_unit_read() {
  local text line active='' group='' invocation='' pid=0
  text=$(exec 9>&-; hc_bound "$2" 4000 systemctl show "$1" \
    -p ActiveState -p ControlGroup -p InvocationID -p MainPID 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      ActiveState=*) active=${line#*=} ;;
      ControlGroup=*) group=${line#*=} ;;
      InvocationID=*) invocation=${line#*=} ;;
      MainPID=*) pid=${line#*=} ;;
    esac
  done <<< "$text"
  case "$active" in active|inactive|failed|activating|deactivating|reloading|maintenance) ;; *) return 1 ;; esac
  case "$group$invocation" in *'|'*) return 1 ;; esac
  if [ -n "$invocation" ]; then
    [[ "$invocation" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [ "${#invocation}" -le 128 ] || return 1
  fi
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  printf '%s|%s|%s|%s\n' "$active" "$group" "$invocation" "$pid"
}

_hc_group_valid() {
  [[ "$1" =~ ^/[a-zA-Z0-9_.@:/-]+$ ]] || return 1
  case "$1" in /|*'//'*|*/../*|*/./*|*/..|*/.) return 1 ;; esac
}

_hc_belongs() {
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

_hc_read_procs() { hc_bound "$2" 4000 cat "$1" 2>/dev/null; }

_hc_candidates() {
  local root="$1" group="$2" deadline="$3" files file contents pid seen=' ' ids='' count=0
  files=$(exec 9>&-; hc_bound "$deadline" 4000 find "$root$group" -type f -name cgroup.procs -print 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r file; do
    _hc_before "$deadline" || return 1
    [ -r "$file" ] || return 1
    contents=$(exec 9>&-; _hc_read_procs "$file" "$deadline") || return 1
    while IFS= read -r pid || [ -n "$pid" ]; do
      case "$pid" in '') continue ;; *[!0-9]*|0) return 1 ;; esac
      case "$seen" in *" $pid "*) continue ;; esac
      count=$((count+1))
      [ "$count" -le 1024 ] || return 2
      seen="$seen$pid "
      ids="${ids}${pid}"$'\n'
    done <<< "$contents"
  done <<< "$files"
  [ -n "$ids" ] || return 0
  printf '%s' "$ids" | hc_bound "$deadline" 4000 sort -n
}

# Reads only relative files in the pinned cwd. Results use caller-local variables.
_hc_proc_identity() {
  local expected="$1" stat suffix start line group='' n=1
  [ -r stat ] && [ -r cgroup ] || return 1
  IFS= read -r stat < stat || return 1
  [ "${stat%% *}" = "$expected" ] || return 1
  suffix=${stat##*) }
  [ "$suffix" != "$stat" ] || return 1
  [[ "$suffix" =~ ^[A-Za-z][[:space:]][0-9[:space:]-]+$ ]] || return 1
  # stat fields after comm contain no strings; field22 is suffix field20.
  set -- $suffix
  [ "$#" -ge 20 ] || return 1
  while [ "$n" -lt 20 ]; do shift; n=$((n+1)); done
  start=$1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  while IFS= read -r line; do
    case "$line" in 0::*) [ -z "$group" ] || return 1; group=${line#0::} ;; esac
  done < cgroup
  [ -n "$group" ] || return 1
  _hc_identity_start=$start
  _hc_identity_group=$group
}

_hc_fd_link() { hc_bound "$2" 1000 readlink "$1" 2>/dev/null; }

_hc_identity_pid() (
  exec 9>&- 3>&- 4>&-
  local root="$1" pid="$2" group="$3" deadline="$4"
  local _hc_identity_start='' _hc_identity_group=''
  _hc_before "$deadline" || { printf 'BUDGET|%s\n' "$pid"; return; }
  cd "$root/$pid" 2>/dev/null || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
  if ! _hc_proc_identity "$pid"; then printf 'INCOMPLETE|%s\n' "$pid"; return; fi
  if _hc_belongs "$_hc_identity_group" "$group"; then printf 'IN|%s:%s\n' "$pid" "$_hc_identity_start"
  else printf 'OUT|%s:%s\n' "$pid" "$_hc_identity_start"; fi
)

_hc_probe_pid() (
  exec 9>&- 3>&- 4>&-
  local root="$1" pid="$2" group="$3" deadline="$4"
  local _hc_identity_start='' _hc_identity_group='' first_start first_group
  local fd link inode sockets line token inodes=' ' has_socket=false positive=false selected_fd='' selected_link=''
  _hc_before "$deadline" || { printf 'BUDGET|%s\n' "$pid"; return; }
  # This cwd pins the process before ss. Never re-open its numeric proc path.
  cd "$root/$pid" 2>/dev/null || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
  if ! _hc_proc_identity "$pid"; then printf 'INCOMPLETE|%s\n' "$pid"; return; fi
  first_start=$_hc_identity_start; first_group=$_hc_identity_group
  if ! _hc_belongs "$first_group" "$group"; then printf 'OUT|%s:%s\n' "$pid" "$first_start"; return; fi
  [ -d fd ] && [ -r fd ] || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
  for fd in fd/*; do
    [ -L "$fd" ] || continue
    link=$(exec 9>&-; _hc_fd_link "$fd" "$deadline") || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
    case "$link" in socket:\[*\]) has_socket=true; break ;; esac
  done
  if [ "$has_socket" = true ]; then
    sockets=$(exec 9>&-; hc_bound "$deadline" 3000 ss -H -t -n -e state established '( dport = :443 )' 2>/dev/null) || {
      printf 'INCOMPLETE|%s\n' "$pid"; return;
    }
    _hc_before "$deadline" || { printf 'BUDGET|%s\n' "$pid"; return; }
    while IFS= read -r line; do
      _hc_before "$deadline" || { printf 'BUDGET|%s\n' "$pid"; return; }
      for token in $line; do
        case "$token" in
          ino:*) inode=${token#ino:}; case "$inode" in ''|*[!0-9]*) ;; *) inodes="$inodes$inode " ;; esac ;;
        esac
      done
    done <<< "$sockets"
    for fd in fd/*; do
      [ -L "$fd" ] || continue
      link=$(exec 9>&-; _hc_fd_link "$fd" "$deadline") || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
      case "$link" in
        socket:\[*\]) inode=${link#socket:\[}; inode=${inode%\]}
          case "$inode" in ''|*[!0-9]*) continue ;; esac
          case "$inodes" in *" $inode "*) positive=true; selected_fd=$fd; selected_link=$link; break ;; esac ;;
      esac
    done
  fi
  if ! _hc_proc_identity "$pid"; then printf 'INCOMPLETE|%s\n' "$pid"; return; fi
  if [ "$first_start" != "$_hc_identity_start" ] || [ "$first_group" != "$_hc_identity_group" ]; then
    printf 'CHANGED|%s\n' "$pid"; return
  fi
  if [ "$positive" = true ]; then
    link=$(exec 9>&-; _hc_fd_link "$selected_fd" "$deadline") || { printf 'INCOMPLETE|%s\n' "$pid"; return; }
    [ "$link" = "$selected_link" ] || { printf 'CHANGED|%s\n' "$pid"; return; }
    printf 'POS|%s:%s\n' "$pid" "$first_start"
  else printf 'IN|%s:%s\n' "$pid" "$first_start"; fi
)

_hc_connection_result() {
  local invocation=null
  [ -z "${3:-}" ] || invocation="\"$3\""
  printf '{"connection":"%s","cause":"%s","unit_invocation":%s}\n' "$1" "$2" "$invocation"
}

hc_connection_snapshot() {
  local unit="$1" proc_root="$2" cgroup_root="$3" deadline="$4"
  local tool attempt=1 before after active rest group invocation pids final_pids pid rc probe initial final
  local positive incomplete changed final_item kind record
  for tool in systemctl ss find readlink sort cat timeout; do
    command -v "$tool" >/dev/null 2>&1 || { _hc_connection_result unknown tools_unavailable; return; }
  done
  [ -f "$cgroup_root/cgroup.controllers" ] || { _hc_connection_result unknown hierarchy_unknown; return; }
  while [ "$attempt" -le 2 ]; do
    _hc_before "$deadline" || { _hc_connection_result unknown budget_exhausted; return; }
    before=$(exec 9>&-; _hc_unit_read "$unit" "$deadline") || { _hc_connection_result unknown unit_unknown; return; }
    active=${before%%|*}; rest=${before#*|}; group=${rest%%|*}; rest=${rest#*|}; invocation=${rest%%|*}
    if [ "$active" != active ]; then _hc_connection_result unknown unit_inactive; return; fi
    if [ -z "$invocation" ] || ! _hc_group_valid "$group" || [ ! -d "$cgroup_root$group" ]; then
      _hc_connection_result unknown group_unknown; return
    fi
    pids=$(exec 9>&-; _hc_candidates "$cgroup_root" "$group" "$deadline")
    rc=$?
    if [ "$rc" -eq 2 ]; then _hc_connection_result unknown candidate_limit "$invocation"; return
    elif [ "$rc" -ne 0 ]; then _hc_connection_result unknown inventory_incomplete "$invocation"; return; fi
    positive=false; incomplete=false; changed=false; initial=''
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      probe=$(exec 9>&-; _hc_probe_pid "$proc_root" "$pid" "$group" "$deadline")
      kind=${probe%%|*}; record=${probe#*|}
      case "$kind" in
        POS) positive=true; break ;;
        IN|OUT) initial="${initial}${kind}|${record}"$'\n' ;;
        CHANGED) changed=true ;;
        BUDGET) _hc_connection_result unknown budget_exhausted "$invocation"; return ;;
        *) incomplete=true ;;
      esac
    done <<< "$pids"
    _hc_before "$deadline" || { _hc_connection_result unknown budget_exhausted "$invocation"; return; }
    after=$(exec 9>&-; _hc_unit_read "$unit" "$deadline") || { _hc_connection_result unknown unit_unknown; return; }
    _hc_before "$deadline" || { _hc_connection_result unknown budget_exhausted "$invocation"; return; }
    [ "${before%|*}" = "${after%|*}" ] || changed=true
    if [ "$changed" != true ] && [ "$positive" = true ]; then
      _hc_connection_result present verified "$invocation"; return
    fi
    if [ "$positive" != true ] && [ "$changed" != true ]; then
      final_pids=$(exec 9>&-; _hc_candidates "$cgroup_root" "$group" "$deadline")
      rc=$?
      if [ "$rc" -eq 2 ]; then _hc_connection_result unknown candidate_limit "$invocation"; return
      elif [ "$rc" -ne 0 ]; then _hc_connection_result unknown inventory_incomplete "$invocation"; return; fi
      final=''
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        final_item=$(exec 9>&-; _hc_identity_pid "$proc_root" "$pid" "$group" "$deadline")
        case "$final_item" in
          IN\|*|OUT\|*) final="${final}${final_item}"$'\n' ;;
          BUDGET\|*) _hc_connection_result unknown budget_exhausted "$invocation"; return ;;
          *) incomplete=true ;;
        esac
      done <<< "$final_pids"
      [ "$initial" = "$final" ] || changed=true
    fi
    if [ "$changed" != true ]; then
      if [ "$incomplete" = true ]; then _hc_connection_result unknown inventory_incomplete "$invocation"
      else _hc_connection_result absent verified "$invocation"; fi
      return
    fi
    attempt=$((attempt+1))
  done
  _hc_connection_result unknown unstable "$invocation"
}

hc_observe() {
  local workspace="$1" unit="$2" epoch_ms="${3:-}" global_deadline="$4"
  local start hc_observation_deadline health=OK codes='' auth auth_class ttl=null
  local journal journal_file connection result rc code identity=NONE epoch_s invocation=null
  start=$(exec 9>&-; hc_mono_ms) || start=$global_deadline
  hc_observation_deadline=$((start+25000))
  [ "$hc_observation_deadline" -le "$global_deadline" ] || hc_observation_deadline=$global_deadline
  if hc_bound "$hc_observation_deadline" 4000 systemctl is-active --quiet "$unit" 2>/dev/null; then :
  else
    rc=$?
    if [ "$rc" -eq 3 ]; then health=DEGRADED; codes='"unit_inactive"'
    else health=WARN; codes='"unit_unknown"'; fi
  fi
  if [ -z "$epoch_ms" ]; then
    epoch_s=$(exec 9>&-; hc_bound "$hc_observation_deadline" 4000 date +%s 2>/dev/null) || epoch_s=''
    case "$epoch_s" in ''|*[!0-9]*) epoch_ms=null ;; *) epoch_ms=$((epoch_s*1000)) ;; esac
  fi
  auth=$(exec 9>&-; hc_auth_snapshot "$workspace/.state/.claude/.credentials.json" "$epoch_ms")
  auth_class=incomplete
  case "$auth" in
    *'"auth_class":"login_lost"'*) auth_class=login_lost ;;
    *'"auth_class":"renewal_expired"'*) auth_class=renewal_expired ;;
    *'"auth_class":"renewal_expiring"'*) auth_class=renewal_expiring ;;
    *'"auth_class":"renewable"'*) auth_class=renewable ;;
  esac
  case "$auth_class" in
    login_lost|renewal_expired) health=DEGRADED; code=$auth_class ;;
    renewal_expiring) [ "$health" != OK ] || health=WARN; code=renewal_expiring ;;
    incomplete)
      [ "$health" != OK ] || health=WARN
      code=auth_incomplete
      case "$auth" in *file_unavailable*|*file_unreadable*|*jq_missing*) code=auth_unavailable ;; esac ;;
    *) code='' ;;
  esac
  [ -z "$code" ] || codes="${codes:+$codes,}\"$code\""
  if command -v jq >/dev/null 2>&1; then
    ttl=$(exec 9>&-; printf '%s\n' "$auth" | hc_bound "$hc_observation_deadline" 4000 jq -r .renewal_remaining_ms 2>/dev/null) || ttl=null
  fi
  journal_file=$(exec 9>&-; umask 077; hc_bound "$hc_observation_deadline" 4000 mktemp "${TMPDIR:-/tmp}/agent-healthcheck.XXXXXX" 2>/dev/null) || journal_file=''
  journal='{"journal_class":"unknown"}'
  if [ -n "$journal_file" ]; then
    journal=$(exec 9>&-; hc_journal_snapshot "$unit" "$auth_class" "$journal_file" "$hc_observation_deadline")
  fi
  code=''
  case "$journal" in
    *'"journal_class":"terminal"'*) health=DEGRADED; code=journal_terminal ;;
    *'"journal_class":"unclassified_401"'*) health=DEGRADED; code=journal_401 ;;
    *'"journal_class":"refresh_unverified"'*) [ "$health" != OK ] || health=WARN; code=journal_refresh ;;
    *'"journal_class":"unknown"'*) [ "$health" != OK ] || health=WARN; code=journal_unknown ;;
  esac
  [ -z "$code" ] || codes="${codes:+$codes,}\"$code\""
  case "$journal" in
    *'"journal_unknown"'*)
      case "$codes" in *'"journal_unknown"'*) ;; *) codes="${codes:+$codes,}\"journal_unknown\"" ;; esac ;;
  esac
  result=$(exec 9>&-; hc_connection_snapshot "$unit" "${hc_proc_root:-/proc}" "${hc_cgroup_root:-/sys/fs/cgroup}" "$hc_observation_deadline")
  case "$result" in
    *'"cause":"unit_inactive"'*)
      health=DEGRADED
      case "$codes" in *'"unit_inactive"'*) ;; *) codes="${codes:+$codes,}\"unit_inactive\"" ;; esac ;;
  esac
  case "$result" in
    *'"unit_invocation":"'*)
      invocation=${result#*\"unit_invocation\":\"}
      invocation=${invocation%%\"*}
      invocation="\"$invocation\"" ;;
  esac
  connection=unknown
  case "$result" in *'"connection":"present"'*) connection=present ;; *'"connection":"absent"'*) connection=absent ;; esac
  if [ "$connection" != present ]; then
    [ "$health" != OK ] || health=WARN
    codes="${codes:+$codes,}\"connection_$connection\""
  fi
  for code in qmd_failed graph_failed; do
    case "$code" in qmd_failed) result="${unit%.service}-qmd-watch.service" ;; *) result="${unit%.service}-wiki-graph.service" ;; esac
    hc_bound "$hc_observation_deadline" 4000 systemctl is-failed --quiet "$result" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      [ "$health" != OK ] || health=WARN
      codes="${codes:+$codes,}\"$code\""
    elif [ "$rc" -ge 124 ]; then
      [ "$health" != OK ] || health=WARN
      codes="${codes:+$codes,}\"budget_exhausted\""
    fi
  done
  case "$health" in DEGRADED) identity=DEGRADED ;; *) [ "$auth_class" != renewal_expiring ] || identity=WARN_EXPIRY ;; esac
  printf '{"health":"%s","reason_codes":[%s],"auth_class":"%s","renewal_remaining_ms":%s,"connection":"%s","unit_invocation":%s,"notice_identity":"%s"}\n' \
    "$health" "$codes" "$auth_class" "$ttl" "$connection" "$invocation" "$identity"
}

_hc_reason_text() {
  local snapshot="$1" reasons='' code message ttl duration
  for code in unit_inactive unit_unknown login_lost renewal_expired renewal_expiring auth_unavailable auth_incomplete journal_terminal journal_401 journal_refresh journal_unknown connection_absent connection_unknown qmd_failed graph_failed budget_exhausted; do
    case "$snapshot" in *"\"$code\""*) ;; *) continue ;; esac
    case "$code" in
      unit_inactive) message='unit not active' ;;
      unit_unknown) message='cannot verify unit state' ;;
      login_lost) message='login unavailable (tokens cleared)' ;;
      renewal_expired) message='login renewal expired' ;;
      renewal_expiring)
        ttl=${snapshot#*\"renewal_remaining_ms\":}
        ttl=${ttl%%,*}; ttl=${ttl%%\}*}
        duration=$(exec 9>&-; hc_format_duration "$ttl") || duration=''
        message="login renewal expiring${duration:+ in $duration}" ;;
      auth_unavailable) message='cannot verify login renewal (credentials unavailable)' ;;
      auth_incomplete) message='cannot verify login renewal (incomplete credentials)' ;;
      journal_terminal) message='login required by terminal journal event' ;;
      journal_401) message='unclassified authentication error in journal' ;;
      journal_refresh) message='session refresh unverified' ;;
      journal_unknown) message='cannot verify journal' ;;
      connection_absent) message='no live relay connection (unit TCP signal absent)' ;;
      connection_unknown) message='cannot verify connection' ;;
      qmd_failed) message='qmd watcher failed (timer still backstops)' ;;
      graph_failed) message='wiki-graph runner failed (last graph still usable)' ;;
      budget_exhausted) message='observation budget exhausted' ;;
    esac
    reasons="${reasons:+$reasons; }$message"
  done
  printf '%s' "$reasons"
}

# One validator is shared by loading, reduction and both durable commits.
# Input is JSON on stdin; no payload, journal or destination is stored here.
_hc_notice_json() {
  local _hc_json_deadline="${_hc_json_deadline:-}" now
  if [ -z "$_hc_json_deadline" ]; then
    now=$(exec 9>&-; hc_mono_ms) || return 124
    _hc_json_deadline=$((now+4000))
  fi
  hc_bound "$_hc_json_deadline" 4000 jq -Rcse --arg op "$1" '
    def uint: if type=="number" then .>=0 and .<=9007199254740991 and .==floor else false end;
    def fields($k): type=="object" and keys==($k|sort);
    def valid:
      fields(["schema","identity","event_version","episode","pending"]) and .schema==1 and
      (.identity=="NONE" or .identity=="WARN_EXPIRY" or .identity=="DEGRADED") and
      (.event_version|uint) and .event_version<=9007199254740990 and
      (. as $s | (.episode==null or
        ((.episode|fields(["id","notified"])) and (.episode.id|uint) and
         .episode.id>0 and .episode.id<=.event_version and (.episode.notified|type)=="boolean")) and
        (.pending==null or
          ((.pending|fields(["version","kind","phase","attempted_at_s","clock_seen_s","retry_remaining_s"])) and
           .pending.version==$s.event_version and (.pending.clock_seen_s|uint) and
           (.pending.retry_remaining_s|uint) and .pending.retry_remaining_s<=1800 and
           (if .pending.phase=="ready" then .pending.attempted_at_s==null and .pending.retry_remaining_s==0
            else (.pending.phase=="inflight" or .pending.phase=="pending") and
              (.pending.attempted_at_s|uint) and .pending.attempted_at_s<=.pending.clock_seen_s end))) and
        (if .identity=="NONE" then
          (.episode==null and .pending==null) or
          (.episode.notified==true and .pending!=null and .pending.kind=="RECOVERY")
         else .episode!=null and
          (if .pending==null then .episode.notified==true
           elif .identity=="DEGRADED" then .pending.kind=="DEGRADED"
           else .pending.kind=="WARN_EXPIRY" or (.pending.kind=="RECOVERY_WARN" and .episode.notified==true) end)
         end));
    def initial: {schema:1,identity:"NONE",event_version:0,episode:null,pending:null};
    def ready($kind;$now): {version:.event_version,kind:$kind,phase:"ready",attempted_at_s:null,clock_seen_s:$now,retry_remaining_s:0};
    (try fromjson catch null) |
    if $op=="validate" then if valid then . else ""|halt_error(10) end
    elif $op=="confirm" then
      if valid and .pending!=null then
        if .pending.kind=="RECOVERY" then .episode=null else .episode.notified=true end | .pending=null
      else error("invalid confirmation") end
    elif $op=="reduce" then
      .now_s as $now | .snapshot.notice_identity as $id | (.state // initial) as $prior |
      if ($now|uint) and ($id=="NONE" or $id=="WARN_EXPIRY" or $id=="DEGRADED") and ($prior|valid) then
        $prior |
        if .event_version>=9007199254740990 then error("version limit") else . end |
        if .identity!=$id then
          .identity as $before | .event_version+=1 | .identity=$id | .pending=null |
          if $id=="NONE" then
            if .episode.notified==true then .pending=ready("RECOVERY";$now) else .episode=null end
          else
            .episode=(.episode // {id:.event_version,notified:false}) |
            .pending=ready((if $before=="DEGRADED" and $id=="WARN_EXPIRY" and .episode.notified then "RECOVERY_WARN" else $id end);$now)
          end
        else . end |
        (.pending!=null and $now<.pending.clock_seen_s) as $reversed |
        if .pending!=null then
          .pending.retry_remaining_s=([0,.pending.retry_remaining_s-([0,$now-.pending.clock_seen_s]|max)]|max) |
          .pending.clock_seen_s=([.pending.clock_seen_s,$now]|max)
        else . end |
        (.pending!=null and .pending.retry_remaining_s==0) as $send |
        if $send then .pending.phase="inflight" | .pending.attempted_at_s=$now | .pending.retry_remaining_s=1800 else . end |
        {state:.,action:(if $send then "send" else "wait" end),changed:(.!=$prior),clock_reversed:$reversed}
      else error("invalid reduction") end
    else error("invalid operation") end' 2>/dev/null
}

hc_notice_reduce() { _hc_notice_json reduce; }

_hc_file_metadata() {
  local path="$1" deadline="$2" result
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  result=$(exec 9>&-; hc_bound "$deadline" 1000 stat -c '%a %s' "$path" 2>/dev/null) ||
    result=$(exec 9>&-; hc_bound "$deadline" 1000 stat -f '%Lp %z' "$path" 2>/dev/null) || return 1
  case "$result" in '600 '*) ;; *) return 1 ;; esac
  printf '%s\n' "${result#* }"
}

_hc_commit_end() {
  local now
  now=$(exec 9>&-; hc_mono_ms) || return 1
  [ "$now" -lt "$1" ] || return 1
  now=$((now+5000))
  [ "$now" -le "$1" ] || now=$1
  printf '%s\n' "$now"
}

_hc_state_write() {
  local body
  IFS= read -r body || return 1
  (umask 077; printf '%s\n' "$body" > "$1") 9>&-
}

hc_state_commit() {
  # Called in the lock-owning controller, never as a pipeline's child.
  local path="$1" deadline="$2" dir="${1%/*}" temp='' body rc=1
  local _hc_json_deadline cleanup_deadline
  cleanup_deadline=$(exec 9>&-; _hc_commit_end "$deadline") || return 1
  # The five-second total includes cleanup. Stop work early enough to unlink
  # a failed staging file without extending either the phase or global cap.
  _hc_json_deadline=$((cleanup_deadline-1000))
  _hc_before "$_hc_json_deadline" || return 1
  body=$(exec 9>&-; _hc_notice_json validate) || return 1
  [ "${#body}" -le 16383 ] || return 1
  temp=$(exec 9>&-; umask 077; hc_bound "$_hc_json_deadline" 1000 mktemp "$dir/.local-healthcheck.XXXXXX" 2>/dev/null) || return 1
  if hc_bound "$_hc_json_deadline" 1000 chmod 600 "$temp" 2>/dev/null &&
     _hc_before "$_hc_json_deadline" && _hc_state_write "$temp" <<< "$body" &&
     hc_bound "$_hc_json_deadline" 2000 sync "$temp" 2>/dev/null &&
     hc_bound "$_hc_json_deadline" 1000 mv "$temp" "$path" 2>/dev/null &&
     hc_bound "$_hc_json_deadline" 2000 sync "$dir" 2>/dev/null; then rc=0; fi
  [ ! -e "$temp" ] || hc_bound "$cleanup_deadline" 1000 rm -f "$temp" 2>/dev/null || true
  return "$rc"
}

_hc_adopt() {
  local deadline
  deadline=$(exec 9>&-; _hc_commit_end "$2") || return 1
  hc_bound "$deadline" 2500 sync "$1" 2>/dev/null &&
    hc_bound "$deadline" 2500 sync "${1%/*}" 2>/dev/null
}

_hc_notify_diag() {
  printf 'agent-%s healthcheck notify: %s\n' "${name:-local}" "$1" >&2
}

_hc_curl_quote() {
  local value="$1"
  [[ "$value" != *[[:cntrl:]]* ]] || return 1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

_hc_notify_send() {
  local workspace="$1" deadline="$2" kind="$3" health="$4" version="$5" snapshot="$6"
  local response http rc result token_q chat_q text_q detail
  command -v curl >/dev/null 2>&1 || { _hc_notify_diag transport_unavailable; return 1; }
  token_q=$(exec 9>&-; _hc_curl_quote "https://api.telegram.org/bot$notify_bot_token/sendMessage") || return 1
  chat_q=$(exec 9>&-; _hc_curl_quote "chat_id=$notify_chat_id") || return 1
  # Event and health are closed enums; a recovery with WARN never announces OK.
  detail=$(exec 9>&-; _hc_reason_text "$snapshot")
  text_q=$(exec 9>&-; _hc_curl_quote "text=agent-${name:-local} $kind health=$health version=$version${detail:+; $detail}") || return 1
  response=$(exec 9>&-; umask 077; hc_bound "$deadline" 1000 mktemp "$workspace/.state/.healthcheck-response.XXXXXX" 2>/dev/null) || { _hc_notify_diag state_unavailable; return 1; }
  # Open independent offsets, then unlink before the network call. No external
  # cleanup/seek is needed if the global deadline expires during transport.
  exec 7>"$response" 8<"$response"
  if ! hc_bound "$deadline" 1000 rm -f "$response" 2>/dev/null; then exec 7>&- 8<&-; _hc_notify_diag state_unavailable; return 1; fi
  http=$(exec 9>&-;
    { printf 'url = %s\ndata-urlencode = %s\ndata-urlencode = %s\n' "$token_q" "$chat_q" "$text_q"; } |
      hc_bound "$deadline" 20000 curl -q --config - --connect-timeout 5 --max-time 15 --retry 0 --silent --output /dev/fd/7 --write-out '%{http_code}' 2>/dev/null)
  rc=$?
  exec 7>&-
  if ! _hc_before "$deadline"; then exec 8<&-; _hc_notify_diag budget_exhausted; return 1; fi
  if [ "$rc" -ne 0 ]; then
    exec 8<&-
    case "$rc" in 124|137|143) _hc_notify_diag timeout ;; *) _hc_notify_diag curl_failure ;; esac
    return 1
  fi
  if [ "$http" != 200 ]; then exec 8<&-; _hc_notify_diag http_failure; return 1; fi
  result=$(exec 9>&-; hc_bound "$deadline" 1000 jq -r 'if type=="object" then .ok==true else false end' <&8 2>/dev/null)
  rc=$?
  exec 8<&-
  if [ "$rc" -ne 0 ]; then _hc_notify_diag invalid_response; return 1; fi
  [ "$result" = true ] || { _hc_notify_diag api_failure; return 1; }
  return 0
}

_hc_notice_transaction() {
  local workspace="$1" snapshot="$2" deadline="$3" state_path="$1/.state/local-healthcheck.json"
  local state='' size='' loaded=false reset=false reduced candidate action kind health version now changed rc
  local _hc_json_deadline="$deadline"
  if [ -e "$state_path" ] || [ -L "$state_path" ]; then
    size=$(exec 9>&-; _hc_file_metadata "$state_path" "$deadline") || { _hc_notify_diag state_unavailable; return; }
    case "$size" in ''|*[!0-9]*) _hc_notify_diag state_unavailable; return ;; esac
    if [ "$size" -le 16384 ]; then
      state=$(exec 9>&-; hc_bound "$deadline" 2000 cat "$state_path" 2>/dev/null) || { _hc_notify_diag state_unavailable; return; }
      state=$(exec 9>&-; _hc_notice_json validate <<< "$state")
      rc=$?
      case "$rc" in
        0) loaded=true ;;
        4|10) ;; # Invalid JSON/schema only; tool failures are not corruption.
        *) _hc_notify_diag state_unavailable; return ;;
      esac
    fi
    if [ "$loaded" = true ]; then
      _hc_adopt "$state_path" "$deadline" || { _hc_notify_diag state_failure; return; }
      case "$state" in *'"event_version":9007199254740990'*) _hc_notify_diag state_unavailable; return ;; esac
    else reset=true; state=null; fi
  else reset=true; state=null; fi
  [ "$reset" != true ] || _hc_notify_diag state_reset
  now=$(exec 9>&-; hc_bound "$deadline" 1000 date +%s 2>/dev/null) || { _hc_notify_diag budget_exhausted; return; }
  case "$now" in ''|*[!0-9]*) _hc_notify_diag state_unavailable; return ;; esac
  reduced=$(exec 9>&-; printf '{"state":%s,"snapshot":%s,"now_s":%s}\n' "$state" "$snapshot" "$now" | hc_notice_reduce) || { _hc_notify_diag state_unavailable; return; }
  candidate=$(exec 9>&-; hc_bound "$deadline" 1000 jq -c .state <<< "$reduced") || { _hc_notify_diag state_unavailable; return; }
  case "$candidate" in *'"event_version":9007199254740990'*) _hc_notify_diag state_unavailable; return ;; esac
  action=$(exec 9>&-; hc_bound "$deadline" 1000 jq -r .action <<< "$reduced") || { _hc_notify_diag state_unavailable; return; }
  case "$reduced" in *'"clock_reversed":true'*) _hc_notify_diag clock_reversed ;; esac
  case "$reduced" in *'"changed":true'*) changed=true ;; *) changed=false ;; esac
  if [ "$changed" = true ] || [ "$reset" = true ]; then
    hc_state_commit "$state_path" "$deadline" <<< "$candidate" || { _hc_notify_diag state_failure; return; }
  fi
  [ "$action" = send ] || { case "$candidate" in *'"pending":null'*) ;; *) _hc_notify_diag retry_pending ;; esac; return; }
  kind=$(exec 9>&-; hc_bound "$deadline" 1000 jq -r .pending.kind <<< "$candidate") || { _hc_notify_diag state_unavailable; return; }
  version=$(exec 9>&-; hc_bound "$deadline" 1000 jq -r .event_version <<< "$candidate") || { _hc_notify_diag state_unavailable; return; }
  health=$(exec 9>&-; hc_bound "$deadline" 1000 jq -r .health <<< "$snapshot") || { _hc_notify_diag state_unavailable; return; }
  if _hc_notify_send "$workspace" "$deadline" "$kind" "$health" "$version" "$snapshot"; then
    candidate=$(exec 9>&-; _hc_notice_json confirm <<< "$candidate") || { _hc_notify_diag delivery_uncertain; return; }
    if hc_state_commit "$state_path" "$deadline" <<< "$candidate"; then _hc_notify_diag confirmed
    else _hc_notify_diag state_failure; _hc_notify_diag delivery_uncertain; fi
  fi
}

hc_notice_run() {
  # This function must run in the CLI parent, which alone owns descriptor 9.
  local workspace="$1" unit="$2" global_deadline="$3" lock="$1/.state/.local-healthcheck.lock"
  local snapshot now deadline lock_ready=false configured=false src parser size config_failed=false sync_version
  local notify_bot_token='' notify_chat_id=''
  unset NOTIFY_BOT_TOKEN NOTIFY_CHAT_ID
  export -n notify_bot_token notify_chat_id
  parser="$workspace/scripts/lib/env_file.sh"
  if [ "${_hc_env_ok:-true}" = true ] && declare -F env_file_get >/dev/null; then
    src="$workspace/.env"
    [ ! -r "$workspace/.state/healthcheck-notify.env" ] || src="$workspace/.state/healthcheck-notify.env"
    notify_bot_token=$(exec 9>&-; hc_bound "$global_deadline" 4000 bash -c '. "$1"; env_file_get "$2" "$3"' _ "$parser" NOTIFY_BOT_TOKEN "$src" 2>/dev/null) || config_failed=true
    notify_chat_id=$(exec 9>&-; hc_bound "$global_deadline" 4000 bash -c '. "$1"; env_file_get "$2" "$3"' _ "$parser" NOTIFY_CHAT_ID "$src" 2>/dev/null) || config_failed=true
    if [ "$config_failed" = true ] && [ -r "$src" ]; then
      _hc_notify_diag state_unavailable
      notify_bot_token=''; notify_chat_id=''
    fi
    if [ -n "$notify_bot_token" ] && [ -n "$notify_chat_id" ] &&
       _hc_curl_quote "$notify_bot_token" >/dev/null && _hc_curl_quote "$notify_chat_id" >/dev/null; then configured=true; fi
  fi
  if [ "$configured" = true ]; then
    sync_version=$(exec 9>&-; hc_bound "$global_deadline" 1000 sync --version 2>/dev/null) || sync_version=''
    sync_version=${sync_version%%$'\n'*}
    case "$sync_version" in 'sync (GNU coreutils) '*) ;; *) _hc_notify_diag state_unavailable; configured=false ;; esac
  fi
  if [ "$configured" = true ]; then
    if ! command -v jq >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1 ||
       ! command -v sync >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 ||
       [ ! -d "$workspace/.state" ] || [ ! -w "$workspace/.state" ] || [ -L "$workspace/.state" ]; then
      _hc_notify_diag state_unavailable
    elif _hc_before "$global_deadline"; then
      if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then (umask 077; set -C; : > "$lock") 9>&- 2>/dev/null || true; fi
      size=$(exec 9>&-; _hc_file_metadata "$lock" "$global_deadline") || size=''
      if [ "$size" = 0 ]; then
        exec 9>>"$lock"
        if _hc_flock "$global_deadline" -n 2>/dev/null; then lock_ready=true
        else _hc_notify_diag notify_busy; exec 9>&-; fi
      else _hc_notify_diag state_unavailable; fi
    else _hc_notify_diag budget_exhausted; fi
  fi
  snapshot=$(exec 9>&-; hc_observe "$workspace" "$unit" '' "$global_deadline")
  hc_last_snapshot=$snapshot
  if [ "$lock_ready" = true ]; then
    now=$(exec 9>&-; hc_mono_ms) || now=$global_deadline
    deadline=$((now+30000)); [ "$deadline" -le "$global_deadline" ] || deadline=$global_deadline
    if _hc_before "$deadline"; then _hc_notice_transaction "$workspace" "$snapshot" "$deadline"
    else _hc_notify_diag budget_exhausted; fi
    # If no time remains, closing the sole owning descriptor releases the lock
    # without starting an external command after the absolute deadline.
    if _hc_before "$deadline"; then _hc_flock "$deadline" -u 2>/dev/null || true; fi
    exec 9>&-
  fi
  printf '%s\n' "$snapshot"
  return 0
}
_hc_library_marker() { :; }
