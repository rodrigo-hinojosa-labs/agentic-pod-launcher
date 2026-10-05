# Contract: capa workspace — render vigente, línea base y re-render seguro

## Archivos

| Nombre | Ruta | Nota |
|---|---|---|
| `C` | `<ws>/CLAUDE.md` | Lo carga Claude Code en cada sesión. |
| `U` | `<ws>/.state/launcher/claude-md.upstream.md` | Render vigente. El nombre no es `CLAUDE.md` a propósito: Claude Code no debe tratarlo como un `CLAUDE.md` anidado. |
| `B` | `<ws>/.state/launcher/claude-md.baseline.md` | Render que `C` incorpora. |

Comparaciones siempre con `cmp -s`. Nunca mtime, nunca hash.

## Librería: `scripts/lib/claude_md.sh` (nueva)

Funciones puras, sin `yq`, cargables desde el hook (ambos modos), `setup.sh` y `agentctl`. Definirlas no
ejecuta nada. Siempre código 0; el resultado va por stdout como un solo token.

### `claude_md_state <C> <U> <B>`

| Salida | Condición |
|---|---|
| `unknown` | `U` no existe o no es legible |
| `in_sync` | `C = U` |
| `customized` | `C ≠ U`, `B` existe, `B = U` |
| `pending_template` | `C ≠ U`, `B` existe, `B ≠ U` |
| `pending_no_baseline` | `C ≠ U`, `B` no existe |

`C` inexistente con `U` presente se reporta como `pending_no_baseline` (no debería ocurrir tras un regenerate,
que lo renderiza).

### `claude_md_regenerate_decision <C> <U> <B> <force> <launcher_own>`

`force` y `launcher_own` son `true`/`false`, ya resueltos por el llamador (`force` = el operador confirmó
`--force-claude-md`; `launcher_own` = modo local y `_is_launcher_own_claude_md C`). Primera fila que aplica:

| Salida | Condición |
|---|---|
| `render` | `C` no existe, o `force=true`, o `launcher_own=true` |
| `refresh` | `B` existe, `C = B`, `C ≠ U` |
| `adopt` | `C = U`, `B` ausente o distinta de `U` |
| `noop` | `C = U`, `B = U` |
| `preserve` | cualquier otro caso |

## Integración en `setup.sh::regenerate()`

Reemplaza el bloque actual de `setup.sh:2680-2700`, conservando el prompt destructivo de `--force-claude-md`:

1. `mkdir -p <ws>/.state/launcher` (fail-silent).
2. Renderizar `modules/claude-md.tpl` a `U` (un solo render; `C` y `B` se obtienen copiando `U`, para que
   sean byte-idénticos).
3. Resolver `force` (si `--force-claude-md` y `C` existe, preguntar como hoy; `n` → `false`) y `launcher_own`.
4. Aplicar la decisión:

| Decisión | Escrituras | Línea en la salida |
|---|---|---|
| `render` (sin `C` previo) | `C ← U`, `B ← U` | `  ✓ CLAUDE.md` |
| `render` (force) | `C ← U`, `B ← U` | `  ✓ CLAUDE.md (overwritten)` |
| `render` (launcher_own) | `C ← U`, `B ← U` | `  ✓ CLAUDE.md (replaced the launcher's own dev doc with this agent's identity)` |
| `refresh` | `C ← U`, `B ← U` | `  ✓ CLAUDE.md (refreshed: no local edits since the last render)` |
| `adopt` | `B ← U` | `  ◦ CLAUDE.md (up to date; baseline recorded)` |
| `noop` | ninguna | `  ◦ CLAUDE.md (up to date)` |
| `preserve` | ninguna | según `claude_md_state`, ver abajo |

Para `preserve`:

- `customized`: `  ◦ CLAUDE.md (preserved: local edits, template unchanged)`
- `pending_*`: `  ◦ CLAUDE.md (preserved: differs from the current template; compare with .state/launcher/claude-md.upstream.md, or use --force-claude-md to overwrite)`

Las tres primeras líneas son las de hoy, sin cambios. Las de `preserve` conservan las subcadenas `preserved` y
`--force-claude-md` que ya imprime el código actual.

5. Toda escritura con `|| true`: un fallo deja el estado anterior y regenerate sigue (FR-010). Un fallo al
   escribir `B` después de escribir `C` deja `C = U` con `B` viejo, que el próximo regenerate resuelve con
   `adopt`.

## Confirmación manual (FR-006b)

Tras integrar a mano los cambios de la plantilla en un `C` con ediciones propias:

```bash
cp <ws>/.state/launcher/claude-md.upstream.md <ws>/.state/launcher/claude-md.baseline.md
```

En docker el agente lo corre con `<ws>` = `/workspace`. Efecto: `pending_*` → `customized` (o `in_sync`).

## Garantías

- `C` solo se escribe en `render` y `refresh` (FR-007). `refresh` exige `C = B`, es decir, cero ediciones.
- Idempotencia: un segundo regenerate sin cambios de entrada no escribe nada y deja `C`, `U` y `B`
  byte-idénticos.
- Determinismo: `modules/claude-md.tpl` no tiene placeholders de fecha ni hora; `U` solo cambia si cambian la
  plantilla, `agent.yml` o la persona.
- Ambos modos. En docker el contenido de `C` cambia, pero el comportamiento de los otros derivados no.

## Efectos sobre tests existentes (a revisar en tasks)

- `tests/regenerate.bats:251` (CLAUDE.md del operador preservado byte a byte) y `:262` (docker preserva el
  `CLAUDE.md` heredado del launcher): siguen pasando, ambos caen en `preserve` sin línea base.
- Cualquier test que renderice `C` y luego cambie `agent.yml` esperando `C` intacto pasa a ver `refresh`.
  Auditar con `grep` antes de implementar y ajustar el oráculo a la regla nueva, dejando el porqué en el test.
