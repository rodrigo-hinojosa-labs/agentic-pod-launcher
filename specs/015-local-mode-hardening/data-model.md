# Phase 1 Data Model: Local-mode & docker RAG hardening

Este launcher no tiene base de datos; las "entidades" son valores de configuración
y artefactos de estado que la feature toca. Cada una lista su fuente de verdad,
reglas de validación y transiciones relevantes.

---

## E1 — Ruta del CLI de Claude (`deployment.claude_cli` → `CLAUDE_BIN`)

- **Fuente de verdad**: `agent.yml` → `deployment.claude_cli` (Principle I).
- **Derivado**: `CLAUDE_BIN` (exportado por `_export_local_context`) → `{{CLAUDE_BIN}}`
  en `modules/systemd-remote-control.service.tpl:14` (`ExecStart`).
- **Campos / forma**: string, ruta **absoluta** a un ejecutable estable
  (p.ej. `/home/<op>/.local/bin/claude`, el symlink del native installer).
- **Reglas de validación**:
  - MUST ser absoluta (`/…`) y ejecutable (`-x`) desde la perspectiva del usuario de
    la unit (`User={{OPERATOR_USER}}`), no del shell que corrió `--regenerate`.
  - MUST apuntar a una referencia **estable** (symlink), no a una versión concreta
    que las actualizaciones de Claude Code invaliden.
  - Si no resuelve a un ejecutable en ningún candidato conocido → **error ruidoso**,
    no persistir ni renderizar una unit rota.
- **Candidatos de resolución** (orden): `command -v claude-enterprise|claude-personal|claude`
  (ya devuelve absoluta si está en PATH) → `$OPERATOR_HOME/.local/bin/claude` →
  `$OPERATOR_HOME/.claude/local/claude`.
- **Transiciones**:
  - *scaffold*: `detect_claude_cli` resuelve → persiste absoluta en `agent.yml`.
  - *regenerate*: si el valor persistido es absoluto+ejecutable → usar tal cual; si
    no (relativo, movido, o vacío) → re-resolver por candidatos → re-persistir; si
    nada resuelve → fail-loud.

## E2 — Build de `bun` provisionada

- **Fuente de verdad**: versión en `modules/local-bootstrap.sh.tpl:29`
  (`BUN_VERSION=1.3.14`, espeja el ARG de `docker/Dockerfile:107`).
- **Campos / forma**: binario en `${TARGET_BIN}/bun` + symlink `bunx`; variante de
  build ∈ {glibc, musl} correspondiente a la libc del host.
- **Reglas de validación**:
  - La variante MUST corresponder a la libc del host (R1): musl→musl, glibc→glibc.
  - Post-provisioning, `bun --version` MUST ejecutar (rc 0). Presencia del archivo
    NO es suficiente (una build musl-en-glibc existe pero no ejecuta).
- **Transiciones (idempotencia FR-005)**:
  - *ausente* → descargar la build por R1 → instalar → symlink `bunx`.
  - *presente y ejecuta* (`bun --version` rc 0) → no-op.
  - *presente pero NO ejecuta* (build incompatible) → re-provisionar con la build
    correcta (no dejar la rota).

## E3 — Directorio de temporales (`TMPDIR` host-backed)

- **Fuente de verdad**: derivado en runtime por los wrappers; anclado al cache root
  ya resuelto (013). No vive en `agent.yml`.
- **Campos / forma**: ruta a un dir host-backed bajo `.state`
  (docker: bajo `$HOME`=`/home/agent`; local: bajo `.state/.cache/qmd`).
  Propuesto: `${cache_root}/tmp` ó `${XDG_CACHE_HOME:-$HOME/.cache}/tmp`.
- **Reglas de validación**:
  - MUST estar respaldado por disco host (no el tmpfs RAM `/tmp`).
  - `mkdir -p` fail-silent; si no se puede crear, el wrapper degrada pero **registra**.
  - Consumido por: extracción de paquete de `bunx` (`$TMPDIR/bunx-<uid>-<pkg>`),
    temporales de qmd, y `mktemp`/`mktemp -d` del runner wiki-graph.
- **Transiciones**: creado on-demand por el wrapper; persiste entre corridas
  (cache de bunx reutilizable → menos cold-starts).

## E4 — State files de batch (observabilidad)

- **Fuente de verdad**: escritos atómicamente por los runners; NO respaldados.
  - `wiki-graph.json` (schema 1): `{schema, last_run, last_status, duration_ms, counts, error}` — `wiki_graph.sh:70-85`.
  - `qmd-index.json`: `{hash, last_run, last_status, runs}` — `qmd_index.sh:98-119`.
- **Regla nueva (FR-007/FR-008)**: el campo `error` (wiki-graph) y el log del reindex
  (qmd) MUST contener el **error real** de infraestructura/qmd cuando falle, no un
  genérico vacío. Ej.: `"aggregation failed: /tmp: No space left on device"` en vez
  de `"jq aggregation failed"`.
- **Regla de seguridad (Principle V)**: antes de escribir stderr/env al state/log,
  redactar secretos (`sk-ant-[A-Za-z0-9_-]+`, `*_TOKEN`, `*_KEY`, OAuth). El state
  file y el log NO deben poder filtrar credenciales.
- **`last_status` valores**: `ok` | `error` | `skipped` (wiki-graph);
  `indexed` | `skipped` | `error` (qmd). Sin cambios de enum; cambia el contenido de
  `error`/log.

---

## Relaciones

```text
agent.yml.deployment.claude_cli ──(render)──> CLAUDE_BIN ──> systemd ExecStart   (E1, US1)
host libc ──(probe R1)──> variante de bun ──> bunx ──> qmd                        (E2, US2)
cache_root(.state) ──> TMPDIR host-backed ──> {bunx cache, qmd tmp, wg mktemp}    (E3, US3)
runner stderr real ──(redactado)──> state.error / reindex log                    (E4, US3/US4)
```

Ninguna entidad cambia de esquema JSON; los cambios son de **procedencia del valor**
(absoluta vs pelada, glibc vs musl, host-backed vs tmpfs, error real vs genérico).
