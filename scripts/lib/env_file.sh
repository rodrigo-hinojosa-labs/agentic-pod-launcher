# shellcheck shell=bash
# Library: safe reading + linting of a `.env`-shaped file (021 local secret
# delivery). Pure function definitions only — no side effects at source time.
#
# The workspace `.env` can arrive from a REMOTE source (--restore-from-fork
# decrypts a `.env.age` from the fork into it), so anything that reads it
# MUST NOT execute its content: no `.`/`source`, no `eval`, no command
# substitution over file text. env_file_get is the anti-RCE primitive; every
# consumer of `.env` in local mode (the healthcheck, the doctor, the boot
# warn) goes through it.
#
# Contract: specs/021-local-secret-delivery/contracts/env-file-format.md
# Bash 3.2 compatible (the host test suite runs on macOS's stock bash).

# env_file_get KEY FILE → the value of the LAST matching "KEY=" line, or
# empty. Missing file / missing key both yield an empty string, exit 0 —
# callers treat "not found" and "found empty" the same way (FR-005).
env_file_get() {
  local key="$1" file="$2" line value found=""
  [ -f "$file" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*)
        value="${line#*=}"
        found="$value"
        ;;
    esac
  done < "$file"
  _env_file_unquote "$found"
}

# _env_file_unquote VALUE → strips exactly one layer of matching surrounding
# quotes (both double and single). Mismatched or absent quotes pass through
# unchanged. Internal helper — not part of the public contract.
_env_file_unquote() {
  local v="$1"
  case "$v" in
    \"*\")
      v="${v#\"}"
      v="${v%\"}"
      ;;
    \'*\')
      v="${v#\'}"
      v="${v%\'}"
      ;;
  esac
  printf '%s' "$v"
}

# env_file_lint FILE → validates against the portable subset (systemd ∩
# compose): blank | comment | KEY=value where the value has no backslash, no
# $, no " #", no leading quote, no CR — and the file is valid UTF-8 with no
# NUL/BOM. One finding per offending line, format "line N: KEY-or-dash:
# reason" — NEVER the value. Exit 0 = clean, 1 = findings; never fails the
# caller by itself.
env_file_lint() {
  local file="$1"
  [ -f "$file" ] || return 0

  local had_findings=0

  # BOM / NUL / non-UTF-8 are whole-file properties (this is exactly the
  # shape that makes systemd silently discard the ENTIRE file because of the
  # `-` prefix on EnvironmentFile — the agent boots healthy with zero
  # secrets). Report once, at line 0, then still walk line-by-line for the
  # per-line shapes.
  if command -v head >/dev/null 2>&1; then
    local bom
    bom=$(head -c 3 "$file" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [ "$bom" = "efbbbf" ]; then
      echo "line 0: -: BOM at start of file (systemd discards the entire file silently)"
      had_findings=1
    fi
  fi
  local _orig_size _clean_size
  _orig_size=$(wc -c < "$file" 2>/dev/null || echo 0)
  _clean_size=$(tr -d '\000' < "$file" 2>/dev/null | wc -c)
  if [ "${_orig_size:-0}" -ne "${_clean_size:-0}" ]; then
    echo "line 0: -: NUL byte present (systemd discards the entire file silently)"
    had_findings=1
  fi
  if command -v iconv >/dev/null 2>&1; then
    if ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
      echo "line 0: -: file is not valid UTF-8 (systemd discards the entire file silently)"
      had_findings=1
    fi
  fi

  local lineno=0 line key
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # CR check first — a CR anywhere in the line is its own finding
    # regardless of shape (both parsers treat it as whitespace/newline, but
    # its presence signals a Windows-edited file worth flagging).
    case "$line" in
      *$'\r'*)
        echo "line ${lineno}: -: carriage return in line (CRLF file — re-save with LF endings)"
        had_findings=1
        continue
        ;;
    esac

    # Blank line: fine.
    [ -z "$line" ] && continue

    # Comment at column 0: fine.
    case "$line" in
      '#'*) continue ;;
    esac

    # `;`-prefixed: systemd treats as a comment, compose hard-fails the
    # parse — divergence, flag it.
    case "$line" in
      ';'*)
        echo "line ${lineno}: -: starts with ';' (compose hard-fails parsing this; systemd treats it as a comment)"
        had_findings=1
        continue
        ;;
    esac

    # Must be KEY=... with a valid identifier key.
    case "$line" in
      [A-Za-z_]*=*)
        key="${line%%=*}"
        case "$key" in
          *[!A-Za-z0-9_]*)
            echo "line ${lineno}: ${key}: invalid characters in variable name (systemd drops the assignment AND logs the full line at ERROR — a credential leak)"
            had_findings=1
            continue
            ;;
        esac
        ;;
      *)
        echo "line ${lineno}: -: not a KEY=value assignment (missing '=', 'export ' prefix, or 'KEY: value' YAML shape — systemd ignores the line, compose may error)"
        had_findings=1
        continue
        ;;
    esac

    local val="${line#*=}"

    case "$val" in
      *'\'*)
        echo "line ${lineno}: ${key}: backslash in value (a trailing backslash makes systemd swallow the NEXT line entirely)"
        had_findings=1
        continue
        ;;
    esac
    case "$val" in
      *'$'*)
        echo "line ${lineno}: ${key}: '\$' in value (compose interpolates it, systemd treats it as a literal character)"
        had_findings=1
        continue
        ;;
    esac
    case "$val" in
      *' #'*)
        echo "line ${lineno}: ${key}: inline ' #' comment in value (compose strips it, systemd keeps it as part of the value)"
        had_findings=1
        continue
        ;;
    esac
    case "$val" in
      '"'*|"'"*)
        echo "line ${lineno}: ${key}: value starts with a quote character (quoting semantics differ between systemd and compose — write it unquoted)"
        had_findings=1
        continue
        ;;
    esac
  done < "$file"

  [ "$had_findings" -eq 0 ]
}
