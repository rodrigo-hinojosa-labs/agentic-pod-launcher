#!/usr/bin/env bats
# Tests for the unified restore flow: setup.sh's restore_from_fork now
# pulls backup/config + backup/identity + backup/vault from the fork in
# that order. Each branch is independently optional.

load 'helper'

setup() {
  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  BARE="$BATS_TEST_TMPDIR/fork.git"
  git init --bare --initial-branch=main "$BARE" >/dev/null 2>&1

  # Seed all three orphan branches in the bare repo. Subshell + plain
  # statements (no '&&' chains) so heredocs don't clash with line
  # continuations.
  WORK="$BATS_TEST_TMPDIR/seed"
  git clone "$BARE" "$WORK" >/dev/null 2>&1
  (
    cd "$WORK"
    git config user.email "t@t"
    git config user.name t

    # backup/config — agent.yml with a non-default vault.path
    git switch --orphan backup/config 2>/dev/null
    cat > agent.yml <<'YAML'
agent:
  name: restored-agent
  display_name: "Restored Agent"
scaffold:
  fork:
    url: dummy
vault:
  enabled: true
  path: .state/notes
YAML
    git add -A
    git commit -m "config seed" >/dev/null 2>&1
    git push origin backup/config >/dev/null 2>&1

    # backup/identity — minimal whitelist files
    git switch --orphan backup/identity 2>/dev/null
    rm -f agent.yml
    mkdir -p .claude/channels/telegram .claude/plugins/config
    echo '{"userID":"u1"}' > .claude.json
    echo '{"permissions":{"defaultMode":"auto"}}' > .claude/settings.json
    echo '{"allowFrom":["987"]}' > .claude/channels/telegram/access.json
    git add -A
    git commit -m "identity seed" >/dev/null 2>&1
    git push origin backup/identity >/dev/null 2>&1

    # backup/vault — markdown subset with a nested directory
    git switch --orphan backup/vault 2>/dev/null
    rm -rf .claude .claude.json
    mkdir -p wiki/summaries
    echo "# Index" > index.md
    echo "# Memex" > wiki/summaries/memex.md
    git add -A
    git commit -m "vault seed" >/dev/null 2>&1
    git push origin backup/vault >/dev/null 2>&1
  )

  DEST="$BATS_TEST_TMPDIR/agent"
  mkdir -p "$DEST"
}

@test "restore_from_fork pulls all three branches in order" {
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run restore_from_fork "$BARE" "$DEST"
  [ "$status" -eq 0 ]

  # config: agent.yml restored at workspace root
  [ -f "$DEST/agent.yml" ]
  run grep -c "restored-agent" "$DEST/agent.yml"
  [ "$status" -eq 0 ]

  # identity: whitelist files in .state/
  [ -f "$DEST/.state/.claude.json" ]
  [ -f "$DEST/.state/.claude/settings.json" ]
  [ -f "$DEST/.state/.claude/channels/telegram/access.json" ]

  # vault: markdown landed at .state/notes (the path declared in the
  # restored agent.yml — NOT the default .state/.vault).
  [ -f "$DEST/.state/notes/index.md" ]
  [ -f "$DEST/.state/notes/wiki/summaries/memex.md" ]
}

@test "restore_from_fork uses default vault path when agent.yml lacks vault.path" {
  # Override backup/config to omit vault.path → restore should fall
  # back to .state/.vault.
  (
    cd "$WORK"
    git switch backup/config 2>/dev/null
    cat > agent.yml <<'YAML'
agent:
  name: restored-agent
scaffold:
  fork:
    url: dummy
YAML
    git add -A
    git commit --amend -m "config no-vault" >/dev/null 2>&1
    git push --force origin backup/config >/dev/null 2>&1
  )

  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run restore_from_fork "$BARE" "$DEST"
  [ "$status" -eq 0 ]

  [ -f "$DEST/.state/.vault/index.md" ]
}

@test "restore_from_fork tolerates a fork with only some of the branches" {
  # Wipe vault from the fork → identity and config still restore fine.
  (
    cd "$WORK"
    git push origin --delete backup/vault >/dev/null 2>&1
  )

  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run restore_from_fork "$BARE" "$DEST"
  [ "$status" -eq 0 ]

  [ -f "$DEST/agent.yml" ]
  [ -f "$DEST/.state/.claude.json" ]
  [[ "$output" == *"no backup/vault"* ]]
}
