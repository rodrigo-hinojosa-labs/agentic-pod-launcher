# Contract: detección de la capa vault (`scripts/lib/vault.sh`)

**Ubicación**: `scripts/lib/vault.sh`, junto a `vault_seed_missing` (que no se modifica). La imagen la copia
tal cual (`docker/Dockerfile:285`); no hay espejo commiteado que mantener. El hook y doctor la cargan desde
la copia del workspace (`<ws>/scripts/lib/vault.sh`), que se actualiza en el mismo upgrade que renderiza el
hook.

## Funciones

### `vault_delta_versions`

- **Salida**: una versión por línea, orden ascendente. Hoy: `0.8.0`, `0.27.0`.
- **Código**: siempre 0. Sin efectos laterales.

### `vault_delta_checkpoint <versión>`

- **Salida**: el hito literal de esa versión, sin salto de línea final.
- **Código**: 0 si la versión está en la tabla; 1 si no.

| Versión | Hito |
|---|---|
| `0.8.0` | `wiki/normalization/` |
| `0.27.0` | `## Actionability (PARA)` |

### `vault_pending_deltas <vault_root>`

- **Entrada**: ruta absoluta a la raíz del vault.
- **Salida**: cero o más líneas, una versión pendiente por línea, en el orden de `vault_delta_versions`.
- **Código**: siempre 0. Un `vault_root` vacío, inexistente, sin `_templates/` o sin un `CLAUDE.md` legible
  no reporta pendientes y no falla (sin poder leer el archivo no hay forma de saber si está integrado).
- **Regla**, por cada versión `v`:
  1. Si `vault_delta_checkpoint v` falla → se omite.
  2. Si no existe `<vault_root>/_templates/.schema-updates-<v>.applied` → se omite (nunca se depositó).
  3. Si `grep -F -q -- "<hito>" <vault_root>/CLAUDE.md` tiene éxito → se omite (integrado).
  4. Si no → se imprime `v`.

## Garantías

- **Solo lectura**: nunca escribe ni crea archivos.
- **Fresca**: no lee `.graph/` ni `wiki-graph.json`; refleja el estado del disco en el momento de la llamada.
- **Barata**: por versión, un `test -f` y un `grep -F` sobre un archivo. No escala con el tamaño del vault.
- **Sin pipelines con salida temprana**: nada de `producer | grep -q` bajo `pipefail` (gotcha SIGPIPE del
  `CLAUDE.md` del repo); el `grep -F -q` lee un archivo, no una tubería.
- **Portable**: bash 3.2 a 5.3 y busybox.
- **Carga segura**: definir las funciones no ejecuta nada (mismo patrón de librería que el resto de
  `scripts/lib/`).

## Guardias de deriva (tests obligatorios)

1. Cada `modules/vault-deltas/schema-updates-<v>.md` tiene `vault_delta_checkpoint <v>` con código 0, y cada
   versión de `vault_delta_versions` tiene su documento.
2. `modules/vault-skeleton/CLAUDE.md` contiene el hito de cada versión (un vault nuevo nunca queda pendiente,
   aunque `vault_seed_if_empty` le escriba el `.applied` de 0.27.0).
3. El literal que usa `scripts/lib/wiki_graph.sh` para `integrated` es igual a `vault_delta_checkpoint 0.27.0`.
4. `modules/vault-deltas/schema-updates-0.27.0.md` contiene su propio hito.

## Consumidores

- `scripts/hooks/upgrade-notice.sh` (contrato `upgrade-notice-hook.md`).
- `scripts/agentctl::_upgrade_notice_doctor` (mismo contrato, sección doctor).

## Fuera de este contrato

- Derivar los hitos del contenido de los documentos (descartado en research R2).
- Cambiar la detección de `schema_delta_pending` de 037 o su gracia de 14 días.
