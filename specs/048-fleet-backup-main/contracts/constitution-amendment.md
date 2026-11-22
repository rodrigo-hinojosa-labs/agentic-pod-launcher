# Contract K: enmienda del Principio V (1.1.0 → 1.2.0)

## Texto que reemplaza la viñeta de los respaldos

> - Backups are five INDEPENDENT units (`identity`, `vault`, `config`, `memory`, `history`) with sha256 content idempotency and per-unit clone caches. With the agent's associated repository, each unit backs up into its own directory `.agent-backup/<unit>/` of the repository's `main` branch, changes nothing outside that directory (the `config` unit also owns `.agent-backup/README.md`), never force-pushes or rewrites the history of `main`, and integrates with concurrent commits by rebuilding its own commit on the current tip. With a fork, each unit keeps its own orphan branch (`backup/<unit>`) as before. The units MUST NOT be merged into a shared primitive: each unit keeps its own clone cache, content hash, staging and commit code, and each MUST be able to be absent without breaking the others. What the units MAY share is limited to code that never stages a unit's tree: the destination rule (the agent's associated repository, else its fork, else nowhere), the push credential, the privacy check and its record, the ownership mark, the per-unit run lock, the record of the last attempt, the encrypted block store, the construction of a commit over the tip of `main` from a unit's already-staged tree, and the verified deletion of a unit's legacy `backup/<unit>` branch. Changes MUST preserve `setup.sh --restore-from-fork` (restore order: config → identity → vault → memory → history), reading each unit from `main` when present and from its branch otherwise.

## Fila del Sync Impact Report

| Versión | Fecha | Cambio | Motivo |
| --- | --- | --- | --- |
| 1.2.0 | 2026-11-21 | Principio V: con repositorio asociado, los respaldos son directorios de `main` en vez de ramas huérfanas; se amplía la lista de lo compartible | Decisión del operador del 21-11-2026 (feature 048); el camino del fork no cambia |

## Plantillas

`.specify/templates/` no menciona ramas de respaldo (verificar con `grep -rn 'orphan\|backup/' .specify/templates`); si las menciona, se actualizan en el mismo commit.
