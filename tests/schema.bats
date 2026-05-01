#!/usr/bin/env bats
# Schema drift detection. Catches three classes of bug that the existing
# suite couldn't:
#
# 1. A new top-level key added to setup.sh's heredoc but missing from the
#    fixture — render tests pass with stale data.
# 2. A new {{VAR}} placeholder added to a template but no corresponding
#    field in agent.yml — renders silently produce empty strings.
# 3. A vault sub-key dropped or renamed without updating the fixture or
#    callers — like the rsync→cp -R fix in PR #17, where the host suite
#    passed because no test actually validated end-to-end behavior.

load helper

setup() {
  setup_tmp_dir
}

teardown() { teardown_tmp_dir; }

@test "schema: fixture sample-agent-with-vault.yml has all expected top-level keys" {
  local fixture="$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml"
  # Fixture is a deliberately minimal agent.yml — no scaffold/fork block,
  # which only appears in wizard-generated yamls. If you add a top-level
  # block to setup.sh's heredoc that the renderer reads, mirror it here.
  local actual expected
  actual=$(yq 'keys | .[]' "$fixture" | sort)
  expected=$(printf '%s\n' \
    agent claude deployment docker features mcps notifications plugins user vault version \
    | sort)
  if [ "$actual" != "$expected" ]; then
    echo "schema drift in $fixture:" >&2
    diff <(echo "$expected") <(echo "$actual") >&2 || true
    return 1
  fi
}

@test "schema: vault block has all expected sub-keys" {
  local fixture="$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml"
  local actual expected
  actual=$(yq '.vault | keys | .[]' "$fixture" | sort)
  expected=$(printf '%s\n' \
    enabled force_reseed initial_sources mcp path qmd schema seed_skeleton \
    | sort)
  if [ "$actual" != "$expected" ]; then
    echo "schema drift in vault block:" >&2
    diff <(echo "$expected") <(echo "$actual") >&2 || true
    return 1
  fi
}

@test "schema: every {{VAR}} placeholder in templates is produced by render context" {
  load_lib render
  cp "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml" "$TMP_TEST_DIR/agent.yml"

  # Vars NOT loaded from agent.yml — they are computed and exported by
  # setup.sh after render_load_context but before render_to_file. Adding
  # an entry here is a deliberate choice: the var must be set externally,
  # not derived from agent.yml.
  local known_external=" NOTIFICATIONS_CHANNEL_IS_TELEGRAM PLUGINS_BLOCK NAME "

  # Capture the env shape produced by render_load_context with the fixture.
  local before_env after_env produced
  before_env=$(env | grep -E "^[A-Z][A-Z0-9_]*=" | cut -d= -f1 | sort -u)
  render_load_context "$TMP_TEST_DIR/agent.yml"
  after_env=$(env | grep -E "^[A-Z][A-Z0-9_]*=" | cut -d= -f1 | sort -u)
  produced=$(comm -13 <(echo "$before_env") <(echo "$after_env"))

  # Every bare {{VAR}} reference in templates (modules/*.tpl). Excludes
  # {{#if/each/unless VAR}} forms, which the render engine reads from a
  # different code path; they're checked separately below.
  local placeholders
  placeholders=$(grep -hoE "\{\{[A-Z_][A-Z0-9_]*\}\}" "$REPO_ROOT/modules"/*.tpl \
    | sort -u | tr -d '{}')

  local missing=""
  local var
  for var in $placeholders; do
    case " $known_external " in *" $var "*) continue ;; esac
    if ! echo "$produced" | grep -qFx "$var"; then
      missing="${missing} $var"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Template placeholders not produced by render_load_context with the fixture:" >&2
    echo "  Missing: $missing" >&2
    echo "" >&2
    echo "If the var is intentionally set elsewhere (e.g. in setup.sh after render_load_context)," >&2
    echo "add it to known_external in this test. Otherwise it's drift between a template and the schema." >&2
    return 1
  fi
}

@test "schema: every {{#if VAR}} / {{#unless VAR}} predicate is in render context" {
  load_lib render
  cp "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml" "$TMP_TEST_DIR/agent.yml"

  # Predicates set externally by setup.sh (wizard) or by the regenerate path —
  # not derived from agent.yml scalars by render_load_context. Adding to this
  # list is a deliberate choice: the var must be set elsewhere.
  local known_external=" NOTIFICATIONS_CHANNEL_IS_TELEGRAM"
  # Optional MCP toggles — exported by setup.sh during the wizard (one per
  # opt-in MCP the user enabled) and re-derived under --regenerate from
  # agent.yml.mcps.defaults[]. The fixture above doesn't list any optional
  # MCPs (only fetch/git/filesystem always-on), so none of these env vars
  # are produced by render_load_context — they're rightfully external.
  known_external="${known_external} MCPS_PLAYWRIGHT_ENABLED MCPS_TIME_ENABLED MCPS_SEQUENTIAL_THINKING_ENABLED"
  known_external="${known_external} MCPS_FIRECRAWL_ENABLED MCPS_GOOGLE_CALENDAR_ENABLED MCPS_AWS_ENABLED"
  known_external="${known_external} MCPS_TREE_SITTER_ENABLED "

  local before_env after_env produced
  before_env=$(env | grep -E "^[A-Z][A-Z0-9_]*=" | cut -d= -f1 | sort -u)
  render_load_context "$TMP_TEST_DIR/agent.yml"
  after_env=$(env | grep -E "^[A-Z][A-Z0-9_]*=" | cut -d= -f1 | sort -u)
  produced=$(comm -13 <(echo "$before_env") <(echo "$after_env"))

  # Predicates from {{#if VAR}} and {{#unless VAR}}. BSD sed (macOS)
  # doesn't grok \s+; use [[:space:]] for portability.
  local predicates
  predicates=$(grep -hoE "\{\{#(if|unless)[[:space:]]+[A-Z_][A-Z0-9_]*\}\}" "$REPO_ROOT/modules"/*.tpl \
    | sed -E 's/^\{\{#(if|unless)[[:space:]]+//; s/\}\}$//' | sort -u)

  local missing=""
  local var
  for var in $predicates; do
    case " $known_external " in *" $var "*) continue ;; esac
    if ! echo "$produced" | grep -qFx "$var"; then
      missing="${missing} $var"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Conditional predicates not produced by render_load_context with the fixture:" >&2
    echo "  Missing: $missing" >&2
    return 1
  fi
}

@test "schema: every {{#each VAR}} loop variable maps to a YAML array path" {
  local fixture="$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml"

  local loops
  loops=$(grep -hoE "\{\{#each[[:space:]]+[A-Z_][A-Z0-9_]*\}\}" "$REPO_ROOT/modules"/*.tpl \
    | sed -E 's/^\{\{#each[[:space:]]+//; s/\}\}$//' | sort -u)

  local missing=""
  local var
  for var in $loops; do
    # MCPS_ATLASSIAN → .mcps.atlassian
    local yaml_path
    yaml_path=".$(echo "$var" | tr '[:upper:]_' '[:lower:].')"
    # The path must exist in the fixture and be either an array or null
    # (rendering supports both — null/missing means "skip the each block").
    # Use yq's `?` to coalesce missing paths to null instead of erroring.
    local kind
    kind=$(yq "$yaml_path | type" "$fixture" 2>/dev/null) || kind="missing"
    case "$kind" in
      "!!seq"|"!!null"|"null"|"missing"|"") ;;  # array or absent — both valid
      *) missing="${missing} ${var}(at ${yaml_path} is ${kind})" ;;
    esac
  done

  if [ -n "$missing" ]; then
    echo "Each loops point at non-array YAML paths:" >&2
    echo "  $missing" >&2
    return 1
  fi
}
