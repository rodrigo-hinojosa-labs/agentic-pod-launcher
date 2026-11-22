#!/usr/bin/env bats
#
# 048: the backups of an agent with an associated repository live in
# `.agent-backup/<unit>/` of its main branch.
#
# Contracts: specs/048-fleet-backup-main/contracts/main-backup.md (M1 to M3, I1 to
# I8). Rules (tasks.md of 048): no intermediate [[ ]] or !; a negative is written
# `if cmd; then false; fi`; the messages asserted are the ones of M1.

load helper
load helper-backup-repo

setup_file() {
  br_require || return 1
  br_start_server
}

teardown_file() { br_stop_server; }

setup() {
  br_require
  br_tools_path
  br_sentinels
  br_server_token "$BR_TOKEN"
  br_server_mode
  unset BR_PAT BR_VAULT_DIR
  # The library, sourced as heartbeatctl does.
  # shellcheck source=/dev/null
  source "$BR_LIB_DIR/backup_dest.sh"
  # shellcheck source=/dev/null
  source "$BR_LIB_DIR/backup_main.sh"
  export GITHUB_PAT="$BR_TOKEN"
  export BACKUP_ASKPASS_OVERRIDE="$REPO_ROOT/docker/scripts/git-askpass-agent.sh"
  export BACKUP_MAIN_RETRY_SLEEP=0
}

# _tm_unit_cache DIR FILE CONTENT...: a unit's own cache (a plain git repo) with one
# commit whose tree is the unit content; stdout: that tree id.
_tm_unit_cache() {
  local dir="$1"
  shift
  rm -rf "$dir"
  _br_git init -q "$dir"
  while [ $# -ge 2 ]; do
    mkdir -p "$(dirname "$dir/$1")"
    printf '%s\n' "$2" > "$dir/$1"
    shift 2
  done
  _br_git -C "$dir" add -A
  _br_git -C "$dir" commit -q -m unit
  _br_git -C "$dir" rev-parse 'HEAD^{tree}'
}

_tm_mark() { printf '{"schema":1,"agent":"%s","unit":"%s"}' "$1" "$2"; }

# ── Shared pieces (T007) ────────────────────────────────────────────────────

@test "TM01 backup_main_tree: the subtree of .agent-backup/<u> in main, or nothing" {
  local url ucache pub tree
  url=$(br_new_repo tm01)
  br_seed_work tm01
  ucache="$BATS_TEST_TMPDIR/u-vault"
  _tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md "v1" > /dev/null
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  [ -z "$(backup_main_tree "$pub" vault)" ]
}

@test "TM02 backup_main_owner: new, ok, foreign and other-agent" {
  local url ucache pub tree commit
  url=$(br_new_repo tm02)
  ucache="$BATS_TEST_TMPDIR/u"
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  [ "$(backup_main_owner "$pub" vault bot)" = "new" ]

  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md v1)
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  commit=$(backup_main_build_commit "$pub" vault bot "$tree")
  backup_main_push "$pub" "$commit"
  backup_main_fetch "$pub" > /dev/null
  [ "$(backup_main_owner "$pub" vault bot)" = "ok" ]
  [ "$(backup_main_owner "$pub" vault otherbot)" = "other-agent" ]

  tree=$(_tm_unit_cache "$ucache" a.md "no mark")
  commit=$(backup_main_build_commit "$pub" vault bot "$tree")
  backup_main_push "$pub" "$commit"
  backup_main_fetch "$pub" > /dev/null
  [ "$(backup_main_owner "$pub" vault bot)" = "foreign" ]
}

@test "TM03 backup_main_build_commit: only .agent-backup/<u> changes, with the launcher author, subject and trailer" {
  local url ucache pub tree commit bare files
  url=$(br_new_repo tm03)
  br_seed_work tm03
  ucache="$BATS_TEST_TMPDIR/u"
  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md v1)
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  commit=$(backup_main_build_commit "$pub" vault bot "$tree")
  backup_main_push "$pub" "$commit"
  bare=$(br_bare tm03)
  files=$(_br_git -C "$bare" diff --name-only main~1 main | paste -sd, -)
  [ "$files" = ".agent-backup/vault/.agentic-pod-backup.json,.agent-backup/vault/a.md" ]
  [ "$(_br_git -C "$bare" log -1 --format='%an <%ae>|%cn <%ce>' main)" = "agentic-pod-backup <backup@agentic-pod.invalid>|agentic-pod-backup <backup@agentic-pod.invalid>" ]
  _br_git -C "$bare" log -1 --format=%s main | grep -qE '^backup\(vault\): bot [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z \[skip ci\]$'
  _br_git -C "$bare" log -1 --format=%B main | grep -qx 'Agentic-Pod-Backup: bot/vault'
  # The work files are untouched.
  [ "$(br_main_show tm03 README-work.md)" = "work notes" ]
  [ "$(br_main_show tm03 src/app.txt)" = "app" ]
}

@test "TM04 the same unit tree rebuilt on a new tip keeps the subtree and changes only the parent" {
  local url ucache pub tree c1 c2 bare
  url=$(br_new_repo tm04)
  ucache="$BATS_TEST_TMPDIR/u"
  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md v1)
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  c1=$(backup_main_build_commit "$pub" vault bot "$tree")
  br_seed_work tm04
  backup_main_fetch "$pub" > /dev/null
  c2=$(backup_main_build_commit "$pub" vault bot "$tree")
  [ "$c1" != "$c2" ]
  [ "$(_br_git -C "$pub" rev-parse "$c1:.agent-backup/vault")" = "$tree" ]
  [ "$(_br_git -C "$pub" rev-parse "$c2:.agent-backup/vault")" = "$tree" ]
  [ "$(_br_git -C "$pub" rev-parse "$c2^")" = "$(_br_git -C "$pub" rev-parse refs/remotes/origin/main)" ]
}

@test "TM04b building and pushing in the blob:none clone asks the server for no blob of another unit (I8)" {
  local url ucache pub tree commit before after
  url=$(br_new_repo tm04b)
  # Another unit's large file already in main.
  ucache="$BATS_TEST_TMPDIR/u-mem"
  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot memory)" big.bin \
           "$(head -c 200000 /dev/urandom | od -An -tx1 | tr -d ' \n')")
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" memory "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  backup_main_push "$pub" "$(backup_main_build_commit "$pub" memory bot "$tree")"
  # Now the vault unit publishes from a fresh clone of its own.
  ucache="$BATS_TEST_TMPDIR/u-vault"
  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md v1)
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  # From here on, building and pushing must not ask the server for anything to
  # read (no upload-pack request: a lazy fetch of a missing blob is one).
  before=$(br_log_count 'git-upload-pack')
  backup_main_push "$pub" "$(backup_main_build_commit "$pub" vault bot "$tree")"
  after=$(br_log_count 'git-upload-pack')
  [ "$after" -eq "$before" ]
  # And the memory unit's blob never reached this clone's object store.
  local blob
  blob=$(_br_git -C "$(br_bare tm04b)" rev-parse "main:.agent-backup/memory/big.bin")
  if GIT_NO_LAZY_FETCH=1 _br_git -C "$pub" cat-file -e "$blob" 2> /dev/null; then false; fi
}

@test "TM04c backup_main_push: a moved main is 3, a protected main is 4, and nothing is forced" {
  local url ucache pub tree commit
  url=$(br_new_repo tm04c)
  ucache="$BATS_TEST_TMPDIR/u"
  tree=$(_tm_unit_cache "$ucache" .agentic-pod-backup.json "$(_tm_mark bot vault)" a.md v1)
  pub=$(backup_main_prepare "$BATS_TEST_TMPDIR/base" vault "$url" "$ucache")
  backup_main_fetch "$pub" > /dev/null
  commit=$(backup_main_build_commit "$pub" vault bot "$tree")
  br_seed_work tm04c
  local rc=0
  backup_main_push "$pub" "$commit" || rc=$?
  [ "$rc" -eq 3 ]
  backup_main_fetch "$pub" > /dev/null
  commit=$(backup_main_build_commit "$pub" vault bot "$tree")
  br_server_mode protected-main
  rc=0
  backup_main_push "$pub" "$commit" || rc=$?
  [ "$rc" -eq 4 ]
  br_server_mode
  [ "$(br_force_count tm04c)" -eq 0 ]
}

# ── US1: the five units write .agent-backup/<u>/ of main (T009) ─────────────

# _tm_ws NAME: a workspace with the operator key, associated with a new repository
# that already has work on main. Exports TM_URL.
_tm_ws() {
  br_keys
  br_workspace
  TM_URL=$(br_new_repo "$1")
  br_seed_work "$1"
  br_set_repo "$TM_URL"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
}

_tm_all_units() {
  local u
  for u in config identity vault memory history; do
    br_unit "$u" || return 1
  done
}

@test "TM05 first cycle: each unit adds only .agent-backup/<u>/ with its mark, the work stays" {
  _tm_ws tm05
  local before u line
  before=$(_br_git -C "$(br_bare tm05)" rev-parse main)
  for u in identity vault memory history; do
    run br_unit "$u"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "^backup-$u: [0-9a-f]{8} pushed"
    [ -n "$(br_main_tree tm05 "$u")" ]
    br_main_show tm05 ".agent-backup/$u/.agentic-pod-backup.json" | jq -e --arg u "$u" '.agent == "repo-bot" and .unit == $u'
  done
  # I1: every commit after the work commits touches one unit directory only.
  while read -r sha paths; do
    [ "$sha" = "$before" ] && break
    _tm_one_unit_only "$paths"
  done < <(br_main_commits tm05)
  [ "$(br_main_show tm05 README-work.md)" = "work notes" ]
  br_is_ancestor tm05 "$before"
}

@test "TM06 config writes .agent-backup/README.md and is the only unit that touches it" {
  _tm_ws tm06
  br_unit vault
  if br_main_show tm06 .agent-backup/README.md > /dev/null 2>&1; then false; fi
  run br_unit config
  [ "$status" -eq 0 ]
  br_main_show tm06 .agent-backup/README.md | grep -q 'agent `repo-bot`'
  _br_git -C "$(br_bare tm06)" diff --name-only main~1 main | grep -qx '.agent-backup/README.md'
}

@test "TM07 a second cycle without changes creates no commit in any unit (I4, SC-004)" {
  _tm_ws tm07
  _tm_all_units > /dev/null
  local n1 u
  n1=$(_br_git -C "$(br_bare tm07)" rev-list --count main)
  for u in config identity vault memory history; do
    run br_unit "$u"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^backup-$u: no changes since last backup"
  done
  [ "$(_br_git -C "$(br_bare tm07)" rev-list --count main)" -eq "$n1" ]
}

@test "TM07b a commit of someone else on main does not make the next cycle a change" {
  _tm_ws tm07b
  br_unit vault > /dev/null
  br_seed_work tm07b
  run br_unit vault
  echo "$output" | grep -q '^backup-vault: no changes since last backup'
}

@test "TM08 a file deleted from the agent disappears from its directory and nothing outside changes" {
  _tm_ws tm08
  printf '# Two\n' > "$BR_WS/.state/.vault/wiki/concepts/two.md"
  br_unit vault > /dev/null
  br_main_files tm08 vault | grep -q 'two.md'
  rm "$BR_WS/.state/.vault/wiki/concepts/two.md"
  run br_unit vault
  echo "$output" | grep -q 'pushed'
  if br_main_files tm08 vault | grep -q 'two.md'; then false; fi
  [ "$(br_main_show tm08 README-work.md)" = "work notes" ]
}

@test "TM09 a sensitive agent: nothing 046 encrypts appears in plaintext under .agent-backup/ (I5)" {
  _tm_ws tm09
  yq -i '.backup.sensitive = true' "$BR_WS/agent.yml"
  _tm_all_units > /dev/null
  local bare s
  bare=$(br_bare tm09)
  for s in "$BR_SENT_SECRETS" "$BR_SENT_VAULT" "$BR_SENT_PERSONA" "$BR_SENT_AUTOMEM" \
           "$BR_SENT_CLAUDEMEM" "$BR_SENT_HISTORY" "$BR_SENT_EXTRA"; do
    if _br_git -C "$bare" grep -a -q -F -e "$s" main -- .agent-backup 2> /dev/null; then
      echo "plaintext sentinel in main: $s" >&2
      false
    fi
  done
  br_main_files tm09 vault | grep -q '^.agent-backup/vault/store/'
}

@test "TM10 a public repository is refused: not-private, and main does not change" {
  _tm_ws tm10
  local before
  before=$(_br_git -C "$(br_bare tm10)" rev-parse main)
  br_server_mode anon-read
  run br_unit vault
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'the repository is public - refusing to push'
  [ "$(_br_git -C "$(br_bare tm10)" rev-parse main)" = "$before" ]
}

@test "TM11 a repository without main: no-main, exit 0, nothing written" {
  br_keys
  br_workspace
  TM_URL=$(br_new_repo tm11 --empty)
  br_set_repo "$TM_URL"
  run br_unit vault
  [ "$status" -eq 0 ]
  [ "$output" = "backup-vault: the repository has no main branch - nothing pushed" ]
  [ "$(br_state vault last_result)" = "no-main" ]
}

@test "TM12 the credential never appears in argv, in the remote URL or in a cache config (I7)" {
  _tm_ws tm12
  br_argv_spy
  _tm_all_units > /dev/null
  if grep -qF "$BR_TOKEN" "$BR_ARGV_LOG"; then false; fi
  if grep -rqF "$BR_TOKEN" "$BR_CACHE" 2> /dev/null; then false; fi
}

@test "TM13 the state records location main and the tree that main holds" {
  _tm_ws tm13
  br_unit memory > /dev/null
  [ "$(br_state memory location)" = "main" ]
  [ "$(br_state memory last_tree)" = "$(br_main_tree tm13 memory)" ]
}

@test "TM20 an .agent-backup/<u>/ in main without a mark is not written: foreign-dir (FR-013)" {
  _tm_ws tm20
  local seed before
  seed="$BATS_TEST_TMPDIR/seed20"
  _br_git clone -q "$(br_bare tm20)" "$seed"
  mkdir -p "$seed/.agent-backup/vault"
  printf 'someone else\n' > "$seed/.agent-backup/vault/x.md"
  _br_git -C "$seed" add -A && _br_git -C "$seed" commit -q -m intruder && _br_git -C "$seed" push -q origin HEAD:main
  before=$(_br_git -C "$(br_bare tm20)" rev-parse main)
  run br_unit vault
  [ "$status" -eq 0 ]
  [ "$output" = "backup-vault: .agent-backup/vault exists in main and is not a launcher backup - refusing to write" ]
  [ "$(_br_git -C "$(br_bare tm20)" rev-parse main)" = "$before" ]
}

@test "TM21 an .agent-backup/<u>/ in main marked by another agent is not written: other-agent" {
  _tm_ws tm21
  local seed before
  seed="$BATS_TEST_TMPDIR/seed21"
  _br_git clone -q "$(br_bare tm21)" "$seed"
  mkdir -p "$seed/.agent-backup/vault"
  printf '{"schema":1,"agent":"other-bot","unit":"vault"}\n' > "$seed/.agent-backup/vault/.agentic-pod-backup.json"
  _br_git -C "$seed" add -A && _br_git -C "$seed" commit -q -m other && _br_git -C "$seed" push -q origin HEAD:main
  before=$(_br_git -C "$(br_bare tm21)" rev-parse main)
  run br_unit vault
  [ "$status" -eq 0 ]
  [ "$output" = "backup-vault: .agent-backup/vault in main belongs to another agent - refusing to write" ]
  [ "$(_br_git -C "$(br_bare tm21)" rev-parse main)" = "$before" ]
  [ "$(br_state vault last_result)" = "other-agent" ]
}

# ── US2: living with the work on main (T017) ────────────────────────────────

# _tm_launcher_commits NAME: the launcher's commits of main, one "<sha> <paths>" each.
_tm_launcher_commits() {
  local bare sha
  bare=$(br_bare "$1")
  for sha in $(_br_git -C "$bare" rev-list --author='agentic-pod-backup' refs/heads/main); do
    printf '%s %s\n' "$sha" "$(_br_git -C "$bare" diff-tree --no-commit-id --name-only -r "$sha" | paste -sd, -)"
  done
}

# _tm_one_unit_only PATHS: rc 0 when every path is under one .agent-backup/<u>/ (the
# config unit may also carry .agent-backup/README.md).
_tm_one_unit_only() {
  local n
  n=$(printf '%s\n' "$1" | tr ',' '\n' | grep -v '^\.agent-backup/README\.md$' \
        | sed -nE 's#^\.agent-backup/([^/]+)/.*#\1#p' | sort -u | wc -l | tr -d ' ')
  [ "$n" = "1" ] || return 1
  if printf '%s\n' "$1" | tr ',' '\n' | grep -vqE '^\.agent-backup/'; then return 1; fi
  return 0
}

@test "TM14 main moved by someone else during the push: the unit rebuilds, pushes, and the foreign commit stays (I3)" {
  _tm_ws tm14
  br_server_mode inject-once
  run br_unit vault
  br_server_mode
  [ "$status" -eq 0 ]
  grep -qE '^backup-vault: [0-9a-f]{8} pushed$' <<< "$output"
  local foreign
  foreign=$(grep -E '^inject tm14\.git ' "$BR_SRV_LOG" | awk '{print $3}')
  [ -n "$foreign" ]
  br_is_ancestor tm14 "$foreign"
  [ -n "$(br_main_tree tm14 vault)" ]
  [ "$(br_force_count tm14)" -eq 0 ]
}

@test "TM15 25 cycles with a foreign commit in every push: none lost, none forced, none outside its directory (SC-001, SC-002)" {
  _tm_ws tm15
  local i u
  for i in $(seq 1 25); do
    if [ $((i % 2)) -eq 0 ]; then
      u=vault
      printf '# Cycle %s\n' "$i" > "$BR_WS/.state/.vault/wiki/concepts/cycle.md"
    else
      u=config
      yq -i ".agent.vibe = \"cycle $i\"" "$BR_WS/agent.yml"
    fi
    br_server_mode inject-once
    br_unit "$u" > /dev/null
  done
  br_server_mode
  local injected sha paths
  injected=$(grep -cE '^inject tm15\.git ' "$BR_SRV_LOG")
  [ "$injected" -eq 25 ]
  for sha in $(grep -E '^inject tm15\.git ' "$BR_SRV_LOG" | awk '{print $3}'); do
    br_is_ancestor tm15 "$sha"
  done
  [ "$(br_force_count tm15)" -eq 0 ]
  [ "$(_tm_launcher_commits tm15 | wc -l | tr -d ' ')" -ge 25 ]
  while read -r sha paths; do
    _tm_one_unit_only "$paths"
  done < <(_tm_launcher_commits tm15)
}

@test "TM16 two units pushing at the same time both end in main" {
  _tm_ws tm16
  local p1 p2 rc1=0 rc2=0
  br_unit vault > "$BATS_TEST_TMPDIR/v.out" 2>&1 3>&- 4>&- &
  p1=$!
  br_unit config > "$BATS_TEST_TMPDIR/c.out" 2>&1 3>&- 4>&- &
  p2=$!
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]
  [ -n "$(br_main_tree tm16 vault)" ]
  [ -n "$(br_main_tree tm16 config)" ]
  [ "$(br_force_count tm16)" -eq 0 ]
}

@test "TM17 main keeps moving through every attempt: main-busy, exit 2, the attempt recorded" {
  _tm_ws tm17
  local before
  br_server_mode inject-once inject-once inject-once inject-once inject-once inject-once
  run br_unit vault
  br_server_mode
  [ "$status" -eq 2 ]
  [ "$output" = "backup-vault: main kept moving - nothing pushed, retrying next cycle" ]
  [ "$(br_state vault last_result)" = "main-busy" ]
  [ -z "$(br_main_tree tm17 vault)" ]
  # The next cycle, without anyone pushing, works.
  run br_unit vault
  [ "$status" -eq 0 ]
  [ -n "$(br_main_tree tm17 vault)" ]
}

@test "TM18 a foreign change inside .agent-backup/vault/ is overwritten and said on stderr (FR-008)" {
  _tm_ws tm18
  br_unit vault > /dev/null
  local good seed
  good=$(br_main_tree tm18 vault)
  seed="$BATS_TEST_TMPDIR/seed18"
  _br_git clone -q "$(br_bare tm18)" "$seed"
  printf 'tampered\n' >> "$seed/.agent-backup/vault/wiki/concepts/page.md"
  _br_git -C "$seed" add -A && _br_git -C "$seed" commit -q -m tamper && _br_git -C "$seed" push -q origin HEAD:main
  run br_unit vault
  [ "$status" -eq 0 ]
  grep -qF 'backup-vault: .agent-backup/vault in main was changed outside the launcher - restoring it' <<< "$output"
  [ "$(br_main_tree tm18 vault)" = "$good" ]
}

@test "TM19 every backup commit asks CI not to run: its subject ends in [skip ci]" {
  _tm_ws tm19
  _tm_all_units > /dev/null
  local n
  n=$(_br_git -C "$(br_bare tm19)" log --author='agentic-pod-backup' --format=%s main | grep -vc '\[skip ci\]$' || true)
  [ "$n" -eq 0 ]
  [ "$(_br_git -C "$(br_bare tm19)" log --author='agentic-pod-backup' --format=%s main | wc -l | tr -d ' ')" -ge 5 ]
}

@test "TM22 a work branch opened before several backup cycles shows no .agent-backup/ path in its PR diff" {
  _tm_ws tm22
  local seed
  seed="$BATS_TEST_TMPDIR/seed22"
  _br_git clone -q "$(br_bare tm22)" "$seed"
  _br_git -C "$seed" checkout -q -b 003-feature
  printf 'feature\n' > "$seed/feature.txt"
  _br_git -C "$seed" add -A && _br_git -C "$seed" commit -q -m feature && _br_git -C "$seed" push -q origin 003-feature
  _tm_all_units > /dev/null
  printf '# Again\n' > "$BR_WS/.state/.vault/wiki/concepts/again.md"
  br_unit vault > /dev/null
  [ "$(_br_git -C "$(br_bare tm22)" diff --name-only main...003-feature)" = "feature.txt" ]
}

@test "TM23 the unit's local cache keeps one commit: it never accumulates past stores" {
  _tm_ws tm23
  local i
  for i in 1 2 3; do
    printf '# Cycle %s\n' "$i" > "$BR_WS/.state/.vault/wiki/concepts/cycle.md"
    br_unit vault > /dev/null
  done
  [ "$(GIT_CONFIG_GLOBAL=/dev/null git -C "$BR_CACHE/agent-backup/vault-repo" rev-list --count HEAD)" = "1" ]
  [ "$(_br_git -C "$(br_bare tm23)" rev-list --count main -- .agent-backup/vault)" -ge 3 ]
}

@test "TM24 no push to main can force: the code has no --force, no + refspec and no delete of main (I2)" {
  local f
  for f in "$BR_LIB_DIR/backup_main.sh" "$BR_LIB_DIR/backup_pr.sh"; do
    if grep -nE 'push[^#]*(--force([^-]|$)|-f([[:space:]]|$)|[[:space:]]"?\+)' "$f"; then false; fi
    if grep -nE 'push[^#]*:refs/heads/main' "$f" | grep -vF '$commit:refs/heads/main'; then false; fi
  done
  grep -qF 'push -q origin "$commit:refs/heads/main"' "$BR_LIB_DIR/backup_main.sh"
}
