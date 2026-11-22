# Implementation Plan: Respaldos en main y cierre de los pendientes de la flota

**Branch**: `048-fleet-backup-main` | **Date**: 2026-11-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/048-fleet-backup-main/spec.md`

## Summary

Con `backup.repo.url`, las cinco unidades de respaldo de 046 dejan de escribir ramas huérfanas `backup/<unidad>` y pasan a escribir cada una su directorio `.agent-backup/<unidad>/` en `main` del repositorio del agente. El commit de cada unidad se construye con plumbing sobre la punta vigente de `main` (reemplaza solo su subárbol), se empuja sin force y se reconstruye si `main` avanzó (R1, R4). Cada caché es un clon parcial sin blobs con checkout parcial de su directorio (R2), y la idempotencia pasa a juzgarse por el subárbol (R3). Tras verificar en el remoto que su directorio está en `main`, cada unidad borra su rama heredada si lleva la marca del agente (R6). Si `main` está protegida, la unidad abre y mergea un pull request con `GITHUB_PAT` (R7). La restauración lee de `main` y cae a las ramas (R10). El clon de trabajo del agente excluye `.agent-backup/` con checkout parcial, filtro y un hook (R9).

La feature corrige además tres avisos falsos del doctor medidos en la flota: la sonda de Atlassian consulta Confluence cuando Jira no existe (404); el doctor lee el estado del heartbeat de su ruta y campo reales; y la sonda de Claude reconoce el token de entorno (R11). Cierra con el despliegue en la flota: cbum como canario, ensayo de restauración, linus y donna, y limpieza (contrato G). Enmienda el Principio V a 1.2.0 (R12) y sube la VERSION a 0.34.0.

## Technical Context

**Language/Version**: bash 3.2–5.3 en el host (`setup.sh`, `scripts/agentctl`); POSIX sh y bash de Alpine en la imagen (`docker/scripts/heartbeatctl`, librerías); Python 3 en la imagen (`backup_store.py`, sin cambios de formato).
**Primary Dependencies**: `git` con clon parcial y `sparse-checkout` (M1), `jq`, `yq` v4, `curl` (camino PR), `age` (sin cambios).
**Storage**: el repositorio privado de GitHub del agente (`main` y, mientras existan, `backup/*`); estado por unidad en `scripts/heartbeat/<unidad>-backup.json`; cachés en `.state/.cache/agent-backup/`.
**Testing**: `bats` en el host con el servidor git de 046 (`tests/fixtures/backup-repo/git-auth-server.py`) más filtros; un servidor de prueba de la API de GitHub para el camino PR; `DOCKER_E2E=1` para el contenedor.
**Target Platform**: contenedor Alpine 3.24 (arm64 en la flota, amd64 en la nocturna); host macOS y Linux para `setup.sh` y la restauración.
**Project Type**: CLI y scripts (launcher).
**Performance Goals**: un ciclo sin cambios no baja blobs (solo árboles de la punta); un ciclo con cambios baja solo los blobs de su unidad.
**Constraints**: nunca force ni reescritura de `main`; cada commit toca solo su directorio; el token nunca en `argv`, URL ni config; fork y sin destino byte a byte iguales; tiempos acotados por llamada (60 s git, 20 s API, 90 s el camino PR).
**Scale/Scope**: 3 agentes con repositorio hoy; cachés de 2,8 a 123 MB; cinco unidades.

## Constitution Check

*GATE: antes de la Fase 0 y otra vez después del diseño.*

| Principio | Evaluación | Estado |
| --- | --- | --- |
| I. Single Source of Truth | Ningún campo nuevo en `agent.yml`: el destino sigue siendo `backup.repo.url`. La sección *Your repository* sale de `modules/claude-md.tpl`. | PASS |
| II. Least-Privilege | Sin capacidades, montajes ni puertos nuevos. El camino PR usa la red saliente y la credencial que 046 ya usa. Revisión de privilegios obligatoria por tocar `docker/`. | PASS (con revisión) |
| III. Test-First, Host-Runnable | Cada contrato tiene sus invariantes como pruebas del host; e2e detrás de `DOCKER_E2E`. | PASS |
| IV. Idempotent, Fail-Silent | Idempotencia por hash y subárbol (R3); reintentos acotados; ningún fallo de respaldo tumba el supervisor ni el heartbeat. | PASS |
| V. Workspace-Is-the-Agent | **Contradice** la viñeta "five INDEPENDENT orphan branches". Se resuelve con la enmienda 1.2.0 (contrato K), que conserva la independencia de las unidades en caché, hash, staging y commit y amplía la lista de lo compartible con dos piezas que no preparan el árbol de ninguna unidad. | PASS tras la enmienda |
| VI. Pinned Dependencies | Sin dependencias nuevas; `git` y `curl` ya están en la imagen (M1 confirma versiones). | PASS |
| Gates de workflow | Regenerate-safety (la plantilla de CLAUDE.md), test gate con DOCKER_E2E, privilege gate, documentation gate (CHANGELOG, docs, VERSION 0.34.0). | Planificados |

**Re-check post-diseño**: los contratos M, L, P, R, W, D y G no agregan capacidades ni estado fuera de `.state/` y del repositorio; la única violación es la de V y queda cubierta por K. Complexity Tracking registra la redefinición.

## Project Structure

### Documentation (this feature)

```text
specs/048-fleet-backup-main/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── checklists/requirements.md
├── contracts/
│   ├── main-backup.md            # M: una unidad respalda en main
│   ├── legacy-migration.md       # L: borrado verificado de backup/<u>
│   ├── pr-fallback.md            # P: main protegida
│   ├── restore-from-main.md      # R: restauración
│   ├── work-clone.md             # W: clon de trabajo
│   ├── doctor-and-probes.md      # D: doctor y sondas
│   ├── fleet-gate.md             # G: despliegue, ensayo, limpieza
│   └── constitution-amendment.md # K: Principio V 1.2.0
└── tasks.md                      # /speckit-tasks
```

### Source Code (repository root)

```text
docker/scripts/
├── heartbeatctl                  # _repo_* comunes: verify de main, build/push con reintento, migración, backup-status
├── lib/backup_dest.sh            # lectura de la marca en main; construcción del commit sobre la punta (R1); borrado verificado (R6)
├── lib/backup_identity.sh        # identity_main_prepare/commit (la rama de fork queda igual)
├── lib/backup_config.sh          # config_main_* + README de .agent-backup
├── lib/backup_memory.sh          # memory_main_*
├── lib/backup_history.sh         # history_main_*
├── lib/agent_repo.sh             # checkout parcial, filtro y hook (W)
├── lib/backup_pr.sh              # NUEVO: camino PR (P); su COPY en docker/Dockerfile
├── lib/token_health.sh           # probe_atlassian con Confluence; probe_claude_oauth con token de entorno (D1, D2)
└── check_token_health.sh         # llamada a la sonda de Claude (D2)
scripts/lib/backup_vault.sh       # vault_main_* (espejo docker si aplica, como en 046)
scripts/agentctl                  # doctor: estado del heartbeat (D3), peso del repositorio (D4)
setup.sh                          # restauración desde main (R)
modules/claude-md.tpl             # sección Your repository (W2)
.specify/memory/constitution.md   # Principio V 1.2.0 (K)
tests/
├── backup-main-units.bats        # NUEVO
├── backup-main-legacy.bats       # NUEVO
├── backup-main-pr.bats           # NUEVO
├── backup-main-restore.bats      # NUEVO
├── agent-repo-sparse.bats        # NUEVO
├── agentctl-doctor-heartbeat.bats# NUEVO
├── docker-e2e-backup-main.bats   # NUEVO, DOCKER_E2E
├── fixtures/backup-repo/gh-api-server.py   # NUEVO: API de GitHub falsa (PR)
└── (extensiones) token-health-lib.bats, token-health-claude-oauth.bats, backup-repo-*.bats, restore-*.bats
```

**Structure Decision**: se extienden las librerías por unidad de 046 con funciones `<unidad>_main_*` hermanas de las `<unidad>_repo_*` (que siguen sirviendo para leer la rama heredada durante la migración) y la orquestación común de `heartbeatctl`. El camino PR va en una librería propia porque es lo único que habla con la API de GitHub. Sin espejo nuevo bajo `scripts/lib/` salvo el vault, que ya vive ahí.

## Complexity Tracking

| Violación | Por qué se necesita | Alternativa más simple rechazada porque |
| --- | --- | --- |
| Redefinición del Principio V (las unidades comparten la rama `main`) | Decisión explícita del operador del 21-11-2026, tras exponérsele los costos | Mantener las ramas `backup/*`, verlas desde main con un README o usar un repo de respaldo aparte: las tres se ofrecieron y el operador eligió los respaldos dentro de main |
| Borrado de ramas por el launcher (capacidad destructiva nueva) | Decisión del operador en Clarifications | Dejar las ramas intactas: rechazado por el operador; mitigado con verificación de árbol, marca y orden (contrato L) y con cbum como canario |
| Llamadas a la API de GitHub (camino PR) | Decisión del operador para `main` protegida | Fallar visible sin PR: rechazado por el operador; se aísla en `backup_pr.sh`, con presupuesto de tiempo y el token por `-K` |
