# Contract: Resolución de `claude_cli` para la unit local (US1)

**Interfaz**: `detect_claude_cli` (setup.sh), persistencia en `agent.yml`, y
`_export_local_context` → render de `systemd-remote-control.service.tpl`.

## Precondiciones

- Modo `deployment.mode: local`.
- `claude` instalado por el native installer en `~/.local/bin/claude` (symlink
  estable), posiblemente **fuera** del PATH del shell que corre `--regenerate`.

## Comportamiento observable

| # | Dado | Cuando | Entonces |
|---|------|--------|----------|
| C1 | `claude` sólo en `~/.local/bin`; `--regenerate` en shell sin ese dir en PATH | se renderiza la unit | `ExecStart=<ruta-absoluta>/claude remote-control …`, ejecutable — nunca el literal `claude` |
| C2 | `agent.yml.deployment.claude_cli` ya es absoluta+ejecutable | `--regenerate` | se usa tal cual (no se re-resuelve ni se pisa) |
| C3 | `agent.yml.deployment.claude_cli` es pelada/relativa/movida | `--regenerate` | se re-resuelve por candidatos y se **re-persiste** absoluta en `agent.yml` |
| C4 | ningún candidato conocido resuelve a un ejecutable | scaffold o `--regenerate` | **fail-loud**: mensaje accionable + rc≠0; NO se emite una unit con `ExecStart` inarrancable |
| C5 | Claude Code se actualiza (binario versionado cambia detrás del symlink) | el agente reinicia | `ExecStart` sigue válido (apunta al symlink estable) |

## Candidatos de resolución (orden)

1. `command -v claude-enterprise` / `claude-personal` / `claude` (devuelve absoluta si en PATH)
2. `${OPERATOR_HOME}/.local/bin/claude`
3. `${OPERATOR_HOME}/.claude/local/claude`

Se resuelve contra el **HOME del operador de la unit** (`User={{OPERATOR_USER}}`),
no el de quien ejecuta `--regenerate` (edge case root-vs-operador del spec).

## Cobertura de test (host, test-first)

- `tests/claude_cli_resolution.bats` (nuevo):
  - Fixture: un `claude` ejecutable en un `HOME/.local/bin` temporal, PATH sin ese dir.
  - Asserta C1: la unit renderizada trae ruta absoluta (grep `ExecStart=/…/claude`).
  - Asserta C4: con candidatos vacíos, `detect`/render falla con rc≠0 y mensaje.
  - Asserta C2/C3: valor persistido absoluto se respeta; pelado se re-resuelve.

## Invariantes de constitución

- Principle I: el valor vive en `agent.yml`; la unit se rerenderiza de ahí.
- El fail-loud (C4) ocurre en scaffold/regenerate, NO en boot/heartbeat (no cruza la
  frontera fail-silent del supervisor).
