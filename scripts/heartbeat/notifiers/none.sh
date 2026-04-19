#!/usr/bin/env bash
# none — no-op notifier. Reads stdin (ignored). Emits the standard JSON envelope.
set -euo pipefail
cat >/dev/null || true    # drain stdin so caller does not SIGPIPE
printf '{"channel":"none","ok":true,"latency_ms":0,"error":null}\n'
