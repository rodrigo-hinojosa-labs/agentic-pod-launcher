# shellcheck shell=bash
# Library: shared observability helpers for the RAG maintenance runners
# (wiki_graph.sh, qmd_index.sh). Two tiny, pure functions — no side effects at
# source time (CLAUDE.md: BASH_SOURCE-safe). Mirrored into the image at
# /opt/agent-admin/scripts/lib/rag_obs.sh (docker/Dockerfile COPY +
# setup.sh::mirror_catalog_to_docker).
#
# 015 US3/US4: the batch runners must (a) route heavy temporaries off the small
# tmpfs /tmp onto host-backed .state, and (b) surface real infra/qmd errors into
# logs/state WITHOUT leaking secrets (Principle V — fail-silent must not become
# error-swallow, but a captured stderr/env dump must never carry a credential).

# redact_secrets — filter stdin, masking anything that looks like a credential.
# Portable across BSD (macOS host tests), GNU (Linux local) and busybox (Alpine
# container) sed: ERES only, no case-insensitive flag, no backrefs beyond \1.
# Catches secret VALUES (key-name agnostic) plus uppercase *_TOKEN/*_KEY/... env
# assignments (the shape of the US4 effective-env dump).
redact_secrets() {
  sed -E \
    -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-REDACTED/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]+/gh_REDACTED/g' \
    -e 's/([0-9]{8,}:)[A-Za-z0-9_-]{20,}/\1REDACTED/g' \
    -e 's/([A-Z_]*(TOKEN|KEY|SECRET|PASSWORD|PAT))=[^[:space:]]+/\1=REDACTED/g'
}

# scratch_dir BASE — ensure a host-backed scratch dir ("$BASE/tmp") exists and
# echo it. Used to point TMPDIR (and bunx's package cache) at disk-backed .state
# instead of the 100MB RAM tmpfs /tmp. Degrades to ${TMPDIR:-/tmp} if BASE is
# empty or cannot be created, so a caller can always `export TMPDIR="$(scratch_dir …)"`.
scratch_dir() {
  local base="${1:-}"
  [ -n "$base" ] || { printf '%s\n' "${TMPDIR:-/tmp}"; return 0; }
  local d="$base/tmp"
  if mkdir -p "$d" 2>/dev/null; then
    printf '%s\n' "$d"
  else
    printf '%s\n' "${TMPDIR:-/tmp}"
  fi
}
