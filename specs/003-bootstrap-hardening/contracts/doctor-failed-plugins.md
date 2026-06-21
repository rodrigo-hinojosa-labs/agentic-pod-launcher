# Contract: plugin-install outcomes + `doctor` surface (Story C)

## Log outcomes (`docker/scripts/start_services.sh`)

The ambiguous line `plugin install skipped (not authenticated yet or install failed): <spec>`
is replaced by two distinct outcomes:

- `plugin install skipped: not authenticated — <spec>`  (expected; retried on the next auth flip)
- `plugin install failed (attempt N/3): <spec> — <short error>`  (non-auth failure)
- `plugin installed: <spec>`  (unchanged success)

## Retry

- A non-auth failure is retried up to **3 attempts** with a short fixed backoff (1s, then 2s).
- "Not authenticated" is NOT counted as a failure and is NOT retried in-loop (it resolves via Story A's auth-flip re-run).
- Boot MUST continue after retry exhaustion (fail-loud, never fail-stuck — Principle IV).

## Failure state file

`.state/plugin-install-failures.jsonl` — one object per residual-failed plugin:

```json
{"spec":"claude-mem@thedotmack","attempts":3,"last_error":"<short>","ts":"2026-06-20T14:18:22Z"}
```

- Under `.state/` (durable, gitignored, bind-mounted). Re-derived from `agent.yml.plugins[]` at boot.
- A spec is removed from the file once a later attempt succeeds (sentinel present).
- `last_error` is truncated to its first line and scrubbed of token-like strings (`ghp_*`, `xox*`, `*_TOKEN=…`) before persisting — never write a secret into `.state/` (Principle V).

## `agentctl doctor` (`scripts/agentctl::cmd_doctor`)

- Adds a check that reads the failure file. For each entry, print a `✗` line + a copy-paste retry:

```text
✗ Plugin install: claude-mem@thedotmack failed (3 attempts)
    retry: ./scripts/agentctl run claude plugin install claude-mem@thedotmack
```

- Empty/absent file ⇒ `✓ Plugins: all configured plugins installed`.

## NEXT_STEPS (`modules/next-steps.en.tpl`)

- When the failure file is non-empty at render time, a "Plugins that failed to install" section
  lists each spec with the same retry command. Absent file ⇒ section omitted.

## Test assertions (host, no Docker)

- Stub `claude` to emit "not authenticated" ⇒ outcome `skipped: not authenticated`, no retry, no failure-file entry.
- Stub `claude` to fail non-auth ⇒ retried 3×, then one failure-file line written.
- Stub `claude` to fail then succeed ⇒ no residual failure-file entry.
- `cmd_doctor` against a fixture failure file ⇒ prints the `✗` + retry line; against an empty file ⇒ prints the `✓` line.
