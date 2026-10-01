# Contract: `vault_pending_deltas` (deteccion compartida)

**Ubicacion**: `scripts/lib/vault.sh` (nueva funcion, junto a `vault_seed_missing` — no la
modifica). Espejada a `docker/scripts/lib/vault.sh` (COPY del Dockerfile, igual que el resto de la
lib) — cualquier cambio aqui exige `DOCKER_E2E`.

## Firma

```bash
vault_pending_deltas <vault_root>
```

- **Input**: `vault_root` — ruta absoluta a la raiz del vault (misma convencion que
  `vault_seed_missing`, `wiki_graph_run`, etc.).
- **Output** (stdout): cero o mas lineas, una version de delta por linea (ej. `0.27.0`), en el
  orden de `_vault_delta_known_versions`. Vacio (sin lineas) si no hay ninguna pendiente.
- **Exit status**: siempre `0`. Nunca falla — un `vault_root` inexistente o sin `_templates/`
  simplemente no reporta nada pendiente (Principio IV: fail-silent, nunca aborta un caller).

## Comportamiento

Para cada version en `_vault_delta_known_versions` (hoy solo `0.27.0`):

1. Si `_vault_delta_checkpoint_text <version>` no resuelve (version desconocida en la tabla) →
   se salta.
2. Si `<vault_root>/_templates/.schema-updates-<version>.applied` NO existe → se salta (el delta ni
   siquiera fue depositado; nada que avisar).
3. Si el texto de checkpoint de esa version SI aparece (grep -F) en
   `<vault_root>/CLAUDE.md` → se salta (ya integrado).
4. En cualquier otro caso → la version se reporta como pendiente.

## Garantias

- **Idempotente y sin efectos secundarios**: solo lee (`.applied`, `CLAUDE.md`); nunca escribe
  nada. Los callers (boot dispatch, doctor) son quienes deciden que hacer con el resultado.
- **Barato**: dos operaciones de filesystem por version conocida (test -f, grep -F de un archivo).
  Nunca escala con el tamano del vault — seguro de llamar de forma sincronica en `agentctl doctor`
  incluso sobre un vault de miles de paginas.
- **Fresco**: NO depende de `.graph/findings.json` ni de ninguna cache de wiki-graph — lee el
  estado real del vault en el momento de la llamada.

## Consumidores

- `docker/scripts/start_services.sh::boot_side_effects()` — dispatch del aviso activo (ver
  contrato `schema-delta-boot-trigger.md`).
- `scripts/agentctl::_local_vault_qmd_doctor()` — linea de WARN en modo local.
- (Potencialmente `scripts/agentctl`'s docker-mode doctor equivalent, si se decide espejar la
  misma linea de WARN alli tambien — ver quickstart.md para el criterio de aceptacion exacto.)

## Fuera de este contrato

- La tabla `_vault_delta_known_versions` / `_vault_delta_checkpoint_text` es intencionalmente
  MANUAL — agregar una version nueva de delta en el futuro requiere una linea nueva aqui. No se
  deriva automaticamente de `modules/vault-deltas/*.md` (leer el contenido de cada delta doc para
  extraer su propio checkpoint declarado seria mas generico, pero es mas fragil — el checkpoint es
  prosa libre dentro de un blockquote, no un campo estructurado; se prefiere la tabla explicita,
  mas facil de testear).
