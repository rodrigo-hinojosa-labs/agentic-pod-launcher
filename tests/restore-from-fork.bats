#!/usr/bin/env bats
load 'helper'

setup() {
  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  BARE="$BATS_TEST_TMPDIR/fork.git"
  git init --bare --initial-branch=main "$BARE" >/dev/null 2>&1

  WORK="$BATS_TEST_TMPDIR/seed"
  git clone "$BARE" "$WORK" >/dev/null 2>&1
  (cd "$WORK" \
    && git config user.email "t@t" && git config user.name t \
    && git switch --orphan backup/identity \
    && mkdir -p .claude/channels/telegram .claude/plugins/config \
    && echo '{"v":1}' > .claude.json \
    && echo '{"permissions":{"defaultMode":"auto"}}' > .claude/settings.json \
    && echo '{"allowFrom":["987"]}' > .claude/channels/telegram/access.json \
    && git add -A \
    && git commit -m "seed" >/dev/null 2>&1 \
    && git push origin backup/identity >/dev/null 2>&1)

  DEST="$BATS_TEST_TMPDIR/agent"
  mkdir -p "$DEST/.state"
  cat > "$DEST/agent.yml" <<YAML
agent:
  name: testagent
scaffold:
  fork:
    url: $BARE
backup:
  identity:
    recipient: null
YAML
}

@test "restore_from_fork populates .state with whitelist" {
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run restore_from_fork "$BARE" "$DEST"
  [ "$status" -eq 0 ]

  [ -f "$DEST/.state/.claude.json" ]
  [ -f "$DEST/.state/.claude/settings.json" ]
  [ -f "$DEST/.state/.claude/channels/telegram/access.json" ]
  run grep -c '987' "$DEST/.state/.claude/channels/telegram/access.json"
  [ "$status" -eq 0 ]
}

@test "restore_from_fork warns and continues when branch doesn't exist" {
  EMPTY_BARE="$BATS_TEST_TMPDIR/empty.git"
  git init --bare --initial-branch=main "$EMPTY_BARE" >/dev/null 2>&1

  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run restore_from_fork "$EMPTY_BARE" "$DEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no backup/identity"* ]] || [[ "$output" == *"skip"* ]]
}
