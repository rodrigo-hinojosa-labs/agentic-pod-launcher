#!/usr/bin/env bats
# Drift detection between agentic-quickstart docs and the actual wizard.
#
# When someone adds a prompt to setup.sh but forgets to mention it in the
# agentic-quickstart docs, these tests fail loud — same defensive pattern
# as schema.bats does for {{VAR}} placeholders vs render context.
#
# The canonical source of truth for wizard prompt order is
# tests/helper.bash::wizard_answers(). Both docs and the /quickstart slash
# command reference it.

load helper

@test "quickstart-doc: ES doc mentions every active wizard block" {
  local doc="$REPO_ROOT/docs/agentic-quickstart.es.md"
  [ -f "$doc" ]

  # Each token here represents a wizard block. If a token is missing from
  # the doc, either someone added a prompt to setup.sh and forgot the doc,
  # or someone removed a prompt and forgot to clean up here.
  local keyword
  for keyword in \
      VAULT_ENABLED \
      VAULT_SEED_SKELETON \
      VAULT_MCP_ENABLED \
      VAULT_QMD_ENABLED \
      PLUGIN_CODE_SIMPLIFIER \
      PLUGIN_COMMIT_COMMANDS \
      PLUGIN_GITHUB \
      PLUGIN_SKILL_CREATOR \
      PLUGIN_SUPERPOWERS \
      ATLASSIAN_WORKSPACES \
      HEARTBEAT_INTERVAL \
      HEARTBEAT_PROMPT \
      USE_DEFAULT_PRINCIPLES \
      FORK_PAT \
      NOTIFY_CHANNEL \
      proceed \
      agentic-pod-launcher; do
    if ! grep -qF "$keyword" "$doc"; then
      echo "Missing in ES quickstart doc: $keyword" >&2
      echo "If you added/renamed a wizard prompt, update docs/agentic-quickstart.es.md" >&2
      echo "and docs/agentic-quickstart.en.md to match." >&2
      return 1
    fi
  done
}

@test "quickstart-doc: EN doc has same uppercase-token coverage as ES" {
  local doc_es="$REPO_ROOT/docs/agentic-quickstart.es.md"
  local doc_en="$REPO_ROOT/docs/agentic-quickstart.en.md"
  [ -f "$doc_en" ]

  # ALL_CAPS_WITH_UNDERSCORE tokens are variable names — they don't translate
  # between locales. Plain ALL_CAPS prose words (NEVER, EXACT, NUNCA, EXACTO)
  # are excluded by requiring at least one underscore. ES and EN must agree.
  local es_keys en_keys
  es_keys=$(grep -hoE '\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b' "$doc_es" | sort -u)
  en_keys=$(grep -hoE '\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b' "$doc_en" | sort -u)
  if [ "$es_keys" != "$en_keys" ]; then
    echo "ES/EN uppercase-token drift in agentic-quickstart docs:" >&2
    diff <(echo "$es_keys") <(echo "$en_keys") >&2 || true
    return 1
  fi
}

@test "quickstart-doc: ES doc references wizard_answers as canonical source" {
  local doc="$REPO_ROOT/docs/agentic-quickstart.es.md"
  grep -q "wizard_answers" "$doc"
  grep -q "tests/helper.bash" "$doc"
}

@test "quickstart-doc: wizard_answers() in helper.bash retains its block markers" {
  local helper="$REPO_ROOT/tests/helper.bash"
  [ -f "$helper" ]
  grep -qE '^wizard_answers\(\) \{' "$helper"

  # The function uses inline comments like "# Identity (4 prompts)" to
  # mark each wizard block. The doc and slash command rely on those
  # markers staying in place. If you rename one, update the doc/slash
  # alongside.
  local hook
  for hook in \
      'Identity (4 prompts)' \
      'User (5 prompts)' \
      'install_service' \
      'GitHub fork' \
      'Notify channel' \
      'Vault block' \
      'Optional plugins' \
      'Review action'; do
    if ! grep -qF "$hook" "$helper"; then
      echo "wizard_answers() drift: missing inline marker '$hook'" >&2
      return 1
    fi
  done
}

@test "quickstart-doc: /quickstart slash command exists and points at canonical sources" {
  local slash="$REPO_ROOT/.claude/commands/quickstart.md"
  [ -f "$slash" ]

  # Frontmatter required for Claude Code slash commands
  head -1 "$slash" | grep -q '^---$'
  grep -qE '^description: ' "$slash"

  # Must point at the two source-of-truth files so future drift is loud
  grep -q "tests/helper.bash" "$slash"
  grep -q "docs/agentic-quickstart.es.md" "$slash"
  grep -q "wizard_answers" "$slash"
}

@test "quickstart-doc: /quickstart slash command tells the model to validate before piping" {
  # The wizard rejects malformed inputs with re-prompts; piping invalid
  # values desyncs the stdin stream. The slash command must instruct the
  # model to validate locally first. If this fails, the validation block
  # got removed or renamed — restore it from .claude/commands/quickstart.md
  # at HEAD~1 if you don't remember the contract.
  local slash="$REPO_ROOT/.claude/commands/quickstart.md"
  grep -q "Validate inputs before piping" "$slash"
  # Each of these field names must appear in the slash command's
  # validation block so the model knows the rule for it.
  local field
  for field in AGENT_NAME EMAIL TIMEZONE HEARTBEAT_INTERVAL NOTIFY_BOT_TOKEN; do
    if ! grep -q "$field" "$slash"; then
      echo "Slash command missing validation rule for: $field" >&2
      return 1
    fi
  done
}

@test "quickstart-doc: validation rules in ES doc match the wizard-validators library" {
  # The "Validaciones aplicadas por el wizard" table mirrors the
  # validators in scripts/lib/wizard-validators.sh. If a validator is
  # added there, the doc must list it; if removed, the doc must drop
  # the row. We check both directions by sampling a representative
  # subset (full row-by-row mapping would be over-engineered).
  local doc="$REPO_ROOT/docs/agentic-quickstart.es.md"
  local lib="$REPO_ROOT/scripts/lib/wizard-validators.sh"
  [ -f "$doc" ]
  [ -f "$lib" ]

  # Doc must mention the validations section.
  grep -q "Validaciones aplicadas por el wizard" "$doc"

  # Each validator function should be reflected in the doc by either its
  # field name or a representative phrase. Loose match is intentional —
  # the doc is meant for humans, not a verbatim mirror.
  local check
  for check in \
      'AGENT_NAME' \
      'EMAIL' \
      'TIMEZONE' \
      'HEARTBEAT_INTERVAL' \
      'NOTIFY_BOT_TOKEN' \
      'URL' \
      'UID'; do
    if ! grep -q "$check" "$doc"; then
      echo "ES quickstart doc missing validation row for: $check" >&2
      return 1
    fi
  done

  # Inverse check: every validator function declared in the lib must be
  # at least mentioned in the doc (by name or by behavior). Add the
  # validate_X function name to scripts/lib/wizard-validators.sh and the
  # doc together to keep this honest.
  local fn
  while IFS= read -r fn; do
    case "$fn" in
      validate_email|validate_telegram_token|validate_timezone| \
      validate_cron_or_interval|validate_agent_name|validate_url| \
      validate_uid_gid|validate_workspace_path) ;;
      *) echo "Unknown validator in lib (update test): $fn" >&2; return 1 ;;
    esac
  done < <(grep -oE '^validate_[a-z_]+' "$lib")
}
