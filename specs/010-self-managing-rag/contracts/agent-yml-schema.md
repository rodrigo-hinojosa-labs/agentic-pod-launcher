# Contract — agent.yml schema + render for vault.qmd.*

**Date**: 2026-06-28 · **Branch**: `010-self-managing-rag`

---

## agent.yml shape (written by `setup.sh`)

The `vault` block gains `version` + `schedule` under `qmd`:

```yaml
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  force_reseed: false
  initial_sources: []
  mcp:
    enabled: true
    server: vault
  qmd:
    enabled: false          # opt-in (unchanged default)
    version: "2.5.3"         # NEW — single source of the pin (D2)
    schedule: "*/5 * * * *"  # NEW — cron backstop cadence (default)
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"
```

`setup.sh` writes `version` and `schedule` with the defaults above in its heredoc (around `setup.sh:1124-1125`). `--regenerate` preserves user-set values (it re-renders derived files from the existing `agent.yml`, not the other way around).

---

## `scripts/lib/schema.sh` additions

```bash
# Booleans — vault.qmd.enabled joins features.heartbeat.enabled.
_SCHEMA_BOOLEANS+=( '.vault.qmd.enabled' )

# Optional non-empty strings — present-but-empty is an error; absent is fine.
_SCHEMA_OPTIONAL_NONEMPTY+=( '.vault.qmd.version' '.vault.qmd.schedule' )
```

**Contract** (`agent_yml_validate FILE`):
- `vault.qmd.enabled` absent → OK (treated as false downstream). Present and not `true|false` → error `".vault.qmd.enabled must be a YAML boolean (true|false), got: <v>"`. A present `false` must NOT be reported missing (the 002/005 `_schema_get` fix already guarantees this — do not reintroduce `// ""`).
- `vault.qmd.version` absent → OK. Present and empty → error. Present non-empty → OK (no semver shape check — keep it light).
- `vault.qmd.schedule` absent → OK. Present and empty → error. Present non-empty → OK (no cron-syntax check; `wizard-validators.sh` owns interval/cron parsing for the heartbeat — not duplicated here, per research D8).

---

## `modules/mcp-json.tpl` change

```diff
   }{{/if}}{{#if VAULT_QMD_ENABLED}},
     "qmd": {
       "command": "bunx",
-      "args": ["@tobilu/qmd@latest", "mcp"],
+      "args": ["@tobilu/qmd@{{VAULT_QMD_VERSION}}", "mcp"],
       "env": {}
     }{{/if}}
```

`$VAULT_QMD_VERSION` is flattened from `vault.qmd.version` by `render.sh` (the existing `section.key → $SECTION_KEY` convention; nested `vault.qmd.version → $VAULT_QMD_VERSION`). Rendered into `.mcp.json`. If the key is absent in an older `agent.yml`, render must fall back to `2.5.3` (template default or render-context default) so a regenerate of a pre-010 workspace still yields a valid pinned spec.

---

## Test contract deltas (assertions that CHANGE)

These existing tests assert the floating `@latest` and MUST be updated to the pin:

| File:line | Was | Becomes |
|-----------|-----|---------|
| `tests/scaffold.bats:170` | `args[0] == "@tobilu/qmd@latest"` | `== "@tobilu/qmd@2.5.3"` |
| `tests/mcp-json.bats:205` | `args[0] == "@tobilu/qmd@latest"` | `== "@tobilu/qmd@2.5.3"` |
| `tests/mcp-json.bats:206` | `args[1] == "mcp"` | unchanged |
| `tests/scaffold.bats:151,168` | `vault.qmd.enabled` true/false | unchanged; add `vault.qmd.version` assertion |
| `tests/schema.bats:43` | vault subkey set | add `version schedule` to the recognized set |

New schema cases: reject `vault.qmd.enabled: ture`; reject empty `vault.qmd.version: ""`; accept a well-formed block.
