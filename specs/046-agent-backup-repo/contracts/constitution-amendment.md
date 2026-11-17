# Contrato: enmienda de la constitución (1.0.1 a 1.1.0)

**Feature**: `046-agent-backup-repo` | Cubre FR-020.

La enmienda se aplica en `.specify/memory/constitution.md` como primera tarea de implementación, antes de cualquier cambio de código, y viaja en el mismo PR. El bump es MINOR: la propia constitución lo define así para una guía ampliada de forma material.

Los textos de este contrato se copian literalmente.

## E1. Principio V, primera viñeta

### Primera viñeta: texto actual

```markdown
- `.state/` is gitignored, contains secrets/tokens, and MUST NEVER be committed
  or logged.
```

### Primera viñeta: texto nuevo

```markdown
- `.state/` is gitignored, contains secrets/tokens, and MUST NEVER be committed
  or logged, other than the whitelisted subset the backup branches carry.
```

La regla ya tenía esa excepción de hecho: la unidad de identidad respalda archivos de `.state/` desde antes de esta feature. La enmienda la deja escrita.

## E2. Principio V, tercera viñeta

### Tercera viñeta: texto actual

```markdown
- Backups are three INDEPENDENT orphan branches (`backup/identity`,
  `backup/vault`, `backup/config`) with sha256 content idempotency and per-branch
  clone caches. They MUST NOT be merged into a shared primitive; each MUST be able
  to be absent without breaking the others; changes MUST preserve
  `setup.sh --restore-from-fork` (restore order: config → identity → vault).
```

### Tercera viñeta: texto nuevo

```markdown
- Backups are five INDEPENDENT orphan branches (`backup/identity`,
  `backup/vault`, `backup/config`, `backup/memory`, `backup/history`) with sha256
  content idempotency and per-branch clone caches. They MUST NOT be merged into a
  shared primitive: each unit keeps its own branch, clone cache, content hash,
  staging and commit code, and each MUST be able to be absent without breaking
  the others. What the units MAY share is limited to code that never stages a
  tree, commits or pushes: the destination rule (the agent's associated
  repository, else its fork, else nowhere), the push credential, the privacy
  check and its record, the branch ownership mark, the per-unit run lock, the
  record of the last attempt, and the encrypted block store. Changes MUST
  preserve `setup.sh --restore-from-fork` (restore order: config → identity →
  vault → memory → history).
- The launcher's backup branches are its only sanctioned path for taking
  whitelisted state out of `.state/`. The secrets file, conversation transcripts,
  the claude-mem store and operator-declared extra paths MUST travel encrypted so
  that only the holder of the operator's key can read them; for an agent marked
  as sensitive, so MUST its vault, its auto memory and its configuration other
  than `agent.yml`. None of these MAY be pushed in plaintext when that key is
  missing or when the destination cannot carry them encrypted. The sensitive
  mark is a docker-mode setting: in local mode the launcher MUST warn that it
  is not honoured.
```

- **Lo que se puede compartir es una lista cerrada**. Cada pieza de la lista existe en el diseño: la regla de destino, el askpass, la comprobación de privacidad con su registro, la marca de pertenencia, el candado, el registro del intento ([destination-and-credential.md](destination-and-credential.md)) y el almacén ([block-store.md](block-store.md)). Ninguna arma un árbol, hace un commit ni empuja.
- **Un fork no lleva almacén**: lo que la lista manda cifrar no se empuja ahí en claro. Por eso el vault de un agente sensible con fork y sin repositorio no se empuja.
- **Lo que se cifra es una lista cerrada**, la misma de D7 de [research.md](../research.md). Lo que no está en la lista (la persona de un agente sin marcar, su vault, su auto-memoria y la lista en claro de la identidad) puede viajar en claro.

## E3. Principio V, `Rationale`

| Texto actual | Texto nuevo |
| --- | --- |
| `disaster recovery (rehydrate from a` seguido de `fork without re-login)` | `disaster recovery (rehydrate from the agent's repository or its fork)` |

Se quita `without re-login`: el login que deja `/login` no viaja en ningún respaldo (M14 y D24 de [research.md](../research.md)). El resto del párrafo queda igual; se vuelve a cortar en líneas de hasta 80 columnas.

## E4. Development Workflow & Quality Gates, "Scope discipline"

| Texto actual | Texto nuevo |
| --- | --- |
| `the three backup` seguido de `primitives stay independent (Principle V)` | `the backup primitives stay independent (Principle V)` |

Solo se quita la palabra `three`; el resto de la viñeta queda igual.

## E5. Versión

```markdown
**Version**: 1.1.0 | **Ratified**: 2026-06-18 | **Last Amended**: <fecha de la enmienda, en ISO>
```

## E6. Informe de sincronización

Se agrega un bloque de comentario después del bloque de 1.0.1 y antes del título, con la misma forma:

```text
SYNC IMPACT REPORT (1.0.1 → 1.1.0)
===================================
Version change: 1.0.1 → 1.1.0
Bump rationale: MINOR — materially expanded guidance in Principle V. Feature 046
  associates a private repository with each agent and makes the agent
  recoverable from it. That needs two more backup units (memory, history), a
  closed list of what the units may share, and a closed list of what must travel
  encrypted.

Sections changed:
  Principle V → the whitelisted-subset proviso on `.state/`; five orphan
    branches; the closed list of shared, non-committing code; the extended
    restore order; the encryption rule; the rationale no longer promises a
    login-free restore.
  Development Workflow & Quality Gates → "Scope discipline" no longer says
    "three".

Templates requiring updates: none (no template names the number of branches).

Follow-up TODOs: none.
```

## E7. Plantillas y documentos dependientes

- `.specify/templates/`: ninguna plantilla nombra la cantidad de ramas (verificado con una búsqueda el 13-11-2026). No hay nada que cambiar.
- Los documentos del launcher que dicen "three orphan branches" se actualizan en la tarea de documentación, no en esta: `README.md`, `docs/getting-started.md`, `docs/heartbeatctl.md`, `docs/state-layout.md` y `docs/vault.md`.

## E8. Lo que la enmienda no cambia

- Los principios I, II, III, IV y VI.
- La segunda viñeta del Principio V.
- La regla de que cada unidad tiene su propia caché de clon y su propio estado.

## E9. Comprobación

Después de aplicar la enmienda:

| Comando | Resultado esperado |
| --- | --- |
| `grep -c 'five INDEPENDENT' .specify/memory/constitution.md` | 1 |
| `grep -c 'three INDEPENDENT' .specify/memory/constitution.md` | 0 |
| `grep -c 'the three backup' .specify/memory/constitution.md` | 0 |
| `grep -c 'without re-login' .specify/memory/constitution.md` | 0 |
| `grep -c 'other than the whitelisted subset' .specify/memory/constitution.md` | 1 |
| `git diff --stat -- .specify/templates` | Vacío |
