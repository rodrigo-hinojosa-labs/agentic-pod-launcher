# Research: 048-fleet-backup-main

Fecha: 21-11-2026. Fuentes: código de `origin/main` (`6170dda`), mediciones en ferrari y en GitHub de ese día, y `git` 2.53.0 del Mac (las versiones de `git` de la imagen Alpine y de los runners se miden en la Fase 0 de tasks, M1).

## Lo que el código de 046 hace hoy (leído, no supuesto)

- Cada unidad del camino de repositorio tiene `<unidad>_repo_prepare`, `<unidad>_repo_commit_and_push` y `<unidad>_repo_write_state` en su librería (`docker/scripts/lib/backup_{identity,config,memory,history}.sh`, `scripts/lib/backup_vault.sh`). `prepare` crea o reutiliza una caché en `/home/agent/.cache/agent-backup/<unidad>-repo` (identity: `identity-backup/identity-repo`), con `HEAD` en `refs/heads/backup/<unidad>`, hace `fetch --depth 1` de esa rama y vacía el árbol (salvo `store/` si se pide conservarlo). `commit_and_push` escribe la marca `.agentic-pod-backup.json`, `add -A`, commitea con autor `<unidad>-backup@localhost` y empuja `HEAD:refs/heads/backup/<unidad>`.
- La orquestación vive en `docker/scripts/heartbeatctl` (`_repo_begin`, `_repo_verify`, `_repo_owner_ok`, `_repo_fail`, `_repo_store_pack`, `_repo_store_unit`, y `_bi_run_repo`, `_bv_run_repo`, `_bc_run_repo` y las de memory/history). La idempotencia es: mismo hash de contenido Y `backup/<unidad>` remota igual a `last_commit` del estado.
- `backup_dest_verify` (`docker/scripts/lib/backup_dest.sh`) hace la sonda anónima y la autenticada y deja los heads en un archivo; `backup_dest_branch_head` lee de ahí la cabeza de una rama; `backup_dest_check_owner` lee la marca de `origin/<rama>`.
- El clon de trabajo (`docker/scripts/lib/agent_repo.sh`) excluye `backup/*` del fetch con un refspec negativo y elige `main` (o la rama por defecto) como rama de trabajo.
- La restauración (`setup.sh`, `_restore_clone_branch`, `_restore_store_unit`, `restore_from_fork`) clona cada rama `backup/<unidad>` con `--single-branch --depth 1` y trabaja sobre la raíz de ese árbol.

## Decisiones

### R1. El commit de una unidad se construye con plumbing sobre la punta de `main`, no con merge ni rebase

- **Decision**: la unidad arma el árbol de su directorio (con un índice temporal limitado a sus propias rutas, cuyos blobs sí tiene) y crea el commit con `git commit-tree`, cuyo árbol es el de la punta actual de `main` con el subárbol `.agent-backup/<unidad>` reemplazado por el suyo. El árbol raíz NO se arma con un índice completo: en un clon `blob:none`, `read-tree FETCH_HEAD` + `write-tree` verifica la existencia de todos los blobs del árbol y, con remoto promisor, los descarga por demanda (los de las otras cuatro unidades y los de la raíz), lo que anula R2. Se arma con plumbing de árboles: `ls-tree FETCH_HEAD:.agent-backup` (sin blobs), reemplazo de la entrada `<unidad>` (y `README.md` en config) y `mktree --missing`; luego `ls-tree FETCH_HEAD`, reemplazo de la entrada `.agent-backup` y `mktree --missing` para la raíz. `mktree --missing` no exige que los objetos referenciados estén en el repo local. Si el empuje es rechazado porque `main` avanzó, vuelve a pedir la punta y reconstruye el commit sobre ella (el subárbol de la unidad no cambia, solo el padre y el resto del árbol).
- **Rationale**: la unidad es dueña exclusiva de su directorio (FR-002, FR-008), así que no hay conflicto posible: lo de afuera se toma tal cual de `main` y lo de adentro tal cual del agente. Reconstruir en vez de mergear nunca deja un merge a medio resolver, no necesita el historial (sirve con `--depth 1`) y cumple FR-005 (nunca force) porque el commit nuevo desciende de la punta vigente. Un cambio ajeno dentro del directorio queda sobrescrito y se detecta comparando el subárbol remoto con el último que la unidad empujó (FR-008).
- **Alternatives considered**: índice completo con `read-tree` + `write-tree` (descarga o exige los blobs ajenos, ver arriba); `git pull --rebase` (necesita historial y puede detenerse en conflicto); merge (deja commits de merge en `main` en cada carrera); una rama intermedia mergeada por el launcher (dos commits por ciclo y más estado).

### R2. Clon parcial sin blobs y checkout parcial de un solo directorio

- **Decision**: la caché de cada unidad es un clon de `main` con `--filter=blob:none`, `--depth 1` y checkout parcial en modo NO cono con el patrón `/.agent-backup/<unidad>/` (medido en T002: el modo cono baja siempre los archivos de la raíz). El subárbol remoto se lee con `git rev-parse FETCH_HEAD:.agent-backup/<unidad>` sin bajar ningún blob.
- **Rationale**: con los respaldos en `main`, la punta trae los cinco directorios (en donna, ~123 MB en las cachés de 046). Sin filtro, cada unidad bajaría en cada ciclo los blobs de las otras cuatro. Con `blob:none` y checkout parcial, la unidad baja solo árboles y, al hacer checkout, solo los blobs de su directorio, que además reutiliza con su mapa de bloques. GitHub soporta clones parciales en HTTPS.
- **Alternatives considered**: clon completo por unidad (multiplica el tráfico por cinco y crece con el historial); una caché compartida entre unidades (prohibida por el Principio V: cada unidad su caché).
- **A medir (M1)**: que la imagen trae un `git` con `sparse-checkout`, filtros de clon y `mktree --missing` (≥ 2.25; Alpine 3.24 trae 2.4x); que construir el commit con R1 y empujarlo desde un clon superficial y parcial no dispara ninguna descarga del promisor (contar las peticiones `upload-pack` en el log del servidor de prueba: solo las del `fetch` inicial y las del checkout de la unidad); y que el servidor de pruebas de 046 (`tests/fixtures/backup-repo/git-auth-server.py`, sobre `git http-backend`) acepta filtros con `uploadpack.allowFilter=true`.

### R3. La idempotencia se juzga por el subárbol, no por la cabeza de la rama

- **Decision**: el estado de cada unidad gana `last_tree` (el id del árbol `.agent-backup/<unidad>` que empujó). "Sin cambios" pasa a ser: mismo hash de contenido de 046 Y subárbol remoto de `main` igual a `last_tree`. La condición vieja (cabeza remota igual a `last_commit`) ya no sirve, porque `main` avanza por commits ajenos.
- **Rationale**: conserva SC-004 (segundo ciclo sin commits) aunque `main` reciba trabajo, y detecta un cambio ajeno o un force push del operador sobre el directorio (subárbol distinto, o ausente) para reescribirlo (edge cases).
- **Alternatives considered**: comparar contra `last_commit` (falla en cuanto alguien commitea en `main`); rehacer el commit y dejar que `diff --cached` decida (bajaría blobs y crearía la caché en cada ciclo).

### R4. Reintentos acotados dentro del límite de tiempo de la unidad

- **Decision**: hasta 5 intentos de empuje por corrida, con espera aleatoria de 1 a 5 s entre intentos, todos dentro del `timeout` por llamada de git de 046 (`BACKUP_GIT_TIMEOUT_S`, 60 s). Al agotarse: resultado `main-busy`, mensaje `backup-<unidad>: main kept moving - nothing pushed, retrying next cycle`, código de salida 2 (como `push-failed`), registro en el último intento.
- **Rationale**: cinco unidades más una persona rara vez chocan más de dos veces; la espera aleatoria separa a las unidades que dispara el mismo minuto (identity y config a las 03:30). El fallo es visible y el próximo ciclo reintenta (FR-006).
- **Alternatives considered**: reintentos sin límite (puede colgar el cron); un candado global en `main` (contradice el Principio V y no protege de las personas).

### R5. Commit del launcher identificable y sin CI

- **Decision**: autor y committer `agentic-pod-backup <backup@agentic-pod.invalid>`; mensaje `backup(<unidad>): <agente> <ISO-8601> [skip ci]`, con el trailer `Agentic-Pod-Backup: <agente>/<unidad>`.
- **Rationale**: FR-009. GitHub Actions omite los workflows de `push` y `pull_request` cuando el mensaje del commit de cabeza contiene `[skip ci]` (convención documentada de Actions). El trailer permite filtrar el historial (`git log --invert-grep --grep 'Agentic-Pod-Backup:'`). El dominio `.invalid` no puede pertenecer a nadie.
- **Alternatives considered**: el autor `<unidad>-backup@localhost` de 046 (no distingue agente); sin `[skip ci]` (un workflow en `push` correría en cada ciclo).

### R6. Verificación previa al borrado de la rama heredada

- **Decision**: tras un empuje aceptado (o un ciclo sin cambios con su directorio ya en `main`), la unidad vuelve a pedir la punta remota de `main` y compara su subárbol con el que acaba de empujar. Solo si coinciden, y si `backup/<unidad>` existe en los heads y su marca (leída con un fetch `--depth 1` sin blobs de la rama más la lectura de un solo blob) nombra a este agente y a esta unidad, la borra con `git push origin :refs/heads/backup/<unidad>`. Registra `legacy_branch: deleted <fecha>` en su estado. Si algo falla, la rama queda y el próximo ciclo reintenta.
- **Rationale**: FR-016, FR-017 y SC-008, con la decisión del operador de que el launcher borre. La comparación de árboles prueba que lo que está en `main` es exactamente lo recién respaldado (el árbol incluye la marca). Leer la marca de la rama antes de borrar impide tocar una rama sin marca o de otro agente.
- **Alternatives considered**: borrar al primer empuje sin verificar (viola FR-016); dejar el borrado al operador (rechazado por el operador en Clarifications).

### R7. Camino de pull request si `main` rechaza el empuje por protección

- **Decision**: si el empuje es rechazado con un mensaje de protección (GitHub responde `GH006: Protected branch update failed` o `protected branch hook declined`), la unidad empuja el mismo commit a `agent-backup-pr/<unidad>-<epoch>`, abre un pull request hacia `main` con la API REST de GitHub y lo mergea con el método `merge` (conserva el commit de respaldo y su `[skip ci]`); si el merge responde 200, borra la rama temporal. Si la creación o el merge fallan (405 por revisión obligatoria o checks pendientes, 403, 409, red), cierra el pull request si se creó, borra la rama temporal y falla con `main-protected`. El token llega a `curl` por un archivo de configuración 0600 (`-K`), nunca por `argv` (patrón de 040).
- **Rationale**: decisión del operador en Clarifications. Hoy no se ejerce (la cuenta no puede proteger ramas privadas), así que se prueba contra un servidor de prueba que emula los dos rechazos y las respuestas de la API.
- **Alternatives considered**: volver a la rama `backup/<unidad>` (rechazado por el operador: dos ubicaciones posibles).
- **Medido (M2, T003)**: GitHub documenta literal `remote: error: GH006: Protected branch update failed for refs/heads/main.` (página *About protected branches*); `GH013` de rulesets no aparece en la documentación leída. La detección acepta `GH006`, `GH013`, `protected branch` o `Repository rule violations`, sin distinguir mayúsculas. El servidor de prueba usa el texto de GH006.

### R8. El directorio raíz, su README y quién lo escribe

- **Decision**: `.agent-backup/README.md` está en la raíz del directorio, fuera de los cinco subdirectorios, y su único dueño es la unidad `config` (corre a diario y ya escribe `CLAUDE.md` y la persona). El commit de `config` puede tocar exactamente dos rutas: `.agent-backup/config/` y `.agent-backup/README.md`. El texto es fijo, nombra al agente y explica cada directorio y cómo restaurar; solo cambia cuando cambia la plantilla. FR-002 se enmienda con esa excepción.
- **Rationale**: un dueño único evita que dos unidades se pisen el README; `config` es la unidad que describe la configuración del agente.
- **Alternatives considered**: README dentro de cada directorio (cinco copias casi iguales); que lo escriba el wizard (no corre en agentes existentes).

### R9. El clon de trabajo no ve ni puede tocar `.agent-backup/`

- **Decision**: `agent_repo.sh` aplica en la creación y en cada reparación (`_agent_repo_settings`, que ya corre en el arranque y en el ciclo diario de `config`): checkout parcial en modo no cono con `/*` y `!/.agent-backup/`, filtro `blob:none` como promisor del remoto, y un hook `pre-commit` del launcher que rechaza cualquier ruta preparada bajo `.agent-backup/` con un mensaje claro.
- **Rationale**: FR-010. El checkout parcial saca el directorio del árbol de trabajo; un `git add -A` no prepara borrados de rutas excluidas (skip-worktree); el hook cubre el caso en que el agente fuerce un `git add`. El filtro evita que un `git pull` del agente baje el historial de blobs cifrados.
- **Alternatives considered**: `.gitignore` (no aplica a archivos ya versionados); solo el hook (el directorio seguiría visible y pesado).
- **Consecuencia aceptada**: un clon humano normal (como el de la Mac para donna) baja todo el historial de `main`. El README y la documentación recomiendan clonar con `--filter=blob:none` y excluir `.agent-backup/`.

### R10. Restauración: `main` primero, rama después

- **Decision**: `_restore_store_unit` y el paso de `config` en `restore_from_fork` intentan primero un clon de `main` con `--filter=blob:none --depth 1 --no-checkout` y checkout parcial de `.agent-backup/<unidad>`; si el directorio existe y su marca nombra la unidad (y el agente, cuando se conoce por `agent.yml` de `config`), trabajan sobre ese directorio en vez de la raíz de la rama. Si no, caen a `_restore_clone_branch` como hoy. Cada línea del informe dice `from main` o `from backup/<unidad>`.
- **Rationale**: FR-014 y FR-015 con el menor cambio: el resto de la restauración (R9 de 046, el almacén, el orden) recibe una raíz distinta y sigue igual.
- **Alternatives considered**: restaurar solo desde `main` (rompe los repos aún no migrados); elegir la ubicación más nueva por fecha (más casos, sin beneficio tras la migración).

### R11. Doctor y sondas veraces

- **Atlassian (FR-022 a FR-024)**: `probe_atlassian` en `docker/scripts/lib/token_health.sh` hace hoy una sola consulta; gana una segunda a `<base>/wiki/rest/api/user/current` solo cuando Jira responde 404, con la misma credencial y el mismo límite de 10 s de `_th_run_probe`. El mensaje (cuarto campo) es `via confluence` en `ok` y `confluence HTTP <código>` en `auth_fail`; con los dos 404 o red, `jira HTTP 404, confluence <resultado>`. Si la URL configurada termina en `/wiki`, se quita antes de armar las dos consultas. Medido: en el sitio del operador Jira da 404 incluso sin credencial y Confluence 200 con el token.
- **Heartbeat (FR-025)**: `scripts/agentctl` lee `/workspace/scripts/heartbeat/logs/state.json`, que no existe; el heartbeat escribe `scripts/heartbeat/state.json` (`scripts/heartbeat/heartbeat.sh:13`, y `heartbeatctl` lo lee de `$HEARTBEAT_DIR/state.json`). Además el doctor pide `.last_run.ended_at`, campo que no existe: `last_run` tiene `ts`, `duration_ms` y `status` (medido en donna). Se corrigen la ruta y el campo.
- **Claude OAuth (FR-026)**: `probe_claude_oauth` gana una primera condición: si `CLAUDE_CODE_OAUTH_TOKEN` tiene valor, devuelve `skipped 000 0 login by environment token (expiry not observable)` sin mirar el archivo de login. `check_token_health.sh` hoy solo llama la sonda cuando el archivo existe; pasa a llamarla también cuando hay token de entorno.

### R12. Enmienda de la constitución

- **Decision**: Principio V, de 1.1.0 a **1.2.0** (MINOR: guía ampliada; el camino del fork sigue siendo de ramas huérfanas). Texto nuevo: con repositorio asociado, cada unidad respalda en su propio directorio `.agent-backup/<unidad>/` de `main`, toca solo ese directorio (más `.agent-backup/README.md` para `config`), nunca fuerza ni reescribe historia de `main`, y conserva caché, hash, staging, commit y empuje propios; con fork, las ramas huérfanas de siempre. Se agrega a la lista de lo compartible la construcción del commit sobre la punta de `main` (R1), porque no prepara el árbol de ninguna unidad, y el borrado verificado de la rama heredada (R6).
- **Rationale**: la gobernanza exige justificar una redefinición; la justificación es la decisión del operador del 21-11-2026 y que la independencia de las unidades se conserva en todo menos en la rama de destino.
- **Alternatives considered**: MAJOR (2.0.0): no corresponde porque el fork y la regla de cifrado no cambian y ningún agente con fork se ve afectado.

### R13. Versión y documentación

- VERSION 0.33.0 → **0.34.0** (MINOR; precedentes 026, 045, 046). Exige reconstruir la imagen (código horneado: librerías de respaldo, `heartbeatctl`, `token_health.sh`, `check_token_health.sh`).
- Documentación: README (*Backups*), `docs/heartbeatctl.md`, `docs/state-layout.md`, `docs/architecture.md`, `docs/getting-started.md`, `modules/claude-md.tpl` (sección *Your repository*, FR-011), CHANGELOG, CLAUDE.md del repo.

## Mediciones pendientes (Fase 0 de tasks)

| Id | Qué | Cómo |
| --- | --- | --- |
| M1 | `git` de la imagen y del servidor de prueba con filtros y checkout parcial | `docker run` de la imagen actual; `git -c uploadpack.allowFilter=true http-backend` en el servidor de 046 |
| M2 | Mensajes de rechazo de GitHub por protección | documentación de GitHub (*About protected branches*, *Troubleshooting rules*) |
| M3 | Peso real del primer ciclo en `main` por agente | tamaño del árbol de `.agent-backup/` tras la migración de cbum |
| M4 | Que `[skip ci]` omite un workflow en `push` | un repo de prueba privado del operador con un workflow trivial (en el gate, SC-007) |

## Ajustes de la implementación (22-11-2026)

Reemplazan lo que contradigan de R1, R2, R3, R6 y R10; el detalle está en el Registro de `tasks.md`.

- **R1/R2, cachés.** La unidad no prepara en un clon de `main`: sigue preparando y commiteando en su propia caché local de 046 (`<u>-repo`, sin remoto efectivo con `BACKUP_REPO_TARGET=main`). Un clon de publicación BARE por unidad (`<u>-main`, `blob:none`, profundidad 1, con un *alternate* hacia la caché de la unidad) recibe los árboles de la punta, arma el commit con `mktree --missing` y empuja. Así ninguna unidad baja blobs de otra y su código de staging queda como en 046. Librería: `docker/scripts/lib/backup_main.sh`.
- **R3, idempotencia.** Se suma `main_tip` al estado: si la cabeza de `main` del `ls-remote` no se movió desde el último ciclo verificado, no hay fetch.
- **R4, rechazos.** Una carrera también llega como `remote rejected ... (incorrect old value provided)`.
- **R6, migración.** La caché `<u>-repo` no se borra al borrar la rama: es la caché local del camino main.
- **R10, informe.** Solo las unidades restauradas desde `main` llevan ` (from main)`; las de rama conservan su texto de 046.
