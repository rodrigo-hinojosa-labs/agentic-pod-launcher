#!/usr/bin/env bash
# YAML reader — thin wrapper around yq v4

# yaml_get FILE PATH → prints value or empty string
yaml_get() {
  local file="$1" path="$2"
  local result
  result=$(yq "$path" "$file" 2>/dev/null)
  [ "$result" = "null" ] && result=""
  echo "$result"
}

# yaml_get_bool FILE PATH → prints "true" or "false"
yaml_get_bool() {
  local file="$1" path="$2"
  local result
  result=$(yq "$path" "$file" 2>/dev/null)
  if [ "$result" = "true" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# yaml_array_length FILE PATH → prints integer length
yaml_array_length() {
  local file="$1" path="$2"
  yq "$path | length" "$file" 2>/dev/null || echo 0
}

# yaml_array_item FILE PATH INDEX SUBPATH → prints value at path[index].subpath
# Returns empty string for null/missing (matches yaml_get behavior).
yaml_array_item() {
  local file="$1" path="$2" index="$3" subpath="$4"
  local result
  result=$(yq "${path}[${index}]${subpath}" "$file" 2>/dev/null)
  [ "$result" = "null" ] && result=""
  echo "$result"
}

# yaml_yq_arch — map uname -m to yq release arch suffix
yaml_yq_arch() {
  local arch
  arch=$(uname -m 2>/dev/null || echo "")
  case "$arch" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l|armv6l)  echo "arm" ;;
    i386|i686)      echo "386" ;;
    *)              echo "amd64" ;;
  esac
}

# yaml_bootstrap_yq — try to auto-download yq into scripts/vendor/bin.
# Returns 0 if yq ends up available (on PATH or via vendor dir, which is prepended to PATH).
yaml_bootstrap_yq() {
  local lib_dir repo_root vendor_dir os yq_arch url
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  repo_root=$(cd "$lib_dir/../.." && pwd)
  vendor_dir="$repo_root/scripts/vendor/bin"

  # Already vendored from a previous run?
  if [ -x "$vendor_dir/yq" ]; then
    export PATH="$vendor_dir:$PATH"
    return 0
  fi

  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$os" in
    darwin|linux) ;;
    *) return 1 ;;
  esac
  yq_arch=$(yaml_yq_arch)
  url="https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${yq_arch}"

  mkdir -p "$vendor_dir"
  echo "▸ Bootstrapping yq (${os}/${yq_arch}, one-time, ~10MB)..." >&2
  if ! curl -sL --fail "$url" -o "$vendor_dir/yq" 2>/dev/null; then
    rm -f "$vendor_dir/yq"
    return 1
  fi
  chmod +x "$vendor_dir/yq"
  if [ -x "$vendor_dir/yq" ]; then
    echo "  ✓ yq installed at $vendor_dir/yq" >&2
    export PATH="$vendor_dir:$PATH"
    return 0
  fi
  return 1
}

# yaml_require_yq — ensure yq is available; auto-download if missing.
yaml_require_yq() {
  if command -v yq &>/dev/null; then
    return 0
  fi
  if yaml_bootstrap_yq && command -v yq &>/dev/null; then
    return 0
  fi
  local arch yq_arch
  arch=$(uname -m 2>/dev/null || echo "")
  yq_arch=$(yaml_yq_arch)
  echo "ERROR: yq is required and auto-download failed. Install manually:" >&2
  echo "  macOS: brew install yq" >&2
  echo "  Linux (${arch:-unknown} → ${yq_arch}): sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch} && sudo chmod +x /usr/local/bin/yq" >&2
  return 1
}
