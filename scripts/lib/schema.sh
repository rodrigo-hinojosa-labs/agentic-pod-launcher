# shellcheck shell=bash
# Library: agent.yml schema validation.
#
# Cheap, fast, dependency-light: yq queries against a known set of
# required keys and enum constraints. Runs in --regenerate and
# --non-interactive paths so a typo in agent.yml fails loud at the
# launcher level instead of producing a half-rendered workspace that
# crashes at runtime.
#
# Sourced by setup.sh and exercised by tests/schema-validate.bats.
#
# Function contract:
#   agent_yml_validate FILE
#     - returns 0 on success (silent)
#     - returns 1 on any violation, with one human-readable line per
#       error on stderr prefixed by `ERROR: agent.yml: `

# Required top-level keys. Missing any of these means setup.sh wouldn't
# get past the render context flatten, so we surface them up-front.
_SCHEMA_REQUIRED_TOP_KEYS=(
  agent
  user
  deployment
  notifications
  features
)

# Required leaf keys with explicit dotted paths. Each entry is the yq
# path that must resolve to a non-empty, non-null value. Union of the
# legacy required set (deployment.workspace, features.heartbeat.*,
# docker.*) plus the new user.* and notifications.channel checks.
_SCHEMA_REQUIRED_LEAVES=(
  '.agent.name'
  '.user.timezone'
  '.user.email'
  '.deployment.workspace'
  '.notifications.channel'
  '.features.heartbeat.enabled'
  '.features.heartbeat.interval'
  '.features.heartbeat.timeout'
  '.features.heartbeat.retries'
  '.features.heartbeat.default_prompt'
  '.docker.uid'
  '.docker.gid'
  '.docker.image_tag'
  '.docker.base_image'
)

# Enum constraints: <yq-path>=<csv-of-allowed-values>. Empty or null
# values get caught by _SCHEMA_REQUIRED_LEAVES first; this list only
# polices the *value* once it's populated.
_SCHEMA_ENUMS=(
  '.notifications.channel=none,log,telegram'
)

# Boolean fields. Same idea as enums but specifically restricted to
# YAML-style true/false. Catches `features.heartbeat.enabled: yes` typos
# (yq parses "yes" as a string in YAML 1.2 mode).
_SCHEMA_BOOLEANS=(
  '.features.heartbeat.enabled'
)

# Internal: read a yq value, normalise null/empty to empty string.
_schema_get() {
  local file="$1" path="$2"
  local val
  val=$(yq -r "$path // \"\"" "$file" 2>/dev/null)
  [ "$val" = "null" ] && val=""
  printf '%s' "$val"
}

agent_yml_validate() {
  local file="${1:?agent_yml_validate: need agent.yml path}"
  local errors=()

  if [ ! -f "$file" ]; then
    printf 'ERROR: agent.yml: file not found: %s\n' "$file" >&2
    return 1
  fi

  # Parseable YAML at all? yq -e returns non-zero on parse errors.
  if ! yq -e '.' "$file" >/dev/null 2>&1; then
    printf 'ERROR: agent.yml: malformed YAML (yq parse failed)\n' >&2
    return 1
  fi

  local key
  for key in "${_SCHEMA_REQUIRED_TOP_KEYS[@]}"; do
    if ! yq -e ".${key}" "$file" >/dev/null 2>&1; then
      errors+=("missing required field: .${key} (top-level block)")
    fi
  done

  local path val
  for path in "${_SCHEMA_REQUIRED_LEAVES[@]}"; do
    val=$(_schema_get "$file" "$path")
    [ -z "$val" ] && errors+=("missing required field: ${path}")
  done

  local entry enum_path enum_csv
  for entry in "${_SCHEMA_ENUMS[@]}"; do
    enum_path="${entry%%=*}"
    enum_csv="${entry#*=}"
    val=$(_schema_get "$file" "$enum_path")
    # Skip empty — already reported by required-leaves check above.
    [ -z "$val" ] && continue
    if ! printf '%s' ",$enum_csv," | grep -q ",${val},"; then
      errors+=("${enum_path} must be one of {${enum_csv//,/, }} (got: ${val})")
    fi
  done

  local bool_path
  for bool_path in "${_SCHEMA_BOOLEANS[@]}"; do
    val=$(_schema_get "$file" "$bool_path")
    [ -z "$val" ] && continue
    case "$val" in
      true|false) ;;
      *)          errors+=("${bool_path} must be a YAML boolean (true|false), got: ${val}") ;;
    esac
  done

  if [ ${#errors[@]} -gt 0 ]; then
    printf 'ERROR: agent.yml schema validation failed (%d issue(s)):\n' "${#errors[@]}" >&2
    local err
    for err in "${errors[@]}"; do
      printf '  - %s\n' "$err" >&2
    done
    return 1
  fi
  return 0
}
