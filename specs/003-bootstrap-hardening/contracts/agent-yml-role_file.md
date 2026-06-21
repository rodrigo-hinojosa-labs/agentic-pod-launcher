# Contract: `agent.yml.agent.role_file` (Story I)

## Field

```yaml
agent:
  name: my-agent
  role: "One-line role (kept; used when role_file is unset)."
  role_file: "personas/my-agent.md"   # OPTIONAL. Absolute, or relative to the workspace.
```

- Type: string (path) or absent/null.
- Optional. Absent ⇒ current one-line behavior, unchanged.

## Wizard / flag

- `./setup.sh --role-file PATH` sets `agent.role_file` to `PATH`.
- The wizard MAY prompt for it (optional, after the role prompt).
- At wizard time, if `--role-file` is given, the path MUST exist and be readable, else the wizard fails loud before writing `agent.yml`.
- If the path is outside the destination workspace, the wizard copies the file into the workspace (e.g. `personas/<name>.md`) and stores the relative path, so the persona travels with clone / backup / `--restore-from-fork` (Principle V).

## Render behavior (`scripts/lib/render.sh` + `modules/claude-md.tpl`)

- If `role_file` is set:
  - render reads the file's full content and exports `AGENT_ROLE_MULTILINE`.
  - `## Identity` injects `AGENT_ROLE_MULTILINE` verbatim (newlines preserved) in place of the one-line `{{AGENT_ROLE}}`.
- If `role_file` is unset/null/empty:
  - `AGENT_ROLE_MULTILINE` is unset; `{{AGENT_ROLE}}` (one-liner) is injected as today.
- If `role_file` is set but the path is missing/unreadable **at render time**:
  - render fails loud: `ERROR: agent.yml: role_file not found: <path>` (non-zero). It MUST NOT inject an empty persona.

## Invariants

- agent.yml stays the single source of truth (Principle I): the path persists; content is re-read on every `--regenerate`, so persona-file edits propagate without re-prompting.
- Schema: `role_file` is an optional leaf (not in `_SCHEMA_REQUIRED_LEAVES`); when present it MUST be a non-empty string.

## Test assertions (host, no Docker)

- `render_load_context` with `role_file` set ⇒ `AGENT_ROLE_MULTILINE` == file content (byte-exact, incl. newlines).
- Template render ⇒ `## Identity` contains the full multiline content.
- `role_file` unset ⇒ one-line `{{AGENT_ROLE}}` path unchanged.
- `role_file` set to a missing path ⇒ render exits non-zero with the `role_file not found` error.
