# shellcheck shell=bash
# Private host harness for 050. Sourcing defines functions only.
# Code and evidence travel in scratch files, never in large argv/env strings.

qmd_boot_race_extract() {
  local root source_file
  root="${REPO_ROOT:-}"
  if [ -z "$root" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 2
  fi
  source_file="${QMD_BOOT_RACE_E2E_FILE:-$root/tests/docker-e2e-qmd.bats}"
  python3 - "$source_file" "$1" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

source, out = map(Path, sys.argv[1:])

def reject(reason):
    print('boot-race: structural:' + reason, file=sys.stderr)
    raise SystemExit(2)

if not source.is_file():
    reject('missing-file')
lines = source.read_text().splitlines(keepends=True)
title = 'qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick'
subject = re.compile(r'''^@test\s+(["'])''' + re.escape(title) + r'''\1\s*\{\s*$''')
starts = [n for n, line in enumerate(lines) if subject.fullmatch(line.rstrip('\n'))]
if len(starts) != 1:
    reject('subject-count')
start = starts[0]
end = next((n for n in range(start + 1, len(lines)) if re.fullmatch(r'}[ \t]*(?:#.*)?\n?', lines[n])), None)
if end is None or any(line.startswith('@test ') for line in lines[start+1:end]):
    reject('subject-end')
sections = ('fixture', 'precondition', 'tick1', 'observe', 'verify')
anchor = re.compile(r'^[ \t]*# 050:([a-z0-9]+):(begin|end)[ \t]*\n?$')
markers = []
for n, line in enumerate(lines):
    match = anchor.fullmatch(line)
    if match:
        markers.append((n, match[1], match[2]))
for section in sections:
    for edge in ('begin', 'end'):
        found = [n for n, name, kind in markers if (name, kind) == (section, edge)]
        if len(found) != 1 or not start < found[0] < end:
            reject('anchor-count:' + section + ':' + edge)
if len(markers) != 10:
    reject('anchor-count:unknown')
stack, spans = [], {}
for n, section, edge in markers:
    if edge == 'begin':
        stack.append(section)
        spans[section] = [n]
    else:
        if not stack or stack.pop() != section:
            reject('anchor-order:' + section)
        spans[section].append(n)
if stack:
    reject('anchor-order:unclosed')
f, p, t, o, v = (spans[s] for s in sections)
if not (f[1] < p[0] < p[1] < min(t[0], o[0], v[0]) and max(t[1], o[1]) < v[0]):
    reject('anchor-order:sections')

def executable(line):
    return bool(line.strip()) and not line.lstrip().startswith('#')

for section, (begin, finish) in spans.items():
    if not any(executable(line) for line in lines[begin+1:finish]):
        reject('empty-section:' + section)
# Build/up and the executor definition between fixture and precondition are
# deliberately outside the replay. Everything from precondition to the end
# must be covered, including any statement appended after verify:end.
for n in list(range(start+1, f[0])) + list(range(p[0], end)):
    if executable(lines[n]) and not any(a < n < b for a, b in spans.values()):
        reject('uncovered-statement:line-' + str(n+1))
if out.exists():
    reject('output-exists')
out.mkdir(parents=True)
for section, (begin, finish) in spans.items():
    (out/(section+'.bash')).write_text(''.join(lines[begin+1:finish]))
# Preserve textual order exactly once, including nested markers; never
# concatenate the five independently extracted sections for execution.
replay = ''.join(lines[p[0]:v[1]+1])
(out/'replay.bash').write_text(replay)
(out/'extraction.json').write_text(json.dumps({
    'source': str(source.resolve()),
    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'replay_sha256': hashlib.sha256(replay.encode()).hexdigest(),
    'replay_first_line': p[0]+1, 'replay_last_line': v[1]+1,
    'sections': {s: {'first_line': a+2, 'last_line': b} for s, (a,b) in spans.items()},
}, indent=2)+'\n')
PY
}

_qmd_boot_race_launcher() {
  local p IFS=:
  # Bats adds its inner libexec to PATH. That script is not a standalone
  # launcher and fails in an empty environment (041's _real_bats precedent).
  for p in $PATH; do
    if [ "$p" = "${BATS_LIBEXEC:-}" ]; then continue; fi
    if [ -x "$p/bats" ]; then printf '%s\n' "$p/bats"; return 0; fi
  done
  printf '%s\n' 'boot-race: harness:launcher' >&2
  return 2
}

qmd_boot_race_replay() {
  local dir="$1" bootstrap="$2" expected="$3" launcher child_path child_rc=0
  if [ ! -f "$dir/replay.bash" ] || [ ! -f "$bootstrap" ]; then
    printf '%s\n' 'boot-race: harness:bootstrap-or-replay' >&2
    return 2
  fi
  if [ -e "$dir/child.bats" ]; then
    printf '%s\n' 'boot-race: harness:reused-child' >&2
    return 2
  fi
  launcher=$(_qmd_boot_race_launcher) || return 2
  child_path="$(dirname "$BASH"):$(dirname "$launcher"):/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$dir/home" "$dir/tmp" || return 2
  : > "$dir/child.trace"
  python3 - "$dir" <<'PY'
import hashlib, json, sys
from pathlib import Path
p = Path(sys.argv[1]); replay = (p/'replay.bash').read_text()
assert hashlib.sha256(replay.encode()).hexdigest() == json.loads((p/'extraction.json').read_text())['replay_sha256']
header = '''#!/usr/bin/env bats
setup() {
  printf '%s\\n%s\\n' "$BASH_VERSION" "$BATS_VERSION" > "$BOOT_RACE_RUN/child.versions"
  source "$BOOT_RACE_BOOTSTRAP"
}
@test "050 replay" {
'''
(p/'child.bats').write_text(header + replay + '}\n')
(p/'child-map.json').write_text(json.dumps({'payload_first_line': len(header.splitlines())+1})+'\n')
PY
  # This is an external Bats process, launched with its own bash and empty
  # environment. Capturing its exit does not wrap the replay in a conditional
  # function or change the child's errexit context. No parent BATS_* is passed.
  env -i "PATH=$child_path" "HOME=$dir/home" "TMPDIR=$dir/tmp" LC_ALL=C LANG=C TZ=UTC \
    "BOOT_RACE_RUN=$dir" "BOOT_RACE_BOOTSTRAP=$bootstrap" "BOOT_RACE_TRACE=$dir/child.trace" \
    "REPO_ROOT=${REPO_ROOT:-}" \
    "$BASH" "$launcher" --tap --print-output-on-failure "$dir/child.bats" \
    > "$dir/child.tap" 2> "$dir/child.stderr" 3>&- 4>&- || child_rc=$?
  printf '%s\n' "$child_rc" > "$dir/child.exit"
  qmd_boot_race_validate "$dir" "$expected"
}

qmd_boot_race_validate() {
  python3 - "$1" "$2" "$BASH_VERSION" "${BATS_VERSION:-}" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

p = Path(sys.argv[1]); expected, bash_version, bats_version = sys.argv[2:]

def reject(reason):
    (p/'result.json').write_text(json.dumps({'classification': 'harness-error', 'reason': reason}, indent=2)+'\n')
    print('boot-race: harness:' + reason, file=sys.stderr)
    raise SystemExit(2)

needed = ('child.tap', 'child.stderr', 'child.exit', 'child.versions', 'child.trace', 'expected.trace', 'child.bats')
if not all((p/name).is_file() for name in needed):
    reject('child-evidence')
tap = (p/'child.tap').read_text()
lines = tap.splitlines()
if [line for line in lines if re.fullmatch(r'1\.\.[0-9]+', line)] != ['1..1']:
    reject('tap-plan')
results = [line for line in lines if re.match(r'^(?:ok|not ok) [0-9]+(?: |$)', line)]
if len(results) != 1 or not re.match(r'^(?:ok|not ok) 1(?: |$)', results[0]):
    reject('tap-result')
if re.search(r'#\s*skip\b', results[0], re.I):
    reject('skip-result')
versions = (p/'child.versions').read_text().splitlines()
if not versions or versions[0] != bash_version:
    reject('interpreter')
if len(versions) != 2 or not bats_version or versions[1] != bats_version:
    reject('bats-version')
if (p/'child.stderr').stat().st_size or re.search(r'command not found|syntax error|BOOT_RACE_FAKE_ERROR:|^Bail out!', tap, re.M):
    reject('child-error')
actual = (p/'child.exit').read_text().strip()
if expected not in ('0', '1') or actual != expected:
    reject('exit-status')
if results[0].startswith('ok ') != (expected == '0'):
    reject('tap-outcome')
failed_line = None
if expected == '1':
    if not (p/'expected.assertion').is_file():
        reject('assertion-location')
    condition = (p/'expected.assertion').read_text().strip()
    body = (p/'child.bats').read_text().splitlines()
    candidates = [n+1 for n, line in enumerate(body) if line.strip() == condition]
    if (p/'expected.source-line').is_file():
        source_line = int((p/'expected.source-line').read_text())
        meta = json.loads((p/'extraction.json').read_text())
        mapping = json.loads((p/'child-map.json').read_text())
        wanted = source_line - meta['replay_first_line'] + mapping['payload_first_line']
        candidates = [wanted] if wanted in candidates else []
    # A repeated condition needs an explicit child line to identify the site.
    if (p/'expected.line').is_file():
        value = (p/'expected.line').read_text().strip()
        candidates = [int(value)] if value.isdigit() and int(value) in candidates else []
    locations = [int(n) for n in re.findall(re.escape(str(p/'child.bats')) + r', line ([0-9]+)\)', tap)]
    if not condition or len(candidates) != 1 or candidates[0] not in locations or condition not in tap:
        reject('assertion-location')
    failed_line = candidates[0]
trace = (p/'child.trace').read_bytes()
expected_trace = (p/'expected.trace').read_bytes()
if not expected_trace or trace != expected_trace:
    reject('fake-trace')
result = {'classification': 'healthy' if expected == '0' else 'assertion',
          'bash_version': versions[0], 'bats_version': versions[1],
          'exit_code': int(actual), 'failed_line': failed_line,
          'trace_sha256': hashlib.sha256(trace).hexdigest()}
(p/'result.json').write_text(json.dumps(result, indent=2)+'\n')
PY
}

# Installed only by a replay child's bootstrap, never on source by the parent.
# Readers execute the actual POSIX inspection against a synthetic HOME; jq is
# the only absolute /workspace read and is mapped at this container boundary.
qmd_boot_race_fake_init() {
  BOOT_MODE=$(cat "$BOOT_RACE_RUN/mode")
  printf '0\n' > "$BOOT_RACE_RUN/clock"
  printf '0\n' > "$BOOT_RACE_RUN/reads"
  mkdir -p "$HOME/.cache/qmd"
  : > "$HOME/.cache/qmd/index.sqlite"
  : > "$HOME/.cache/qmd/.qmd-setup-ok"
  case "$BOOT_MODE" in
    no-index) rm "$HOME/.cache/qmd/index.sqlite" ;;
    no-setup) rm "$HOME/.cache/qmd/.qmd-setup-ok" ;;
    migrated) : > "$HOME/.cache/qmd/.qmd-collection-wiki" ;;
    prior-replace) printf 'collection remove prior\n' > "$HOME/.cache/qmd/engine-calls.log" ;;
  esac
  _boot_trace() { printf '%s\n' "$1" >> "$BOOT_RACE_TRACE"; }
  _boot_fake_error() { printf 'BOOT_RACE_FAKE_ERROR: %s\n' "$1" >&2; return 98; }
  date() {
    [ "$*" = '+%s' ] || { _boot_fake_error "date $*"; return 98; }
    cat "$BOOT_RACE_RUN/clock"
  }
  sleep() {
    [ "$*" = 2 ] || { _boot_fake_error "sleep $*"; return 98; }
    _boot_trace sleep:2
    printf '%s\n' "$(( $(cat "$BOOT_RACE_RUN/clock") + 2 ))" > "$BOOT_RACE_RUN/clock"
  }
  _qmd_e2e_note() { :; }
  in_container() {
    [ "$#" -eq 3 ] && [ "$1" = sh ] && [ "$2" = -c ] || { _boot_fake_error 'exec shape'; return 98; }
    local script="$3" kind rc=0 reads
    case "$script" in
      *'.qmd-setup-ok'*) kind=pre ;;
      *'.qmd-collection-wiki'*) kind=sentinel ;;
      *'jq -r .migration'*)
        _boot_trace inspect:state
        cat "$BOOT_RACE_RUN/migration"
        if [ "$BOOT_MODE" = state-status7 ]; then return 7; fi
        return 0 ;;
      *'grep -c'*'^collection'*) kind=count ;;
      *'cat '*'engine-calls.log'*)
        reads=$(( $(cat "$BOOT_RACE_RUN/reads") + 1 ))
        printf '%s\n' "$reads" > "$BOOT_RACE_RUN/reads"
        case "$BOOT_MODE:$reads" in
          no-log:*|slow-log:1) _boot_trace read:missing; return 1 ;;
        esac
        _boot_trace read:ready
        printf '%s\n' "$script" > "$BOOT_RACE_RUN/inspection.sh"
        command sh "$BOOT_RACE_RUN/inspection.sh"
        return $? ;;
      *) _boot_fake_error "unknown inspection: $script"; return 98 ;;
    esac
    _boot_trace "inspect:$kind"
    printf '%s\n' "$script" > "$BOOT_RACE_RUN/inspection.sh"
    command sh "$BOOT_RACE_RUN/inspection.sh" || rc=$?
    case "$BOOT_MODE:$kind" in pre-status7:pre|sentinel-status7:sentinel|count-status7:count) return 7 ;; esac
    return "$rc"
  }
  qmd_e2e_reindex_wait() {
    local tick
    case "$2" in 'test 13 tick 1') tick=1 ;; 'test 13 tick 2') tick=2 ;; *) _boot_fake_error 'tick label'; return 98 ;; esac
    _boot_trace "tick:$tick"
    REINDEX_STATUS=0 REINDEX_OUTPUT='controlled reindex'
    if [ "$tick" = 1 ]; then
      cp "$BOOT_RACE_RUN/engine.expected" "$HOME/.cache/qmd/engine-calls.log"
      if [ "$BOOT_MODE" != sentinel-missing ]; then : > "$HOME/.cache/qmd/.qmd-collection-wiki"; fi
      printf 'done\n' > "$BOOT_RACE_RUN/migration"
      if [ "$BOOT_MODE" = state-pending ]; then printf 'pending\n' > "$BOOT_RACE_RUN/migration"; fi
      if [ "$BOOT_MODE" = slow-log ]; then printf '100\n' > "$BOOT_RACE_RUN/clock"; fi
    elif [ "$BOOT_MODE" = repeated ]; then
      printf 'collection remove vault\ncollection add /vault --name vault --mask wiki/**/*.md\n' >> "$HOME/.cache/qmd/engine-calls.log"
    fi
    # An observed effect can be healthy even if this attempt's return/status
    # is invalid (another actor could have done the work). Only the required
    # execution guards may reject these cases, not a later missing effect.
    case "$BOOT_MODE:$tick" in
      tick1-rc1:1|tick2-rc1:2) return 1 ;;
      tick1-rc3:1|tick2-rc3:2) return 3 ;;
      tick1-status7:1|tick2-status7:2) REINDEX_STATUS=7; return 0 ;;
    esac
    return 0
  }
}
