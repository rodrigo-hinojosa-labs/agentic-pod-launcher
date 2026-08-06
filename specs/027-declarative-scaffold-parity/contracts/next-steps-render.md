# Contract: NEXT_STEPS render in the non-interactive path — US4

Governs rendering `NEXT_STEPS.md` from `regenerate()` (backs `--non-interactive` and
`--regenerate`), reusing `render_next_steps()`'s template selection + `{{PLUGINS_BLOCK}}`.

## Render decision

**Given** a local-mode workspace,
**When** `./setup.sh --non-interactive` runs,
**Then** `NEXT_STEPS.md` exists and, being local mode, names the local next-actions (the
`./setup.sh --login` command, the systemd unit-install path, validation) for THIS agent —
selected by `user.language`.

**Given** the render is re-run (`--regenerate`),
**When** it completes,
**Then** `NEXT_STEPS.md` is re-produced deterministically (idempotent; same input → same bytes),
surviving regeneration (FR-011).

**Given** a docker-mode workspace,
**When** `--non-interactive` runs,
**Then** `NEXT_STEPS.md` names the docker next-actions (the branch already lives in the template);
docker render output is otherwise unchanged (FR-012).

**Given** the interactive wizard path,
**When** an agent is scaffolded,
**Then** the wizard still prints `NEXT_STEPS.md` to stdout as before (FR-013) — the refactor only
adds a quiet file-write path for `regenerate()`.

## Mutation check (SC-007)

Reverting the `regenerate()` NEXT_STEPS render leaves `NEXT_STEPS.md` absent after
`--non-interactive` → the US4 test fails.
