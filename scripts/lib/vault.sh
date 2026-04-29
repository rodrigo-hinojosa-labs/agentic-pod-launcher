#!/usr/bin/env bash
# vault.sh — host-side helpers for the per-agent Obsidian vault (Karpathy LLM Wiki pattern).
#
# Used by:
#   - setup.sh (host-side scaffold) — seed `<workspace>/.state/.vault/` from the skeleton
#   - docker/entrypoint.sh (image-baked, copy of this file at /opt/agent-admin/scripts/lib/)
#     — ensure path + seed at first boot
#   - tests/vault.bats — behavior tests
#
# Pattern: only function definitions, no side-effecting code at source-time.
# Matches scripts/lib/plugin-catalog.sh.

# vault_ensure_paths VAULT_DIR
# Ensure the vault root directory exists. Idempotent.
vault_ensure_paths() {
  local vault_dir="$1"
  [ -n "$vault_dir" ] || { echo "vault_ensure_paths: missing vault_dir" >&2; return 1; }
  mkdir -p "$vault_dir"
}

# vault_seed_if_empty TARGET_DIR SKELETON_DIR [TODAY]
# Copy SKELETON_DIR/* into TARGET_DIR if TARGET_DIR is empty (or missing).
# No-op if TARGET_DIR already has content (idempotent at boot).
# Replaces SCAFFOLD_DATE in seeded log.md with TODAY (defaults to current date,
# overrideable for tests).
#
# Uses `cp -R` rather than `rsync` or `cp -a`: rsync is not installed in the
# Alpine runtime image, and `cp -a` (which implies `-p` preserve attributes)
# fails under `cap_drop: ALL` because the non-root agent user can't chown.
# Plain `cp -R "$skeleton"/. "$target"/` copies recursively (including
# dotfiles via the trailing `/.`) and lets new files inherit the running
# user's ownership — exactly what we want here.
vault_seed_if_empty() {
  local target="$1" skeleton="$2" today="${3:-$(date +%Y-%m-%d)}"
  [ -n "$target" ] || { echo "vault_seed_if_empty: missing target" >&2; return 1; }
  [ -n "$skeleton" ] || { echo "vault_seed_if_empty: missing skeleton" >&2; return 1; }
  [ -d "$skeleton" ] || { echo "vault_seed_if_empty: skeleton not found: $skeleton" >&2; return 1; }

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    return 0
  fi

  mkdir -p "$target" || return 1
  cp -R "$skeleton"/. "$target"/ || { echo "vault_seed_if_empty: cp failed: $skeleton -> $target" >&2; return 1; }

  if [ -f "$target/log.md" ]; then
    sed "s/SCAFFOLD_DATE/${today}/g" "$target/log.md" > "$target/log.md.tmp" || return 1
    mv "$target/log.md.tmp" "$target/log.md" || return 1
  fi
}

# vault_backup_and_reseed TARGET_DIR SKELETON_DIR [TODAY] [TIMESTAMP]
# Move TARGET_DIR (with its contents) to TARGET_DIR.backup-<TIMESTAMP> and
# re-seed from SKELETON_DIR. Used when agent.yml.vault.force_reseed=true to
# upgrade an existing agent to a newer skeleton without losing user content.
#
# TIMESTAMP defaults to now (YYYY-MM-DD-HHMMSS) but can be overridden for
# tests. TODAY is forwarded to vault_seed_if_empty for the SCAFFOLD_DATE
# replacement.
#
# If TARGET_DIR is missing or empty, this function is equivalent to
# vault_seed_if_empty (no backup needed). On success, a fresh skeleton is
# at TARGET_DIR; the prior content lives at TARGET_DIR.backup-<TIMESTAMP>.
vault_backup_and_reseed() {
  local target="$1" skeleton="$2"
  local today="${3:-$(date +%Y-%m-%d)}"
  local ts="${4:-$(date +%Y-%m-%d-%H%M%S)}"
  [ -n "$target" ] || { echo "vault_backup_and_reseed: missing target" >&2; return 1; }
  [ -n "$skeleton" ] || { echo "vault_backup_and_reseed: missing skeleton" >&2; return 1; }
  [ -d "$skeleton" ] || { echo "vault_backup_and_reseed: skeleton not found: $skeleton" >&2; return 1; }

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    local backup="${target}.backup-${ts}"
    mv "$target" "$backup" \
      || { echo "vault_backup_and_reseed: backup mv failed: $target -> $backup" >&2; return 1; }
  fi

  vault_seed_if_empty "$target" "$skeleton" "$today"
}

# vault_log_append VAULT_DIR OP TITLE [TODAY]
# Append a chronological entry to <VAULT_DIR>/log.md following the format:
#   ## [YYYY-MM-DD] <op> | <title>
vault_log_append() {
  local vault_dir="$1" op="$2" title="$3" today="${4:-$(date +%Y-%m-%d)}"
  [ -n "$vault_dir" ] || { echo "vault_log_append: missing vault_dir" >&2; return 1; }
  [ -n "$op" ] || { echo "vault_log_append: missing op" >&2; return 1; }
  [ -n "$title" ] || { echo "vault_log_append: missing title" >&2; return 1; }
  [ -f "$vault_dir/log.md" ] || { echo "vault_log_append: no log.md at $vault_dir" >&2; return 1; }
  printf '\n## [%s] %s | %s\n' "$today" "$op" "$title" >> "$vault_dir/log.md"
}
