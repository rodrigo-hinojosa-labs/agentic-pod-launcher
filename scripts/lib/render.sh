#!/usr/bin/env bash
# Render engine — placeholders, conditionals, loops

# Internal: path to the loaded YAML file (set by render_load_context)
_RENDER_YAML_FILE=""

# render_load_context FILE
# Reads YAML scalars and exports them as UPPERCASE_SNAKE_CASE env vars.
# Skips array items (paths with numeric components).
# Stores FILE path in _RENDER_YAML_FILE for later {{#each}} lookups.
render_load_context() {
  local file="${1:-}"
  [ -z "$file" ]        && { echo "render_load_context: missing FILE argument" >&2; return 1; }
  [ ! -f "$file" ]      && { echo "render_load_context: file not found: $file" >&2; return 1; }
  command -v yq &>/dev/null || { echo "render_load_context: yq is required" >&2; return 1; }

  _RENDER_YAML_FILE="$file"
  export _RENDER_YAML_FILE

  local line key value varname
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"

    # Skip array items — paths that contain a numeric segment
    if [[ "$key" =~ (^|\.)[0-9]+($|\.) ]] || [[ "$key" =~ \.[0-9]+$ ]] || [[ "$key" =~ ^[0-9]+ ]]; then
      continue
    fi

    varname=$(printf '%s' "$key" | tr '.' '_' | tr '[:lower:]' '[:upper:]')
    export "${varname}=${value}"
  done < <(yq '.. | select(tag != "!!map" and tag != "!!seq") | (path | join(".")) + "=" + (. | tostring)' "$file" 2>/dev/null)
}

# _render_each CONTENT YAML_FILE → stdout
# Expands {{#each VAR}}...{{/each}} blocks by iterating YAML arrays.
_render_each() {
  local content="$1"
  local yaml_file="$2"
  local var block_tpl full_match yq_key yq_path length expanded field fval row_expanded field_upper

  while [[ "$content" =~ \{\{#each[[:space:]]+([^}]+)\}\}(.*)\{\{/each\}\} ]]; do
    var="${BASH_REMATCH[1]}"
    block_tpl="${BASH_REMATCH[2]}"
    full_match="${BASH_REMATCH[0]}"

    # Derive yq path from var name (MCPS_ATLASSIAN -> .mcps.atlassian)
    yq_key=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '.')
    yq_path=".${yq_key}"
    length=$(yq "${yq_path} | length" "$yaml_file" 2>/dev/null || echo 0)

    expanded=""
    for (( i=0; i<length; i++ )); do
      row_expanded="$block_tpl"
      # Get field names for this item
      while IFS= read -r field; do
        [ -z "$field" ] && continue
        fval=$(yq "${yq_path}[${i}].${field}" "$yaml_file" 2>/dev/null)
        [ "$fval" = "null" ] && fval=""
        # Replace {{fieldname}} — use escaped braces to avoid quote injection
        row_expanded="${row_expanded//\{\{${field}\}\}/$fval}"
        # Replace {{FIELDNAME}} with uppercase value
        field_upper=$(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')
        local fval_upper
        fval_upper=$(printf '%s' "$fval" | tr '[:lower:]' '[:upper:]')
        row_expanded="${row_expanded//\{\{${field_upper}\}\}/$fval_upper}"
      done < <(yq "${yq_path}[${i}] | keys | .[]" "$yaml_file" 2>/dev/null)
      expanded+="$row_expanded"
    done

    # Replace full_match with expanded. The replacement is fetched via
    # ENV{REPL} inside an /e (eval) substitution rather than passed as
    # a literal replacement string — this prevents perl from
    # interpolating $1, $2, \1, \2 inside the field value (e.g. a yaml
    # value containing "$1bn revenue" or "C:\path" used to corrupt).
    content=$(REPL="$expanded" perl -0777 -e '
      my $full = $ARGV[0];
      my $text = do { local $/; <STDIN> };
      $full = quotemeta($full);
      $text =~ s/$full/$ENV{REPL}/e;
      print $text;
    ' "$full_match" <<< "$content")
  done

  printf '%s' "$content"
}

# _render_conditionals CONTENT → stdout
# Processes {{#if VAR}}...{{/if}} and {{#unless VAR}}...{{/unless}} blocks.
# Includes/excludes the inner block based on the env var being "true" or not.
_render_conditionals() {
  local content="$1"
  # Use perl for safe multi-line regex replacement
  content=$(perl -0777 -pe '
    use Env;
    # Process {{#if VAR}}...{{/if}} — include when var == "true"
    s/\{\{#if\s+(\w+)\}\}(.*?)\{\{\/if\}\}/$ENV{$1} eq "true" ? $2 : ""/gse;
    # Process {{#unless VAR}}...{{/unless}} — include when var != "true"
    s/\{\{#unless\s+(\w+)\}\}(.*?)\{\{\/unless\}\}/$ENV{$1} ne "true" ? $2 : ""/gse;
  ' <<< "$content")
  printf '%s' "$content"
}

# _render_placeholders CONTENT → stdout
# Replaces {{UPPERCASE_VAR}} with the value of the corresponding env var.
_render_placeholders() {
  local content="$1"
  content=$(perl -0777 -pe '
    use Env;
    s/\{\{([A-Z][A-Z0-9_]*)\}\}/defined $ENV{$1} ? $ENV{$1} : ""/ge;
  ' <<< "$content")
  printf '%s' "$content"
}

# render_template FILE → stdout
# Renders the template file: expands each loops, then conditionals, then placeholders.
render_template() {
  local tpl="${1:-}"
  [ -z "$tpl" ]     && { echo "render_template: missing FILE argument" >&2; return 1; }
  [ ! -f "$tpl" ]   && { echo "render_template: template not found: $tpl" >&2; return 1; }

  local content yaml_file
  content=$(< "$tpl")
  yaml_file="${_RENDER_YAML_FILE:-}"

  # Step 1: expand {{#each}} loops (requires YAML file for array data)
  if [ -n "$yaml_file" ] && [ -f "$yaml_file" ]; then
    content=$(_render_each "$content" "$yaml_file")
  fi

  # Step 2: process conditionals
  content=$(_render_conditionals "$content")

  # Step 3: substitute remaining placeholders
  content=$(_render_placeholders "$content")

  printf '%s\n' "$content"
}

# render_to_file TPL DEST
# Renders TPL and writes result to DEST (creates parent directories as needed).
render_to_file() {
  local tpl="${1:-}" dest="${2:-}"
  [ -z "$tpl" ]  && { echo "render_to_file: missing TPL argument" >&2; return 1; }
  [ -z "$dest" ] && { echo "render_to_file: missing DEST argument" >&2; return 1; }
  [ ! -f "$tpl" ] && { echo "render_to_file: template not found: $tpl" >&2; return 1; }

  mkdir -p "$(dirname "$dest")"
  render_template "$tpl" > "$dest"
}
