#!/usr/bin/env bats
# 050: the harness must reject broken evidence before testing the migration.
# H01-H14 execute the real fixture and assertions before/after the e2e fix.

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_tmp_dir
  BOOT_HELPER="$REPO_ROOT/tests/helper-qmd-e2e-boot-race.bash"
  H00_SUBJECT="$TMP_TEST_DIR/subject.bats"
  H00_BOOTSTRAP="$TMP_TEST_DIR/bootstrap.bash"
  RACE_CASE_NO=0
  # Preserve an externally selected copy; mutation runs use the same seam.
}

_race_use() { source "$BOOT_HELPER"; }

# Configure responses at container/reindex boundaries, independently of the
# assertions under test. Every child consumes an exact expected trace.
_race_case() {
  local mode="$1" expected="$2" section="${3:-}" condition="${4:-}" occurrence="${5:-1}"
  RACE_CASE_NO=$((RACE_CASE_NO + 1))
  local out="$TMP_TEST_DIR/case-$RACE_CASE_NO-$mode" rc=0
  qmd_boot_race_extract "$out"
  python3 - "$out" "$mode" "$expected" "$section" "$condition" "$occurrence" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); mode, expected, section, condition=sys.argv[2:6]; occurrence=int(sys.argv[6])
(p/'mode').write_text(mode+'\n')
calls=['collection remove vault','collection add /vault --name vault --mask wiki/**/*.md','update','cleanup']
if mode=='remove-missing': calls=calls[1:]
if mode=='add-missing': calls=[calls[0]]+calls[2:]
if mode=='mask-wrong': calls[1]=calls[1].replace('wiki/**/*.md','**/*.md')
if mode=='cleanup-missing': calls=calls[:-1]
if mode=='add-first': calls[0],calls[1]=calls[1],calls[0]
if mode=='cleanup-first': calls=[calls[0],calls[3],calls[1],calls[2]]
if mode=='remove-twice': calls.insert(0,calls[0])
if mode=='add-twice': calls.insert(1,calls[1])
if mode=='no-migration': calls=['update','cleanup']
(p/'engine.expected').write_text('\n'.join(calls)+'\n')
trace=['inspect:pre','tick:1','read:ready','inspect:sentinel','inspect:state','tick:2','inspect:count']
if mode in ('no-index','no-setup','migrated','prior-replace','pre-status7'): trace=trace[:1]
elif mode.startswith('tick1-'): trace=trace[:2]
elif mode in ('no-log','no-migration','remove-missing'):
    trace=trace[:2]+[item for _ in range(23) for item in ('read:missing' if mode=='no-log' else 'read:ready','sleep:2')]
elif mode=='slow-log': trace=trace[:2]+['read:missing','sleep:2']+trace[2:]
elif mode in ('add-missing','mask-wrong','cleanup-missing','add-first','cleanup-first','remove-twice','add-twice'): trace=trace[:3]
elif mode in ('sentinel-missing','sentinel-status7'): trace=trace[:4]
elif mode in ('state-pending','state-status7'): trace=trace[:5]
elif mode.startswith('tick2-'): trace=trace[:6]
(p/'expected.trace').write_text('\n'.join(trace)+'\n')
if expected=='1':
    # Legacy and corrected count guards can name the same observed failure
    # differently. Preserve that distinction during the pre-fix measurement.
    text=(p/(section+'.bash')).read_text().splitlines()
    fallback={'[ "$remove_count" -eq 1 ]':'[ -n "$remove_line" ]',
              '[ "$add_count" -eq 1 ]':'[ -n "$add_line" ]',
              '[ "$mask_count" -eq 1 ]':'[ -n "$add_line" ]',
              '[ "$cleanup_line" -gt 0 ]':'[ -n "$cleanup_line" ]'}
    if not any(line.strip()==condition for line in text):
        condition=fallback.get(condition,condition)
        # [[ ]] is behaviorally equivalent on bash 5, but H14 still rejects
        # its shape. Attribute the real assertion instead of a parser error.
        if condition.startswith('[ ') and condition.endswith(' ]'):
            alias='[[ '+condition[2:-2]+' ]]'
            if any(line.strip()==alias for line in text):condition=alias
    (p/'expected.assertion').write_text(condition+'\n')
    indices=[i for i,line in enumerate(text) if line.strip()==condition]
    reader={'sentinel-status7':'.qmd-collection-wiki', 'state-status7':'jq -r .migration', 'count-status7':'grep -c'}.get(mode)
    if reader:
        # Removing an earlier status guard changes ordinals. Identify this
        # reader's own assertion, not the nth remaining status comparison.
        commands=[i for i,line in enumerate(text) if line.lstrip().startswith('run in_container')]
        starts=[i for i in commands if reader in text[i]]
        if len(starts)==1:
            start=starts[0];end=next((i for i in commands if i>start),len(text))
            indices=[i for i in indices if start<i<end]
            occurrence=1
        else:indices=[]
    if len(indices)>=occurrence:
        meta=json.loads((p/'extraction.json').read_text())
        (p/'expected.source-line').write_text(str(meta['sections'][section]['first_line']+indices[occurrence-1])+'\n')
(p/'bootstrap.bash').write_text('source "$REPO_ROOT/tests/helper-qmd-e2e-boot-race.bash"\nqmd_boot_race_fake_init\n')
PY
  qmd_boot_race_replay "$out" "$out/bootstrap.bash" "$expected" || rc=$?
  # Mutation evidence is opt-in, external and limited to synthetic code/TAP,
  # never the child's HOME or workspace state. Default host runs write none.
  if [ -n "${QMD_BOOT_RACE_ARTIFACT_DIR:-}" ]; then
    python3 - "$out" "$QMD_BOOT_RACE_ARTIFACT_DIR" "$REPO_ROOT" "${BATS_TEST_NUMBER:-0}" "${BATS_TEST_DESCRIPTION:-${BATS_TEST_NAME:-unknown}}" "$mode" "$rc" <<'PY'
import json,shutil,sys
from pathlib import Path
source,target,root=map(Path,sys.argv[1:4]); number,description,mode,rc=sys.argv[4:]
target=target.resolve();root=root.resolve()
assert target!=root and root not in target.parents, 'mutation evidence must be external'
target=target/(number+'-'+source.name);target.mkdir(parents=True)
for name in ['child.tap','child.stderr','child.exit','child.versions','child.trace','child-map.json','child.bats','result.json','expected.trace','expected.assertion','expected.source-line','extraction.json','replay.bash']:
    p=source/name
    if p.is_file():shutil.copyfile(p,target/name)
(target/'case.json').write_text(json.dumps({'test':description,'mode':mode,'validation_return':int(rc)},indent=2)+'\n')
PY
  fi
  if [ "$rc" -ne 0 ]; then
    printf '# case=%s expected=%s\n' "$mode" "$expected" >&3
    sed 's/^/# child: /' "$out/child.tap" >&3
    sed 's/^/# trace: /' "$out/child.trace" >&3
  fi
  [ "$rc" -eq 0 ]
}

teardown() {
  unset QMD_BOOT_RACE_E2E_FILE BATS_050_PARENT_ONLY
  teardown_tmp_dir
}

_h00_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

_h00_subject() {
  # Keep the nested @test header out of Bats' preprocessing of this file.
  printf '@test "%s" {\n' 'qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick' > "$H00_SUBJECT"
  cat >> "$H00_SUBJECT" <<'SUBJECT'
  # 050:fixture:begin
  :
  # 050:fixture:end
  # 050:precondition:begin
  run boot_probe pre
  [ "$status" -eq 0 ]
  [ "$output" = "healthy" ]
  # 050:precondition:end
  # 050:observe:begin
  local i=0
  while [ "$i" -lt 1 ]; do
    # 050:tick1:begin
    boot_tick
    # 050:tick1:end
    i=$((i + 1))
  done
  # 050:observe:end
  # 050:verify:begin
  run boot_probe final
  [ "$status" -eq 0 ]
  [ "$output" = "healthy" ]
  [ -z "${BATS_050_PARENT_ONLY+x}" ]
  # 050:verify:end
}
SUBJECT
  cat > "$H00_BOOTSTRAP" <<'BOOTSTRAP'
boot_probe() {
  printf 'probe:%s\n' "$1" >> "$BOOT_RACE_TRACE"
  printf 'healthy\n'
}
boot_tick() { printf 'tick\n' >> "$BOOT_RACE_TRACE"; }
BOOTSTRAP
}

# Only short replacement tokens cross argv; bodies and TAP stay in files.
_h00_mutate() {
  python3 - "$H00_SUBJECT" "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path
src, dst, old, new = sys.argv[1:]
text = Path(src).read_text()
assert text.count(old) == 1, (old, text.count(old))
Path(dst).write_text(text.replace(old, new))
PY
}

_h00_reject_extract() {
  local file="$1" reason="$2" out="$3"
  QMD_BOOT_RACE_E2E_FILE="$file" run qmd_boot_race_extract "$out"
  [ "$status" -eq 2 ]
  _h00_has "$output" "boot-race: structural:$reason"
  [ ! -f "$out/replay.bash" ]
}

@test "H00: extraction, isolated Bats replay and failure attribution reject invalid evidence" {
  # A missing implementation is a harness RED, never a migration regression.
  if [ -f "$BOOT_HELPER" ]; then source "$BOOT_HELPER"; fi
  qmd_boot_race_extract "$TMP_TEST_DIR/real"
  # The replay is the contiguous original interval, including its nested tick,
  # rather than concatenated sections that move or duplicate that tick.
  python3 - "$TMP_TEST_DIR/real" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); meta = json.loads((p/'extraction.json').read_text())
lines = Path(meta['source']).read_text().splitlines(keepends=True)
assert (p/'replay.bash').read_text() == ''.join(lines[meta['replay_first_line']-1:meta['replay_last_line']])
assert (p/'replay.bash').read_text().count('qmd_e2e_reindex_wait in_container "test 13 tick 1"') == 1
assert set(meta['sections']) == {'fixture', 'precondition', 'tick1', 'observe', 'verify'}
PY

  # Source the helper in a separate clean shell: no writes, output, directory
  # change, PATH mutation or shell-option change is allowed at load time.
  mkdir "$TMP_TEST_DIR/source-only"
  cat > "$TMP_TEST_DIR/source-probe.bash" <<'SOURCE_PROBE'
cd "$1" || exit 90
before_flags=$-
before_options=$(set +o)
before_path=$PATH
source "$2"
source_status=$?
[ "$source_status" -eq 0 ] || exit 91
[ "$before_flags" = "$-" ] || exit 93
[ "$before_options" = "$(set +o)" ] || exit 93
[ "$before_path" = "$PATH" ] || exit 94
[ "$PWD" = "$1" ] || exit 95
SOURCE_PROBE
  run env -i "PATH=$(dirname "$BASH"):/usr/bin:/bin" "HOME=$TMP_TEST_DIR/source-only" LC_ALL=C \
    "$BASH" "$TMP_TEST_DIR/source-probe.bash" "$TMP_TEST_DIR/source-only" "$BOOT_HELPER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  python3 - "$TMP_TEST_DIR/source-only" <<'PY'
import sys
from pathlib import Path
assert not list(Path(sys.argv[1]).iterdir())
PY
  cp "$BOOT_HELPER" "$TMP_TEST_DIR/source-mutant.bash"
  printf '\nPATH=/intentionally-missing-path\n' >> "$TMP_TEST_DIR/source-mutant.bash"
  run env -i "PATH=$(dirname "$BASH"):/usr/bin:/bin" "HOME=$TMP_TEST_DIR/source-only" LC_ALL=C \
    "$BASH" "$TMP_TEST_DIR/source-probe.bash" "$TMP_TEST_DIR/source-only" "$TMP_TEST_DIR/source-mutant.bash"
  [ "$status" -eq 94 ]

  _h00_subject
  _h00_reject_extract "$TMP_TEST_DIR/absent.bats" missing-file "$TMP_TEST_DIR/missing-file"
  _h00_mutate "$TMP_TEST_DIR/no-title.bats" 'qmd e2e (037): a legacy' 'different subject: a legacy'
  _h00_reject_extract "$TMP_TEST_DIR/no-title.bats" subject-count "$TMP_TEST_DIR/no-title"
  cat "$H00_SUBJECT" "$H00_SUBJECT" > "$TMP_TEST_DIR/two-subjects.bats"
  _h00_reject_extract "$TMP_TEST_DIR/two-subjects.bats" subject-count "$TMP_TEST_DIR/two-subjects"
  _h00_mutate "$TMP_TEST_DIR/missing-anchor.bats" '  # 050:verify:end' ''
  _h00_reject_extract "$TMP_TEST_DIR/missing-anchor.bats" anchor-count "$TMP_TEST_DIR/missing-anchor"
  _h00_mutate "$TMP_TEST_DIR/duplicate-anchor.bats" '  # 050:verify:end' '  # 050:verify:end
  # 050:verify:end'
  _h00_reject_extract "$TMP_TEST_DIR/duplicate-anchor.bats" anchor-count "$TMP_TEST_DIR/duplicate-anchor"
  _h00_mutate "$TMP_TEST_DIR/empty-section.bats" '    boot_tick' '    # no executable statement'
  _h00_reject_extract "$TMP_TEST_DIR/empty-section.bats" empty-section "$TMP_TEST_DIR/empty-section"
  _h00_mutate "$TMP_TEST_DIR/omitted-section.bats" '    # 050:tick1:begin
    boot_tick
    # 050:tick1:end' '    boot_tick'
  _h00_reject_extract "$TMP_TEST_DIR/omitted-section.bats" anchor-count "$TMP_TEST_DIR/omitted-section"
  _h00_mutate "$TMP_TEST_DIR/inverted.bats" '    # 050:tick1:begin
    boot_tick
    # 050:tick1:end' '    # 050:tick1:end
    boot_tick
    # 050:tick1:begin'
  _h00_reject_extract "$TMP_TEST_DIR/inverted.bats" anchor-order "$TMP_TEST_DIR/inverted"
  _h00_mutate "$TMP_TEST_DIR/crossed.bats" '    # 050:tick1:end
    i=$((i + 1))
  done
  # 050:observe:end' '    i=$((i + 1))
  done
  # 050:observe:end
    # 050:tick1:end'
  _h00_reject_extract "$TMP_TEST_DIR/crossed.bats" anchor-order "$TMP_TEST_DIR/crossed"
  _h00_mutate "$TMP_TEST_DIR/uncovered.bats" '  # 050:precondition:end' '  # 050:precondition:end
  [ 1 -eq 0 ]'
  _h00_reject_extract "$TMP_TEST_DIR/uncovered.bats" uncovered-statement "$TMP_TEST_DIR/uncovered"
  _h00_mutate "$TMP_TEST_DIR/trailing.bats" '  # 050:verify:end' '  # 050:verify:end
  [ 1 -eq 0 ]'
  _h00_reject_extract "$TMP_TEST_DIR/trailing.bats" uncovered-statement "$TMP_TEST_DIR/trailing"

  # Healthy child: same bash/Bats, clean environment, each statement runs once.
  export BATS_050_PARENT_ONLY=must-not-leak
  QMD_BOOT_RACE_E2E_FILE="$H00_SUBJECT" qmd_boot_race_extract "$TMP_TEST_DIR/healthy"
  printf 'probe:pre\ntick\nprobe:final\n' > "$TMP_TEST_DIR/healthy/expected.trace"
  qmd_boot_race_replay "$TMP_TEST_DIR/healthy" "$H00_BOOTSTRAP" 0
  [ "$(jq -r .classification "$TMP_TEST_DIR/healthy/result.json")" = healthy ]

  # A real assertion RED is valid only at the expected line and trace prefix.
  _h00_mutate "$TMP_TEST_DIR/assertion.bats" '  run boot_probe pre' '  run boot_probe pre
  [ "$output" = "injected-bad-value" ]'
  QMD_BOOT_RACE_E2E_FILE="$TMP_TEST_DIR/assertion.bats" qmd_boot_race_extract "$TMP_TEST_DIR/assertion"
  printf 'probe:pre\n' > "$TMP_TEST_DIR/assertion/expected.trace"
  printf '%s\n' '[ "$output" = "injected-bad-value" ]' > "$TMP_TEST_DIR/assertion/expected.assertion"
  qmd_boot_race_replay "$TMP_TEST_DIR/assertion" "$H00_BOOTSTRAP" 1
  [ "$(jq -r .classification "$TMP_TEST_DIR/assertion/result.json")" = assertion ]
  # The same RED attributed to a different condition must be rejected.
  printf '%s\n' '[ "$status" -eq 0 ]' > "$TMP_TEST_DIR/assertion/expected.assertion"
  run qmd_boot_race_validate "$TMP_TEST_DIR/assertion" 1
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:assertion-location'

  # Real skipped child, not a fabricated successful TAP.
  _h00_mutate "$TMP_TEST_DIR/skipped.bats" '  run boot_probe pre' '  skip "injected skip"
  run boot_probe pre'
  QMD_BOOT_RACE_E2E_FILE="$TMP_TEST_DIR/skipped.bats" qmd_boot_race_extract "$TMP_TEST_DIR/skipped"
  cp "$TMP_TEST_DIR/healthy/expected.trace" "$TMP_TEST_DIR/skipped/expected.trace"
  run qmd_boot_race_replay "$TMP_TEST_DIR/skipped" "$H00_BOOTSTRAP" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:skip-result'

  # Corrupt saved evidence independently: empty TAP, extra result, wrong
  # interpreter/version and unexpected exit all fail their own guard.
  cp "$TMP_TEST_DIR/healthy/child.tap" "$TMP_TEST_DIR/saved.tap"
  : > "$TMP_TEST_DIR/healthy/child.tap"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:tap-plan'
  cp "$TMP_TEST_DIR/saved.tap" "$TMP_TEST_DIR/healthy/child.tap"
  printf 'ok 2 unexpected\n' >> "$TMP_TEST_DIR/healthy/child.tap"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:tap-result'
  cp "$TMP_TEST_DIR/saved.tap" "$TMP_TEST_DIR/healthy/child.tap"
  cp "$TMP_TEST_DIR/healthy/child.versions" "$TMP_TEST_DIR/saved.versions"
  printf 'different-bash\n%s\n' "$BATS_VERSION" > "$TMP_TEST_DIR/healthy/child.versions"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:interpreter'
  printf '%s\ndifferent-bats\n' "$BASH_VERSION" > "$TMP_TEST_DIR/healthy/child.versions"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:bats-version'
  cp "$TMP_TEST_DIR/saved.versions" "$TMP_TEST_DIR/healthy/child.versions"
  printf '7\n' > "$TMP_TEST_DIR/healthy/child.exit"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:exit-status'
  printf '0\n' > "$TMP_TEST_DIR/healthy/child.exit"
  printf 'unexpected-call\n' >> "$TMP_TEST_DIR/healthy/child.trace"
  run qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:fake-trace'
  cp "$TMP_TEST_DIR/healthy/expected.trace" "$TMP_TEST_DIR/healthy/child.trace"
  qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0

  # A command missing from the child and an incomplete fake cannot masquerade
  # as the intended assertion, even if their line is declared as expected.
  _h00_mutate "$TMP_TEST_DIR/missing-command.bats" '    boot_tick' '    boot_050_missing_command'
  QMD_BOOT_RACE_E2E_FILE="$TMP_TEST_DIR/missing-command.bats" qmd_boot_race_extract "$TMP_TEST_DIR/missing-command"
  printf 'probe:pre\n' > "$TMP_TEST_DIR/missing-command/expected.trace"
  printf 'boot_050_missing_command\n' > "$TMP_TEST_DIR/missing-command/expected.assertion"
  run qmd_boot_race_replay "$TMP_TEST_DIR/missing-command" "$H00_BOOTSTRAP" 1
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:child-error'
  QMD_BOOT_RACE_E2E_FILE="$H00_SUBJECT" qmd_boot_race_extract "$TMP_TEST_DIR/incomplete-fake"
  cp "$H00_BOOTSTRAP" "$TMP_TEST_DIR/incomplete.bash"
  cat >> "$TMP_TEST_DIR/incomplete.bash" <<'INCOMPLETE'
boot_tick() { echo 'BOOT_RACE_FAKE_ERROR: no response for tick' >&2; return 98; }
INCOMPLETE
  printf 'probe:pre\n' > "$TMP_TEST_DIR/incomplete-fake/expected.trace"
  printf 'boot_tick\n' > "$TMP_TEST_DIR/incomplete-fake/expected.assertion"
  run qmd_boot_race_replay "$TMP_TEST_DIR/incomplete-fake" "$TMP_TEST_DIR/incomplete.bash" 1
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:child-error'

  # A child that fails during setup is infrastructure, not a body assertion.
  QMD_BOOT_RACE_E2E_FILE="$H00_SUBJECT" qmd_boot_race_extract "$TMP_TEST_DIR/setup-error"
  cp "$H00_BOOTSTRAP" "$TMP_TEST_DIR/setup-error.bash"
  printf 'return 19\n' >> "$TMP_TEST_DIR/setup-error.bash"
  printf 'probe:pre\n' > "$TMP_TEST_DIR/setup-error/expected.trace"
  printf 'boot_tick\n' > "$TMP_TEST_DIR/setup-error/expected.assertion"
  run qmd_boot_race_replay "$TMP_TEST_DIR/setup-error" "$TMP_TEST_DIR/setup-error.bash" 1
  [ "$status" -eq 2 ]
  _h00_has "$output" 'boot-race: harness:assertion-location'
  [ "$(jq -r .classification "$TMP_TEST_DIR/setup-error/result.json")" = harness-error ]
  qmd_boot_race_validate "$TMP_TEST_DIR/healthy" 0
}

@test "H01: the actual pre-boot fixture has completed setup, pending migration, seeded wiki and impossible cron" {
  _race_use
  qmd_boot_race_extract "$TMP_TEST_DIR/fixture"
  # Plain source in the Bats test, never a conditional function or run wrapper.
  source "$TMP_TEST_DIR/fixture/fixture.bash"
  [ -f "$D2/.state/.cache/qmd/index.sqlite" ]
  [ -f "$D2/.state/.cache/qmd/.qmd-setup-ok" ]
  [ ! -e "$D2/.state/.cache/qmd/.qmd-collection-wiki" ]
  [ "$(yq -r .vault.qmd.schedule "$D2/agent.yml")" = '0 0 31 2 *' ]
  python3 - "$D2" "$TMP_TEST_DIR/fixture/extraction.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);m=json.loads(Path(sys.argv[2]).read_text())
assert list((p/'.state/.vault/wiki').rglob('*.md')), 'wiki was not seeded before boot'
text=Path(m['source']).read_text().splitlines()
up=[i+1 for i,line in enumerate(text) if '(cd "$D2" && docker compose up -d)' in line]
assert len(up)==1 and m['sections']['fixture']['last_line']<up[0]
PY
  export QMD_CACHE_HOME="$D2/.state/.cache/qmd" VAULT_ROOT_OVERRIDE="$D2/.state/.vault"
  export PATH="$(install_bun_stub "$TMP_TEST_DIR/h01bin"):$PATH"
  _qmd_run() { printf 'unexpected engine invocation\n' >> "$TMP_TEST_DIR/engine-unexpected"; return 99; }
  [ "$(qmd_collection_migration_state)" = pending ]
  run qmd_setup_if_needed "$D2/agent.yml"
  [ "$status" -eq 0 ]
  _h00_has "$output" 'setup: already done'
  [ ! -e "$TMP_TEST_DIR/engine-unexpected" ]
  [ "$(qmd_collection_migration_state)" = pending ]
}

@test "H02: precondition rejects absent index/setup, migrated collection and a previous replace" {
  _race_use
  _race_case healthy 0
  local mode
  for mode in no-index no-setup migrated prior-replace; do
    _race_case "$mode" 1 precondition '[ "$output" = "LEGACY_PENDING" ]'
  done
}

@test "H03: correct precondition text with inspection status 7 fails" {
  _race_use
  _race_case healthy 0
  _race_case pre-status7 1 precondition '[ "$status" -eq 0 ]'
}

@test "H04: first tick requires helper return and REINDEX_STATUS independently" {
  _race_use
  _race_case healthy 0
  _race_case tick1-rc1 1 tick1 false 1
  _race_case tick1-rc3 1 tick1 false 1
  _race_case tick1-status7 1 tick1 false 2
}

@test "H05: delayed log after a 100-second tick retains 45 seconds of observation and one first tick" {
  _race_use
  _race_case healthy 0
  _race_case slow-log 0
}

@test "H06: missing log or omitted migration expires without relaunching the first tick" {
  _race_use
  _race_case healthy 0
  _race_case no-log 1 verify '[ "$remove_count" -eq 1 ]'
  _race_case no-migration 1 verify '[ "$remove_count" -eq 1 ]'
}

@test "H07: healthy migration and idempotent second tick pass the complete real replay" {
  _race_use
  _race_case healthy 0
}

@test "H08: missing remove, add, wiki mask or cleanup fails its own condition" {
  _race_use
  _race_case healthy 0
  _race_case remove-missing 1 verify '[ "$remove_count" -eq 1 ]'
  _race_case add-missing 1 verify '[ "$add_count" -eq 1 ]'
  _race_case mask-wrong 1 verify '[ "$mask_count" -eq 1 ]'
  _race_case cleanup-missing 1 verify '[ "$cleanup_line" -gt 0 ]'
}

@test "H09: unordered or duplicated collection operations fail" {
  _race_use
  _race_case healthy 0
  _race_case add-first 1 verify '[ "$remove_line" -lt "$add_line" ]'
  _race_case cleanup-first 1 verify '[ "$add_line" -lt "$cleanup_line" ]'
  _race_case remove-twice 1 verify '[ "$remove_count" -eq 1 ]'
  _race_case add-twice 1 verify '[ "$add_count" -eq 1 ]'
}

@test "H10: absent confirmation fails despite done state, and valid text with status 7 fails" {
  _race_use
  _race_case healthy 0
  _race_case sentinel-missing 1 verify '[ "$output" = "HAVE_SENTINEL" ]'
  _race_case sentinel-status7 1 verify '[ "$status" -eq 0 ]' 1
}

@test "H11: pending final state or done text with inspection status 7 fails" {
  _race_use
  _race_case healthy 0
  _race_case state-pending 1 verify '[ "$output" = "done" ]'
  _race_case state-status7 1 verify '[ "$status" -eq 0 ]' 2
}

@test "H12: second tick helper return, REINDEX_STATUS and count inspection must succeed" {
  _race_use
  _race_case healthy 0
  _race_case tick2-rc1 1 verify '[ "$rc2" -eq 0 ]'
  _race_case tick2-rc3 1 verify '[ "$rc2" -eq 0 ]'
  _race_case tick2-status7 1 verify '[ "$REINDEX_STATUS" -eq 0 ]'
  _race_case count-status7 1 verify '[ "$status" -eq 0 ]' 3
}

@test "H13: a repeated collection replacement in the second tick fails idempotence" {
  _race_use
  _race_case healthy 0
  _race_case repeated 1 verify '[ "$output" = "$calls_before" ]'
}

@test "H14: actual wiring preserves budgets, direct assertions and a first tick before observation" {
  _race_use
  qmd_boot_race_extract "$TMP_TEST_DIR/wiring"
  python3 - "$TMP_TEST_DIR/wiring" "$REPO_ROOT" <<'PY'
import json,re,sys
from pathlib import Path
p,root=map(Path,sys.argv[1:]); m=json.loads((p/'extraction.json').read_text())
code='\n'.join(line for line in (p/'replay.bash').read_text().splitlines() if not line.lstrip().startswith('#'))
assert '[[' not in code and not re.search(r'^\s*!\s',code,re.M), 'inactive intermediate assertion'
assert m['sections']['tick1']['last_line']<m['sections']['observe']['first_line'], 'tick 1 is inside observation'
assert '+ 45 ))' in code and 'sleep 2' in code
assert code.count('qmd_e2e_reindex_wait in_container')==2 and 'heartbeatctl qmd-reindex' not in code
assert '|| true)' in code and 'schedule: "0 0 31 2 *"' in (p/'fixture.bash').read_text()
helper=(root/'tests/helper-qmd-e2e.bash').read_text()
assert 'timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex' in helper
assert 'w=120' in helper and 'QMD_E2E_LOCK_CADENCE_S=2' in helper
b2=(root/'tests/qmd-e2e-lock.bats').read_text()
assert 'tick 1 and both guards precede the observation loop' in b2
PY
}
