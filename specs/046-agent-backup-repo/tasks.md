---

description: "Tareas de 046-agent-backup-repo: un repositorio privado por agente para su trabajo y su respaldo completo"
---

# Tasks: Un repositorio privado por agente para su trabajo y su respaldo completo

**Input**: `specs/046-agent-backup-repo/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorias y primero (Principio III; FR-021). Son 124 pruebas nuevas del host, en seis suites, y 8 de extremo a extremo. El significado de cada una está en la sección V2 de [contracts/evidence.md](contracts/evidence.md); aquí va lo que hace falta para escribirlas.

| Suite | Pruebas | Dónde se escriben |
| --- | --- | --- |
| `tests/backup-dest.bats` | TD01 a TD18 | Foundational |
| `tests/backup-repo-units.bats` | TU01 a TU40 | Foundational (TU31), US1 y US2 |
| `tests/backup-store.bats` | TS01 a TS22 | US2 |
| `tests/backup-repo-restore.bats` | TR01 a TR14 | US3 |
| `tests/agent-repo-surface.bats` | TA01 a TA20 | Foundational (TA04, TA05 y TA17) y US4 |
| `tests/backup-status.bats` | TB01 a TB10 | US5 |
| `tests/docker-e2e-backup-repo.bats` | TE1 a TE8 | US6 |

- **Nacen en verde a propósito**: TU05, TU19, TU20, TU31, TR06, TA06, TA14 y TB08. Guardan que el camino del fork, el de un agente sin destino y el modo local no cambien. El catálogo de mutaciones prueba que pueden fallar.
- **Todas las demás** se escriben y se ven en ROJO antes del código que las hace pasar. Una pierna que se agrega a una prueba ya en verde también se ve en ROJO antes de su código.

**Organization**: por **dependencia** entre archivos, no solo por prioridad (precedente de 040 a 045):

```text
Setup -> Foundational -> US1 (P1) -> US2 (P1) -> US3 (P1) -> US4 (P2) -> US5 (P2)
      -> Polish (documentos) -> US6 (P3: evidencia, gate en linus y PR) -> Cierre (despliegue)
```

- **US1** es el mínimo entregable: con ella, un agente sin fork respalda identidad, secretos, vault y `agent.yml` en su repositorio.
- **US2** necesita la herramienta del almacén, que también usan US3 (restauración), US4 (huella de la llave) y US5.
- **Polish** va antes de US6, porque la revisión independiente y los commits incluyen los documentos.
- **Cierre** es la parte de US6 que ocurre después del merge: el despliegue en linus, donna y cbum.

**Correcciones de diseño ya integradas**: las tareas dan por hechas las decisiones D19 a D36 de [research.md](research.md).

| Origen | Qué cambió | Dónde quedó |
| --- | --- | --- |
| M13: la unidad de identidad busca el archivo de secretos donde no existe | Con repositorio, cifra el de la raíz del workspace | D19; U2 de `contracts/backup-units.md` |
| Cruce con SC-006 y la historia 4 | Cada ciclo hace una consulta autenticada, aunque no haya cambios | D20; C3 de `contracts/destination-and-credential.md` |
| M16: donna guarda estado donde el launcher no sabe | `config` suma `.claude/` del workspace; `backup.extra_paths` | D21 y D22; FR-025 y FR-026 |
| M17 y M18: más de una base SQLite, archivos volátiles, copia determinista | Captura genérica por cabecera y exclusiones | D23; `contracts/block-store.md` |
| M14 y M15: la flota usa el token del archivo de secretos | El login de `/login` y el archivo de configuración vivo quedan fuera | D24; sección 9 de `data-model.md` |
| Análisis: la llave del operador cambiada dejaba bloques ilegibles; M19 | Una llave de datos por almacén, con rotación | D27; S1 de `contracts/block-store.md` |
| Análisis: la persona de un agente sensible viajaba en claro | En un agente sensible, `config` va cifrada salvo `agent.yml` | D28; U3 de `contracts/backup-units.md` |
| Análisis: `--regenerate` no fija la llave (M21) | Paso explícito con huella; regenerar solo avisa | D29; A2 de `contracts/agent-surface.md` |
| Análisis: SC-002 no se podía medir como estaba | Comparación contra lo respaldado; el workspace restaurado no se arranca | D30; R7 de `contracts/restore.md` |
| Análisis: la comprobación de privacidad fallaba abierta | Veredicto `unverified`; solo GitHub | D31; C3 |
| Análisis: reintentos sin freno, topes, corridas simultáneas, `~/.gitconfig` | Plazo del supervisor, topes, candado y git aislado | D32; C2, C6 y C7 |
| Análisis: estado tras un árbol idéntico; repositorio vacío; crecimiento; restauración | Reglas de estado, de rama por defecto, señal de tamaño y temporal de restauración | D33 a D36 |

**Decisiones del operador**: incluir el estado propio del agente, dejar fuera el login de `/login` y entregar la feature en un solo PR (13-11-2026); una llave de datos por almacén, la configuración cifrada en un agente sensible, la llave fijada con un paso explícito y SC-002 acotado (14-11-2026).

**Compuertas**:

- **Qué la lleva**: cada commit, push, creación o borrado de una rama remota, PR y merge exige la confirmación explícita del operador, CADA VEZ, y está marcado COMPUERTA. También la llevan el DOCKER_E2E local (T072), todo lo que toque un agente en ferrari (T077 a T079 y T083 a T085), la creación de issues (T086) y toda escritura en Confluence (T087).
- **Qué no la lleva**: las mediciones en contenedores desechables `--rm` con imágenes ya en caché (T070) y las lecturas locales. Se avisa antes de empezar.
- **Reglas fijas**:
  - nada se commitea antes de T002, y no hay hooks que ejecutar (`.specify/extensions.yml` tiene `hooks: {}`);
  - todo `docker exec` en un contenedor de agente lleva `-u agent` (Principio II), sin excepciones;
  - nunca se lee, se muestra ni se copia el contenido de un archivo de secretos. Las mediciones miran solo presencia, tamaño, modo, fecha y hash;
  - las pruebas y los scripts que nombran el archivo de secretos se escriben con las herramientas Write o Edit, no con comandos de shell: el hook `protect-secrets` bloquea el comando. No se rodea ese guard;
  - nada temporal va a `/tmp` dentro del contenedor, que es un tmpfs de 100 MB;
  - el merge es siempre del operador, y no se propone antes de que pase el gate en linus (FR-022).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta). `bats` nunca se corre en paralelo con otro `bats`.
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US6).
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/046-agent-backup-repo`.
- `<scratchpad>` es `/private/tmp/claude-501/-Users-rodrigo-hinojosa-Documents-Cencosud-Claude-Agents-agentic-pod-launcher/39e5ee01-c1c3-454a-ba47-6d398dabb108/scratchpad`. Se borra entre sesiones: lo que deba durar va a la memoria o a este archivo. Las herramientas de la feature viven en `<scratchpad>/046/` y no se versionan; la auditoría de bytes es `<scratchpad>/tools/byte_audit_files.py`.
- En el Mac, `bats`, `yq`, `gh`, `gpg`, `age` y `tmux` necesitan `/opt/homebrew/bin` en el PATH.
- Ferrari se alcanza con `ssh -o ConnectTimeout=120 ssh-ferrari`.
- Las líneas citadas son las de `origin/main` `10f22a7`.

### Reglas para escribir las pruebas

- Ningún `[[ ]]` ni `!` intermedio: se usa `[ ]`, `grep -q` o `if cmd; then false; fi`. En bash 3.2 un `[[ ]]` intermedio falso no hace caer la prueba.
- `setup.sh` y `docker/scripts/start_services.sh` se cargan dentro del cuerpo de la prueba, nunca en `setup()`.
- En bash 3.2 con `set -u`, expandir un arreglo vacío es un error: se escribe `${arr[@]+"${arr[@]}"}`.
- Cada doble de prueba usa un valor distinto por cada fuente de datos, y cada afirmación de "no aparece" busca un centinela que sí está en el origen.
- Una espera siempre tiene tope, y un proceso lanzado en segundo plano cierra los descriptores de bats (`3>&- 4>&-`) y se mata en `teardown`.
- Una prueba no detecta la sonda anónima contando peticiones `auth=none`: toda operación autenticada de git empieza con una petición sin credencial. Mira `anon_checked_epoch` y el código de las respuestas.
- Toda prueba de restauración corre con un `HOME` propio y vacío, para que ninguna toque las llaves del operador.
- Un criterio de aceptación nombra pruebas enteras. Una prueba que recorre varias unidades sigue en rojo hasta que existe la última.
- Los mensajes que una prueba afirma son los de la tabla de U1 de [contracts/backup-units.md](contracts/backup-units.md). Esa tabla es la única fuente.

### Costuras de prueba

Las que ya existen (`HEARTBEATCTL_WORKSPACE`, `HEARTBEATCTL_LIB_DIR`, `HEARTBEATCTL_CRONTAB_FILE`, `IDENTITY_STATE_DIR` y las tres `*_BACKUP_CACHE_DIR`) se usan como hoy. Las nuevas:

| Variable | Para qué | Valor por defecto |
| --- | --- | --- |
| `BACKUP_DEST_AGENT_YML` | El `agent.yml` que lee la regla de destino | `/workspace/agent.yml` |
| `BACKUP_DEST_STATE_FILE` | El registro del destino | `/workspace/scripts/heartbeat/backup-dest.json` |
| `BACKUP_DEST_ALLOW_HTTP` | Con `1`, admite `http://` hacia `127.0.0.1`, `localhost` y `host.docker.internal`, en la librería y en los validadores | Sin definir |
| `BACKUP_DEST_NOW` | Reloj fijo, en segundos desde la época | `date +%s` |
| `BACKUP_PROBE_TIMEOUT_S` | Tope de la sonda anónima y de la consulta autenticada | 60 |
| `BACKUP_GIT_TIMEOUT_S` | Tope del `fetch` y del `push` de `identity`, `vault` y `config` | 60 |
| `BACKUP_PUSH_TIMEOUT_S` | Tope del `fetch` y del `push` de `memory` y de `history` | 900 |
| `BACKUP_ASKPASS_OVERRIDE` | Ruta del askpass | `/opt/agent-admin/scripts/git-askpass-agent.sh` |
| `BACKUP_STORE_PY` | Ruta de la herramienta del almacén | `/opt/agent-admin/scripts/backup_store.py` |
| `AGE_BIN`, `AGE_KEYGEN_BIN` | Binarios de `age` | `age` y `age-keygen` |
| `MEMORY_BACKUP_CACHE_DIR`, `HISTORY_BACKUP_CACHE_DIR` | Caché de las dos unidades nuevas | `/home/agent/.cache/agent-backup` |
| `IDENTITY_BACKUP_WORKSPACE_OVERRIDE` | Workspace que usa `_check_identity_backup` | `/workspace` |
| `IDENTITY_BACKUP_RETRY_S` | Espera del supervisor tras un intento fallido | 900 |
| `AGENT_REPO_DIR` | Ruta del clon de trabajo | `${WORKDIR:-${HEARTBEATCTL_WORKSPACE:-/workspace}}/agent-repo` |
| `AGENT_REPO_CREDENTIAL_HELPER` | Ruta del ayudante de credenciales | `/opt/agent-admin/scripts/git-credential-agent.sh` |
| `AGENT_REPO_FETCH_TIMEOUT_S` | Tope del `fetch` del clon de trabajo | 120 |
| `DOCTOR_BACKUP_CACHE_MAX_MB` | Umbral de la advertencia de tamaño | 800 |

El directorio de estado de las unidades nuevas es `$IDENTITY_STATE_DIR` (`$WORKSPACE/.state`, que en el contenedor es `/home/agent`): de ahí salen `.claude/projects` y `.claude-mem`.

### Molde del camino `repo` en cada librería

Cada unidad conserva sus funciones propias; no se comparte ninguna que arme un árbol, haga un commit o empuje (Principio V). Las funciones que ya existen, incluidos los tres envoltorios de git, **no cambian**, salvo `identity_hash`, que gana un argumento opcional. Con un repositorio asociado, cada librería gana estas, con esta forma:

```text
_<unidad>_repo_git ARGS...                -> git con el entorno de C2 y timeout -k 10 N
<unidad>_repo_prepare URL CABEZA_REMOTA   -> stdout: directorio de la caché
<unidad>_repo_commit_and_push DIR ...     -> stdout: "<sha>" o "-"; código 2 si el empuje falla
<unidad>_repo_write_state ARCHIVO ...     -> fusiona hash, last_commit, last_push (y mode o store_recipient)
```

- **La caché** es `<base>/<unidad>-repo`: un repositorio normal, persistente, distinto del que usa el camino `fork`.
- **`prepare`**: si la cabeza remota está vacía, borra la caché y la crea de nuevo, con una rama huérfana. Si no, hace `git init` si falta, fija el remoto, hace `fetch --depth 1` de `refs/heads/backup/<unidad>` y deja esa rama extraída. Después borra el árbol de trabajo, salvo `.git` y, si la unidad usa el almacén, `store/`.
- **`commit_and_push`**: escribe la marca `.agentic-pod-backup.json`, hace `git add -A`, y si no hay diferencia devuelve `-`. Si la hay, hace el commit con la identidad de la unidad (`<unidad>-backup@localhost`) y empuja `HEAD:refs/heads/backup/<unidad>`. Nunca `--all` ni `--mirror`.
- **El envoltorio** fija `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS` con la salida de `backup_dest_askpass`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` y `LC_ALL=C`. Donde no existe `timeout`, corre sin tope.
- **Las unidades con almacén** calculan su hash con `digest`, con la marca de datos sensibles y la llave pública del operador en `--extra`; empaquetan con `pack`, con esa llave en `--recipients` y el `store_recipient` de su estado en `--expect-recipient`; y guardan la `recipient` que `pack` devuelve. El `hash` del estado es el de `digest`, calculado antes de empaquetar.
- **En `heartbeatctl`**, tres ayudantes que no hacen commits: `_repo_begin UNIDAD` (candado y credencial), `_repo_verify UNIDAD URL` (privacidad y archivo de cabezas, después del hash) y `_repo_end` (suelta el candado). Ante una falla imprimen el mensaje de la tabla de U1 y llaman a `backup_dest_record`.

---

## Phase 1: Setup

**Purpose**: fijar el punto de partida, commitear los artefactos y medir la línea base.

- [X] T001 Verificar, solo con lecturas, y anotar en el Registro de `specs/046-agent-backup-repo/tasks.md`:
  - **El remoto**: `origin/main` sigue en `10f22a7` (por HTTPS con el ayudante de `gh`, como en T001 de 045) y `git show origin/main:VERSION` da 0.31.0. Si `main` se movió, leer `git log --stat 10f22a7..origin/main` y ver si toca algún archivo de esta feature.
  - **Los PR abiertos** (`gh pr list --state open`) y si alguno toca esos archivos.
  - **El estado local**: `git status --short` muestra solo `.specify/feature.json` modificado y `specs/046-agent-backup-repo/` sin rastrear.
  - **Las anclas del código**:
    - `docker/scripts/heartbeatctl`: carga de librerías en `:28-42`, archivos de estado en `:60-63`, `cmd_reload` en `:263-455` con su heredoc del crontab en `:428-437`, `_bi_run` en `:764-818`, `_bi_configure_key` en `:820-841`, `_bv_run` en `:901-953`, `_bc_run` en `:993-1039` y el despacho de `main` en `:1238-1267`;
    - `docker/scripts/start_services.sh`: `_trigger_identity_backup` en `:382-395`, `_identity_backup_fork_configured` en `:1123-1129`, `_check_identity_backup` en `:1134-1168`, `_run_watchdog` desde `:1264` y `main` en `:1374-1388`;
    - los tres envoltorios de git, que no se tocan: `docker/scripts/lib/backup_identity.sh:19-25`, `docker/scripts/lib/backup_config.sh:12-18` y `scripts/lib/backup_vault.sh:13-19`;
    - la lectura del archivo de secretos en `docker/scripts/lib/backup_identity.sh:72` y `:152-154`;
    - el bloque `COPY` de `docker/Dockerfile:241-274`;
    - `setup.sh`: `fetch_github_ssh_key` y `configure_identity_backup` en `:187-229` (su única llamada, en `:2005`), `parse_args` en `:448-473`, el paso del fork en `:621-659`, el del MCP de GitHub en `:831-840`, el resumen en `:953-1108`, el heredoc de `agent.yml` en `:1205-1314`, la escritura de secretos en `:1316-1338`, la restauración en `:1755-1854`, los backfill de `regenerate` en `:2422-2540` y `uninstall` en `:3258`, con sus ramas de `--nuke` en `:3308` y `:3419`;
    - `scripts/lib/wizard.sh:76-94` (`ask_validated`), `modules/claude-md.tpl:232-244`, `modules/env-example.tpl:23-26`, el bloque de docker de `modules/next-steps.en.tpl:3-348`, `scripts/agentctl:193-243`, `:440`, `:452` y `:774-788`, `scripts/lib/schema.sh:65` y `:107`;
    - los oráculos que hay que mover: `tests/schema.bats:21-36`, `:62-83` y `:129-139`, `tests/quickstart-doc.bats:164-177`, y los pasos del nightly en `.github/workflows/docker-e2e.yml:65-81`.
  - **Las herramientas del host**: `git --exec-path` trae `git-http-backend`; `age --version`; `age-keygen` existe; `python3 --version`; `ssh-keygen` existe; y si hay `timeout` y `flock` (en el Mac no hay ninguno de los dos: las pruebas llevan los suyos, T008).
  - **Los archivos de ignorar**: `.gitignore` gana `/agent-repo/` en T051. No existe `docker/.dockerignore` y no se crea.
  - **La identidad de los commits**: la misma de 045, por variables de entorno.
- [X] T002 COMPUERTA (commit local): commitear `specs/046-agent-backup-repo/**` y `.specify/feature.json`.
  - **Antes**: `python3 -I <scratchpad>/tools/byte_audit_files.py` sobre cada archivo de `specs/046-agent-backup-repo/`, con 0 hallazgos. Tras el `git add`, `git ls-files -s` muestra modo 100644.
  - **El mensaje**: en español, en imperativo y sin atribución. Por ejemplo, `docs: agrega los artefactos de spec-kit de 046 (repositorio privado por agente)`.
  - Sin push.
- [X] T003 Medir la línea base de la suite del host en una copia aislada de `origin/main` (`git worktree add --detach <scratchpad>/046/base origin/main`), que se conserva hasta el gate completo de T074:
  - **Las corridas**: en secuencia, `bats tests/` (bash 5.x) y `PATH=/bin:$PATH bats tests/` (bash 3.2.57), con la salida a archivos del scratchpad.
  - **Lo que se anota** en el Registro de `specs/046-agent-backup-repo/tasks.md`: `1..N`, los ok, los `not ok`, las saltadas, la duración y la salida de error.
  - **Lo esperado**: 1972 de 1972 en cada bash, con 61 saltadas en 5.x y 62 en 3.2, que es lo que dejó el gate de 045. Si da otra cifra, manda la medida. El esperado final es la línea base más 132: las 124 pruebas del host y las 8 de extremo a extremo, que en el host salen saltadas.
  - Mientras corre se pueden escribir archivos, pero no correr ningún otro `bats` en el worktree.
- [X] T004 [P] Comprobar con lecturas el estado de Docker para T070 y T072, y anotarlo en `specs/046-agent-backup-repo/tasks.md`: `docker info --format '{{.ServerVersion}} {{.Architecture}} {{.NCPU}} {{.MemTotal}}'`, las imágenes en caché (`alpine:3.24.1`, `ubuntu:24.04`, `agent-admin:e2e`) y el disco libre. No se toca ningún contenedor ni imagen.

---

## Phase 2: Foundational

**Purpose**: la enmienda de la constitución, las claves de `agent.yml`, el doble de prueba y la regla de destino con su credencial. Bloquea todas las historias.

- [X] T005 Enmendar `.specify/memory/constitution.md` de 1.0.1 a 1.1.0, antes de cualquier cambio de código (FR-020; `contracts/constitution-amendment.md`, E1 a E9). Los textos se copian literalmente del contrato:
  - la primera viñeta del Principio V gana la salvedad del subconjunto que llevan las ramas de respaldo (E1);
  - la tercera viñeta se reemplaza por las dos del contrato (E2);
  - el `Rationale` del principio deja de prometer una restauración sin iniciar sesión (E3);
  - en "Scope discipline" se quita la palabra `three` (E4);
  - la línea final pasa a `**Version**: 1.1.0 | **Ratified**: 2026-06-18 | **Last Amended**: <fecha del día, en ISO>` (E5);
  - el bloque `SYNC IMPACT REPORT (1.0.1 → 1.1.0)` va después del bloque de 1.0.1 y antes del título (E6).
  - **Comprobación**: los seis comandos de E9 dan el resultado esperado.
- [X] T006 ROJO: crear `tests/agent-repo-surface.bats` con su cabecera y escribir TA04, TA05 y TA17:
  - **La cabecera**: el propósito (046), los contratos y las reglas para escribir las pruebas.
  - **El `agent.yml` de partida** se escribe dentro de la prueba, sin las claves nuevas (molde: `_write_agent_yml` de `tests/mcp-handshake-timeout.bats`). No se saca de `git show`: la CI clona sin historia.
  - **TA04**: tras `./setup.sh --regenerate`, `yq` muestra `backup.repo.url` vacío, `backup.repo.allow_unverified` y `backup.sensitive` en `false`, `backup.extra_paths` como lista vacía, y las dos unidades nuevas con `enabled: true` y sus `schedule`. Segunda pierna: con `features.memory_backup.enabled: false`, `backup.sensitive: true`, `backup.repo.allow_unverified: true` y `backup.extra_paths: [".custom"]` escritos por el operador, regenerar no cambia ninguno. Tercera pierna: dos regeneraciones seguidas dejan el mismo `agent.yml`, salvo `meta.regenerated_at`.
  - **TA05**: `agent_yml_validate` rechaza un valor no booleano en cada una de las cuatro claves booleanas, y nombra la clave. Para la URL recorre `tests/fixtures/backup-repo/url-cases.tsv` (T008): rechaza `http://x/y`, `https://u:p@github.com/o/r`, `https://github.com/a b`, `git@github.com:o/r.git`, `https://gitlab.com/o/r` y `https://github.com/o`; acepta `https://github.com/o/r`, `https://github.com/o/r.git` y la cadena vacía. Con `BACKUP_DEST_ALLOW_HTTP=1` acepta `http://127.0.0.1:1/r` y sigue rechazando `http://example.com/r`.
  - **TA17**: `backup.extra_paths` con un texto en vez de una lista se rechaza; ausente, se completa con `[]`.
  - Contra el código actual caen las tres.
- [X] T007 Agregar las claves nuevas (sección 1 de `data-model.md`) en `setup.sh`, `scripts/lib/schema.sh`, `tests/fixtures/sample-agent.yml`, `tests/fixtures/sample-agent-with-vault.yml` y `tests/schema.bats`. Reglas, citadas literalmente:
  - `backup.repo.url`, texto, `""`: «Vacío significa sin repositorio asociado. Si no está vacío, debe tener la forma `https://github.com/<dueño>/<nombre>`, con `.git` opcional al final, sin credenciales ni espacios»;
  - `backup.repo.allow_unverified`, booleano, `false`: «En `true`, se acepta un destino cuya privacidad no se pudo comprobar. Nunca habilita un repositorio público»;
  - `backup.sensitive`, booleano, `false`: «En `true`, el vault, la auto-memoria y la configuración, salvo `agent.yml`, viajan cifrados»;
  - `backup.extra_paths`, lista de textos, `[]`: «Cada entrada es una ruta relativa a la raíz del workspace. Se normaliza antes de validar: sin `./` al comienzo ni `/` al final. No está vacía, no es `.`, no empieza con `/` y no tiene ningún segmento `..`. No puede ser `.state`, ni estar bajo `.state/.cache` o bajo `agent-repo`, ni tener un componente `.git`. Una entrada que no cumple, o que no existe, se omite y se informa»;
  - `features.memory_backup.enabled`, booleano, `true`, y `features.memory_backup.schedule`, `"40 3 * * *"`: «Cinco campos válidos; se admite `*` y `*/N` en todos, incluido el minuto»;
  - `features.history_backup.enabled`, booleano, `true`, y `features.history_backup.schedule`, `"50 3 * * *"`, con la misma regla.

  Cambios:
  - **El heredoc** (`setup.sh:1205-1314`): un bloque `backup:` nuevo, con `repo`, `sensitive` y `extra_paths`, y las dos unidades bajo `features:`. Por ahora con los valores por defecto literales; las variables del wizard llegan en T046.
  - **El backfill** en `regenerate()`, antes de `render_load_context`: una comprobación `has()` por clave, con el molde de `upgrade_notice` (`setup.sh:2448`). Nunca `//`, que pisaría un `false` explícito.
  - **El esquema**: las cuatro claves booleanas entran a `_SCHEMA_BOOLEANS`; `agent_yml_validate` gana la regla de la URL (que honra `BACKUP_DEST_ALLOW_HTTP=1`) y la del tipo de `backup.extra_paths`.
  - **Los fixtures**: las claves nuevas con sus valores por defecto.
  - **`tests/schema.bats:28-30`**: la lista de claves de primer nivel de `sample-agent-with-vault.yml` gana `backup`.
  - TA04, TA05 y TA17 en verde; `tests/schema.bats`, `tests/regenerate.bats`, `tests/scaffold.bats` y `tests/e2e-smoke.bats` en verde, en los dos bash.
- [X] T008 [P] Crear el doble de prueba `tests/fixtures/backup-repo/git-auth-server.py`, el arnés `tests/helper-backup-repo.bash` y los archivos dorados (`contracts/evidence.md`, V1 y V2):
  - **El servidor** sale del prototipo `<scratchpad>/046/git-auth-server.py`. Sirve los repositorios bare de `GIT_TEST_ROOT` pasando cada petición a `git http-backend`. En cada petición lee la credencial válida de `GIT_TEST_TOKEN_FILE` y los modos de `GIT_TEST_MODE_FILE` (`anon-read`, `anon-error-once`, `stall-anon-once`, `deny-push`, `stall-auth` y `stall-push`). Los dos modos `-once` valen solo para la próxima petición sin credencial: git empieza toda operación autenticada con una, así que un modo permanente rompería también la consulta autenticada. Escucha en `GIT_TEST_BIND` (`127.0.0.1` por defecto), en un puerto efímero que escribe en `GIT_TEST_PORT_FILE`. Deja en `GIT_TEST_LOG` una línea por petición, con el código, la ruta, el servicio y `auth=ok`, `auth=bad`, `auth=none` o `auth=anon`, y nunca la credencial. Una petición en modo `stall` se suelta sola a los 300 segundos.
  - **Lo que no usa**: `HTTPServer.server_bind`. Sobrescribe `server_bind` para llamar a `socketserver.TCPServer.server_bind`, como `tests/fixtures/nightly-alert/tg-server.py`.
  - **El arnés** entrega:
    - `br_require`: si faltan `git http-backend`, `age`, `age-keygen`, `python3` o `ssh-keygen`, salta la prueba con su motivo; con la variable `CI` definida, la hace **fallar**;
    - `br_start_server` y `br_stop_server` (lanza con `3>&- 4>&-`, espera el puerto 10 segundos como máximo y mata el proceso al terminar), `br_server_mode PALABRAS...` y `br_server_token VALOR`;
    - `br_new_repo NOMBRE` (un repositorio bare con una rama de trabajo `main` y un commit) y `br_new_repo NOMBRE --empty` (sin ninguna rama);
    - `br_workspace` (un workspace con la disposición real de un agente: `agent.yml`, el archivo de secretos en la raíz, y `.state/` sin archivo de secretos);
    - `br_keys` (dos pares `ssh-ed25519` de prueba, A y B, con sus archivos de destinatarios);
    - `br_unit UNIDAD ARGS` (corre `heartbeatctl backup-<unidad>` con todas las costuras);
    - `br_branch_has REPO RAMA TEXTO` (busca un texto en todos los blobs de todos los commits de una rama, con `git grep -a`);
    - `br_work_heads REPO` (las cabezas de las ramas que no empiezan con `backup/`) y `br_log_count PATRÓN` (cuenta líneas del log del servidor);
    - `br_tools_path` (arma un directorio con los dobles que el host no tiene y lo pone al comienzo del PATH).
  - **Los dobles de `timeout` y de `flock`**, en `tests/fixtures/backup-repo/bin/`, los dos en perl. El `timeout` aplica el tope de verdad (admite `-k N`, envía TERM y después KILL al grupo del proceso); el `flock` admite la forma por descriptor (`-n 9` y `-u 9`). No se usa `tests/fixtures/qmd-lock`, cuyo `timeout` no aplica ningún tope. En el Mac no existe ninguno de los dos comandos (medido el 14-11-2026): sin el doble, las pruebas de los topes esperarían los 300 segundos del servidor.
  - **Aislamiento**: los comandos de git del propio arnés corren con `GIT_CONFIG_GLOBAL=/dev/null` y `GIT_CONFIG_NOSYSTEM=1`. `br_unit` no exporta esas variables a la unidad: la corre con un `HOME` propio y vacío. Así TU38 prueba el aislamiento de producción y no el del arnés.
  - **Centinelas**: uno distinto para la credencial y uno distinto por cada fuente de datos (secretos, vault, persona, auto-memoria, claude-mem, historial y ruta adicional).
  - **`tests/fixtures/backup-repo/url-cases.tsv`**: una fila por URL, con la costura apagada o encendida y el resultado esperado. La recorren TD11 y TA05, para que la librería y los validadores no se separen.
  - **Los archivos dorados** se generan UNA vez, desde la copia de T003, y se commitean: la CI clona sin historia y no tiene con qué comparar. Se anota el sha256 de cada uno en el Registro.
    - `tests/fixtures/backup-repo/agent-fork.yml` y `tests/fixtures/backup-repo/crontab-fork.golden`: un `agent.yml` con fork, y el crontab que le genera el `heartbeatctl reload` de `origin/main`;
    - `tests/fixtures/backup-repo/claude-md-backups-section.golden`: la sección `## Backups (what actually survives)` que renderiza la plantilla de `origin/main` para `tests/fixtures/sample-agent.yml`;
    - `tests/fixtures/backup-repo/restore-fork-output.golden`: la salida de `restore_from_fork` de `origin/main` para el fork de tres ramas de `tests/restore-unified.bats`, con la ruta de destino reemplazada por `<DEST>`.
- [X] T009 ROJO: escribir TD01 a TD18 en `tests/backup-dest.bats`, con un solo servidor por archivo (`setup_file` y `teardown_file`):
  - **TD01 a TD03**: `backup_dest_resolve` entrega `tipo<TAB>url`. TD01: solo repositorio, y los dos (gana el repositorio). TD02: solo fork. TD03: ninguno, valores vacíos, `null` y `agent.yml` ausente.
  - **TD04 y TD05**: la tabla de `backup_dest_askpass`. El script responde `x-access-token` a una pregunta que empieza con `Username` y el valor de `GITHUB_PAT` a una que empieza con `Password`; no imprime nada con otra pregunta, y nada por stderr.
  - **TD06**: veredicto `private`; el log tiene una petición `auth=none` rechazada con 401 y una `auth=ok`.
  - **TD07**: con `anon-read`, veredicto `public`.
  - **TD08**: `unreachable` con una credencial equivocada y con un puerto cerrado.
  - **TD09**: con `anon-error-once` y `allow_unverified` activo, `unverified-allowed`; el log tiene una respuesta 500, y `anon_checked_epoch` es el momento de la corrida: la sonda no se saltó. Si se saltara, el 500 le tocaría a la consulta autenticada y el veredicto sería `unreachable`.
  - **TD10**, con `BACKUP_DEST_NOW`: tras un veredicto `private` en t0, las corridas en t0+1 h y t0+23 h dejan `anon_checked_epoch` en t0 y `checked_epoch` en su propio momento; la corrida en t0+25 h deja `anon_checked_epoch` en t0+25 h, y el log gana más peticiones sin credencial válida que en la corrida de t0+23 h. Esa secuencia es la que distingue el plazo contado desde la última sonda anónima del contado desde la última corrida. Además, un cambio de URL fuerza la sonda.
  - **TD11**: por cada fila rechazada de `url-cases.tsv`, el veredicto es `unreachable` y el log del servidor no gana ninguna petición.
  - **TD12**: `backup_dest_check_owner` da `new`, `ok`, `foreign` y `other-agent`, este último con otro agente y con otra unidad.
  - **TD13**: `backup_dest_record` conserva `hash`, `mode`, `last_commit`, `last_push` y `store_recipient`; escribe `last_attempt`, `last_attempt_epoch`, `last_result` y, si lo recibe, `attempt_hash`; y no deja ningún temporal en el directorio.
  - **TD14**: el centinela de la credencial aparece 0 veces en el log del servidor, en `backup-dest.json`, en el `.git/config` de cualquier clon y en la salida de `GIT_TRACE=1`.
  - **TD15**: `backup_dest_branch_head` entrega el commit de la rama pedida, entre varias, y vacío si no existe.
  - **TD16**: con `anon-error-once` y sin `allow_unverified`, `unverified`; con `stall-anon-once` y un tope de 2 segundos, también. La corrida siguiente, ya sin el modo, vuelve a hacer la sonda anónima y da `private`: el veredicto anterior no se reutilizó.
  - **TD17**: con `anon-read` y `allow_unverified` activo, `public`.
  - **TD18**: con `stall-auth` y un tope de 2 segundos, la consulta termina en menos de 15 segundos con `unreachable`.
  - Contra el código actual caen las dieciocho: la librería no existe.
- [X] T010 Crear `docker/scripts/lib/backup_dest.sh` y `docker/scripts/git-askpass-agent.sh`, y agregar sus líneas en `docker/Dockerfile` (`contracts/destination-and-credential.md`, C1 a C8):
  - **La librería** es bash, sin efectos al cargarla. Define `backup_dest_resolve`, `backup_dest_askpass`, `backup_dest_url_ok`, `backup_dest_verify`, `backup_dest_branch_head`, `backup_dest_check_owner`, `backup_dest_record`, `backup_dest_lock` y `backup_dest_unlock`. No arma árboles, no hace commits, no empuja y no calcula hashes de contenido.
  - **El registro** `backup-dest.json` lleva `url`, `verdict`, `checked_at`, `checked_epoch`, `anon_checked_at` y `anon_checked_epoch`, y se escribe de forma atómica. Los plazos se calculan con los campos en segundos.
  - **La sonda anónima** corre con `LC_ALL=C`, y solo cuenta como rechazo por falta de credencial si su stderr trae `Authentication failed`, `could not read Username` o `terminal prompts disabled`.
  - **El tope** de cada consulta es `BACKUP_PROBE_TIMEOUT_S`, con `timeout -k 10` cuando `timeout` existe. La imagen lo trae; en el Mac lo pone el arnés.
  - **El registro del intento**: sin el hash, `backup_dest_record` deja `attempt_hash` vacío.
  - **El candado**: `backup_dest_lock UNIDAD` abre el descriptor 9 sobre `scripts/heartbeat/.backup-<unidad>.lock` y hace `flock -n 9`; devuelve 1 si está tomado, y 0 sin candado si no existe `flock`. `backup_dest_unlock` hace `flock -u 9` y cierra el descriptor.
  - **El askpass** es el de C2, en `sh` POSIX, con modo 100755.
  - **El Dockerfile**: `COPY scripts/lib/backup_dest.sh /opt/agent-admin/scripts/lib/backup_dest.sh` junto a las demás librerías (`:263-272`), `COPY scripts/git-askpass-agent.sh /opt/agent-admin/scripts/git-askpass-agent.sh`, y el script en el `chmod +x` de `:274-275`.
  - TD01 a TD18 en verde en los dos bash. `shellcheck -S error` sobre la librería y `shellcheck -s sh` sobre el askpass, con código 0.
- [X] T011 Crear `tests/backup-repo-units.bats` con su cabecera, `load helper-backup-repo`, un servidor por archivo y la prueba TU31, que nace en verde: por cada archivo que entrega `git ls-files --cached --others --exclude-standard docker/scripts`, `docker/Dockerfile` tiene una línea `COPY scripts/<ruta>`. Con `--others` ve también los archivos nuevos que todavía no se commitean. La prueba falla si la lista tiene menos de 15 entradas, para que una lista vacía no pase.
- [X] T012 Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`: `tests/backup-dest.bats` 18 de 18; TA04, TA05, TA17 y TU31 en verde; ninguna prueba deja un proceso del servidor vivo (`pgrep -f git-auth-server.py` vacío).

**Checkpoint**: la regla de destino, la credencial y el doble de prueba están listos. Las historias pueden empezar.

---

## Phase 3: User Story 1 - Un agente sin fork respalda en su repositorio privado (Priority: P1), MVP

**Goal**: `identity`, `vault` y `config` llegan al repositorio asociado con la credencial del agente, con su marca de pertenencia y sin tocar las ramas de trabajo. `identity` cifra el archivo de secretos real. El camino nuevo no se atasca ni se pisa. Con fork o sin destino, todo queda como hoy (FR-001, FR-002, FR-004 a FR-007, FR-013 y FR-018).

**Independent Test**: `bats tests/backup-repo-units.bats` en los dos bash, con las pruebas de esta fase en verde, más las suites de respaldo que ya existían, sin editarlas.

- [X] T013 [US1] ROJO: escribir TU01, TU02 y TU24 en `tests/backup-repo-units.bats`:
  - **TU01**: con un repositorio asociado, `backup-identity` deja `backup/identity` con `.agentic-pod-backup.json` (`schema` 1, el agente y la unidad `identity`), y el estado local con `hash`, `last_commit`, `last_push`, `last_attempt` y `last_result: ok`. Segunda pierna: lo mismo contra un repositorio creado con `--empty`.
  - **TU02**: un segundo ciclo sin cambios crea 0 commits y deja `last_result: no-change`. Segunda pierna: `backup-identity --gc`, también sin cambios, termina igual y no imprime `no fork url`.
  - **TU24**: con el workspace de `br_workspace` (el archivo de secretos solo en la raíz) y una llave de `br_keys`, la rama trae `.env.age`; su descifrado con la llave privada de prueba tiene el mismo SHA-256 que el original; `br_branch_has` no encuentra el centinela de los secretos; y la caché de la unidad tampoco lo tiene en claro. Segunda pierna: sin llave, el modo es `partial` y la rama no trae `.env.age`.
- [X] T014 [US1] ROJO: escribir TU13, TU14, TU15, TU17 y TU18 en `tests/backup-repo-units.bats`, cada una sobre `identity`, `vault` y `config`:
  - **TU13**: sin `GITHUB_PAT`, el resultado es `no-credential`, el código es 0 y el log del servidor no gana ninguna petición.
  - **TU14**: con una credencial equivocada, `unreachable` y código 2.
  - **TU15**: con `anon-read`, `not-private`, código 0 y ninguna petición `receive-pack` en el log.
  - **TU17**: con una rama `backup/<unidad>` que no tiene la marca, `foreign-branch`; la cabeza de esa rama no cambia.
  - **TU18**: con una marca de otro agente, `other-agent`; la cabeza no cambia.
- [X] T015 [US1] ROJO: escribir TU22, TU23 y TU26 en `tests/backup-repo-units.bats`:
  - **TU22**: con `deny-push` solo para una corrida, esa unidad termina en `push-failed` con código 2, y las otras dos, corridas después sin ese modo, terminan en `ok`. Segunda pierna: tras una corrida con la credencial equivocada (`unreachable`), se corrige la credencial y la unidad siguiente termina en `ok`: el veredicto anterior no se reutilizó.
  - **TU23**, sobre `config`, en tres piernas, cada una sin cambios de contenido: la prueba borra la rama en el repositorio bare, y el ciclo siguiente la vuelve a crear con su marca y los mismos archivos; la prueba agrega un commit ajeno que conserva la marca, y el ciclo siguiente deja otra vez el árbol de la unidad; la prueba quita la marca, y el ciclo siguiente termina en `foreign-branch` sin mover la cabeza.
  - **TU26**, sobre `config`: tras un respaldo correcto, la prueba cambia la credencial válida del servidor. El ciclo siguiente, sin cambios de contenido, da `unreachable` y código 2. Al restaurar la credencial, el ciclo siguiente da `no-change`.
- [X] T016 [US1] ROJO: escribir TU25 y TU34 en `tests/backup-repo-units.bats`. Dentro del cuerpo de cada prueba se carga `docker/scripts/start_services.sh` con `START_SERVICES_NO_RUN=1` (molde: `tests/start-services-watchdog.bats:9-23`), se fija `IDENTITY_BACKUP_WORKSPACE_OVERRIDE` y se reemplaza `_trigger_identity_backup` por una función que anota cada llamada:
  - **TU25**: primero, con un repositorio asociado y sin ningún respaldo, `_check_identity_backup` (con `_last_backup_check=0`) anota una llamada. Después de un `backup-identity` correcto, no anota ninguna. Después de cambiar el archivo de secretos de la raíz, anota una.
  - **TU34**: tras un intento fallido (`unreachable`), con el mismo contenido y `BACKUP_DEST_NOW` 60 segundos después, no anota ninguna llamada; 901 segundos después, anota una; y con un contenido nuevo anota una de inmediato. Lo mismo tras un `no-credential`, que no deja `attempt_hash`: a los 60 segundos no anota ninguna. Con un archivo de estado truncado, y con un `last_attempt_epoch` que no es un número, la función devuelve 0 bajo `set -euo pipefail` y anota una llamada. Última pierna, sin reemplazar `_trigger_identity_backup` y con un `timeout` espía en el PATH: con repositorio, la llamada lleva `-k 10 300`; con fork, lleva `90`, como hoy.
- [X] T017 [US1] ROJO: escribir TU36, TU37 y TU38 en `tests/backup-repo-units.bats`:
  - **TU36**, sobre `identity` y sobre `vault`, con `br_tools_path`: con `stall-push` y `BACKUP_GIT_TIMEOUT_S=2`, la unidad termina en menos de 30 segundos con `push-failed` y código 2; el estado tiene `last_result: push-failed` y `attempt_hash`; y una corrida inmediata, sin el modo, funciona: el candado quedó suelto.
  - **TU37**, sobre `identity`, con `br_tools_path`: mientras otro proceso tiene tomado `scripts/heartbeat/.backup-identity.lock`, una corrida imprime `another run holds the lock - skipping`, sale con 0 y no cambia el archivo de estado ni el log del servidor. Al soltarse el candado, la corrida siguiente termina en `ok`.
  - **TU38**: con un `HOME` cuyo `.gitconfig` trae un `url.<otra>.insteadOf` que desvía la URL del repositorio y `commit.gpgsign=true`, `backup-identity`, `backup-vault` y `backup-config` terminan en `ok` contra el repositorio verdadero.
- [X] T018 [US1] Escribir en `tests/backup-repo-units.bats` las pruebas que nacen en verde y las que caen:
  - **TU19** (sin destino, nace en verde): los mensajes son los de hoy, palabra por palabra (`agent.yml has no scaffold.fork.url` en las tres unidades), el código es 0 y no se crea ningún archivo de estado ni `backup-dest.json`.
  - **TU20** (con fork, nace en verde): con un repositorio bare local, como en `tests/backup-identity-git.bats`, la rama no trae la marca y el estado no trae `last_attempt` ni `last_result`. Segunda pierna: con el fork apuntando al servidor de prueba, el log no tiene ninguna petición `auth=ok`, y la corrida falla como en `main`: el fork no recibe la credencial.
  - **TU05** (con fork, nace en verde): `backup/config` trae solo `agent.yml`.
  - **TU03** (cae): tras 10 ciclos de `identity`, `vault` y `config`, con cambios entre ciclos, `git for-each-ref` del repositorio bare muestra, fuera de `refs/heads/backup/`, las mismas referencias y las mismas cabezas que al comienzo, y bajo `refs/heads/backup/`, exactamente tres ramas, una por unidad.
  - **TU06** (cae): sin la marca de datos sensibles, `backup/vault` trae los `.md` en claro, con su estructura.
  - **TU29** (cae): con un repositorio asociado y sin la clave `features.identity_backup.enabled`, el crontab generado tiene la línea de `backup-identity`; con `enabled: false`, no la tiene; con fork y sin la clave, no la tiene, como hoy. Segunda pierna: después de `heartbeatctl set-interval`, `agent.yml` conserva `backup.repo.url` y el crontab conserva la línea.
  - **TU33** (cae), sobre `config` y `vault`: tras un respaldo correcto, la prueba borra el archivo de estado y la caché. El ciclo siguiente crea 0 commits y deja el estado con `hash`, `last_commit` igual a la cabeza remota y `last_push`. El ciclo que sigue termina en `no-change` y no hace ningún `fetch`: el archivo `FETCH_HEAD` de la caché queda igual, byte a byte y en su fecha.
- [X] T019 [US1] Anotar el ROJO en `specs/046-agent-backup-repo/tasks.md`, en bash 5.x y en 3.2: caen TU01 a TU03, TU06, TU13 a TU15, TU17, TU18, TU22 a TU26, TU29, TU33, TU34 y TU36 a TU38; pasan TU05, TU19, TU20 y TU31. Cada una cae en la línea prevista y no por un error del arnés (un servidor que no levanta, una llave que no se genera o un `heartbeatctl` que no carga). Un ROJO por otra razón se corrige ahora y se vuelve a anotar.
- [X] T020 [US1] Extender `docker/scripts/lib/backup_identity.sh` (U2 de `contracts/backup-units.md`; D19 y D32), sin tocar `_identity_git` ni ninguna función que ya existe, salvo el argumento opcional:
  - `identity_secrets_file TIPO WORKSPACE DIR_DE_ESTADO` entrega `<workspace>/.env` con el tipo `repo`, y `<directorio de estado>/.env` en otro caso;
  - `identity_hash` acepta la ruta del archivo de secretos como último argumento opcional. Sin él, lee el del directorio de estado, como hoy. `identity_commit_and_push` no cambia;
  - `_identity_repo_git`, `identity_repo_prepare`, `identity_repo_commit_and_push` e `identity_repo_write_state`, con el molde del camino `repo`. Copian la lista de archivos de hoy y cifran el archivo de secretos con `age -R`, leyéndolo desde su ruta: nunca se copia en claro a la caché ni al árbol (I8).
  - `tests/backup-identity-lib.bats` y `tests/backup-identity-git.bats` siguen en verde, sin editarlas.
- [X] T021 [US1] Cambiar `docker/scripts/heartbeatctl` para el camino `repo` de `identity` (U1 y U8):
  - **La carga**: `backup_dest.sh` desde `$LIB_DIR`, con su guarda `[ -f ]`, junto a las demás (`:28-42`). Los archivos de estado nuevos junto a los de `:60-63`.
  - **El despacho**: al comienzo de `_bi_run`, después de sus salidas tempranas, si `backup_dest_resolve` existe y responde `repo`, se llama a `_bi_run_repo` y se devuelve su código. El resto del cuerpo de `_bi_run` no cambia.
  - **`_repo_begin`, `_repo_verify` y `_repo_end`**: los del molde. Dejan el archivo de cabezas en la caché de la unidad y, ante una falla, imprimen el mensaje de U1 y llaman a `backup_dest_record`, con el hash intentado si ya se calculó.
  - **`_bi_run_repo`**: los trece pasos de U1, con `identity_secrets_file`. Con `--dry-run` se detiene después del hash, sin tocar la red. Ante un árbol idéntico, completa el estado como dice U1.
  - **`--gc`** con repositorio: `git gc` sobre la caché `identity-repo`, si existe, y después la corrida.
  - TU01, TU02, TU24 y TU37, que corren solo sobre `identity`, en verde. Las que recorren las tres unidades siguen en rojo hasta T023. `tests/backup-identity-cmd.bats` y `tests/heartbeatctl.bats` en verde, sin editarlas.
- [X] T022 [US1] Agregar el camino `repo` de `vault` en claro: `_vault_repo_git`, `vault_repo_prepare`, `vault_repo_commit_and_push` y `vault_repo_write_state` en `scripts/lib/backup_vault.sh`, y `_bv_run_repo` con su `--gc` en `docker/scripts/heartbeatctl`. El contenido es el de `vault_list_markdown`, con su estructura, más la marca. El camino cifrado llega en T033. TU06 y TU36 quedan en verde; `tests/backup-vault-*.bats` y `tests/local-vault-backup.bats` siguen en verde, sin editarlas.
- [X] T023 [US1] Agregar el camino `repo` de `config` con el contenido de hoy: `_config_repo_git`, `config_repo_prepare`, `config_repo_commit_and_push` y `config_repo_write_state` en `docker/scripts/lib/backup_config.sh`, y `_bc_run_repo` con su `--gc` en `docker/scripts/heartbeatctl`. Por ahora la rama lleva `agent.yml` y la marca; el contenido ampliado llega en T031. Con las tres unidades en el camino `repo`, quedan en verde TU03, TU13 a TU15, TU17, TU18, TU22, TU23, TU26, TU33 y TU38; `tests/backup-config.bats` sigue en verde, sin editarla.
- [X] T024 [US1] Cambiar `docker/scripts/start_services.sh` (C1 y C6; U2), sin tocar `_run_watchdog`:
  - cargar `backup_dest.sh` con la cascada de `agent_path.sh` (`:82-86`);
  - `_identity_backup_fork_configured` conserva su nombre y responde 0 cuando el tipo es `repo` o `fork`. Si la librería no cargó, usa la lectura de hoy;
  - `_check_identity_backup` deja de salir cuando falta la ruta horneada de la librería: su guarda pasa a comprobar que `identity_hash` esté definida. Sin ese cambio, en el host la función sale antes de calcular nada, y TU25 pasaría sin probar nada;
  - la misma función toma el workspace de `IDENTITY_BACKUP_WORKSPACE_OVERRIDE`, y de él salen el directorio de estado y el archivo de estado (la costura `IDENTITY_BACKUP_AGENT_YML_OVERRIDE` que ya existe se conserva). Con el tipo `repo`, le pasa a `identity_hash` la ruta de `identity_secrets_file` y aplica la tabla "El supervisor no insiste" de U2, con `IDENTITY_BACKUP_RETRY_S`. Con `fork`, la regla es la de hoy;
  - `agent.yml` sale de una sola fuente, `${IDENTITY_BACKUP_AGENT_YML_OVERRIDE:-<workspace>/agent.yml}`, para la regla de destino y para la llave pública;
  - toda lectura del estado tolera un archivo ilegible: un valor que no se puede leer cuenta como ausente, y la función devuelve 0 siempre. El supervisor la llama sin `|| true`, bajo `set -euo pipefail`;
  - `_trigger_identity_backup` corre la unidad con `timeout -k 10 300` cuando el tipo es `repo`, y con `timeout 90`, como hoy, en otro caso. Su línea de log nombra el `last_result` anterior, si lo hay.
  - TU25 y TU34 en verde. `tests/start-services-watchdog.bats`, incluido su oráculo de sha de `_run_watchdog`, y `tests/backup-trigger-plugin-install.bats` en verde, sin editarlas.
- [X] T025 [US1] Cambiar `cmd_reload` de `docker/scripts/heartbeatctl` (`:319-326`) para la línea diaria de `identity` (U7; D20): con el tipo `repo`, la línea existe salvo que `features.identity_backup.enabled` sea `false`; con `fork` o `none`, existe solo si vale `true`, como hoy. TU29 en verde; `tests/heartbeatctl.bats` en verde, sin editarla.
- [X] T026 [US1] Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`:
  - `tests/backup-repo-units.bats`: TU01 a TU03, TU05, TU06, TU13 a TU15, TU17 a TU20, TU22 a TU26, TU29, TU31, TU33, TU34 y TU36 a TU38 en verde;
  - `tests/backup-identity-*.bats`, `tests/backup-vault-*.bats`, `tests/backup-config.bats`, `tests/local-vault-backup.bats`, `tests/restore-from-fork.bats`, `tests/restore-unified.bats`, `tests/heartbeatctl.bats` y `tests/start-services-*.bats` en verde, con `git diff origin/main --` sobre ellas vacío;
  - `git diff origin/main` no toca `_identity_git`, `_vault_git` ni `_config_git`;
  - `bash -n` (con `/bin/bash` y con el 5.x) sobre los archivos cambiados.

**Checkpoint**: un agente sin fork ya respalda identidad, secretos, vault y `agent.yml`. Es el corte que se puede entregar solo.

---

## Phase 4: User Story 2 - El respaldo cubre todo lo que hace recuperable al agente (Priority: P1)

**Goal**: el almacén cifrado por bloques con su llave de datos, `config` ampliada, el vault y la configuración cifrados de un agente sensible, y las unidades `memory` e `history`, con las rutas adicionales (FR-008 a FR-012 y FR-025).

**Independent Test**: `bats tests/backup-store.bats tests/backup-repo-units.bats` en los dos bash, con las 22 y las 40 pruebas en verde.

- [X] T027 [P] [US2] ROJO: crear `tests/backup-store.bats` y escribir TS01 a TS09 (`contracts/block-store.md`, S1 a S6). Todas usan un `--block-size` chico (por ejemplo 4096) para que un archivo de pocos KB ocupe varios bloques:
  - **TS01 a TS04**: `unpack` de la salida de `pack` reproduce byte a byte un archivo de texto, uno binario de varios bloques, uno vacío, y un árbol con rutas anidadas y con espacios, con sus modos.
  - **TS05**: un segundo `pack` informa `new_blocks: 0` y `rotated` vacío.
  - **TS06**: tras agregar bytes al final de un archivo, el `pack` siguiente escribe como máximo el último bloque anterior y los nuevos.
  - **TS07**: tras quitar un archivo del mapa, `blocks/` contiene solo los bloques que nombra el manifiesto.
  - **TS08**: ningún archivo de `--store` contiene el centinela, y los únicos archivos legibles como texto son `recipient` y `operator`.
  - **TS09**: `manifest.json.age` no es JSON legible y no contiene ninguna ruta lógica.
- [X] T028 [US2] ROJO: escribir TS10 a TS22 en `tests/backup-store.bats`:
  - **TS10**: con una llave privada que no corresponde, `unpack` sale con 4 y no escribe nada en `--dest`.
  - **TS11**: con un bloque alterado, sale con 5 y no deja ningún archivo en `--dest`.
  - **TS12**: un manifiesto con una ruta absoluta o con `..` se rechaza. La prueba lo arma cifrando un manifiesto a mano para la `recipient` del almacén.
  - **TS13**: un `.jsonl` cuya última línea no termina en salto de línea se empaqueta sin ella, y el `size` del manifiesto es el de lo empaquetado. Uno sin ningún salto de línea se omite.
  - **TS14**: `sqlite-snapshot` de una base en modo WAL, con un escritor abierto, pasa `integrity_check` y contiene las filas ya confirmadas.
  - **TS15**: `digest` y el campo `digest` de `pack` coinciden, y cambian con `--extra`.
  - **TS16**: `fingerprint` da lo mismo que `ssh-keygen -lf`.
  - **TS17**: `python3 -m py_compile` sobre la herramienta sale con 0, y la prueba imprime `python3 --version`. El piso es Python 3.9, que es el del Mac del operador.
  - **TS18**: una base SQLite con otro nombre (por ejemplo `datos.bin`) se reconoce por su cabecera y se empaqueta desde la copia; dos corridas sin cambios dan el mismo `digest`, también después de que el escritor cierra y se vacía el WAL; los archivos `-wal`, `-shm` y `-journal` del mapa no aparecen en el manifiesto; sin `--snapshot-dir`, encontrar una base es un error de uso (código 2).
  - **TS19**: tras un `pack` con la llave A, un `pack` con la llave B informa `rotated: operator-changed` y `new_blocks` igual a `blocks`; `unpack` con B reproduce los archivos, y con A sale con 4.
  - **TS20**: con un `age` espía en `AGE_BIN`, `unpack` de un almacén de más de 20 bloques invoca a `age` con la llave del operador exactamente una vez. Después de `pack` y después de `unpack`, ningún archivo del almacén, del directorio de copias, del directorio de trabajo ni del destino contiene `AGE-SECRET-KEY-`.
  - **TS21**: la prueba reemplaza `recipient` por la de un par ajeno. Con `--expect-recipient` de la original, `pack` informa `rotated: recipient-mismatch`, y la llave ajena no descifra ningún bloque. Sin esa opción, `pack` no rota.
  - **TS22**: `digest --list` entrega una línea por archivo, con la ruta lógica, el tamaño y el SHA-256. Para un `.jsonl` con la última línea incompleta, el tamaño es el de lo capturado. Para una base SQLite, el SHA-256 es el del archivo que `unpack` reconstruye.
  - Contra el código actual caen las veintidós: la herramienta no existe.
- [X] T029 [US2] Crear `docker/scripts/backup_store.py` y agregar su línea en `docker/Dockerfile` (`contracts/block-store.md`; sección 6 de `data-model.md`; D27):
  - **Un solo archivo**, solo con la biblioteca estándar, que corre en Python 3.9 y en 3.14. Sin anotaciones ni sintaxis posteriores a 3.9.
  - **Subcomandos**: `digest` (con `--list`), `pack` (con `--expect-recipient`), `unpack` (con `--work-dir`), `sqlite-snapshot` y `fingerprint`, con los códigos de salida de S4.
  - **La llave de datos**: `pack` la genera con `age-keygen`, cuya salida lee por un pipe; cifra la parte privada para la llave del operador en `key.age`; y escribe `recipient` y `operator`. Rota en los tres casos de S1. La parte privada nunca toca un archivo en claro.
  - **Formato**: bloques de 1.048.576 bytes como máximo; cada uno comprimido con gzip y cifrado con `age` para `recipient`, por la entrada estándar; el nombre del bloque es el SHA-256 de su contenido en claro, bajo `blocks/<2 hex>/`; el manifiesto va cifrado y se escribe de forma atómica.
  - **Determinismo**: el gzip se escribe con `mtime=0`. Un bloque que ya existe no se vuelve a cifrar, salvo al rotar.
  - **`unpack`**: abre `key.age` con la llave del operador en una sola invocación; deja la llave de datos en un archivo con modo 0600 dentro del directorio de trabajo, y la borra al terminar, también ante un error o una señal.
  - **Captura**: las reglas de la sección 6 de `data-model.md`, incluidas la de las líneas completas de un `.jsonl` y la de las bases SQLite por cabecera, con `--snapshot-dir`.
  - **Errores**: por stderr, sin contenido de archivos y con la ruta lógica, nunca la de origen.
  - **El Dockerfile**: `COPY scripts/backup_store.py /opt/agent-admin/scripts/backup_store.py`. No necesita `chmod`: las librerías lo llaman con `python3 "$BACKUP_STORE_PY"`.
  - TS01 a TS22 en verde en los dos bash; TU31 sigue en verde.
- [X] T030 [US2] ROJO: escribir TU04, TU27, TU32 y TU35 en `tests/backup-repo-units.bats`:
  - **TU04**: con un repositorio asociado, `backup/config` trae `agent.yml`, `CLAUDE.md`, `personas/<agente>.md` y `docker-compose.override.yml`; no trae `personas/<agente>.md.bak-...`; y un cambio en la persona produce un commit nuevo.
  - **TU27**: la rama trae `.claude/settings.json`, `.claude/skills/<algo>/SKILL.md` y un archivo de `commands/`, `agents/`, `hooks/` y `output-styles/`; no trae `.claude/settings.local.json`, `.claude/scheduled_tasks.lock`, nada de `.claude/worktrees/` ni un archivo suelto de otro nombre.
  - **TU32**: con repositorio, `backup-identity --configure-key` con la llave pública de `br_keys` imprime `key fingerprint SHA256:` con la huella de `ssh-keygen -lf` y la línea de las unidades cifradas, y deja el estado de `identity` con `mode: full`. Con fork, su salida es la de hoy.
  - **TU35**: con `backup.sensitive: true`, `backup/config` trae solo la marca, `agent.yml` y `store/`; `br_branch_has` no encuentra el centinela de la persona en el commit nuevo; y sin llave pública termina en `no-recipient`, con código 0 y sin empuje.
- [X] T031 [US2] Ampliar `config` en `docker/scripts/lib/backup_config.sh` y en `docker/scripts/heartbeatctl` (U2 y U3; D21, D28 y D29):
  - **El árbol** con el tipo `repo`: `agent.yml`, `CLAUDE.md`, `personas/` sin las copias `*.bak*`, `docker-compose.override.yml` si existe, y la lista cerrada de `.claude/` (`settings.json`, `skills/`, `commands/`, `agents/`, `hooks/` y `output-styles/`).
  - **En un agente sensible**: `agent.yml` en claro y todo lo demás empaquetado con `backup_store.py pack`, con `--recipients`, `--expect-recipient` (el `store_recipient` del estado, si lo hay) y la caché de la unidad como directorio de copias. Sin llave pública, `no-recipient`.
  - **El hash**: con `repo`, el de `backup_store.py digest` sobre todos los archivos, con la marca de datos sensibles y la llave pública en `--extra`. Con `fork`, `config_hash` y el árbol son los de hoy.
  - **`--configure-key`** (`_bi_configure_key`, `:820-841`): con el tipo `repo`, después de `recipient updated` imprime las dos líneas de U2, con la huella de `backup_store.py fingerprint`. Con fork o sin destino no cambia.
  - TU04, TU05, TU27, TU32 y TU35 en verde.
- [X] T032 [US2] ROJO: escribir TU07 y TU16 en `tests/backup-repo-units.bats`:
  - **TU07**: con `backup.sensitive: true`, `backup/vault` trae solo la marca y `store/`; `br_branch_has` no encuentra el centinela del vault en el commit nuevo; y pasar de sin marca a con marca produce un commit que quita los `.md` del árbol. Segunda pierna: con la marca y un fork en vez de repositorio, `backup-vault` imprime el mensaje de U1, sale con 0 y no crea ningún commit en el fork.
  - **TU16**: sin llave pública, `vault` y `config` en un agente sensible, `memory` e `history` terminan en `no-recipient`, con código 0 y sin ninguna petición `receive-pack`. `identity` corre en modo `partial`. Queda en verde al terminar T037.
- [X] T033 [US2] Agregar el camino cifrado de `vault` en `scripts/lib/backup_vault.sh` y en `_bv_run_repo` de `docker/scripts/heartbeatctl` (U4): con el tipo `repo` y `backup.sensitive: true`, la lista de `vault_list_markdown` se convierte en un mapa y se empaqueta con `backup_store.py pack`; el hash sale de `digest`, con la marca de datos sensibles y la llave pública en `--extra`; y el estado guarda `store_recipient`. Además, al comienzo de `_bv_run`: con el tipo `fork` y `backup.sensitive: true`, imprime el mensaje de U1 y sale con 0, sin empujar. El modo local no cambia: `tests/local-vault-backup.bats` sigue en verde, sin editarla. TU06 y TU07 en verde. TU16 sigue en rojo hasta T037.
- [X] T034 [US2] ROJO: escribir TU08, TU09, TU10, TU28, TU30 y TU39 en `tests/backup-repo-units.bats`, y extender TU03 a las cinco unidades:
  - **TU08**: sin la marca, `backup/memory` trae `auto-memory/<proyecto>/<archivo>` en claro y `store/`; el centinela de claude-mem no aparece en la rama. Segunda pierna: un cambio que solo toca la auto-memoria produce un commit nuevo.
  - **TU09**: con la marca, la rama no trae `auto-memory/`, y el centinela de la auto-memoria no aparece.
  - **TU10**: la base del fixture está en modo WAL, con filas que solo están en su `-wal`. Tras restaurar el almacén con `unpack`, la copia las trae. Una copia en bruto del archivo principal no las traería.
  - **TU28**: con `backup.extra_paths` nombrando un directorio de la raíz y uno bajo `.state/`, los dos llegan bajo `extra/` dentro de `store/`, y el centinela de la ruta adicional no aparece en la rama. Estas se omiten, cada una con su mensaje de U1: una ruta absoluta, una con `..`, una que no existe, `.`, `.state` entero (también escrito `./.state` y `.state/`), una bajo `.state/.cache`, `agent-repo`, una con un componente `.git`, y un enlace simbólico que apunta fuera del workspace. Un subdirectorio `.git` dentro de una ruta aceptada no llega al almacén.
  - **TU30**: tras un respaldo correcto, la prueba cambia solo `worker.pid`, `worker-heartbeat.json`, `supervisor.json`, `telemetry.json` y un archivo de `logs/`. El segundo ciclo crea 0 commits.
  - **TU39**, sobre `memory` e `history`: sin `GITHUB_PAT`, `no-credential`; con `anon-read`, `not-private`; con una rama sin marca, `foreign-branch`; con la marca de otro agente, `other-agent`. En los cuatro casos, ninguna petición `receive-pack`. Además: `memory` sin ninguna fuente termina en `nothing-to-back-up`, con código 0 y su registro; y con `stall-push` y `BACKUP_PUSH_TIMEOUT_S=2`, `history` termina en menos de 30 segundos con `push-failed`. Queda en verde al terminar T037.
  - **TU03**: los 10 ciclos pasan a correr las cinco unidades, y el repositorio queda con exactamente cinco ramas `backup/*`. Vuelve a verde al terminar T037.
- [X] T035 [US2] Crear `docker/scripts/lib/backup_memory.sh` y el comando `heartbeatctl backup-memory [--dry-run]` en `docker/scripts/heartbeatctl`, con su línea `COPY` en `docker/Dockerfile` (U5; D22, D23 y D33):
  - **Las fuentes**: `$IDENTITY_STATE_DIR/.claude/projects/<proyecto>/memory/**`, `$IDENTITY_STATE_DIR/.claude-mem/**` y cada ruta de `backup.extra_paths` bajo el workspace, con las exclusiones de la sección 5 de `data-model.md`.
  - **Las rutas adicionales** se validan con la regla de `backup.extra_paths` y, además, se resuelven: una que salga del workspace se omite. Los enlaces simbólicos no se siguen.
  - **El mapa** se arma con rutas lógicas `auto-memory/...`, `claude-mem/...` y `extra/...`. La auto-memoria va en claro en un agente sin marcar y al almacén en uno sensible.
  - **El hash** sale de `backup_store.py digest` sobre el mapa completo, los archivos que van en claro y los del almacén, con la marca de datos sensibles y la llave pública del operador en `--extra`. Es el valor que queda en el estado.
  - **El empaquetado**: `pack` recibe solo lo que va al almacén, con `--recipients` y, si el estado lo tiene, `--expect-recipient`. La `recipient` que devuelve queda en el estado como `store_recipient`.
  - **El directorio de copias** de SQLite (`--snapshot-dir`) vive dentro de la caché de la unidad.
  - **El `fetch` y el empuje** usan `BACKUP_PUSH_TIMEOUT_S`.
  - **Sin fuentes**: `nothing-to-back-up`, con su registro.
  - **El comando** sigue los trece pasos de U1 y entra al despacho de `main` (`:1251-1253`) y a `cmd_help`.
  - TU08 a TU10, TU28 y TU30 en verde. TU03, TU16 y TU39 siguen en rojo hasta T037; TU31 sigue en verde.
- [X] T036 [US2] ROJO: escribir TU11 y TU12 en `tests/backup-repo-units.bats`, y agregar a TU33 su pierna del almacén:
  - **TU11**: `backup/history` trae solo la marca y `store/`; los centinelas del historial no aparecen; un `.jsonl` con una última línea a medio escribir se restaura sin ella; y `projects/<proyecto>/memory/` no entra.
  - **TU12**: con un bloque chico, tras agregar líneas al final de un `.jsonl` de muchos bloques, el commit siguiente agrega como máximo dos bloques nuevos por archivo cambiado.
  - **TU33**: tras un respaldo correcto de `history`, la prueba borra su archivo de estado y su caché. El ciclo siguiente no agrega ningún bloque a la rama, y el que sigue termina en `no-change`.
  - **TU40**, sobre `history`, con las dos llaves de `br_keys`. Primera pierna: tras un respaldo con la llave A, `backup-identity --configure-key` con la llave B; el ciclo siguiente de `history` crea un commit en que cambian todos los bloques, su almacén se abre con B y no con A, y el estado tiene un `store_recipient` nuevo. Segunda pierna: la prueba empuja a la rama un commit que reemplaza `store/recipient` por la de un par ajeno y conserva la marca; el ciclo siguiente rota, y la llave ajena no abre ningún bloque de la cabeza nueva.
- [X] T037 [US2] Crear `docker/scripts/lib/backup_history.sh` y el comando `heartbeatctl backup-history [--dry-run]` en `docker/scripts/heartbeatctl`, con su línea `COPY` en `docker/Dockerfile` (U6): las fuentes son `$IDENTITY_STATE_DIR/.claude/projects/**` sin los directorios `memory/`; todo va al almacén; el directorio de configuración aislado del heartbeat no entra; el `fetch` y el empuje usan `BACKUP_PUSH_TIMEOUT_S`; sin fuentes, `nothing-to-back-up`. El hash y el empaquetado siguen la misma regla que en T035: la llave pública del operador en `--extra`, `--recipients` y `--expect-recipient`. TU03, TU11, TU12, TU16, TU33, TU39 y TU40 en verde.
- [X] T038 [US2] ROJO y código: TU21 en `tests/backup-repo-units.bats` y las dos líneas de cron en `cmd_reload` de `docker/scripts/heartbeatctl` (U7):
  - **TU21**: sin destino, el crontab generado es idéntico byte a byte a `tests/fixtures/crontab-v0.26.0.golden`, con el `agent.yml` de `tests/heartbeatctl.bats:10-21`, como en la prueba de `:359`. Con fork, es idéntico a `tests/fixtures/backup-repo/crontab-fork.golden`. Con `repo` y `features.identity_backup.enabled: false`, gana exactamente dos líneas, las de `backup-memory` y `backup-history`, con sus `schedule`. Con una unidad deshabilitada, o con un `schedule` inválido, falta esa línea, y en el segundo caso stderr trae una advertencia que nombra la clave y no el valor.
  - **El código**: las dos líneas se concatenan al último renglón del heredoc (`:436`), con el mecanismo de `review_line`. El validador es nuevo y admite `*` y `*/N` en los cinco campos (`_v_cron5_field` con el cuarto argumento en 1).
  - TU21 en verde; `tests/heartbeatctl.bats` y la prueba del crontab dorado (`tests/fixtures/crontab-v0.26.0.golden`) siguen en verde, sin editarlas.
- [X] T039 [US2] Escribir el simulador de SC-007 en `specs/046-agent-backup-repo/tools/sc007_sim.py`, versionado, y anotar su resultado en `specs/046-agent-backup-repo/tasks.md`. No lleva compuerta: corre en un directorio temporal del Mac.
  - **Los datos** son sintéticos, del tamaño de los de donna: un `.jsonl` de 68,6 MiB con líneas de hasta 5 MB, 32,6 MB en 86 archivos y una base SQLite de 13,9 MB.
  - **Los ciclos**: 30, y en cada uno se agregan unos 2 MB al `.jsonl` y se cambian filas de la base. Cada ciclo corre el `pack` real y un commit en un repositorio bare local.
  - **Lo que se anota**: el tamaño del repositorio tras el ciclo 1 y tras el 30 (`du -sk` después de `git gc`), los bloques nuevos por ciclo y la duración del primero.
  - **Lo esperado**: menos de 1 GB tras 30 ciclos. Si no se cumple, se detiene la fase y se revisa D8 con el operador.
- [X] T040 [US2] Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`: `tests/backup-store.bats` 22 de 22 y `tests/backup-repo-units.bats` 40 de 40; las suites de respaldo que ya existían, en verde y sin editar; `bash -n` y `python3 -m py_compile` sobre lo cambiado.

**Checkpoint**: las cinco unidades respaldan, y lo que debe ir cifrado no se puede leer en el repositorio.

---

## Phase 5: User Story 3 - El operador recupera un agente completo desde su repositorio (Priority: P1)

**Goal**: la restauración trae las cinco unidades desde el repositorio del agente, con la llave del operador, y sigue funcionando con un fork (FR-014).

**Independent Test**: `bats tests/backup-repo-restore.bats` en los dos bash, 14 de 14, más `tests/restore-from-fork.bats` y `tests/restore-unified.bats` sin editarlas.

- [X] T041 [P] [US3] ROJO: crear `tests/backup-repo-restore.bats` y escribir TR01 a TR05. El origen de cada prueba se arma corriendo las unidades reales de US1 y US2 contra el servidor de prueba. La restauración se llama como en `tests/restore-unified.bats`, dentro del cuerpo de la prueba: `source setup.sh` y `restore_from_fork ORIGEN DESTINO`, con `RESTORE_IDENTITY_KEY` y `GIT_TERMINAL_PROMPT=0`. El origen es la ruta en disco del repositorio bare que sirve el servidor: así la restauración no necesita credencial, como cuando el operador la corre con las suyas. Todas corren con un `HOME` propio y vacío; "sin llave" quiere decir sin `RESTORE_IDENTITY_KEY` y sin ninguna llave por defecto en ese `HOME`:
  - **TR01**: con la llave, cada archivo restaurado de las cinco unidades cae en la ruta de la sección 8 de `data-model.md`. Los que viajan tal cual tienen el mismo SHA-256 que su origen. Los capturados (una base SQLite y un `.jsonl` con la última línea incompleta) coinciden con la salida de `backup_store.py digest --list` tomada en el origen.
  - **TR02**: sin la rama `backup/history`, las otras cuatro se restauran y la salida dice cuál faltó.
  - **TR03**: sin llave, lo cifrado se omite con su línea, y lo que va en claro se restaura.
  - **TR04**: sin `python3` en el PATH (un PATH armado para la prueba), lo que viene en `store/` se omite con su línea, y lo demás se restaura.
  - **TR05**: con un bloque alterado en `backup/memory`, lo que viene en el almacén de esa unidad no deja ningún archivo en el destino, y las demás unidades se restauran.
- [X] T042 [US3] ROJO: escribir TR06 a TR14 en `tests/backup-repo-restore.bats`:
  - **TR06** (nace en verde): con un fork de tres ramas como el de `tests/restore-unified.bats`, la salida de la restauración, con la ruta de destino reemplazada por `<DEST>`, es idéntica a `tests/fixtures/backup-repo/restore-fork-output.golden`.
  - **TR07**: `--restore-from-repo` deja `RESTORE_FORK_URL` igual que `--restore-from-fork`, y aparece en `--help`.
  - **TR08**: un vault respaldado con la marca de datos sensibles se restaura en `vault.path`, con sus `.md`.
  - **TR09**: tras restaurar un repositorio de agente, los archivos de `memory` y de `history` están en su lugar, y `.agentic-pod-backup.json`, `key.age`, `recipient` y `operator` no quedan en ninguna parte del destino.
  - **TR10**: el archivo de secretos restaurado está en la raíz del destino, con modo 600 y el mismo SHA-256 que el original. Segunda pierna: si no trae un `CLAUDE_CODE_OAUTH_TOKEN` con valor, la salida trae el aviso de iniciar sesión; si lo trae, no.
  - **TR11**: `.claude/skills/<algo>/SKILL.md` queda en la raíz del destino.
  - **TR12**: las rutas adicionales vuelven a su ruta, también la que está bajo `.state/`. Un manifiesto con una ruta `extra/../fuera` se rechaza y no escribe nada fuera del destino.
  - **TR13**: con la `config` de un agente sensible. Con llave, vuelven `agent.yml`, la persona, `CLAUDE.md` y `.claude/`. Sin llave, vuelve solo `agent.yml`, con la línea `only agent.yml was restored`.
  - **TR14**: en `memory` sin llave, la auto-memoria en claro se restaura y lo cifrado se omite con su línea. Al terminar no existe `<destino>/.restore-tmp/`, ni en este caso ni tras la falla de integridad de TR05. Y cuando la restauración deja un `docker-compose.override.yml`, la salida trae su aviso.
- [X] T043 [US3] Extender la restauración en `setup.sh` (`contracts/restore.md`, R1 a R8; D16, D19 y D36):
  - **El alias**: `--restore-from-repo` en `parse_args` (`:465`) y en `print_usage`.
  - **`config`**: además de `agent.yml`, copia `CLAUDE.md`, `personas/`, `docker-compose.override.yml` y `.claude/`, si están. Si la rama trae `store/`, lo que no es `agent.yml` sale de ahí, y sin llave vuelve solo `agent.yml`.
  - **`identity`**: como hoy, y el archivo de secretos descifrado queda con modo 0600. Si no trae un `CLAUDE_CODE_OAUTH_TOKEN` con valor (`env_file_get`, que no lo imprime), sale el aviso de R3.
  - **`vault`**: si la rama trae `store/`, se descifra con `backup_store.py unpack`; si no, el camino de hoy.
  - **`memory` e `history`**: dos pasos nuevos, con el mapa de la sección 8 de `data-model.md`. Se intentan siempre, en silencio.
  - **Repositorio de agente o fork**: las líneas de los dos pasos nuevos y el resumen final solo se imprimen si alguna rama trajo la marca de pertenencia. Con un fork, la salida es la de hoy.
  - **El temporal**: lo cifrado se desempaqueta en `<destino>/.restore-tmp/`, con modo 0700, y se mueve a su lugar solo si la verificación pasó (I1). Un `trap` lo borra al terminar, también ante un error o una interrupción.
  - **Las rutas adicionales** se restauran solo dentro del destino (I6).
  - **La llave**: una sola regla para toda pieza cifrada, la de `_restore_decrypt_env` (`:1769-1788`): la llave indicada y, si no, las dos por defecto del directorio personal del operador. Se usa la primera que abre.
  - **Los requisitos**: sin `python3` 3.9 o superior, sin `age` o sin una llave que abra, lo cifrado se omite con la línea que corresponde.
  - **Lo que no se copia**: la marca y los tres archivos de la llave de datos.
  - **Los avisos**: el del token y el del override de compose, solo cuando el origen es un repositorio de agente. **Los prefijos** de cada línea son los que `setup.sh` ya usa en `:1806`, `:1810` y `:652`.
  - La herramienta se llama desde el clon del launcher: `$SCRIPT_DIR/docker/scripts/backup_store.py`.
  - TR01 a TR14 en verde.
- [X] T044 [US3] Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`: `tests/backup-repo-restore.bats` 14 de 14; `tests/restore-from-fork.bats` y `tests/restore-unified.bats` en verde, sin editarlas; `bash -n setup.sh` con los dos bash.

**Checkpoint**: un agente respaldado se puede reconstruir, y la prueba lo compara con lo respaldado.

---

## Phase 6: User Story 4 - El agente conoce su repositorio y trabaja en él sin tocar los respaldos (Priority: P2)

**Goal**: el wizard ofrece la asociación, el contexto del agente la describe, y el agente tiene un clon de trabajo con su credencial (FR-003, FR-010, FR-015, FR-016 y FR-019).

**Independent Test**: `bats tests/agent-repo-surface.bats` en los dos bash, 20 de 20, más las suites del wizard y del render, sin regresiones.

- [X] T045 [US4] ROJO: escribir TA01, TA02, TA03, TA16 y TA18 en `tests/agent-repo-surface.bats`, con flujos de respuestas hechos a mano para el paso nuevo:
  - **TA01**: en modo docker, la salida del wizard trae la pregunta `Associate a private repository with this agent?`. Con `n`, el `agent.yml` queda con `backup.repo.url` vacío, y el archivo de secretos no gana `GITHUB_PAT` si el MCP de GitHub está apagado.
  - **TA02**: con `y`, una URL válida, `y` a la pregunta de datos sensibles y el MCP de GitHub apagado, el wizard pide el token; `agent.yml` queda con la URL y `backup.sensitive: true`; y el archivo de secretos tiene la línea `GITHUB_PAT=`, con el valor de prueba.
  - **TA03**: con una URL inválida y la entrada por un pipe, el wizard termina con código 1 y un mensaje que nombra la regla. La prueba lo corre con un tope de 20 segundos: si se queda preguntando, falla. Además, `validate_backup_repo_url` da el resultado esperado para cada fila de `tests/fixtures/backup-repo/url-cases.tsv`.
  - **TA16**: en modo local, el flujo no tiene la pregunta (las mismas respuestas de hoy completan el wizard), y el `agent.yml` trae las claves nuevas con sus valores por defecto. Segunda pierna: con una URL en el `agent.yml` de un agente local, `--regenerate` imprime por stderr `WARN: backup.repo is docker-only - ignored in local mode`, y el `CLAUDE.md` renderizado no trae `## Your repository`. Tercera pierna: con `backup.sensitive: true` en un agente local, imprime `WARN: backup.sensitive is docker-only - the local vault backup stays in plaintext`.
  - **TA18**: en modo docker, con `backup.repo.url` y sin `backup.identity.recipient`, `--regenerate` imprime la advertencia de la llave con el comando `--configure-key`, y `agent.yml` sigue sin `recipient`. Sin `GITHUB_PAT` en el archivo de secretos, imprime la advertencia de la credencial. Con un `GITHUB_PAT` centinela presente, no la imprime, y el centinela no aparece en la salida. Sin `backup.repo.url`, no imprime ninguna.
- [X] T046 [US4] Agregar el paso del wizard en `setup.sh` y el validador en `scripts/lib/wizard-validators.sh` (A1 de `contracts/agent-surface.md`; D13 y D25):
  - **El paso** va después del bloque del fork (`setup.sh:659`) y antes de las notificaciones, solo si `deploy_mode` es `docker`. Sus textos son los del contrato, en inglés.
  - **El validador** `validate_backup_repo_url` aplica la regla de `backup.repo.url`.
  - **Una URL inválida**: la pregunta no usa `ask_validated`. Lee con `ask`, valida, y si la URL no sirve vuelve a preguntar solo cuando la entrada es una terminal (`[ -t 0 ]`); sin terminal, imprime la regla y termina con `exit 1`.
  - **El token**: en el paso del MCP de GitHub (`:831-840`), si el MCP no se activa y hay repositorio, se pide con el texto del contrato.
  - **Los secretos** (`:1333`): `GITHUB_PAT` se escribe cuando el MCP está activo o cuando hay repositorio.
  - **El heredoc**: las tres claves toman los valores del wizard.
  - **El resumen** (`:984-991`): tres ítems nuevos al final de la lista numerada, 24 a 26, con sus casos de edición. Los ítems 1 a 23 no cambian de número. Al editar el 24 y dejar un repositorio sin token, se pide el token.
  - **Sin gum**: el paso funciona con `scripts/lib/wizard.sh` a secas.
  - TA01 a TA03 en verde. TA16 sigue en rojo hasta T049.
- [X] T047 [US4] Actualizar los puntos de contacto de una pregunta nueva del wizard, y dejar sus suites en verde en los dos bash:
  - `tests/helper.bash`: en `wizard_answers()`, una respuesta `n` después de la del fork, solo en modo docker, con su comentario marcador `# Agent repository (docker only)`;
  - `tests/e2e-smoke.bats`: la respuesta nueva en su arreglo, y su tabla de comentarios;
  - **los flujos hechos a mano**: buscar con `grep -ln 'setup.sh' tests/*.bats` los que pasan por el paso del fork en modo docker sin `wizard_answers`, y agregarles la respuesta;
  - `docs/agentic-quickstart.es.md` y `docs/agentic-quickstart.en.md`: las tres preguntas nuevas en la tabla, después de la 19, con su columna "Asked when", el total de preguntas y la fila de `validate_backup_repo_url` en la tabla de validaciones;
  - `.claude/commands/quickstart.md`: el bloque nuevo en la plantilla del flujo y en la lista de validaciones;
  - `tests/quickstart-doc.bats`: la palabra clave nueva en la lista de bloques, el marcador nuevo en la de `wizard_answers()` y `validate_backup_repo_url` en la lista de validadores (`:171-174`).
  - `tests/wizard-flow.bats`, `tests/scaffold.bats`, `tests/e2e-smoke.bats`, `tests/quickstart-doc.bats`, `tests/deployment-mode.bats`, `tests/fork-commands.bats` y `tests/voice-config.bats` en verde.
- [X] T048 [US4] ROJO y código: TA09 en `tests/agent-repo-surface.bats` y `configure_identity_backup` en `setup.sh` (`:211-229`; D17):
  - **TA09**: con `SSH_KEYS_URL_TEMPLATE` apuntando a un archivo local y un `agent.yml` sin dueño de fork y con `backup.repo.url`, la llave pública queda en `backup.identity.recipient`, y la salida trae la huella `SHA256:` y el comentario de la llave. Sin fork y sin repositorio, la salida es la de hoy.
  - **El código**: el dueño sale del fork y, si no hay, de la URL del repositorio (el primer segmento de la ruta). Al fijar la llave se imprime el bloque de A2, con la huella de `backup_store.py fingerprint`. Si falta `python3`, se omite la línea de la huella. La función sigue llamándose solo desde el scaffold (`:2005`).
- [X] T049 [US4] Agregar los avisos de `--regenerate` en `setup.sh` (A2 de `contracts/agent-surface.md`; D25 y D29): después del backfill, las cinco líneas de la tabla del contrato, por stderr: las tres del repositorio y las dos de la marca de datos sensibles. La de la credencial mira solo si el valor existe, con `env_file_get` de `scripts/lib/env_file.sh`. `--regenerate` no escribe `backup.identity.recipient` ni ningún secreto. TA16 y TA18 en verde.
- [X] T050 [US4] ROJO: escribir TA06, TA07, TA08, TA13, TA14 y TA15 en `tests/agent-repo-surface.bats`:
  - **TA06** (nace en verde): para un `agent.yml` sin repositorio, la sección `## Backups (what actually survives)` del `CLAUDE.md` renderizado es idéntica byte a byte a `tests/fixtures/backup-repo/claude-md-backups-section.golden`, y el archivo no contiene ninguna cadena nueva de 046 (`Your repository`, `agent-repo`, `backup-memory`, `backup-history`).
  - **TA07**: con repositorio, el `CLAUDE.md` trae la tabla con las cinco ramas, la sección `## Your repository` y el punto `Not covered` con `backup.extra_paths`; no trae la frase `Backups exist only if`.
  - **TA08**: con repositorio, la URL de `agent.yml` y `/workspace/agent-repo` aparecen en `CLAUDE.md` y en `NEXT_STEPS.md`. Es esa presencia la que detecta un marcador sin exportar: el motor lo deja vacío, sin `{{`. En modo docker `NEXT_STEPS.md` solo lo escribe el wizard, así que la prueba lo obtiene llamando a `render_next_steps` (`setup.sh:1480`), dentro de su cuerpo.
  - **TA13**: `.gitignore` tiene la línea `/agent-repo/`.
  - **TA14** (nace en verde): para un `agent.yml` de modo local, con y sin `backup.repo.url`, ningún archivo derivado contiene `agent-repo`, `backup-memory`, `backup-history` ni `BACKUP_REPO`. La comparación completa contra `origin/main` es la de T067.
  - **TA15**: con repositorio, el `NEXT_STEPS.md` que entrega `render_next_steps` nombra el repositorio del agente, `heartbeatctl backup-memory`, `backup-history` y `backup-status`, en el bloque de docker; sin repositorio, no contiene ninguna de esas cadenas. Con repositorio y el MCP de GitHub apagado, el ejemplo de secretos renderizado trae la línea `GITHUB_PAT=`; sin repositorio y sin MCP, no la trae.
- [X] T051 [US4] Cambiar las plantillas, exportar los marcadores en `setup.sh` y actualizar `tests/schema.bats` (A3 y A8; D25):
  - **`modules/claude-md.tpl`**: la sección `## Backups (what actually survives)` de hoy (`:232-244`) queda dentro de `{{#unless BACKUP_REPO_ENABLED}}`, sin cambiar ni un byte de su texto, y el texto nuevo del contrato va dentro de `{{#if BACKUP_REPO_ENABLED}}`. Las etiquetas van pegadas al texto, sin saltos de línea entre una etiqueta y lo que encierra, como muestra A3. Los dos bloques van en el nivel superior: el motor no admite condicionales anidados. El texto nuevo es ASCII.
  - **`modules/next-steps.en.tpl` y `modules/next-steps.es.tpl`**: el marcador `{{BACKUP_REPO_NEXT_STEPS}}`, pegado al final de una línea que ya existe dentro del bloque de docker, para que un valor vacío no deje rastro. El texto del marcador empieza con sus propios saltos de línea.
  - **`modules/env-example.tpl`** (`:23-26`): la condición de la línea `GITHUB_PAT=` pasa de `MCPS_GITHUB_ENABLED` a `GITHUB_PAT_NEEDED`.
  - **Los marcadores**: `BACKUP_REPO_ENABLED` vale `true` solo con URL y modo docker; `BACKUP_REPO_WORKDIR` vale `/workspace/agent-repo`; `BACKUP_REPO_NEXT_STEPS` es el bloque ya renderizado, o vacío; `GITHUB_PAT_NEEDED` vale `true` con el MCP de GitHub activo o con `BACKUP_REPO_ENABLED`. Se exportan después de `render_load_context`, en `regenerate()` y en el camino de `render_next_steps` (`:1510`). Un valor de varias líneas se pasa como la persona (`scripts/lib/render.sh:63-73`).
  - **`.gitignore`**: la línea `/agent-repo/`.
  - **`tests/schema.bats`**: los marcadores derivados entran a sus dos listas `known_external` (`:62-83` y `:129-139`).
  - TA06 a TA08 y TA13 a TA15 en verde; `tests/claude-md-refresh.bats`, `tests/local-render.bats` y `tests/docker-render.bats` en verde, sin editarlas.
- [X] T052 [US4] ROJO: escribir TA10, TA11, TA12 y TA19 en `tests/agent-repo-surface.bats`. Cargan `docker/scripts/lib/agent_repo.sh` dentro del cuerpo de la prueba y usan `AGENT_REPO_DIR` y `AGENT_REPO_CREDENTIAL_HELPER`:
  - **TA10**: con el tipo `repo`, `agent_repo_ensure` crea el clon con la rama por defecto del remoto extraída; `git config --get-all remote.origin.fetch` trae la exclusión `^refs/heads/backup/*`; `credential.<esquema>://<servidor>.helper` es la ruta del ayudante; y el clon no tiene ninguna referencia `refs/remotes/origin/backup/*`, aunque el servidor las tenga.
  - **TA11**: con un directorio que ya es un repositorio, con una rama y un archivo propios, la función solo asegura las dos configuraciones. Con un directorio que no es un repositorio, no hace nada y deja una línea de log. Con el tipo `fork` o `none`, no hace nada y no escribe ningún log. Última pierna: con el clon borrado y sin la costura `AGENT_REPO_DIR`, `heartbeatctl backup-config` lo vuelve a crear en `<workspace>/agent-repo`.
  - **TA12**: desde el clon, `git push origin <rama nueva>` funciona sin preguntar; el centinela de la credencial aparece 0 veces en `.git/config`, y la URL del remoto no lleva credenciales.
  - **TA19**, en cuatro piernas: con un repositorio vacío, el clon queda en una rama `main` local sin commits; con uno que solo tiene ramas `backup/*`, lo mismo; con uno cuya rama por defecto es `trunk`, queda `trunk`; y con uno cuya rama por defecto es `backup/config` y que además tiene `main`, queda `main`. En las cuatro, `git branch --show-current` no empieza con `backup/`.
- [X] T053 [US4] Crear `docker/scripts/lib/agent_repo.sh` y `docker/scripts/git-credential-agent.sh`, llamarlos desde `docker/scripts/start_services.sh` y `docker/scripts/heartbeatctl`, y agregar sus líneas en `docker/Dockerfile` (A4 y A5; D11, D12 y D34):
  - **El ayudante** es el de A5, en `sh` POSIX, con modo 100755.
  - **`agent_repo_dir`** entrega `${AGENT_REPO_DIR:-${WORKDIR:-${HEARTBEATCTL_WORKSPACE:-/workspace}}/agent-repo}`: `heartbeatctl` no define `WORKDIR` y corre con `set -u`.
  - **`agent_repo_ensure`** sigue las dos tablas de A4. El `fetch` tiene el tope `AGENT_REPO_FETCH_TIMEOUT_S` y usa el ayudante, no el askpass de los respaldos. Si la creación falla a medias, borra el directorio.
  - **El clon** toma `user.name` y `user.email` de git desde `user.name` y `user.email` de `agent.yml`, solo si no los tiene.
  - **`start_services.sh`**: carga la librería con la cascada de `agent_path.sh`, y `main()` llama a `agent_repo_ensure` una vez, en segundo plano, después de `qmd_watch_start` (`:1385`), con su `|| true`. No se llama desde `_run_watchdog`.
  - **`heartbeatctl`**: `_bc_run_repo` la llama al terminar, con cualquier resultado, sin cambiar su código de salida (U3).
  - **El Dockerfile**: las dos líneas `COPY`, y el ayudante en el `chmod +x` de `:274-275`.
  - TA10 a TA12 y TA19 en verde; el oráculo de sha de `_run_watchdog` sigue en verde; TU31 sigue en verde.
- [X] T054 [US4] ROJO y código: TA20 en `tests/agent-repo-surface.bats` y el aviso de `--nuke` en `uninstall` de `setup.sh` (`:3258`; A8):
  - **TA20**: con un `agent-repo` que tiene un commit que no está en ninguna rama remota, o un archivo sin commitear, `./setup.sh --uninstall --nuke --yes` imprime un aviso que dice cuántos son, antes de borrar. Sin ninguna de las dos cosas, o sin `agent-repo`, no lo imprime.
  - **El código**: la comprobación va antes de las dos ramas de `--nuke` (`:3308` y `:3419`). Con `--yes` avisa y sigue; sin `--yes`, el aviso va antes de la confirmación que ya existe.
- [X] T055 [US4] Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`: `tests/agent-repo-surface.bats` 20 de 20; `tests/schema.bats`, `tests/regenerate.bats`, `tests/local-render.bats`, `tests/docker-render.bats`, `tests/uninstall.bats`, `tests/nuke-and-hints.bats` y las suites de T047 en verde.

**Checkpoint**: un agente nuevo puede nacer con su repositorio, y uno que ya existe lo adopta con `agent.yml`, `--regenerate` y su llave.

---

## Phase 7: User Story 5 - El operador ve si el respaldo está al día (Priority: P2)

**Goal**: un comando de estado dentro del contenedor y el diagnóstico que lo muestra, sin exponer ningún secreto (FR-017).

**Independent Test**: `bats tests/backup-status.bats` en los dos bash, 10 de 10.

- [X] T056 [P] [US5] ROJO: crear `tests/backup-status.bats` y escribir TB01 a TB06, TB09 y TB10 (A6 y A7 de `contracts/agent-surface.md`):
  - **TB01**: con repositorio, `backup-status --json` es JSON válido, con `destination`, `credential`, `sensitive`, `recipient`, `extra_paths`, las cinco `units` (con sus `max_age_hours`: 48, 25, 192, 49 y 49, y su `cache_bytes`), `cache_bytes_total` y `work_clone`.
  - **TB02**: con fork y sin destino, entrega el destino y las tres unidades de hoy, y no trae `work_clone`.
  - **TB03**: una unidad cuyo `last_push` supera su umbral aparece marcada como vencida en la salida legible.
  - **TB04**: una unidad con `last_result: push-failed` aparece con ese resultado y con su último respaldo correcto.
  - **TB05**: con un clon de trabajo que tiene 2 commits sin publicar y 1 archivo sin commitear, `unpublished_commits` es 2 y `dirty_files` es 1.
  - **TB06**: el centinela de la credencial aparece 0 veces en la salida con `--json` y sin `--json`, y `credential` vale `present` o `missing`.
  - **TB09**: con dos rutas adicionales declaradas y una que no existe, `extra_paths.declared` es 2 y `extra_paths.missing` trae esa ruta.
  - **TB10**: con una caché de tamaño conocido, `cache_bytes` de esa unidad y `cache_bytes_total` son mayores que 0, y sin el clon de trabajo `work_clone.present` es `false`. Las piernas del diagnóstico, con el doble de `docker` de T058: con `DOCTOR_BACKUP_CACHE_MAX_MB=1` y una caché de 2 MB sale la advertencia `Backup size`; sin el clon sale `Agent repository clone: missing`; y si `backup-status` falla con el contenedor arriba, el diagnóstico muestra las líneas que salen de los archivos de estado. Queda en verde al terminar T059.
- [X] T057 [US5] Agregar `heartbeatctl backup-status [--json]` en `docker/scripts/heartbeatctl`, con su entrada en `cmd_help` y en el despacho de `main` (A6; D14 y D35): lee la regla de destino, los archivos de estado, `backup-dest.json`, la huella de la llave (`backup_store.py fingerprint`), el tamaño de cada caché (`du -sk`), las rutas adicionales y el clon de trabajo. No toca la red y no modifica nada. TB01 a TB06 y TB09 en verde.
- [X] T058 [US5] ROJO: escribir TB07 y TB08 en `tests/backup-status.bats`, con un doble de `docker` propio. Parte del de `tests/agentctl-doctor-freshness.bats:26-40`, que responde "sano" y deja al diagnóstico llegar a su parte de respaldos, y le suma dos cosas: anota en un archivo los argumentos de cada llamada, y a `exec ... heartbeatctl backup-status --json` le responde un JSON fijo que la prueba elige:
  - **TB07**: con repositorio, `agentctl doctor` llama a `docker exec -u agent <agente> heartbeatctl backup-status --json` y muestra las líneas de A7: el destino, una por unidad, la llave, las rutas adicionales y el clon de trabajo. Cada situación de la lista de A7 produce su advertencia, incluido un veredicto `unverified`.
  - **TB08** (nace en verde): sin repositorio, el archivo de llamadas no tiene ninguna a `backup-status`; la parte de respaldos trae exactamente las tres líneas de hoy (`Backup identity`, `Backup vault` y `Backup config`, con `never pushed yet` en un agente sin fork); y no trae ninguna línea que nombre `Backup memory`, `Backup history`, `Backup destination`, `Backup size` ni `Agent repository clone`.
- [X] T059 [US5] Cambiar el diagnóstico en `scripts/agentctl` (`:193-243` y `:774-788`; A7): con `backup.repo.url` en el `agent.yml` del workspace, los datos salen de `backup-status --json`; si ese comando falla con el contenedor arriba, se leen los cinco archivos de estado. `_check_backup_freshness` gana las etiquetas de `memory` y de `history`. La advertencia de tamaño usa `DOCTOR_BACKUP_CACHE_MAX_MB`, 800 por defecto. Sin repositorio, el código de hoy no cambia. El contrato de salida (0, 1 o 2) no cambia. TB07, TB08 y TB10 en verde; `tests/agentctl*.bats` en verde, sin editarlas.
- [X] T060 [US5] Punto de control en bash 5.x y en 3.2, anotado en `specs/046-agent-backup-repo/tasks.md`: `tests/backup-status.bats` 10 de 10, y las seis suites nuevas juntas, 124 de 124.

**Checkpoint**: un respaldo roto deja de ser silencioso.

---

## Phase 8: Polish (documentos y comprobaciones locales, sin compuertas)

- [X] T061 [P] Reescribir en `README.md` la sección de respaldos (`:235-290`) y la de actualización de un agente:
  - las cinco ramas, la regla de destino y cómo asociar un repositorio a un agente nuevo y a uno que ya existe, con el paso de la llave y su huella;
  - que el repositorio tiene que estar en GitHub, y la recomendación de crearlo con un commit inicial en `main`;
  - la restauración con `--restore-from-repo`, sus requisitos (`python3` y `age`), la llave, y cuántas veces se pide una passphrase;
  - el recorte de una rama de respaldo y el cambio de la llave del operador;
  - que el cifrado da confidencialidad y no autenticidad;
  - la tabla de lo que ninguna unidad cubre (sección 9 de `data-model.md`) y `backup.extra_paths`;
  - la corrección de lo que hoy promete de más: el login de `/login` no viaja en el respaldo.
- [X] T062 [P] Actualizar los documentos que describen los respaldos: `docs/heartbeatctl.md` (los tres comandos nuevos, los resultados y `--configure-key`), `docs/architecture.md` (la regla de destino, la credencial, la llave de datos, el candado y el modelo de privilegios de los dos scripts), `docs/state-layout.md`, `docs/getting-started.md`, `docs/creating-an-agent.md`, `docs/adding-an-mcp.md` (`GITHUB_PAT` ya no es solo del MCP) y `docs/vault.md`. Donde decían tres ramas, dicen cinco con un repositorio asociado y tres con un fork.
- [X] T063 [P] Escribir la entrada de 0.32.0 en `CHANGELOG.md` (FR-024) y subir `VERSION` a 0.32.0, tras verificar que `git show origin/main:VERSION` da 0.31.0. La entrada dice qué se agrega, qué defecto se corrige (la unidad de identidad nunca cifró el archivo de secretos), qué no cambia (fork, sin destino y modo local) y que hace falta reconstruir la imagen.
- [X] T064 Escribir a mano el bloque de 046 en `CLAUDE.md`, actualizar su sección "Backup model" a cinco ramas, y agregar en "Common gotchas" lo que sirve más allá de esta feature:
  - con `CLAUDE_CONFIG_DIR` definido, el archivo de configuración vivo de Claude es `<config>/.claude.json`, no el del directorio de estado, y se reescribe hasta una vez por minuto;
  - un fixture que pone un archivo donde producción no lo tiene esconde el defecto: la unidad de identidad pasó sus pruebas durante meses sin cifrar nunca el archivo de secretos real;
  - la copia de una base SQLite con la API de respaldo es determinista, y una copia en bruto en modo WAL pierde datos;
  - `age` pide la passphrase de una llave ssh en cada invocación y no descifra sin terminal;
  - `ask_validated` no termina al llegar al fin de la entrada;
  - el motor de plantillas deja los saltos de línea que rodean a un bloque condicional que no se renderiza.

  Se commitea con `git add -f CLAUDE.md`. Auditar los bytes de los archivos de esta fase.
- [X] T065 Agregar al nightly un paso que instala `age`, en `.github/workflows/docker-e2e.yml` (V4 de `contracts/evidence.md`; M21):
  - **El paso** es nuevo, con `id: install_age`, entre `install_bats` y `verify_deps`: instala el paquete y comprueba `age --version` y `age-keygen`, con el molde de `.github/workflows/test.yml:89-96`. Sin `continue-on-error` y sin ningún pipe hacia `head` o `grep -q`.
  - **Lo que no se toca**: el texto de `Verify deps + docker` ni el de `Run docker-e2e suite`, que otras features congelaron por sha256.
  - **El oráculo que cambia**: `tests/nightly-alert.bats:1431` (N30) fija la lista de ids de los pasos del job. Pasa a `mark_start,checkout,install_yq,install_bats,install_age,verify_deps,fetch_models,run_suite,collect`.
  - **Los que no cambian**: `tests/ci-workflows.bats` y `tests/qmd-embed-nightly.bats` siguen en verde en los dos bash, sin editarse.
- [X] T066 Correr las comprobaciones estáticas y medir la duración, anotado en `specs/046-agent-backup-repo/tasks.md`:
  - el `shellcheck` exacto del job de la CI (`.github/workflows/shellcheck.yml`), con código 0, y `shellcheck -s sh` sobre `docker/scripts/git-askpass-agent.sh` y `docker/scripts/git-credential-agent.sh`;
  - `python3 -m py_compile` sobre `docker/scripts/backup_store.py`, `tests/fixtures/backup-repo/git-auth-server.py` y `specs/046-agent-backup-repo/tools/sc007_sim.py`;
  - `git ls-files -s` muestra 100755 en los dos scripts de credenciales;
  - `python3 --version` del Mac del operador, que debe ser 3.9.x: es la pata que cubre el piso de la herramienta del almacén. Si ya no lo es, T070 suma una corrida de `tests/backup-store.bats` con Python 3.9;
  - la duración de las seis suites nuevas en cada bash. Objetivo: menos de 180 segundos en total por bash en el Mac. El brazo macOS de la CI corre con un tope de 30 minutos y ya tarda unos 25 (issue #132): si las suites nuevas lo empujan sobre el tope, se propone al operador subirlo en un PR aparte, antes de T081.
- [X] T067 Comprobar el alcance, anotado en `specs/046-agent-backup-repo/tasks.md` (SC-004 y FR-018):
  - `git diff --stat origin/main` y `git status --short`, que ve los archivos todavía sin rastrear, muestran solo los archivos del árbol de `plan.md`, más los puntos de contacto de T007, T047, T051 y T065;
  - `git diff origin/main -- tests/backup-identity-*.bats tests/backup-vault-*.bats tests/backup-config.bats tests/restore-*.bats tests/local-vault-backup.bats` queda vacío;
  - el render completo de un `agent.yml` de modo docker sin repositorio y el de uno de modo local, desde la rama y desde la copia de T003, no tienen diferencias (`diff -r`) en ningún archivo derivado, y el crontab que genera `heartbeatctl reload` tampoco;
  - `modules/docker-compose.yml.tpl` y `docker/entrypoint.sh` no cambian: no hay capacidades, mounts ni variables nuevas.

---

## Phase 9: User Story 6 - La mejora se demuestra y llega a la flota (Priority: P3)

**Goal**: el catálogo de mutaciones, la prueba en un contenedor real, la revisión independiente, el gate completo y el respaldo y la restauración de un agente real, antes del merge (FR-021 y FR-022).

**Independent Test**: el Registro de este archivo tiene cada medición con su comando y su resultado.

- [X] T068 [US6] Preparar el corredor de mutaciones en `<scratchpad>/046/mutate.py`, con el molde de 045: para cada mutación copia el árbol a un directorio limpio, aplica un reemplazo exacto (con error si no encuentra el ancla), corre las suites afectadas en bash 5.x y con `PATH=/bin:$PATH`, y anota qué pruebas cayeron. M0 corre las pruebas finales contra el código de `origin/main`.
- [X] T069 [US6] Correr M0 a M167 en los dos bash (M139 a M167, de los arreglos de T073) y anotar la tabla en `specs/046-agent-backup-repo/tasks.md`. Cada fila es una sola variante, y debe hacer caer, al menos, las pruebas nombradas. Una que sobreviva obliga a endurecer la prueba, con su ROJO visto, y a repetir la corrida.

  | Id | Mutación | Debe caer | Resultado 5.x / 3.2 (s) |
  | --- | --- | --- | --- |
  | M0 | El código de `origin/main` con las pruebas finales | Todas, salvo TU05, TU19, TU20, TU31, TR06, TA06, TA14 y TB08 | 116 fallas; 8 verdes (70 / 75) |
  | M1 | La regla de destino ignora el repositorio asociado | TD01, TU01 | Cazada (1 / 1) |
  | M2 | Con fork y repositorio, la regla prefiere el fork | TD01 | Cazada (0 / 0) |
  | M3 | Con solo fork, la regla responde `none` | TD02 | Cazada (0 / 0) |
  | M4 | Un valor `null` cuenta como una URL | TD03 | Cazada (0 / 0) |
  | M5 | El askpass siempre es `/bin/true` | TD04, TD06, TU01 | Cazada (2 / 2) |
  | M6 | El askpass responde la contraseña vacía | TD05, TU01 | Cazada (2 / 1) |
  | M7 | La credencial se escribe en la URL del remoto | TD14 | Cazada (1 / 1) |
  | M8 | Se omite la sonda anónima | TD07, TU15 | Cazada (3 / 2) |
  | M9 | Se empuja con el veredicto `public` | TU15 | Cazada (2 / 1) |
  | M10 | Una sonda anónima que falla por otra razón cuenta como privada | TD16 | Cazada (1 / 0) |
  | M11 | `allow_unverified` habilita un repositorio público | TD17 | Cazada (1 / 0) |
  | M12 | `allow_unverified` salta la sonda anónima | TD09 | Cazada (0 / 0) |
  | M13 | El veredicto guardado nunca vence | TD10 | Cazada (2 / 1) |
  | M14 | El plazo de la sonda anónima se cuenta desde la última corrida | TD10 | Cazada (1 / 1) |
  | M15 | Un veredicto que no es `private` se guarda y se reutiliza | TD16, TU22 | Cazada (10 / 12) |
  | M16 | Una consulta autenticada que falla cuenta como alcanzable | TD08, TU14 | Cazada (3 / 2) |
  | M17 | La regla de la URL de la librería acepta otro servidor | TD11 | Cazada (3 / 2) |
  | M18 | La regla de la URL del esquema acepta otro servidor | TA05 | Cazada (7 / 8) |
  | M19 | El validador de la URL del wizard acepta otro servidor | TA03 | Cazada (1 / 0) |
  | M20 | Una consulta no tiene tope | TD18 | Cazada (301 / 300) |
  | M21 | `backup_dest_branch_head` no mira la rama pedida | TD15 | Cazada (0 / 0) |
  | M22 | No se comprueba la marca de pertenencia | TD12, TU17 | Cazada (4 / 3) |
  | M23 | No se compara el agente que nombra la marca | TD12, TU18 | Cazada (4 / 3) |
  | M24 | No se escribe la marca | TU01, TU23 | Cazada (8 / 6) |
  | M25 | El registro del intento reemplaza el estado en vez de fusionar | TD13 | Cazada (0 / 1) |
  | M26 | No se comprueba que exista la credencial | TU13 | Cazada (1 / 1) |
  | M27 | Un ciclo sin cambios no consulta al destino | TU23, TU26 | Cazada (6 / 6) |
  | M28 | El hash no se guarda después de un empuje | TU02 | Cazada (3 / 3) |
  | M29 | `--gc` con repositorio sigue leyendo solo el fork | TU02 | Cazada (2 / 2) |
  | M30 | El estado no se completa cuando el árbol es idéntico | TU33 | Cazada (4 / 4) |
  | M31 | Una unidad empuja con `--mirror` | TU03 | Cazada (2 / 2) |
  | M32 | Se quita el candado | TU37 | Cazada (2 / 2) |
  | M33 | El empuje de `identity` no tiene tope | TU36 | Cazada (302 / 301) |
  | M34 | El empuje de `vault` no tiene tope | TU36 | Cazada (306 / 307) |
  | M35 | El git de los respaldos honra la configuración global | TU38 | Cazada (2 / 1) |
  | M36 | `identity` vuelve a leer el archivo de secretos del directorio de estado | TU24 | Cazada (2 / 2) |
  | M37 | El supervisor y el comando calculan el hash de identidad con rutas distintas | TU25 | Cazada (2 / 2) |
  | M38 | El supervisor no espera tras un intento fallido | TU34 | Cazada (2 / 1) |
  | M39 | El disparador conserva el tope de 90 segundos con repositorio | TU34 | Cazada (3 / 2) |
  | M40 | Un registro sin hash conserva el `attempt_hash` anterior | TU34 | Cazada (2 / 2) |
  | M41 | Un estado ilegible hace fallar a `_check_identity_backup` | TU34 | Cazada (2 / 2) |
  | M42 | `--configure-key` no muestra la huella | TU32 | Cazada (2 / 2) |
  | M43 | Falta la línea diaria de `identity` con repositorio | TU29 | Cazada (1 / 1) |
  | M44 | El crontab gana líneas sin repositorio | TU21 | Cazada (1 / 1) |
  | M45 | Se quita la línea `COPY` de un archivo nuevo | TU31 | Cazada (0 / 0) |
  | M46 | `config` se amplía también con fork | TU05 | Cazada (1 / 1) |
  | M47 | El fork recibe la marca | TU20 | Cazada (1 / 2) |
  | M48 | El fork recibe el askpass | TU20 | Cazada (62 / 62) |
  | M49 | El estado gana campos nuevos con `fork` o `none` | TU19, TU20 | Cazada (2 / 1) |
  | M50 | Un agente sin destino escribe `backup-dest.json` | TU19 | Cazada (0 / 1) |
  | M51 | `unpack` escribe los bloques sin descomprimirlos | TS01, TS02, TS04 | Cazada (1 / 1) |
  | M52 | Un archivo vacío queda fuera del manifiesto | TS03 | Cazada (0 / 0) |
  | M53 | No se restauran los permisos | TS04 | Cazada (1 / 2) |
  | M54 | `pack` vuelve a cifrar bloques que ya existen | TS05, TS06, TU12 | Cazada (5 / 5) |
  | M55 | `pack` deja bloques sin referencia | TS07 | Cazada (0 / 0) |
  | M56 | `pack` deja un temporal en claro dentro del almacén | TS08 | Cazada (0 / 0) |
  | M57 | El manifiesto se escribe en claro | TS09 | Cazada (0 / 0) |
  | M58 | `unpack` deja salida parcial cuando `age` falla | TS10 | Cazada (0 / 0) |
  | M59 | `unpack` no verifica el hash | TS11 | Cazada (0 / 0) |
  | M60 | `unpack` acepta una ruta con `..` | TS12, TR12 | Cazada (13 / 12) |
  | M61 | Se quita la regla de las líneas completas | TS13, TU11 | Cazada (3 / 3) |
  | M62 | La base se copia en bruto | TS14, TU10 | Cazada (4 / 3) |
  | M63 | `digest` ignora `--extra` | TS15 | Cazada (0 / 0) |
  | M64 | `fingerprint` calcula sobre la línea entera | TS16 | Cazada (0 / 0) |
  | M65 | Un error de sintaxis en la herramienta | TS17 | Cazada (0 / 0) |
  | M66 | Una base SQLite con otro nombre se empaqueta en bruto | TS18 | Cazada (0 / 0) |
  | M67 | No hay rotación al cambiar la llave del operador | TS19 | Cazada (0 / 0) |
  | M68 | `unpack` usa la llave del operador en cada bloque | TS20 | Cazada (1 / 1) |
  | M69 | `unpack` deja la llave de datos en un archivo | TS20 | Cazada (1 / 1) |
  | M70 | Se ignora `--expect-recipient` | TS21 | Cazada (0 / 1) |
  | M71 | El hash de una unidad con almacén no incluye la llave del operador | TU40 | Cazada (4 / 4) |
  | M72 | Una unidad no le pasa `--expect-recipient` a `pack` | TU40 | Cazada (7 / 6) |
  | M73 | `digest --list` informa el tamaño del archivo vivo | TS22 | Cazada (0 / 0) |
  | M74 | La persona queda fuera de `config` | TU04 | Cazada (3 / 2) |
  | M75 | `config` incluye todo el directorio `.claude/` | TU27 | Cazada (3 / 2) |
  | M76 | Con la marca de datos sensibles, la configuración queda en claro | TU35 | Cazada (3 / 2) |
  | M77 | El vault va siempre al almacén | TU06 | Cazada (1 / 1) |
  | M78 | Con la marca, el vault queda en claro | TU07 | Cazada (2 / 2) |
  | M79 | Con la marca y un fork, el vault se empuja en claro | TU07 | Cazada (5 / 4) |
  | M80 | claude-mem va en claro | TU08 | Cazada (2 / 2) |
  | M81 | El hash de `memory` ignora la auto-memoria | TU08 | Cazada (3 / 2) |
  | M82 | Con la marca, la auto-memoria queda en claro | TU09 | Cazada (2 / 2) |
  | M83 | El historial va en claro | TU11 | Cazada (3 / 2) |
  | M84 | Sin llave pública se sube en claro | TU16 | Cazada (3 / 2) |
  | M85 | Una ruta adicional con `..` se acepta | TU28 | Cazada (3 / 2) |
  | M86 | Una ruta adicional viaja en claro | TU28 | Cazada (3 / 2) |
  | M87 | Una ruta adicional bajo `.state/.cache` se acepta | TU28 | Cazada (3 / 2) |
  | M88 | Una entrada `.` de `backup.extra_paths` se acepta | TU28 | Cazada (1 / 1) |
  | M89 | Se quitan las exclusiones de los archivos volátiles de claude-mem | TU30 | Cazada (4 / 3) |
  | M90 | `memory` e `history` no comprueban la marca | TU39 | Cazada (3 / 3) |
  | M91 | El empuje de `history` no tiene tope | TU39 | Cazada (307 / 307) |
  | M92 | `memory` sin fuentes no registra `nothing-to-back-up` | TU39 | Cazada (7 / 6) |
  | M93 | claude-mem se restaura en otro directorio | TR01 | Cazada (8 / 7) |
  | M94 | Una rama que falta aborta la restauración | TR02 | Cazada (8 / 7) |
  | M95 | Sin llave, la restauración aborta | TR03 | Cazada (9 / 8) |
  | M96 | Sin `python3`, la restauración aborta | TR04 | Cazada (13 / 13) |
  | M97 | La restauración deja una unidad a medias | TR05 | Cazada (8 / 8) |
  | M98 | La restauración imprime las líneas de `memory` y de `history` para un fork | TR06 | Cazada (1 / 1) |
  | M99 | El alias no se registra | TR07 | Cazada (0 / 0) |
  | M100 | Un vault cifrado se restaura como su `store/` | TR08 | Cazada (9 / 8) |
  | M101 | La marca se copia al workspace | TR09 | Cazada (8 / 7) |
  | M102 | El archivo de secretos restaurado queda con otro modo | TR10 | Cazada (8 / 8) |
  | M103 | El aviso del token sale siempre | TR10 | Cazada (11 / 9) |
  | M104 | `.claude/` se restaura bajo `.state/` | TR11 | Cazada (8 / 7) |
  | M105 | Las rutas adicionales se restauran bajo `extra/` | TR12 | Cazada (9 / 8) |
  | M106 | Sin llave, la configuración cifrada no restaura `agent.yml` | TR13 | Cazada (12 / 9) |
  | M107 | El directorio temporal no se borra | TR14 | Cazada (8 / 7) |
  | M108 | `GITHUB_PAT` se escribe siempre en el archivo de secretos | TA01 | Cazada (5 / 4) |
  | M109 | El token no se pide sin el MCP | TA02 | Cazada (5 / 5) |
  | M110 | El wizard vuelve a preguntar sin terminal | TA03 | Cazada (20 / 22) |
  | M111 | El backfill usa `//` y pisa un `false` | TA04 | Cazada (4 / 4) |
  | M112 | El esquema acepta un `backup.sensitive` que no es booleano | TA05 | Cazada (1 / 1) |
  | M113 | Los bloques `unless` e `if` de la plantilla se invierten | TA06, TA07 | Cazada (4 / 5) |
  | M114 | Un marcador derivado no se exporta | TA08 | Cazada (2 / 3) |
  | M115 | El dueño de la llave sale solo del fork | TA09 | Cazada (0 / 0) |
  | M116 | El clon de trabajo trae las ramas de respaldo | TA10 | Cazada (1 / 1) |
  | M117 | Un clon que ya existe se vuelve a crear | TA11 | Cazada (1 / 1) |
  | M118 | `backup-config` no vuelve a intentar el clon de trabajo | TA11 | Cazada (3 / 2) |
  | M119 | La credencial se escribe en la configuración del clon | TA12 | Cazada (1 / 1) |
  | M120 | `.gitignore` pierde `/agent-repo/` | TA13 | Cazada (0 / 0) |
  | M121 | `BACKUP_REPO_ENABLED` vale `true` en modo local | TA14, TA16 | Cazada (15 / 15) |
  | M122 | `NEXT_STEPS.md` muestra el bloque sin repositorio | TA15 | Cazada (5 / 4) |
  | M123 | La pregunta del wizard aparece en modo local | TA16 | Cazada (5 / 5) |
  | M124 | El esquema acepta un `backup.extra_paths` que no es una lista | TA17 | Cazada (1 / 1) |
  | M125 | `--regenerate` fija una llave por su cuenta | TA18 | Cazada (2 / 2) |
  | M126 | El aviso de `--regenerate` muestra el valor de `GITHUB_PAT` | TA18 | Cazada (3 / 3) |
  | M127 | El clon deja extraída una rama `backup/*` | TA19 | Cazada (1 / 1) |
  | M128 | `--nuke` no avisa | TA20 | Cazada (3 / 3) |
  | M129 | `backup-status` omite una unidad | TB01 | Cazada (0 / 0) |
  | M130 | Con fork, el JSON trae `work_clone` | TB02 | Cazada (0 / 0) |
  | M131 | El umbral de antigüedad nunca se supera | TB03 | Cazada (0 / 0) |
  | M132 | Un último intento fallido se informa como correcto | TB04 | Cazada (1 / 1) |
  | M133 | Los commits sin publicar siempre son 0 | TB05 | Cazada (0 / 0) |
  | M134 | `backup-status` imprime el valor de la credencial | TB06 | Cazada (0 / 1) |
  | M135 | El diagnóstico no advierte un intento fallido | TB07 | Cazada (1 / 0) |
  | M136 | El diagnóstico muestra las líneas nuevas sin repositorio | TB08 | Cazada (0 / 0) |
  | M137 | Una ruta adicional que falta no se lista | TB09 | Cazada (0 / 0) |
  | M138 | La advertencia de tamaño nunca sale | TB10 | Cazada (1 / 1) |
  | M139 | El clon de trabajo pasa `GITHUB_PAT` en los argumentos de `env` | TA12 | Cazada (1 / 1) |
  | M140 | El git de una unidad pasa `GITHUB_PAT` en los argumentos de `env` | TU01 | Cazada (2 / 2) |
  | M141 | El clon no reinicia los ayudantes de credenciales heredados | TA12 | Cazada (2 / 1) |
  | M142 | `--gc` corre `git gc` sin tomar el candado | TU37 | Cazada (2 / 2) |
  | M143 | Un `--dry-run` registra su resultado | TU13 | Cazada (1 / 1) |
  | M144 | El stderr de la herramienta del almacén se descarta | TU10 | Cazada (3 / 2) |
  | M145 | Con repositorio, el supervisor ignora `identity_backup.enabled: false` | TU25 | Cazada (3 / 2) |
  | M146 | El archivo del login de `/login` entra en las rutas adicionales | TU28 | Cazada (4 / 4) |
  | M147 | `memory_extra_path_check` no consulta las rutas reservadas | TU28 | Cazada (1 / 1) |
  | M148 | Un bloque se nombra con el SHA-256 de su contenido en claro | TS08 | Cazada (0 / 0) |
  | M149 | `pack` no usa el mapa de bloques | TS05, TS06 | Cazada (0 / 1) |
  | M150 | Una unidad no le pasa `--block-map` a `pack` | TU12 | Cazada (4 / 4) |
  | M151 | `unpack` no verifica el nombre de un bloque antes de descifrarlo | TS11 | Cazada (0 / 0) |
  | M152 | `unpack` acepta un segmento `.git` | TS12, TR12 | Cazada (11 / 11) |
  | M153 | `unpack` conserva los bits setuid, setgid y sticky | TS04 | Cazada (1 / 1) |
  | M154 | Una falla posterior a abrir `key.age` sale con 4 | TS11 | Cazada (0 / 0) |
  | M155 | La URI de SQLite se arma sin escapar la ruta | TS14 | Cazada (0 / 0) |
  | M156 | La restauración acepta un `vault.path` con `.git` | TR08 | Cazada (13 / 12) |
  | M157 | La restauración escribe a través de un enlace del destino | TR11 | Cazada (11 / 10) |
  | M158 | La configuración en claro se restaura sin su lista cerrada | TR11 | Cazada (9 / 9) |
  | M159 | La configuración del almacén se restaura sin su lista cerrada | TR13 | Cazada (11 / 10) |
  | M160 | El vault del almacén se restaura sin el filtro de markdown | TR08 | Cazada (11 / 9) |
  | M161 | La restauración sigue un `vault.path` con `..` | TR08 | Cazada (11 / 10) |
  | M162 | Las rutas adicionales se restauran sin las rutas reservadas | TR12 | Cazada (10 / 9) |
  | M163 | Las rutas adicionales se restauran sin la lista declarada | TR12 | Cazada (9 / 9) |
  | M164 | El archivo del login se restaura desde las rutas adicionales | TR12 | Cazada (10 / 9) |
  | M165 | Las rutas adicionales restauradas no se excluyen del git del workspace | TR12 | Cazada (8 / 8) |
  | M166 | La línea del vault sale aunque su almacén se haya omitido | TR08 | Cazada (14 / 13) |
  | M167 | La identidad en claro copia los enlaces de su rama | TR11 | Cazada (10 / 9) |

  Las mutaciones de la clase SIGPIPE se plantan con un comando externo, no con un builtin. Cada una de las 124 pruebas cae con al menos una fila.
- [X] T070 [US6] Pata Linux en contenedores desechables (sin COMPUERTA; se avisa antes), anotada en `specs/046-agent-backup-repo/tasks.md`. El repo se copia, no se monta, y las pruebas corren como usuario no root:
  - **`ubuntu:24.04`** (GNU, bats 1.11, `git http-backend` del paquete `git`, `age`, `python3` y el `flock` de util-linux): las seis suites nuevas, 124 de 124, con la variable `CI` definida, para que ninguna dependencia que falte se salte en silencio.
  - **`alpine:3.24.1`** (BusyBox y el Python de la imagen del agente): `tests/backup-store.bats` y `tests/backup-dest.bats`, para ver el `timeout -k 10` de BusyBox y la herramienta en Python 3.14. Con un `git` falso que ignora TERM, la consulta termina dentro del tope más 10 segundos.
  - **El candado bajo BusyBox** (lección de 044): dos corridas seguidas de una unidad, sin espera entre ellas, y la segunda no encuentra el candado tomado.
- [X] T071 [US6] Escribir `tests/docker-e2e-backup-repo.bats` con TE1 a TE8 (`contracts/evidence.md`, V4), en el molde de `tests/docker-e2e-user-bin-path.bats`:
  - **El arranque**: `skip` sin `DOCKER_E2E=1`; un solo arranque en `setup_file`; agente `br-e2e`; `plugins: []`.
  - **El servidor** corre en el host, con `GIT_TEST_BIND=0.0.0.0`. El compose del agente de prueba gana `extra_hosts: ["host.docker.internal:host-gateway"]` con un `docker-compose.override.yml`.
  - **El archivo de secretos** del workspace de prueba lleva `GITHUB_PAT` con el centinela y `BACKUP_DEST_ALLOW_HTTP=1`. Se escribe con el arnés, no con un comando de shell que lo nombre.
  - **TE5** usa un segundo workspace, o una segunda fase con `backup.sensitive: true`, y busca también el centinela de la persona.
  - **TE6** fija el `schedule` de `memory` en `* * * * *`, que U7 admite, y espera, acotado a 150 segundos, a que la rama cambie. Un minuto fijo podría perder su disparo: el crontab se sincroniza cada 15 segundos.
  - **TE7** restaura en un directorio del host, desde la ruta en disco del repositorio bare que llenó el contenedor, y compara con las dos listas de R7 de `contracts/restore.md`.
  - Cada prueba tiene su espera acotada y un volcado solo al fallar. `teardown_file` baja el contenedor, borra la imagen de prueba y mata el servidor.
  - En el host, sin Docker, el archivo carga y salta limpio en los dos bash.
- [X] T072 [US6] COMPUERTA (DOCKER_E2E local, arm64), anotada en `specs/046-agent-backup-repo/tasks.md`:
  - anotar la huella sha256 de los archivos de código de la rama;
  - correr `DOCKER_E2E=1 bats tests/docker-e2e-backup-repo.bats` (8 de 8);
  - correr `DOCKER_E2E=1 bats tests/docker-e2e-*.bats`: 62 casos. En este Mac, `tests/docker-e2e-smoke.bats:79` falla también en `origin/main`, y no es de esta feature;
  - anotar la duración y cada resultado. Un rojo se diagnostica con el volcado, se corrige con su prueba primero y se repite.
- [X] T073 [US6] Revisión independiente de solo lectura (agente `code-reviewer`), antes del gate completo, anotada en `specs/046-agent-backup-repo/tasks.md`. El encargo incluye:
  - **La revisión de privilegios** que la constitución exige para todo cambio bajo `docker/` (Principio II): capacidades, mounts, qué corre como root, y cualquier `docker exec` sin `-u agent` en el código y en las pruebas;
  - **El manejo de secretos**: que el valor de `GITHUB_PAT` no llegue a argumentos, URL, configuración de git, logs ni archivos de estado; que nada que deba ir cifrado toque el disco en claro dentro de un árbol que se commitea; y que la llave de datos no quede en ningún archivo en claro;
  - **Las clases de hallazgo** de la memoria: aserciones vacuas, guardias redundantes, una guardia de seguridad sin prueba, un verificador propio que falla en silencio, y fixtures que no tienen la disposición de producción.

  Los hallazgos que se acepten se corrigen con su prueba primero, y se repite lo afectado de T069 y T072.
- [X] T074 [US6] Gate completo del host sobre el árbol final, anotado en `specs/046-agent-backup-repo/tasks.md` (SC-009):
  - `bats tests/` en bash 5.x y en 3.2, en secuencia. Esperado: la línea base de T003 más 132, con 0 `not ok`, las saltadas de la línea base más las 8 de extremo a extremo, y stderr vacío;
  - las seis suites nuevas con SIGPIPE ignorada: `perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`;
  - las comprobaciones de T066 y T067, y la huella de T072 sin cambios;
  - al terminar, se quita la copia de T003.
- [X] T075 [US6] COMPUERTA (commits locales), en commits atómicos y sin ninguno intermedio en rojo, con la identidad de T001 y sin atribución. Antes, `git ls-files -s` para los modos y la auditoría de bytes de los archivos nuevos:
  1. `docs:` la enmienda de `.specify/memory/constitution.md`;
  2. `feat:` las librerías, `docker/scripts/heartbeatctl`, `docker/scripts/start_services.sh`, `docker/scripts/backup_store.py`, los dos scripts de credenciales, `docker/Dockerfile`, `setup.sh`, `scripts/agentctl`, `modules/`, `.github/workflows/docker-e2e.yml` y las pruebas;
  3. `docs:` `README.md`, `docs/`, `CHANGELOG.md`, `VERSION`, `CLAUDE.md` y el Registro de este archivo.
- [X] T076 [US6] COMPUERTA (push): empujar la rama `046-agent-backup-repo` por HTTPS con el ayudante de `gh`, y anotar en `specs/046-agent-backup-repo/tasks.md` el commit que quedó en el remoto. El cambio del workflow necesita el permiso `workflow` del token, que la cuenta ya tiene desde 025.
- [ ] T077 [US6] COMPUERTA (gate en linus, preparación; `quickstart.md`, sección 4, pasos 1 a 9), anotada en `specs/046-agent-backup-repo/tasks.md`:
  1. respaldar la imagen como `agentic-pod:linus-pre046` y copiar los archivos de sistema del workspace;
  2. anotar las cabezas de las ramas de trabajo en GitHub, antes de asociar nada;
  3. llevar el código de la rama con el procedimiento de actualización del `README.md`, correr `./setup.sh --regenerate` y `custom-apply --no-regenerate`, como en 045;
  4. hacer el inventario del estado que ninguna unidad cubre (FR-026), con una sonda de solo nombres y tamaños, y decidir con el operador cada entrada. En linus se sabe de `/workspace/repos/` y de su clon antiguo, que tiene un commit sin publicar;
  5. revisar los nombres de los archivos que van a viajar en claro (la lista de identidad y la configuración), y confirmar con el operador que ninguno lleva un valor sensible;
  6. fijar `backup.repo.url` con la URL de `linus-workspace-agent-admin` y regenerar. Anotar los avisos de `--regenerate`;
  7. comprobar que el `CLAUDE.md` vivo ganó la sección `## Your repository`; si no, forzar el render con `--force-claude-md`;
  8. `docker compose build`, stop, 150 segundos y up;
  9. fijar la llave con `heartbeatctl backup-identity --configure-key`, y confirmar con el operador que la huella que imprime es la de una llave cuya parte privada tiene a mano.
- [ ] T078 [US6] COMPUERTA (gate en linus, respaldo; pasos 10 a 12 y 15), anotada en `specs/046-agent-backup-repo/tasks.md`:
  - **El primer ciclo**: correr las cinco unidades y `heartbeatctl backup-status`, todo con `docker exec -u agent`. Anotar el commit de cada rama en GitHub y la duración de cada empuje.
  - **La verificación**: las cinco ramas `backup/*` existen; la de identidad trae `.env.age`; las de `memory` y de `history` traen sus tres archivos de llave; las ramas de trabajo tienen las cabezas del paso 2 de T077; el repositorio sigue privado.
  - **El segundo ciclo**, sin conversación de por medio: 0 commits nuevos en las cinco ramas. Si `memory` crea uno, hay un archivo volátil fuera de la lista de D23: se corrige con su prueba y se repite.
  - **El tercer ciclo**, después de un par de mensajes al agente: cuántos bloques nuevos subió `history`.
  - **El clon de trabajo**: existe en `/workspace/agent-repo`, en una rama de trabajo, sin ramas de respaldo.
  - **El estado final**: el contenedor sano, 0 reinicios y el canal arriba. `agentctl doctor` muestra las líneas de respaldo sin advertencias.
- [ ] T079 [US6] COMPUERTA (gate en linus, restauración; pasos 13 y 14; R7 de `contracts/restore.md`), anotada en `specs/046-agent-backup-repo/tasks.md`:
  - **Las dos listas de origen**: dentro del agente, justo después de un ciclo, el tamaño y el SHA-256 de cada archivo que viaja tal cual, incluido el archivo de secretos, y la salida de `backup_store.py digest --list` de cada unidad con capturas. Sin mostrar contenido. El script se escribe con Write.
  - **La restauración**: en el equipo que tiene la llave privada, sobre un directorio limpio, llamando a la función de restauración. No se arranca ningún contenedor ni el canal. Anotar cuántas veces se pidió la passphrase, si la llave la tiene.
  - **La comparación**: el 100 % de los archivos coincide, salvo los que cambiaron después del último respaldo, que se anotan uno por uno.
  - **La medición de M5**: dentro del agente, copiar el historial restaurado a un directorio de configuración temporal y correr `claude -p --continue` desde `/workspace`. Anotar si retomó la conversación. Gasta cuota de la suscripción: el operador lo autoriza aparte.
  - **La limpieza**: borrar el directorio restaurado, que contiene secretos descifrados, y confirmarlo.
- [ ] T080 [US6] Cerrar el gate, anotado en `specs/046-agent-backup-repo/tasks.md`:
  - si la medición de M5 no retomó la conversación, enmendar SC-002 y la historia 3 de `specs/046-agent-backup-repo/spec.md` antes del merge, con el operador;
  - si cualquier otro punto de la sección V5 de `contracts/evidence.md` falló, no se propone el merge: se vuelve a `agentic-pod:linus-pre046` con los archivos respaldados, se vacía `backup.repo.url` y se anota la causa;
  - si todo pasó, linus se queda con la imagen de la rama hasta el merge.
- [ ] T081 [US6] COMPUERTA (PR): abrir el PR contra `main` con el resumen, la evidencia de T069 a T080 y el despliegue pendiente. Esperar la CI en verde en los tres checks (shellcheck, bats en ubuntu y en macOS) y anotar en `specs/046-agent-backup-repo/tasks.md` los conteos y la duración de cada brazo. En los dos brazos, ninguna de las 124 pruebas nuevas sale saltada. El merge lo hace el operador.

**Checkpoint**: la evidencia de FR-022 está completa y el PR espera el merge.

---

## Phase 10: Cierre (después del merge)

**Purpose**: el despliegue en la flota (FR-023 y SC-010), un agente a la vez, y el registro. Todas las tareas son de la historia 6.

- [ ] T082 [US6] Verificar `main` con lecturas, tras el merge que hace el operador, y anotarlo en `specs/046-agent-backup-repo/tasks.md`: el árbol es el de la cabeza validada; `VERSION` es 0.32.0; la constitución está en 1.1.0; existen `docker/scripts/lib/backup_dest.sh` y `docker/scripts/backup_store.py`, con sus líneas `COPY`. Mirar la primera nocturna posterior: su resumen debe decir `total=62 executed=62 skipped=0`.
- [ ] T083 [US6] COMPUERTA (despliegue en linus; sección 5 de `quickstart.md`): alinear linus con `main` si algo cambió respecto de la rama, correr un ciclo y `backup-status`, avisarle al agente que su clon de trabajo es ahora `/workspace/agent-repo`, y observar 24 horas. Anotar en `specs/046-agent-backup-repo/tasks.md` el primer respaldo verificado, las ramas de trabajo intactas y los reinicios (SC-010).
- [ ] T084 [US6] COMPUERTA (despliegue en donna), anotado en `specs/046-agent-backup-repo/tasks.md`:
  - el respaldo `agentic-pod:donna-pre046`, los archivos de sistema y las cabezas de sus ramas de trabajo;
  - el inventario de FR-026 y sus rutas adicionales. Por lo medido en M16, al menos `.custom` y `.state/.config/donna`; los adjuntos descargados los decide el operador;
  - la revisión de lo que viaja en claro, la asociación de `donna-workspace-agent-admin` y la regeneración;
  - la sección `## Your repository` en su `CLAUDE.md` vivo, con `--force-claude-md` si hace falta, y después `custom-apply --no-regenerate`, porque el render le borra sus MCP de overlay;
  - build, stop, 150 segundos y up; y la llave, con `--configure-key` y su huella confirmada;
  - el primer ciclo. El empuje del historial es el más grande de la flota (unos 55 MB): anotar su duración;
  - la verificación de las ramas, el aviso al agente sobre su clon de trabajo, y el destino de su clon antiguo en `~/donna-workspace-agent-admin`, que decide el operador;
  - 24 horas de observación.
- [ ] T085 [US6] COMPUERTA (despliegue en cbum), anotado en `specs/046-agent-backup-repo/tasks.md`:
  - el operador crea el repositorio privado de cbum, con un commit inicial en `main`, y ajusta la regla de su persona que prohíbe subir datos de salud a un repositorio, para que permita el respaldo cifrado del launcher y nada más;
  - el respaldo `agentic-pod:cbum-pre046`, el inventario de FR-026 (en la sonda del 13-11-2026 no tenía estado fuera de las rutas conocidas), la revisión de la lista de identidad, que es lo único que viaja en claro además de `agent.yml`, la asociación y `backup.sensitive: true`;
  - la sección `## Your repository` en su `CLAUDE.md` vivo; build, stop, 150 segundos y up; y la llave, con `--configure-key` y su huella confirmada;
  - el primer ciclo y la verificación de SC-010: 0 archivos en claro de su vault, sus memorias, su historial y su configuración, salvo `agent.yml`;
  - 24 horas de observación.
- [ ] T086 [US6] COMPUERTA (issues): abrir, con el visto bueno del operador, los issues de los hallazgos laterales de `specs/046-agent-backup-repo/research.md`:
  - con destino fork, la unidad de identidad no cifra el archivo de secretos y el respaldo no puede autenticarse desde el contenedor;
  - el wizard escribe un bloque `features.review` que nadie lee (`setup.sh:1279`);
  - `fetch_github_ssh_key` usa `printf ... | grep -m 1` bajo `pipefail`;
  - el informe automático de estado sin clasificar, como mejora posterior (D22);
  - `ask_validated` no termina al llegar al fin de la entrada (`scripts/lib/wizard.sh:76-94`).
  - procesar archivo por archivo en `backup_store.py`, diferido por decisión del operador el 15-11-2026 durante T073.
- [ ] T087 [US6] COMPUERTA (registro fuera del repo), con la lista anotada en `specs/046-agent-backup-repo/tasks.md`:
  - en Confluence, la página del equipo (397072) y una fila por agente en el historial de versiones de la flota (32243715);
  - las fichas de los agentes y la memoria de la sesión;
  - la ficha de Doctor Milagro (`definiciones/milagro/milagro.md`): ahora necesita `GITHUB_PAT`, la marca de datos sensibles, una respuesta más del wizard y su repositorio privado, creado con un commit inicial en `main`.
- [ ] T088 [US6] Abrir un PR de documentos con el Registro final de `specs/046-agent-backup-repo/tasks.md` y el estado de `CLAUDE.md`. COMPUERTA para el commit, el push y el PR.
- [ ] T089 [US6] Dejar anotado en `specs/046-agent-backup-repo/tasks.md` lo que limpia el operador, porque el modo auto bloquea `git push --delete`: el worktree, la rama local y la remota de 046, y los respaldos `agentic-pod:<agente>-pre046` una vez pasadas las 24 horas de cada despliegue.

---

## Trazabilidad de requisitos

Cada requisito y cada criterio de éxito del spec, con las pruebas y las tareas que lo cubren.

| Requisito | Pruebas | Tareas |
| --- | --- | --- |
| FR-001 | TA04, TU29 | T006, T007, T018, T046 |
| FR-002 | TD01 a TD03 | T009, T010, T021 a T023 |
| FR-003 | TA01 a TA03, TA16, TA18 | T045 a T047, T049 |
| FR-004 | TD12, TU03, TU17, TU18, TU23, TU39 | T014, T015, T018, T021 a T023, T034 |
| FR-005 | TD06 a TD11, TD16, TD17, TU15, TA05 | T006, T009, T010, T014 |
| FR-006 | TD04, TD05, TU13 | T009, T010, T014, T046 |
| FR-007 | TD14, TA12, TB06 | T009, T052, T056, T073 |
| FR-008 | TU04, TU08, TU11, TU24, TU27 | T020, T031, T035, T037 |
| FR-009 | TS08, TS09, TU06 a TU09, TU11, TU35 | T029, T031, T033, T035, T037 |
| FR-010 | TS19, TU16, TU32, TU40, TA09, TA18 | T029, T031, T032, T036, T048, T049 |
| FR-011 | TS13, TS14, TS18, TU10 | T028, T029, T034 |
| FR-012 | TS05, TS06, TU02, TU12, TU30, TU33, TB10 | T029, T036, T039, T057, T059 |
| FR-013 | TD18, TU14, TU22, TU23, TU26, TU34, TU36 a TU38 | T015 a T017, T021, T024, T070 |
| FR-014 | TR01 a TR14 | T041 a T044 |
| FR-015 | TA06 a TA08 | T050, T051 |
| FR-016 | TA10 a TA12, TA19 | T052, T053 |
| FR-017 | TB01 a TB10 | T056 a T059 |
| FR-018 | TU05, TU19, TU20, TU21, TR06 | T018, T038, T067 |
| FR-019 | TA14, TA16 | T045, T049 a T051, T067 |
| FR-020 | No aplica | T005 |
| FR-021 | Las 124 del host y TE1 a TE8 | T071, T072, T074 |
| FR-022 | No aplica | T077 a T080 |
| FR-023 | No aplica | T083 a T085 |
| FR-024 | No aplica | T061 a T064 |
| FR-025 | TU28, TR12, TB09, TA17 | T007, T034, T035, T043, T057 |
| FR-026 | No aplica | T077, T084, T085 |

| Criterio | Pruebas | Tareas |
| --- | --- | --- |
| SC-001 | TU01, TU02, TE1, TE2 | T013, T078 |
| SC-002 | TR01, TR10, TS22, TE7 | T041, T042, T079 |
| SC-003 | TU03, TE3 | T018, T034, T078 |
| SC-004 | TA06, TA14, TU19 a TU21 | T018, T038, T067 |
| SC-005 | TD14, TS08, TS19, TU24, TU35, TU40, TA12, TB06, TE5, TE8 | T073 |
| SC-006 | TD18, TU14, TU26, TU36, TE4 | T015, T017, T070 |
| SC-007 | TU12 | T039, T084 |
| SC-008 | TA06, TA07 | T050, T051 |
| SC-009 | Todas | T003, T074 |
| SC-010 | No aplica | T083 a T085 |

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001 a T004)**: T002 antes de cualquier otro commit. T003 corre mientras se escriben archivos, sin otro `bats` en paralelo.
- **Foundational (T005 a T012)**: T005 antes de cualquier cambio de código. T006 antes de T007. T008 antes de T009, y T009 antes de T010. Bloquea todas las historias.
- **US1 (T013 a T026)**: el ROJO (T013 a T019) antes del código (T020 a T025). T020 antes de T021. T021 antes de T022 y T023, que usan sus tres ayudantes.
- **US2 (T027 a T040)**: después de US1. T029 antes de T031, T033, T035 y T037. T035 y T037 antes de T038.
- **US3 (T041 a T044)**: después de US2, porque restaura lo que respaldan las cinco unidades.
- **US4 (T045 a T055)**: después de US2 (la huella de T048 usa la herramienta) y de T007. T046 antes de T047. T053 después de T031, porque agrega una llamada a `_bc_run_repo`.
- **US5 (T056 a T060)**: después de US2 y de T053, por el clon de trabajo.
- **Polish (T061 a T067)**: después de US5.
- **US6 (T068 a T081)**: T069 antes de T072. T072 antes de T073 y de T074. T074 antes de T075. T076 antes de T077, y T077 a T080 antes de T081.
- **Cierre (T082 a T089)**: después del merge del operador. Un agente a la vez: linus, donna y cbum.

### User Story Dependencies

- **US1 (P1)**: depende solo de Foundational. Es el corte mínimo.
- **US2 (P1)**: depende de US1, porque comparte `heartbeatctl` y el camino `repo`.
- **US3 (P1)**: depende de US1 y de US2. No se puede probar sin algo que restaurar.
- **US4 (P2)**: depende de Foundational y de la herramienta de US2. Su parte del wizard y de la plantilla es independiente de US3.
- **US5 (P2)**: depende de US1, US2 y del clon de trabajo de US4.
- **US6 (P3)**: depende de todas.

### Within Each User Story

- Las pruebas se escriben y se ven en ROJO antes del código que cubren.
- Cada cambio de código tiene un punto de control en los dos bash antes de pasar al siguiente archivo.
- Las suites que ya existían no se editan, salvo los puntos de contacto de T007, T047, T051 y T065.

### Parallel Opportunities

- T003 (línea base) y T004 (Docker), mientras se escriben T005 a T009.
- T008 (el doble de prueba) no toca los archivos de T006 y T007.
- T027 (pruebas del almacén) se puede escribir mientras se termina US1, y a la par de T030: es un archivo nuevo.
- T041 y T056 crean archivos de pruebas nuevos.
- T061, T062 y T063 tocan archivos distintos.

## Parallel Example: User Story 2

```text
T027 tests/backup-store.bats (TS01 a TS09)   |   T030 tests/backup-repo-units.bats (TU04, TU27, TU32 y TU35)
```

Son dos archivos distintos y ninguno depende del otro. Después todo va en serie, porque cada unidad pasa por `docker/scripts/heartbeatctl`, y `bats` se corre una vez por punto de control.

## Implementation Strategy

### MVP primero (US1)

1. Setup y Foundational.
2. US1.
3. **Detenerse y validar**: con US1, un agente sin fork respalda identidad, secretos, vault y `agent.yml`. Es entregable solo, y ya corrige el defecto de M13.

### Entrega incremental

1. Setup y Foundational: la enmienda, las claves, el doble de prueba, y el destino con su credencial.
2. US1: las tres unidades de hoy, en el repositorio del agente, con sus topes, su candado y su plazo.
3. US2: el almacén con su llave de datos, `config` ampliada, `memory`, `history` y las rutas adicionales.
4. US3: la restauración.
5. US4 y US5: el wizard, el contexto del agente, el clon de trabajo y el diagnóstico.
6. Polish: los documentos y el paso del nightly.
7. US6: las mutaciones, el contenedor, la revisión, el gate, linus y el PR.
8. Cierre: el despliegue, un agente a la vez.

### Un PR o dos

El plan dejó abierta esa decisión para cuando existieran las tareas. Los dos cortes que se compararon:

| Corte | Qué lleva | A favor | En contra |
| --- | --- | --- | --- |
| Un solo PR (T001 a T081) | Todo | Un solo gate en linus y una sola reconstrucción de imagen por agente | Un PR grande, de unas 130 pruebas nuevas |
| Dos PR | Primero Foundational y US1, con su propio gate; después el resto | El defecto de M13 se corrige antes, y cada PR se revisa mejor | Dos gates en linus, dos despliegues, y `VERSION` sube dos veces |

**Decisión del operador (13-11-2026)**: un solo PR. La flota no tiene ningún respaldo hoy, y lo que más cuesta es el gate en un agente real. Si más adelante hiciera falta partirlo, el corte va después de T026, con T068 a T081 repetidas para cada mitad.

## Notes

- **Lo que no se hace**: tocar `_run_watchdog`, el compose, el entrypoint, `modules/local-*.tpl` o los tres envoltorios de git que ya existen; cambiar el camino del fork o el de un agente sin destino; agregar el archivo de configuración vivo de Claude o el login de `/login` a una unidad; agregar una unidad al modo local; instalar paquetes en la imagen; admitir un repositorio que no esté en GitHub.
- **El conteo esperado**: la línea base más 132 en el host (124 del host y 8 de extremo a extremo, saltadas), y 62 en el DOCKER_E2E.
- **Si el gate falla**: linus vuelve a `agentic-pod:linus-pre046`. Las ramas `backup/*` que hayan quedado en su repositorio no afectan a las ramas de trabajo, y borrarlas es del operador.
- **Riesgo de la CI**: el brazo macOS ya corre cerca de su tope de 30 minutos (issue #132). T066 mide cuánto suman las suites nuevas.
- **Sin medir todavía**, y a cargo del gate en linus: si `claude -p --continue` retoma un historial restaurado, y cuántos bloques se reutilizan entre dos días.
- **Sin medir, y evitado por construcción**: si GitHub deja como rama por defecto la primera que recibe un repositorio vacío. El repositorio de cbum se crea con un commit inicial en `main`.
- **Sin prueba propia**: el tope largo del `fetch` de `memory` y de `history`. Usa la misma variable que su empuje, que sí la tiene (TU39).

### Registro (se completa durante la implementación)

- **Generación de las tareas (13-11-2026)**: dos sondas de solo lectura en donna, linus y cbum (presencia, tamaños, modos, fechas y claves de `agent.yml`; ningún contenido) y una medición local en un directorio temporal dieron M13 a M18 de `research.md`. Corrigieron el diseño con D19 a D26, ya integradas en `spec.md`, `plan.md`, `data-model.md`, `quickstart.md` y los contratos. El spec pasó de 24 a 26 requisitos funcionales, y las pruebas del host de 86 a 102. Las herramientas están en `<scratchpad>/046/` (`fleet_identity_probe.sh`, `fleet_extra_state_probe.sh` y `m18_sqlite_snapshot_determinism.py`).
- **Análisis y remediación (14-11-2026)**: `/speckit-analyze`, con dos revisiones independientes de solo lectura, dio 44 hallazgos: 2 críticos, 15 altos, 21 medios y 6 bajos. Se remediaron todos en los artefactos, sin tocar código.
  - **Mediciones nuevas**: M19 (`age` pide la passphrase en cada invocación; medido en el Mac con un par de prueba), M20 (la imagen trae `age-keygen`, `flock` y `timeout`; sonda de solo lectura en los tres agentes) y M21 (lecturas de código).
  - **Decisiones del operador**, las cuatro la opción recomendada: una llave de datos por almacén (D27), la configuración cifrada en un agente sensible (D28), la llave fijada con un paso explícito (D29) y SC-002 acotado (D30).
  - **Diseño corregido**: D31 a D36, y el texto de la enmienda de la constitución, que no describía lo que el diseño comparte ni lo que cifra.
  - **Estas tareas**: se rehicieron enteras. Pasaron de 88 a 89, las pruebas del host de 102 a 124, y las mutaciones de 31 a 138, con una variante por fila y al menos una por prueba. Los tres envoltorios de git que ya existen dejaron de cambiar: el camino `repo` tiene los suyos.
  - **Las herramientas** están en `<scratchpad>/046/` (`m19_age_passphrase_prompts.py`, `image_tools_probe.sh` y los `patch_r*.py`), y la copia de los artefactos anteriores en `<scratchpad>/046/before-remediation/`.
- **Verificación de la remediación (14-11-2026)**: dos revisiones independientes, de solo lectura, sobre los artefactos ya remediados.
  - **La primera** recorrió los 44 hallazgos: 36 remediados, 8 parciales y ninguno sin remediar.
  - **La segunda** buscó defectos nuevos, contra los artefactos y contra el código: 2 altos, 8 medios y 7 bajos. Confirmó las anclas de T001 y la factibilidad de T024, T025, T038, T043, T046, T051 y T059.
  - **Medido por las revisiones**: toda operación autenticada de git empieza con una petición sin credencial (git 2.53.0 contra el prototipo del servidor), y en el Mac no hay `timeout` ni `flock`.
  - **Lo que se corrigió**: los modos de un solo uso del servidor de prueba y la forma de detectar la sonda anónima; los dobles de `timeout` y de `flock`; la frase de la enmienda que su propia comprobación prohibía; el supervisor ante un agente sin credencial y ante un estado ilegible; la rotación de la llave de datos probada a través de una unidad (TU40); el vault de un agente sensible con fork; la normalización de las rutas adicionales; qué hash guarda una unidad mixta; la ruta del clon de trabajo en `heartbeatctl`; las llaves por defecto al restaurar; dos pruebas que habrían nacido en verde (TA01 y TR09); y N30, el oráculo del nightly que cambia.
- **T001 (14-11-2026, solo lecturas)**:
  - **El remoto**: el `origin` del worktree es `rodrigo-hinojosa-labs/agentic-pod-launcher` (no `rodrigo-hinojosa/...`). El `fetch` por HTTPS con el ayudante de `gh` dio `main` = `10f22a7`, y `VERSION` 0.31.0: `main` no se movió.
  - **Los PR abiertos**: ninguno.
  - **El estado local**: solo `.specify/feature.json` modificado (de 045 a 046) y `specs/046-agent-backup-repo/` sin rastrear.
  - **Las anclas**: las 50 líneas citadas en T001 coinciden con `10f22a7`.
  - **Las herramientas del host**: git 2.53.0 con `git-http-backend`, age 1.3.1 y `age-keygen`, Python 3.9.6 (el piso del almacén), `ssh-keygen`, bats 1.13.0, bash 5.3.15 y 3.2.57, yq 4.52.5, jq 1.7.1, shellcheck 0.11.0 y perl. No hay `timeout`, `gtimeout` ni `flock`.
  - **Los archivos de ignorar**: `.gitignore` todavía no tiene `/agent-repo/`; no existe `docker/.dockerignore`.
  - **La identidad de los commits**: `Rodrigo Andres Hinojosa Acuña` con el correo de desarrollador de los commits de 045 (`36a9669`), por `GIT_AUTHOR_*` y `GIT_COMMITTER_*`. El `user.email` local del repo es otro y no se usa.
- **T004 (14-11-2026, solo lecturas)**: Docker 29.8.0, aarch64, 12 CPU y 7,75 GiB de memoria; en caché `alpine:3.24.1`, `ubuntu:24.04` y `agent-admin:e2e` (1,85 GB), más otras doce imágenes `agent-admin:*-e2e`; 26 GiB libres en el disco.
- **T003 (14-11-2026, copia aislada de `10f22a7` en `<scratchpad>/046/base`)**:
  - **bash 5.3.15**: `1..1972`, 1972 ok, 0 `not ok`, 61 saltadas, 20 min 39 s, salida de error vacía.
  - **bash 3.2.57**: `1..1972`, 1971 ok, 1 `not ok`, 62 saltadas, 20 min 46 s, salida de error vacía. La que cayó es `verify_channel_healthy: returns 1 without sleeping the full timeout when bun never appears` (`tests/start-services-watchdog.bats:390`), que afirma un tiempo de reloj menor a 3 segundos; corrió mientras esta sesión generaba los archivos dorados en paralelo. Repetida 5 veces sola en bash 3.2, sobre la misma copia: 5 de 5 en verde. Queda anotada como sensible a la carga, sin más; se vuelve a mirar en el gate completo de T074.
  - **Esperado final**: 1972 + 132 = 2104 por bash.
- **T008 (14-11-2026)**: el servidor, el arnés y los dobles de `timeout` y `flock` (probados a mano: el `timeout` corta un hijo que ignora TERM a los 3 s con `-k 1 1` y sale con 124; el `flock` toma, rechaza la segunda toma y suelta). Archivos dorados, generados UNA vez con el código de `10f22a7` (`<scratchpad>/046/gen_goldens.sh`), con su sha256:
  - `agent-fork.yml` `8f8b6a659cfbbecc7265b08e53cb55483c51e12242dbf82c00364a27bf2d9e34`;
  - `crontab-fork.golden` `a3390d9274d784a80b10becff760417fa636619bb779ca350e3ed952eaeb3f40`;
  - `claude-md-backups-section.golden` `6126169c9290a1181564d60dc35415999738ab5ec45b2e2b3eef62fe2ad5818d`;
  - `restore-fork-output.golden` `0159012ff4dcb03548d8d21cf4ae197ff1f9c9607f7a909f111c3d9a5f680677`. Además de `<DEST>`, la ruta del fork se reemplaza por `<FORK>`; TR06 normaliza las dos.
- **T012 (14-11-2026)**: en bash 5.3.15 y 3.2.57, `tests/backup-dest.bats` 18 de 18 y TA04, TA05 y TA17 en verde a la primera tras T007 y T010 (todas en ROJO antes, por la clave ausente o por la librería que no existía); TU31 en verde; `tests/schema.bats`, `tests/regenerate.bats`, `tests/scaffold.bats` y `tests/e2e-smoke.bats` 44 de 44; ningún servidor de prueba vivo al terminar. `shellcheck -S error` y `shellcheck -s sh` en 0.
- **T019 (14-11-2026)**: el ROJO de US1, igual en los dos bash: caen TU01 a TU03, TU06, TU13 a TU15, TU17, TU18, TU22 a TU26, TU29, TU33, TU34 y TU36 a TU38, cada una en su afirmación del mensaje, del código o del estado (ninguna por el arnés); pasan TU05, TU19, TU20 y TU31.
  - **Corrección del arnés antes del verde**: TU20 suponía que el camino del fork termina con un código distinto de 0 al fallar el empuje. En `main` termina con 0: `_bi_run` hace `if ! result=$(...); then return $?; fi`, y ese `$?` es el de la negación. La prueba ahora afirma la línea `push failed` y que el fork no recibe la credencial. Es un defecto del camino del fork que esta feature no cambia (FR-018); queda como hallazgo lateral para T086.
- **T026 (14-11-2026)**: en bash 5.3.15 y 3.2.57, `tests/backup-repo-units.bats` 24 de 24 (TU01 a TU03, TU05, TU06, TU13 a TU15, TU17 a TU20, TU22 a TU26, TU29, TU31, TU33, TU34 y TU36 a TU38); las suites que ya existían (`backup-identity-*`, `backup-vault-*`, `backup-config`, `local-vault-backup`, `restore-from-fork`, `restore-unified`, `heartbeatctl`, `start-services-*` y `backup-trigger-plugin-install`) 210 de 210, con `git diff 10f22a7` vacío sobre ellas; los tres envoltorios de git sin cambios; `bash -n` con los dos bash y `shellcheck -S error` en 0.
  - **Un defecto de la prueba, no del código**: el `_trigger_identity_backup` de reemplazo que define `_tu_check_strict` usaba `$2` dentro de la función, que bajo `set -u` no existe. Se corrigió en la prueba.
- **US2 (14-11-2026)**:
  - **El ROJO**: TS01 a TS22 cayeron todas porque la herramienta no existía, y pasaron a la primera al copiarla (22 de 22). TU04, TU07 a TU12, TU16, TU21, TU27, TU28, TU30, TU32, TU35, TU39 y TU40 cayeron en su afirmación (el árbol de `config`, el comando desconocido, la línea de cron o el mensaje), y TU03 y TU33 en su pierna nueva. TU21 ya mostraba en ROJO que el crontab sin destino y con fork es idéntico a los dorados.
  - **T039 (SC-007)**, con `specs/046-agent-backup-repo/tools/sc007_sim.py` en el Mac (Python 3.9.6, age 1.3.1, git 2.53.0): datos de 72,1 MB de `.jsonl`, 31,5 MB en 86 archivos y una base de 14,5 MB. El repositorio pesó 15,4 MB tras el ciclo 1 y 102,5 MB tras el ciclo 30 (`du -sk` después de `git gc`): bajo 1 GB. El primer ciclo tardó 11,5 s; los siguientes, unos 2 s, con 17 a 20 bloques nuevos cada uno (18,6 en promedio), casi todos de la base. **Advertencia**: el texto sintético se comprime mucho mejor que un historial real; aun sin compresión (115 MB más 30 ciclos de unos 19 MB) quedaría cerca de 690 MB, bajo el tope.
  - **T040**: en bash 5.3.15 y 3.2.57, `tests/backup-store.bats` 22 de 22 y `tests/backup-repo-units.bats` 40 de 40, y las suites de respaldo que ya existían en verde y sin editar (267 de 267 en total); `python3 -m py_compile` en 0.
- **US3 (14-11-2026)**:
  - **El ROJO**: TR01 a TR05 y TR07 a TR14 cayeron en su afirmación; TR06 nació en verde. Dos defectos del arnés se corrigieron antes del código: `setup.sh` pone `RESTORE_IDENTITY_KEY` en vacío al cargarse (`:403`), así que la prueba la fija después del `source`; y el ayudante que falsifica un bloque armaba mal su ruta.
  - **Un defecto del código, visto en verde a medias (13 de 14)**: `dirname` del Mac trata como opción una ruta que empieza con `-` (`-workspace/...`). Todo `mkdir -p` nuevo pasa a `mkdir -p "$(dirname "$dest/$rel")"`, con la ruta absoluta.
  - **T044**: en bash 5.3.15 y 3.2.57, `tests/backup-repo-restore.bats` 14 de 14, y `tests/restore-from-fork.bats` y `tests/restore-unified.bats` en verde y sin editar (19 de 19); `bash -n setup.sh` con los dos bash y `shellcheck -S error` en 0.
- **US4 (14-11-2026)**:
  - **El ROJO**: TA01 a TA03, TA07, TA08, TA09, TA10 a TA13, TA15, TA16, TA18, TA19 y TA20 cayeron en su afirmación (el encabezado del paso, el mensaje, la clave, la librería que no existía); TA06 y TA14 nacieron en verde, como estaba previsto.
  - **Una desviación del texto de TA01**: sin terminal, `read -p` no imprime su pregunta, así que la prueba reconoce el paso por su encabezado (`▸ Agent repository (private backup + the agent's own work)`), que el wizard escribe con `echo`.
  - **Un falso positivo del arnés, no del código**: TA14 encontraba `agent-repo` en el `NEXT_STEPS.md` de un agente local llamado `repo-bot`, porque sus unidades se llaman `agent-repo-bot-...`. La prueba usa otro nombre para el agente local.
  - **T047**: `wizard_answers()` gana `repo=`, `sensitive=` y `repo_pat=`, con el marcador `# Agent repository (docker only)`; `tests/e2e-smoke.bats` gana la respuesta; los dos quickstart pasan de 52 a 56 preguntas (tres después de la 19 y la del token después de la del PAT del MCP), con sus referencias internas renumeradas, las variables `AGENT_REPO_*` y la fila de `validate_backup_repo_url`; el comando `/quickstart` y `tests/quickstart-doc.bats` también. 243 de 243 en las suites del wizard en bash 5.x.
  - **T055**: en bash 5.3.15 y 3.2.57, 351 de 351: `tests/agent-repo-surface.bats` 20 de 20, las suites de T047 y las del render, `uninstall`, `nuke-and-hints`, y de nuevo `backup-repo-units`, `backup-repo-restore`, `start-services-*`, `backup-config` y `heartbeatctl` (el oráculo de sha de `_run_watchdog` en verde).
- **US5 (14-11-2026)**:
  - **El ROJO**: TB01 a TB07, TB09 y TB10 cayeron (el comando no existía); TB08 nació en verde.
  - **Un defecto del código, visto en TB07**: con `IFS=$'\t'`, un `last_push` vacío colapsaba con el campo siguiente, porque un tab es un separador de espacio para `read`; `backup-status` y el diagnóstico pasan a separar con `|`.
  - **T060**: en bash 5.3.15 y 3.2.57, las seis suites nuevas 124 de 124, y `tests/agentctl*.bats` en verde y sin editar (268 de 268 en total).
- **Polish (14-11-2026)**:
  - **T061 y T062**: los escribió un subagente de documentación, con el código como fuente. La revisión de esta sesión cruzó con el código las 75 cadenas citadas que agregó y las cifras del README (el tope de 800 MB del diagnóstico, la nueva consulta anónima a lo más una vez al día, los textos del wizard, la salida de `--configure-key`, las reglas de cron y de `backup.extra_paths`): ninguna inventada.
  - **Cinco hallazgos de esa escritura, corregidos en el código**:
    - `backup-history` saltaba cualquier directorio `memory` a cualquier profundidad, y no solo `<proyecto>/memory/`, que es de la unidad de memoria. TU11 ganó una pierna con un `memory/` anidado, se vio en ROJO y pasó a verde con el arreglo.
    - La ayuda de `backup-identity` prometía el login y solo nombraba el fork.
    - La ayuda de `backup-config` no decía lo que la unidad lleva con un repositorio.
    - El aviso de la llave del diagnóstico no decía que identity sigue corriendo sin los secretos.
    - El `trap` de la restauración borraba el temporal pero no terminaba el proceso ante INT o TERM. Ahora sale con 130 o 143.
  - **Un comentario corregido**: el de `restore_from_fork` en `setup.sh` también prometía el login.
  - **Después de los arreglos**: en bash 5.3.15 y 3.2.57, 118 de 118 en `backup-repo-units`, `backup-status`, `backup-repo-restore`, `backup-config`, `restore-from-fork` y `heartbeatctl`, con la salida de error vacía.
  - **T064**: el bloque de 046, la sección "Backup model" con cinco ramas y los seis gotchas pedidos están en `CLAUDE.md`. Se commitea con `git add -f CLAUDE.md`. La auditoría de bytes de las líneas agregadas (`<scratchpad>/046/audit_added.py`) da 0 problemas en los documentos, el código, las pruebas, los specs y el workflow: ninguna marca combinante, ningún carácter de control y ningún emoji. Los archivos nuevos se auditaron enteros. Los únicos símbolos son `▸`, `✓`, `✗` y `⚠`, que reproducen la salida del propio programa.
  - **T065**: el paso `install_age`; N30 con la lista nueva de pasos. `tests/nightly-alert.bats`, `tests/ci-workflows.bats` y `tests/qmd-embed-nightly.bats` dan 97 de 97 en los dos bash.
  - **T066**:
    - El `shellcheck` exacto del job de la CI da 0, y `shellcheck -s sh` sobre los dos scripts de credenciales también.
    - `python3 -m py_compile` sobre los tres archivos da 0, sin dejar `__pycache__`.
    - Los dos scripts de credenciales tienen modo 755 en el disco; `git ls-files -s` se mira en T075, cuando estén agregados.
    - El Python del Mac es 3.9.6.
    - **La duración de las seis suites nuevas es de 367 s en bash 5.3.15 y 361 s en 3.2.57**, sobre el objetivo de 180 s. `backup-repo-units` toma 174 a 176 s, `backup-repo-restore` 92 a 94 s y `agent-repo-surface` 68 a 69 s.
    - En la CI, el brazo macOS de `main` ya se canceló a los 30 min en 2 de las 3 últimas corridas (el 10 y el 12-11-2026) y tardó 25 min 42 s en la que pasó. **Decisión del operador (14-11-2026)**: un PR aparte, antes de T081, que sube `timeout-minutes` de `.github/workflows/test.yml` de 30 a 45 y cierra #132.
  - **T067**:
    - `git status --short` muestra solo archivos del árbol de `plan.md` y los puntos de contacto de T007, T047, T051 y T065.
    - `git diff origin/main` sobre `tests/backup-identity-*.bats`, `tests/backup-vault-*.bats`, `tests/backup-config.bats`, `tests/restore-*.bats` y `tests/local-vault-backup.bats` está vacío, y sobre `modules/docker-compose.yml.tpl` y `docker/entrypoint.sh` también.
    - El render de `sample-agent.yml` de `10f22a7`, en modo docker sin repositorio y en modo local, no tiene diferencias en ningún archivo derivado entre la rama y la copia de T003: `CLAUDE.md`, `.mcp.json`, `docker-compose.yml` o `NEXT_STEPS.md`, `heartbeat.conf` y los 16 archivos de `scripts/local/`.
    - El crontab de `heartbeatctl reload` es idéntico sin destino y con fork.
    - Las dos copias se renderizan en la misma ruta, porque el `CLAUDE.md` de modo local lleva la ruta absoluta del vault. La herramienta es `<scratchpad>/046/t067_render_diff.sh`.
- **T073, revisión independiente (15-11-2026)**: agente `code-reviewer`, de solo lectura, sin bats ni docker. Dio 2 hallazgos ALTOS, 3 MEDIOS y 11 BAJOS. El catálogo de mutaciones se pausó tras su control para no correr sobre un árbol a medio cambiar.
  - **ALTA 1, verificada**: el clon de trabajo pasaba `GITHUB_PAT="$GITHUB_PAT"` en los argumentos de `env`, dentro de `timeout`, así que el token quedaba en `/proc/<pid>/cmdline` mientras duraban el `ls-remote` y el `fetch`. Ninguna prueba lo veía. Se quitó, porque la variable ya se hereda. Un espía de argumentos (`br_argv_spy`, un `timeout` delante del PATH) lo afirma en TA12 para el clon y en TU01 para las unidades.
  - **ALTA 2, verificada leyendo el código**: la restauración movía al destino cualquier ruta del manifiesto, `.git/` incluido, y lo hacía después del `git init` y antes del primer commit del scaffold. Un manifiesto con `extra/.git/hooks/pre-commit` habría corrido como el operador; uno con `scripts/lib/render.sh`, en el `--regenerate` siguiente. Cualquiera que escriba el repositorio, el agente incluido, puede armarlo: `age` no autentica y `store/recipient` es público. Se corrigió con la regla R9 de `contracts/restore.md`:
    - `unpack` rechaza un segmento `.git` en cualquier caja;
    - `_restore_move_tree` no escribe a través de un enlace y nunca copia uno;
    - `config` restaura solo su lista cerrada, en claro o del almacén;
    - el vault restaura solo markdown, y un `vault.path` con `..` o `.git` cae a `.state/.vault` con su línea;
    - las rutas adicionales vuelven solo bajo una entrada declarada que el launcher no reserve. `memory_extra_path_reserved` es la única fuente, para el respaldo y la restauración.
  - **MEDIA 1**: un vault cifrado que no se abrió salía igual como `✓ restore: vault restored`. Ahora la línea sale solo cuando algo se restauró.
  - **MEDIA 2**: lo descifrado entraba en claro en el primer commit del workspace. Las rutas adicionales restauradas fuera de `.state/` pasan a `.git/info/exclude`.
  - **MEDIA 3**: una ruta adicional `.state/.claude` llevaba el archivo del login de `/login`. Ese archivo ya no viaja ni se restaura.
  - **BAJAS corregidas**:
    - el código 5 (integridad) para toda falla posterior a abrir `key.age`; antes una restauración probaba otras llaves y terminaba en "no usable key";
    - `git gc` de `--gc` bajo el candado de la unidad;
    - el stderr de la herramienta del almacén llega al log de la unidad;
    - un `--dry-run` no registra nada;
    - el clon reinicia los ayudantes de credenciales heredados: con un `credential.helper=store` global, el push del agente guardaba el token en claro;
    - la URI de SQLite escapa la ruta;
    - las pruebas e2e reponen el estado en `teardown`.
  - **BAJA que resultó peor de lo descrito**: con `?` en la ruta, SQLite abría otro archivo y copiaba una base vacía que pasaba su verificación. TS14 la primera vez nació en verde porque solo miraba el código de salida; se endureció para mirar el contenido, se vio en ROJO y pasó a verde con el arreglo.
  - **Decisiones del operador (15-11-2026)**, las tres la opción recomendada:
    - nombres de bloque que no delaten el contenido (D37 de `research.md`): el nombre es el SHA-256 del archivo cifrado y la deduplicación usa un mapa local (`--block-map`). Un HMAC con la llave de datos no es posible tal cual, porque `pack` nunca tiene su parte privada (S1); esta forma cumple lo pedido sin un secreto nuevo;
    - con repositorio, el supervisor respeta `features.identity_backup.enabled: false`; el fork, como en `main`;
    - procesar archivo por archivo queda para un issue (T086), fuera de 046.
  - **El ROJO**: TS04, TS08, TS11, TS12, TS14, TU13, TU25, TU37, TU10, TU28, TA12, TR08, TR11, TR12 y TR13 cayeron en su afirmación nueva contra el código anterior; TU01 nació en verde (es la guardia de las unidades, que ya no pasaban el token), y la pierna del ayudante heredado de TA12 se vio en ROJO aparte, con un mutante. Las piernas del almacén se corrieron desde una copia de la suite sin `--block-map`, para que cada una cayera por su propia afirmación.
  - **Filas nuevas del catálogo**: M139 a M167, una por cada guardia nueva. Para que ninguna fuera redundante se agregaron tres piernas: un bloque cifrado de nuevo con el mismo contenido (TS11), un `vault.path` bajo `.git` (TR08) y un enlace que ya estaba en el destino (TR11).
  - **Sin cambio**: el número de pruebas (124 del host). Todas las piernas nuevas viven en pruebas que ya existían.
  - **Residuo declarado**: el contenido de la lista cerrada sigue confiando en el repositorio. Un `docker-compose.override.yml` o un hook de `.claude/` hacen lo que dicen dentro del contenedor. La restauración avisa del override; los hooks del proyecto corren en el contenedor y no en el equipo.
  - **Checkpoint posterior (15-11-2026)**: las seis suites nuevas y las 21 de respaldo, restauración y supervisor que ya existían, 334 pruebas. En bash 5.3.15 dio 332 de 334, con la salida de error vacía. Cayeron TU33 (sin caché no hay mapa de bloques, y el ciclo sube todo una vez) y TU40 (tras una rotación los nombres cambian, así que `diff --name-only` cuenta altas y bajas). Las dos se adaptaron al costo de D37, que el operador aceptó el mismo día. La pasada de bash 3.2 se detuvo a propósito en la prueba 92 de 334, para dejar la máquina libre al traspaso. Hasta ahí solo habían caído TU33 y TU40 (con su texto anterior), y TU16 pasó. Se repite entera (sección 5 de `handoff-codex.md`).
  - **Traspaso a Codex (15-11-2026)**: decisión del operador. Las herramientas pasaron del scratchpad a `specs/046-agent-backup-repo/tools/`, con las rutas parametrizadas (`BR046_REPO`, `BR046_WORK`). La guía para retomar es `specs/046-agent-backup-repo/handoff-codex.md`. Un commit local `wip:` (sin push) queda como punto de restauración; T075 lo rehace en los tres commits atómicos.
- **Rebase a `9608e4a` (15-11-2026, sección 5, paso 1 del traspaso)**: autorizado por el operador, tras leer completos el traspaso y el índice de memoria del proyecto. El worktree estaba limpio en `8463586`, con base `10f22a7`. `git rebase origin/main` terminó con código 0 y sin conflictos; Git integró automáticamente `CHANGELOG.md`, conservando las entradas de 046 en `Added` y `Fixed` y la del tope de CI de 45 min en `Changed`.
  - **Commits reescritos**: `3358cc3` pasa a `0f41236` y `8463586` a `3f11357`. `git range-diff 10f22a7..8463586 9608e4a..HEAD` marca los dos parches como equivalentes (`=`).
  - **Verificación**: `git diff 8463586 HEAD` solo incorpora los cambios de `9608e4a` en `.github/workflows/test.yml` y `CHANGELOG.md`; el resto del árbol del commit de restauración permanece idéntico. `VERSION` de `origin/main` = 0.31.0 y de la rama = 0.32.0. El worktree quedó limpio al terminar el rebase, antes de registrar este paso.
  - **Continuidad**: las referencias operativas del traspaso a T075 usan ahora `git reset --soft 0f41236`; esa compuerta no se ejecutó. Este registro y la actualización del traspaso quedan sin commit. El siguiente paso es el checkpoint de T073; no se corrieron pruebas en este paso de rebase.
- **Checkpoint `t073b` posterior al traspaso (15-11-2026, 22:02:08 a 22:19:42, Santiago)**: pedido explícito del operador, sección 5, paso 2 de `handoff-codex.md`, sobre `3f11357`, sin modificar código ni correr dos bats a la vez.
  - **Comando**: `/bin/bash specs/046-agent-backup-repo/tools/run_checkpoint.sh t073b` con las 27 suites de la sección 6 del traspaso (el glob `tests/start-services-*.bats` expandido en orden). `BR046_REPO` apunta a este worktree; `BR046_WORK` = `/Users/rodrigo-hinojosa/.cache/agentic-046/validation-20261115T220208`. La lista exacta de argumentos está en `checkpoint-start.json` de ese directorio.
  - **bash 5.3.15, bats 1.13.0**: `1..334`, 334 ok, 0 `not ok`, 0 saltadas, rc 0, 515 s (8 min 35 s), stderr de 0 bytes.
  - **bash 3.2.57, bats 1.13.0**: `1..334`, 334 ok, 0 `not ok`, 0 saltadas, rc 0, 539 s (8 min 59 s), stderr de 0 bytes. Esta pasada empezó después de terminar la de bash 5.
  - **TU16, TU33 y TU40**: las tres pasan en los dos bash (líneas TAP 70, 64 y 79, respectivamente). Queda confirmada en este checkpoint la adaptación de TU33 y TU40 a D37.
  - **Evidencia**: `checkpoints/t073b-bash{5,32}.{tap,err,sum}`, `checkpoint-runner-exit.json` y `checkpoint-verified.json` dentro de `BR046_WORK`. Se verificaron los conteos, la ausencia de saltadas y el tamaño de stderr; el `done` del corredor por sí solo no fue el criterio.
- **TU16 sola, cinco corridas seguidas en bash 3.2.57 (15-11-2026, desde las 22:20:10, Santiago)**:
  - **Comando**: `PATH=/bin:/opt/homebrew/bin:$PATH bats tests/backup-repo-units.bats -f TU16`, siempre una corrida a la vez.
  - **Resultado solicitado: 4 de 5**, no 5 de 5. La primera dio rc 1 en 0,962 s; las otras cuatro, rc 0 en 2,753 s, 3,304 s, 2,737 s y 2,733 s. Las cinco tuvieron stderr de 0 bytes y ninguna saltada.
  - **Hallazgo presentado al operador antes de tocar código**: la primera falla en `tests/backup-repo-units.bats:796`, en `[ "$output" = "$(_tu_msg "$u" no-recipient)" ]`. El TAP original no imprime el valor capturado ni identifica cuál unidad del bucle lo produjo. No se infiere la causa ni se clasifica como un problema de carga.
  - **Diagnóstico sin cambios**: se leyó el bucle de TU16, `_tu_msg`, `br_unit`/`br_ctl` y la ruta `no-recipient` de `heartbeatctl`. Luego se corrió la misma prueba en secuencia con `--print-output-on-failure --no-tempdir-cleanup`, con un límite de 20 intentos y parada ante la primera falla: 20 de 20 en verde, 54,157 s en total. La falla no se reprodujo y la causa sigue sin determinarse; esas corridas adicionales no sustituyen el 4 de 5 original. Los temporales de diagnóstico se conservaron mediante la opción de bats, sin leer sus archivos de credenciales.
  - **Evidencia**: `tu16-bash32-results.json`, `tu16-bash32-{1,2,3,4,5}.{tap,err}` y `tu16-diagnostic-results.json` con los 20 pares `tu16-diagnostic-N.{tap,err}`, dentro del mismo `BR046_WORK`. El criterio de cinco corridas consecutivas en verde sigue pendiente. No se modificó código ni se hizo commit.
- **SC-007 repetido después de D37 (15-11-2026, 22:23:16 a 22:24:38, Santiago; sección 5, paso 3 del traspaso)**:
  - **Comando**: `python3 specs/046-agent-backup-repo/tools/sc007_sim.py`, sin opciones (30 ciclos), con Python 3.9.6, age 1.3.1 y git 2.53.0. Usa el mapa local de bloques y la herramienta real `docker/scripts/backup_store.py`; los repositorios y commits de la simulación son temporales y locales. No se hizo commit en la rama de 046 ni se usó la red.
  - **Datos sintéticos iniciales**: 72.072.288 bytes de historial, 31.507.042 bytes en 86 archivos y una base de 14.532.608 bytes. Se mantuvieron la semilla y los cambios del simulador de T039.
  - **Resultado**: rc 0, 30 ciclos completos, 81,750 s totales. Tras `git gc`, 15.808 KiB (15,4 MiB) en el ciclo 1 y 104.224 KiB (101,8 MiB; 106.725.376 bytes) en el ciclo 30. El campo `repo_mb_*` del simulador divide los KiB de `du -sk` por 1024: su escala es MiB. `under_1_gb=true`; también queda bajo 1.000.000.000 bytes.
  - **Comparación con T039**: 15,4 frente a 15,4 en el ciclo 1; 101,8 frente a 102,5 en el ciclo 30, una diferencia de -0,7 en la misma escala del simulador. El primer ciclo tomó 9,9 s frente a 11,5 s (-1,6 s). Los ciclos 2 a 30 agregaron entre 17 y 20 bloques, 18,621 de promedio (T039: 17 a 20, promedio 18,6). No se atribuye la pequeña diferencia de tamaño final a una causa sin medirla.
  - **Alcance de la evidencia**: SC-007 cumple con este corpus sintético. Se mantiene la limitación de T039: ese texto se comprime mejor que un historial real; esta corrida no mide un respaldo vivo de donna.
  - **Evidencia**: `sc007-start.json`, `sc007-report.json`, `sc007-progress.err`, `sc007-exit.json` y `sc007-verified.json` en `/Users/rodrigo-hinojosa/.cache/agentic-046/validation-20261115T220208`. El archivo de stderr contiene las 30 líneas de progreso que el simulador emite por diseño. La simulación se ejecutó después de terminar todas las corridas de bats.
  - **Estado al cerrar estos pasos**: checkpoint de 334 pruebas por bash conforme; SC-007 conforme; las cinco repeticiones solicitadas de TU16 dieron 4 de 5 y su causa sigue pendiente de diagnóstico. No se modificó código ni se hizo commit. Antes de cualquier arreglo de TU16, presentar el hallazgo y verlo en ROJO por su propia afirmación.
- **Diagnóstico instrumentado de TU16, invocación acotada de `speckit-implement` (15-11-2026, 23:41:25 a 23:46:47, Santiago)**:
  - **Alcance autorizado**: una copia temporal de TU16, hasta 100 intentos secuenciales en bash 3.2, parada ante la primera falla, diagnóstico antes de corregir y ningún commit. No se avanzó a T068 ni se aplicó un arreglo.
  - **Prerrequisitos**: `check-prerequisites.sh --json --require-tasks --include-tasks` resolvió este directorio de feature; `requirements.md` tiene 16 de 16 marcadas. `.specify/extensions.yml` se validó con `yq`: `hooks: {}`, sin hooks anteriores ni posteriores que ejecutar.
  - **Copia temporal**: `/Users/rodrigo-hinojosa/.cache/agentic-046/tu16-instrumented-20261115T234023-o9vlnry4/backup-repo-units.tu16-diagnostic.bats`. Carga los dos helpers originales mediante rutas absolutas y usa el runtime original del worktree. Conserva las expresiones de todas las aserciones de TU16; solo agrega, en el camino de falla, una llamada de diagnóstico seguida de `return 1`.
  - **Campos del diagnóstico**: `unit`, `check`, `status`, `expected`, `received` y `last_result`, en una línea JSON `TU16_DIAG`. Lee únicamente el campo `last_result` del estado de prueba y redacta el centinela de credencial del arnés si aparece en los mensajes. No lee archivos de credenciales. Se probó el formateador con datos sintéticos en `/bin/bash`; ese control no es una falla real de TU16.
  - **Control de alcance de la copia**: la transformación se revirtió en memoria para comprobar que devuelve exactamente el texto del test original; `bats --count ... -f TU16` seleccionó una sola prueba. El original tiene SHA-256 `5cafc298557c6ff29d108097093182a43c4ff331001028d9db84335f3c712fd4`; la copia, `147356835646ce1889dc007aa995ea946421af468d9810ec299fa5638f512b71`.
  - **Comando por intento**: `PATH=/bin:/opt/homebrew/bin:$PATH bats --print-output-on-failure --no-tempdir-cleanup <copia-temporal> -f TU16`. Se verificó que `bash` resuelve a 3.2.57; el corredor espera el término de cada proceso antes de iniciar el siguiente y se detiene ante rc distinto de 0, `not ok`, una saltada o un resultado distinto de una prueba ejecutada.
  - **Resultado**: 100 de 100 en verde, rc 0 en cada intento, 0 saltadas, 0 registros de diagnóstico y 321,310 s totales (5 min 21,310 s). Duración por intento: mínimo 2,681 s, mediana 2,9665 s y máximo 10,585 s. La serie terminó por alcanzar el límite de 100, sin una primera falla que activara la parada.
  - **Stderr**: 82 bytes por intento, exclusivamente la línea `BATS_RUN_TMPDIR: <ruta>` que emite `--no-tempdir-cleanup`. Se verificaron las 100 salidas; no es stderr vacío ni una salida de error del producto. Los temporales del arnés quedan conservados sin inspeccionar sus archivos de credenciales.
  - **Hallazgo y límite de la evidencia, presentados antes de cualquier corrección**: no se reprodujo la comparación fallida de la corrida original de 4 de 5. Por eso no se obtuvo una unidad afectada ni un mensaje recibido inesperado de una falla real, y su causa sigue sin determinarse. Los 100 resultados de esta copia instrumentada no reescriben el 4 de 5 original ni demuestran que el defecto esté corregido.
  - **Verificación final**: SHA-256 idéntico antes y después en los 10 archivos originales controlados (test, helpers, `heartbeatctl` y librerías de respaldo); `HEAD` sigue en `3f11357`; no quedan procesos de bats ni del servidor git de prueba. No se modificó código del repositorio ni se hizo commit.
  - **Evidencia**: `manifest.json`, la copia `.bats`, `tu16-diagnostic-function.sh`, `formatter-control.json`, los 100 pares `attempt-NNN.{tap,err}`, `results.json` y `verified.json` en el directorio temporal indicado. La instrumentación queda disponible para la próxima reproducción; esta invocación concluye solo el diagnóstico acotado solicitado, con la causa original todavía abierta.
- **Retoma del cierre local (15/16-11-2026, T068 en curso)**: el operador pidió terminar la feature. Se retoma el bloque local T068 a T074; continúan las compuertas de commit, push, linus y PR. TU16 permanece como falla no reproducida, sin declararla corregida: su captura solo al fallar se incorporó al test original, conservando sus aserciones, para que una reaparición en los controles o gates entregue el contexto y detenga la validación.
  - **T068, anclas y catálogo**: el chequeo original falló; una inspección completa encontró 12 anclas obsoletas (M53, M54, M56, M59, M60, M68, M71, M87, M88, M101, M104 y M105) y las 29 filas ausentes M139 a M167. Un explorador de solo lectura mapeó las guardias actuales; no ejecutó bats ni Docker. Se actualizaron las anclas conservando el defecto descrito por cada fila y se agregaron M139 a M167. `python3 -B specs/046-agent-backup-repo/tools/mutate.py --check` dio `anclas ok: 167 filas`.
  - **Cuatro defectos del corredor demostrados en ROJO antes del arreglo**: un control con una prueba fallida devolvía 0; un control con saltadas devolvía 0; M0 podía marcarse correcto con resultados incompletos; y un timeout podía contarse como mutación cazada. `tools/test_mutate.py` contiene siete pruebas sin bats ni Docker: las cuatro anteriores fallaron por sus propias aserciones contra el corredor anterior, y tres controles positivos pasaron. Tras el arreglo, siete de siete en verde.
  - **Corredor corregido**: valida plan TAP, conjunto y cantidad de pruebas, ausencia de duplicadas/saltadas, código de salida y término sin timeout; un control defectuoso devuelve 1; una fila incompleta o sobreviviente detiene la secuencia. La copia usa archivos rastreados o no ignorados de git y omite rutas de estado y archivos sensibles; no copia indiscriminadamente el directorio del operador. El TAP activo queda disponible durante cada corrida para seguir su avance.
  - **Evidencia de preparación**: `/Users/rodrigo-hinojosa/.cache/agentic-046/closure-20261115T235851-obh9ouin/{manifest.json,runner-red.log,runner-green.log}`. Se creó una copia base propia y separada, con `git worktree add --detach <ese-directorio>/base 10f22a7`; no se tocó la copia antigua del traspaso.
  - **Control real iniciado**: `BR046_WORK=<ese-directorio> BR046_REPO=<worktree-046> python3 -u specs/046-agent-backup-repo/tools/mutate.py --control`, con las seis suites nuevas y ambos bash en secuencia. El catálogo completo no arranca hasta que este control confirme 124 de 124 sin saltadas en cada bash. Una revisión independiente está examinando los cambios del corredor y el diagnóstico de TU16 en solo lectura, sin ejecutar pruebas durante el control.
- **T068 cerrada (16-11-2026)**:
  - **Control real**: 124 de 124 en bash 5.3.15 (395 s) y 124 de 124 en bash 3.2.57 (501 s), en secuencia, con rc 0, sin saltadas, sin resultados faltantes y sin timeout. TU16 pasó en ambos. `mutations/CTRL.json` confirma `valid: true`; los TAP completos están en `CTRL.bash5.tap` y `CTRL.bash32.tap`.
  - **Correspondencia**: las 167 filas M1 a M167 tienen exactamente los identificadores y pruebas objetivo de la tabla de T069, y todas sus anclas se verificaron contra el código actual. La base M0 sigue en `10f22a7`, como en el traspaso; el rebase a `9608e4a` solo agregó cambios de CI y CHANGELOG.
  - **Revisión independiente del corredor**: sin hallazgos críticos; dos problemas adicionales confirmados. La superposición de `tests/` de M0 usaba un `rsync` que omitía las exclusiones, y `--only` aceptaba identificadores desconocidos omitiéndolos en silencio. Tres pruebas nuevas reprodujeron esos problemas en ROJO por sus propias aserciones. M0 reutiliza ahora el mismo inventario seguro y toda selección desconocida devuelve 2 antes de ejecutar filas. El chequeo total del corredor pasó de siete a diez pruebas, todas en verde.
  - **Evidencia de la revisión**: `runner-review-red.log` y `runner-final-green.log` en el directorio de cierre. `control-code-hashes.json` confirma que la copia del control y el árbol actual coinciden en los 19 archivos de runtime y pruebas controlados; las correcciones posteriores solo afectan el corredor y sus pruebas auxiliares. `runner-final-hashes.json` identifica el corredor final y la captura de TU16 que usará el catálogo.
  - **T069 iniciada**: `BR046_WORK=<directorio-de-cierre> BR046_REPO=<worktree-046> python3 -u specs/046-agent-backup-repo/tools/mutate.py --only M0`. No se ha declarado terminado el catálogo. Una fila incompleta o sobreviviente detiene la secuencia y requiere diagnóstico; no se cuenta un timeout como prueba de que una mutación fue detectada.
- **T069, control M0 (16-11-2026)**: veredicto `ok` en el código de `10f22a7` con las pruebas finales. En bash 5.3.15 y en 3.2.57 dieron exactamente 116 `not ok` y las ocho previstas en verde: TA06, TA14, TB08, TR06, TU05, TU19, TU20 y TU31. Duración 79 s por bash; plan de 124 completo, rc 1 esperado por las pruebas en rojo, sin saltadas, sin timeout y sin errores de integridad del TAP. Evidencia: `mutations/M0.json` y `M0.bash{5,32}.tap` en el directorio de cierre. Después arrancó `mutate.py --no-m0` para M1 a M167, secuencialmente y con parada ante la primera fila que requiera revisión.
- **T069, primera brecha del oráculo (16-11-2026, M15)**: el corredor se detuvo correctamente: TD16 detectó la mutación en ambos bash, pero TU22 no. La mutación evita volver a sondear de forma anónima tras `unreachable`; TU22 comprobaba la recuperación con credenciales y el veredicto `private`, pero no la renovación del sondeo. El hallazgo se presentó antes de editar. Se agregó a TU22 un reloj fijo antes y después de recuperar la conexión y la comparación exacta de `anon_checked_epoch` con el segundo instante, sin cambiar producto ni número de pruebas.
  - **ROJO**: la nueva afirmación de TU22 cayó contra M15 en ambos bash; ahora TD16 y TU22 detectan M15, con plan completo y sin timeout (10 s y 12 s). La evidencia anterior del sobreviviente se conservó en `mutations/revisions/M15-before-TU22/`.
  - **VERDE**: TU22 sin mutar pasó en bash 5.3.15 y 3.2.57, rc 0, stderr vacío, en 6,157 s y 6,251 s. Evidencia: `TU22-positive.json`, sus TAP y stderr, y `mutations/M15.json` dentro del directorio de cierre. La secuencia se retomó desde M16; M1 a M14 y M16 a M19 están detectadas en ambos bash.
  - **Cobertura del catálogo**: la unión de las pruebas objetivo de M1 a M167 coincide exactamente con las 124 pruebas de las seis suites; sin identificadores ausentes ni desconocidos (`catalog-coverage.json`). Esto verifica la tabla; la ejecución del catálogo sigue en curso.
- **Preparación de T070, sin correr otra suite (16-11-2026)**: durante la espera intencional de M20 se construyeron dos imágenes de dependencias aisladas, `agent-admin:br046-linux-ubuntu-obh9ouin` y `agent-admin:br046-linux-alpine-obh9ouin`. Ambas usan bats 1.11.0 (fuente oficial, commit `5da66876b8b619235aee1eb3e54954eaca88059b`) y yq 4.44.3 para Linux arm64, verificado contra el SHA-256 publicado `0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156`. Se revisó el instalador antes de ejecutarlo; las imágenes corren como `agent`, con temporales bajo `/work/tmp`. No contienen una copia del repositorio ni ejecutaron bats. Construcciones rc 0 en 40,719 s y 2,532 s; detalle en `linux-dependencies.json`, `linux-builds.json` y los logs de construcción del directorio de cierre.
- **Preparación de los modelos de T072 (16-11-2026)**: durante la espera de M34 se ejecutó `.github/scripts/fetch-qmd-models.sh` con un directorio nuevo bajo el directorio de cierre. Verificó los dos tamaños y SHA-256 de su tabla: 333.590.944 bytes y 1.282.438.912 bytes, 1.616.029.856 en total, un intento por archivo y 121 s. El propósito es correr `qmd real (041)` con `QMD_EMBED_E2E=1` en la regresión completa. No se inició el DOCKER_E2E; los datos y el log están en `qmd-models/`, `qmd-models.env` y `qmd-fetch.log` del directorio de cierre.
- **T066/T067 repetidas durante la espera de M34 (16-11-2026)**: sin otra corrida de bats. `shellcheck` con el texto exacto del workflow dio rc 0 en 14,896 s y el POSIX de los dos ayudantes, rc 0 en 0,025 s. Los tres Python de T066 compilaron con Python 3.9.6, dejando los bytecodes en el directorio de evidencia. `git ls-files -s` confirma 100755 en ambos ayudantes. `t067_render_diff.sh` dio rc 0 en 28,556 s: derivados docker/local, `heartbeat.conf`, `scripts/local/` y los dos crontabs idénticos; los cuatro regenerados dieron rc 0. La auditoría de líneas agregadas y la del archivo auxiliar nuevo dio 0 hallazgos. El diff protegido por T067 (suites anteriores, compose y entrypoint) sigue vacío. Evidencia: `static-gate.json`, `shellcheck-*`, `render-diff.*`, `byte-audit-*` en el directorio de cierre. El gate completo de T074 todavía no se ejecutó; si cambia el código se repite lo afectado.
- **T069, segunda brecha del oráculo (16-11-2026, M60)**: TS12 detectaba la falta de las guardias de `..`, pero TR12 pasaba. Se diagnosticó y presentó antes de editar: el manifiesto hostil de TR12 convertía varias entradas a la misma ruta, por lo que la validación de duplicados rechazaba la unidad antes de probar la guardia mutada. Además, comprobar solo el destino final no observa una escritura dentro del temporal, que se borra al terminar.
  - **Cambio del test, sin producto**: el caso hostil contiene una sola entrada con `extra/../../fuera`, sin los residuos de la pierna anterior de `.git`, y exige el mensaje de falla de integridad de memory.
  - **ROJO**: TS12 y TR12 detectan M60 en ambos bash; TR12 cae en la afirmación nueva del mensaje. **VERDE**: TR12 sin mutar pasa en ambos, rc 0 y stderr vacío, en 11,784 s y 11,271 s. Los resultados anteriores se conservan en `mutations/revisions/M60-before-TR12/`; el nuevo resultado está en `mutations/M60.json`, y los controles en `TR12-positive-bash{5,32}.*`.
- **T069, tercera brecha del oráculo (16-11-2026, M62)**: TU10 detectaba la copia bruta de SQLite, pero TS14 solo ejercía el subcomando `sqlite-snapshot`, que evita la selección mutada dentro de `capture()`. Hallazgo presentado antes de editar. TS14 ahora también invoca `digest` sobre la base abierta en WAL, con escrituras sin confirmar, y exige una captura con las 100 filas confirmadas. No cambia el producto ni el número de pruebas.
  - **ROJO**: TS14 cae contra M62 en `captured_rows 100`; TU10 también cae por la tabla ausente en la copia bruta. Ambas detectan la fila en ambos bash, sin timeout. Evidencia anterior conservada en `mutations/revisions/M62-before-TS14/`; controles sin mutar en `TS14-positive-bash{5,32}.*`. La secuencia continúa desde M63 solo después de los dos controles verdes.
- **T069, cuarta brecha del oráculo (16-11-2026, M132)**: sobrevivió en ambos bash. La mutación quitaba el fallo de la columna `status`, pero TB04 buscaba `push-failed` en toda la fila; la columna separada `last result` ya satisfacía esa afirmación. Se presentó el hallazgo antes de editar y se agregó la comparación de la frase final completa `ok, last attempt push-failed`, sin cambio de producto. TB04 cayó por esa afirmación contra M132 en ambos bash. Evidencia anterior conservada en `mutations/revisions/M132-before-TB04/`; nuevo resultado en `mutations/M132.json`. El corredor exige los controles verdes `TB04-positive-bash{5,32}.*` antes de retomar desde M133.
- **T069 cerrada (16-11-2026)**: 167 de 167 mutaciones detectadas en bash 5.3.15 y 3.2.57; las 124 pruebas del host caen al menos una vez. Se exigió que cayeran TODAS las pruebas nombradas en cada fila, sin timeout ni resultados incompletos. La tabla de T069 lleva ahora el resultado y los segundos de cada bash, incluida M0.
  - **M0 final**: repetida después de endurecer TU22, TR12, TS14 y TB04; exactamente 116 fallas y las ocho verdes previstas en ambos bash. La versión anterior se preservó en `mutations/revisions/M0-before-final-oracles/`.
  - **Cuatro sobrevivientes iniciales corregidos en el oráculo**: M15, M60, M62 y M132. Cada hallazgo se presentó antes de editar; cada afirmación nueva cayó contra su mutante y pasó sin mutar en ambos bash. Sin cambios de producto y sin aumentar las 124 pruebas.
  - **La captura de TU16 fue ejercida por M84**: identificó `memory`, la comparación del mensaje, esperado, recibido y `last_result`. Es una falla plantada; no explica ni cierra la falla espontánea original.
  - **Evidencia consolidada**: `mutations-final.json` y `mutations/results-final.md` en el directorio de cierre, además de los 168 JSON y los 336 TAP por fila y bash. El consolidado verifica identificadores, resultados, integridad y cobertura, y guarda la huella de las seis suites finales. Continúa T070; no hubo commit ni push.
- **T070 cerrada (16-11-2026)**: repositorio copiado por tar (sin bind mount), contenedores desechables `--rm`, `--user agent`, `cap_drop: ALL`, `no-new-privileges`, `CI=1` y temporales bajo `/work/tmp`.
  - **Ubuntu 24.04, Linux arm64**: UID 1001, bash 5.2.21, Python 3.12.3, bats 1.11.0; 124 de 124, rc 0, sin saltadas, 113,199 s.
  - **Alpine 3.24.1, Linux arm64**: UID 501, bash 5.3.9, Python 3.14.5, bats 1.11.0; las 40 de almacén y destino pasan, rc 0, sin saltadas, 13,792 s. TU02, con ciclos consecutivos y sin espera entre ellos, también pasa en 2,560 s: el segundo ciclo dice `no changes`, no `locked`.
  - **BusyBox 1.37, git que ignora TERM**: la consulta autenticada real de `backup_dest_verify` recibió un `git` falso que ignora TERM, con una sonda privada reciente para aislar esa consulta. Límite 2 s y KILL a los 10 s; terminó en 12,132 s, una invocación de git, salida y registro `unreachable`, rc 0. La tolerancia de medición fue de 2 s adicionales por arranque y escritura de estado; no se contó un timeout del corredor como éxito.
  - **Falla de preparación conservada**: la primera imagen de Alpine no traía `git-http-backend` ni `ssh-keygen`. `CI=1` rechazó esa ausencia antes de probar producto; se presentó el diagnóstico y se agregaron `git-daemon` y `openssh-keygen` solo a la imagen desechable. La repetición usó el mismo tar, cuyo SHA-256 y las seis suites se verificaron sin cambios. No se modificó el runtime del repositorio.
  - **Evidencia**: `linux-source-sha256.json`, `ubuntu.{json,tap,err}`, `alpine.{json,tap,err}`, `alpine-lock.{json,tap,err}`, `alpine-ignore-term.{json,err}` y `linux-revisions/alpine-dependencies-missing/` en el directorio de cierre. Los stderr de las suites contienen solo la línea de versiones que agrega el corredor.
- **T071 y primera parte de T072, DOCKER_E2E de 046 (16-11-2026)**: 8 de 8, rc 0, sin saltadas, stderr vacío, 55,829 s (01:42:10 a 01:43:06, Santiago). Se ejecutaron los cinco respaldos, idempotencia, clon de trabajo, credencial errónea, sensibilidad, cron, restauración y estado. Autorización de T072 ya registrada en el traspaso; no hubo commit ni operaciones sobre agentes reales.
  - **ROJOS del arnés presentados antes de corregir**: `setup_file` no tiene `BATS_TEST_TMPDIR` (intentaba `/seed-br-e2e`); el regenerate del host no habilitaba la costura de HTTP local; y `State.Running` precedía las escrituras de settings del supervisor. Se fijó el temporal de archivo en esa llamada, la costura solo en regenerate y la espera de la sesión tmux real. TE1 y TE2 pasaron después de la espera.
  - **TE5, propiedad del caché**: el volcado solo al fallar mostró UID efectivo 501, raíz del repo 0:0 y `.git` 501:20. Una sonda sin producto reprodujo el cambio de propietario tras recrear el directorio y hacer `git init` en un bind mount de Docker Desktop; la misma secuencia en el filesystem nativo conservó 501:20. El override del test usa un volumen desechable para `/home/agent/.cache`, retirado con `compose down -v`. El compose del producto, sus capacidades y sus mounts no cambian. Evidencia: `ownership-probe.out` y `ownership-native.out`.
  - **TE7, SQLite**: el esperado del host se calculaba con SQLite 3.51.0, frente a 3.53.4 del contenedor. Un diagnóstico separado confirmó que el digest calculado en el origen coincide exactamente con el archivo restaurado. TE7 calcula ahora la lista de capturas dentro del contenedor, con el mismo Python/SQLite que hizo el respaldo; conserva todas las comparaciones de tamaño y SHA-256. No se relajó la comparación.
  - **Evidencia**: `e2e-046.{json,tap,err}`, `TE7-diagnosis.*` y los intentos anteriores en `e2e-revisions/`. La huella inicial está en `pre-e2e-hashes.json`; `validated-046-hashes.json` confirma que desde ella solo cambió `tests/docker-e2e-backup-repo.bats`. Runtime, seis suites del host y corredor de mutaciones permanecen idénticos. T072 sigue abierta hasta terminar los 62 casos de regresión.
- **T072 cerrada con el rojo previo del smoke identificado (16-11-2026)**: la regresión completa ejecutó los 62 casos, 61 en verde y uno en rojo, sin saltadas, stderr vacío, rc 1 y 1.343,572 s (22 min 23,572 s; 01:43:37 a 02:06:00, Santiago). Los ocho de 046 volvieron a pasar dentro de esa corrida. `qmd real (016)` y `qmd real (041)` pasaron; esta última con sus ocho fases en orden y los modelos sin cambios.
  - **Único rojo**: `E2E: scaffold + build + up + healthcheck`, `tests/docker-e2e-smoke.bats:79`, al no encontrar la sesión tmux tras 20 s. Es la excepción que T072 y el traspaso ya registraban; no se corrigió fuera de alcance.
  - **Confirmación fresca en la base**: el mismo test dio rojo en la misma línea sobre `10f22a7`, en 30,971 s, sin saltadas y stderr vacío. `git diff 10f22a7 origin/main -- docker scripts modules setup.sh tests` está vacío: el runtime y las pruebas de esa base son idénticos a `origin/main=9608e4a`. No se atribuye el rojo a carga ni se declara corregido.
  - **Evidencia**: `e2e-all.{json,tap,err}`, `baseline-smoke.{json,tap,err}` y `baseline-runtime-equivalence.json`. El informe completo conserva rc 1 y `valid: false`; el cierre de T072 es calificado por la excepción explícita de su tarea, no un 62 de 62 verde.
  - **T074 iniciada**: un corredor secuencial hará la suite completa de 2104 en bash 5.3.15 y 3.2.57, las 124 nuevas con SIGPIPE ignorada en ambos, y cinco TU16 originales instrumentadas solo al fallar en bash 3.2, con parada ante la primera falla. Se mantienen las compuertas de commit, push y linus.
- **T074, primera pasada completa (16-11-2026)**: bash 5.3.15, bats 1.13.0, plan `1..2104`, 2104 `ok`, 0 `not ok`, 69 saltadas (61 de la línea base más las ocho nuevas e2e), rc 0, stderr de 0 bytes, 1.624,412 s (27 min 4,412 s). TU16 pasó, sin activar su diagnóstico. La pasada de bash 3.2 comenzó después de terminar esta. Evidencia: `host-bash5.{json,tap,err}` en el directorio de cierre. T074 sigue abierta hasta las demás comprobaciones.
- **T074, segunda pasada completa (16-11-2026)**: bash 3.2.57, bats 1.13.0, plan `1..2104`, 2104 `ok`, 0 `not ok`, 70 saltadas (62 de la línea base más ocho e2e nuevas), rc 0, stderr de 0 bytes, 1.644,377 s (27 min 24,377 s). TU16 pasó sin activar el diagnóstico. La única saltada adicional frente a bash 5 es la prueba de `read -t` del watcher de QMD, que requiere bash 4+. Evidencia: `host-bash32.{json,tap,err}` y `host-matrix-verified.json`. Las 124 con SIGPIPE ignorada comenzaron después de terminar esta pasada; T074 sigue abierta hasta concluirlas y verificar la huella final.
- **T074 cerrada (16-11-2026; verificación final a las 03:15:39, Santiago)**: el verificador final volvió a leer los TAP, exigió plan y numeración completos, resultados, saltadas previstas y stderr vacío, y cruzó los informes con las huellas de código. No contó un `done` del corredor como evidencia suficiente.

  | Comprobación | Resultado | Saltadas | Duración | Stderr |
  | --- | --- | --- | --- | --- |
  | Host, bash 5.3.15 | 2104 ok, 0 fallas | 69 previstas | 1.624,412 s | 0 bytes |
  | Host, bash 3.2.57 | 2104 ok, 0 fallas | 70 previstas | 1.644,377 s | 0 bytes |
  | Seis suites con SIGPIPE ignorada, bash 5.3.15 | 124 de 124 | 0 | 392,486 s | 0 bytes |
  | Seis suites con SIGPIPE ignorada, bash 3.2.57 | 124 de 124 | 0 | 401,589 s | 0 bytes |
  | TU16 sola, cinco veces seguidas en bash 3.2.57 | 5 de 5 | 0 | 14,576 s totales | 0 bytes |

  - **TU16**: las cinco duraron 2,932 s, 2,775 s, 2,844 s, 3,191 s y 2,834 s. Ninguna activó `TU16_DIAG`. También pasó en ambas suites completas y ambas pasadas con SIGPIPE ignorada. Se cumple ahora la serie final de cinco verdes; la falla original de la serie de 4 de 5 permanece histórica, no reproducida y con causa desconocida. No se aplicó ni se declara un arreglo del producto para ella.
  - **T066/T067 y alcance**: las estáticas, compilaciones, modos 100755, renders y crontabs ya registrados siguen aplicando: el runtime no cambió desde el WIP. La auditoría de bytes se repite sobre el texto final. Solo se modificaron el corredor, sus pruebas, los cuatro oráculos, la captura al fallar de TU16 y el arnés e2e, además del Registro y el traspaso.
  - **Huella estable**: `23dfb736beb560fa6552da80e445479c4cd725b2e273e91e624e351d1fc21099`, sobre los archivos de `validated-046-hashes.json`. Las seis suites coinciden también con `mutations-final.json`. `git diff HEAD` sobre runtime, plantillas, workflow, `.gitignore`, VERSION y constitución está vacío. HEAD sigue en `3f113576d13d6c4edd5dfafe67d0cfbaceb37d2a`; no hubo commit, push ni intervención en linus.
  - **Base temporal**: se comprobó limpia y se retiró con `git worktree remove`, sin `--force`, la copia propia `<directorio-de-cierre>/base` usada para M0, T067 y la confirmación del smoke. No se tocaron otros worktrees. Para repetir esas comprobaciones se recrea sobre `10f22a7`.
  - **Evidencia**: `T074-verified.json`, `host-matrix-verified.json`, `host-bash{5,32}.*`, `sigpipe-bash{5,32}.*`, `TU16-final-{1,2,3,4,5}.*`, `host-runner.log` y `host-active.json` (complete), en el directorio de cierre. El resultado Docker sigue siendo el de T072: 8/8 de 046; regresión 61/62 con el mismo smoke fallando en la base, no un verde total.
  - **Siguiente paso**: T075, con su COMPUERTA y respetando la instrucción de no hacer commit en esta invocación. Rehacer el WIP desde `0f41236` en los tres commits atómicos previstos. Después, por sus compuertas separadas, T076 (push), T077 a T080 (gate en linus antes del merge) y T081 (PR). El bloque local T068 a T074 está concluido; la feature completa y su despliegue siguen pendientes de esos pasos.
  - **Auditoría final del texto**: `byte-audit-final.out` da `problems: 0` y `byte-audit-new-final.out` da 0 hallazgos. Se conserva el resultado de las nueve comprobaciones del host en `T074-verified.json`. La invocación termina con el árbol sin commit y T075 pendiente.
- **T075, entrega en tres commits (16-11-2026)**: el operador autorizó los commits y pidió avanzar con la mayor autonomía posible mientras duerme. Se preservaron el diff y la copia del test auxiliar en `t075/` del directorio de cierre; `git reset --soft 0f41236` sustituyó el WIP sin borrar archivos.
  - **Constitución**: `679b313`, `docs: enmienda la constitución para los respaldos por agente`. Runtime y tests idénticos a la base ya validada. La auditoría de archivo entero encontró tres símbolos históricos que también están en `0f41236`; no se reescribió historia. La auditoría de líneas nuevas dio `problems: 0`.
  - **Implementación y pruebas**: `f30ad4c`, `feat: respalda el estado en el repositorio privado del agente`. Incluye las herramientas y sus diez pruebas auxiliares. Los dos scripts de credenciales están en modo 100755. Se verificó cada SHA-256 contra `validated-046-hashes.json`; huella de T074 conservada.
  - **Dependencia de las guías**: el árbol del feat sin las guías rápidas cayó en su propia afirmación: falta `AGENT_REPO_URL` en ES. Las dos guías ES/EN van con el feat para evitar ese rojo intermedio; sobre una copia del árbol exacto del índice, `quickstart-doc` da 9/9 en bash 5.3.15 y 3.2.57, stderr vacío (0,888 s y 2,664 s). No se editó código ni se relajó la prueba. Las demás guías y VERSION van en el tercer commit.
  - **Documentos**: el commit que contiene esta entrada actualiza las guías, VERSION 0.32.0, CHANGELOG, contratos corregidos durante la validación, CLAUDE.md, este Registro y el traspaso. Los SHA completos de los tres commits quedan en `t075/commits.json` después de crearlos, evitando un cuarto commit para registrar su propio SHA.
  - **Excepción de whitespace**: el único aviso de `git diff --check` es la línea en blanco final de `claude-md-backups-section.golden`; se conserva porque el contrato lo compara byte a byte. No hay otros avisos.
  - **Siguiente paso autorizado**: T076 y PR borrador para adelantar la CI mientras duerme el operador. Abrir el borrador no completa T081: falta el gate real en linus (FR-022). Preparar inventario con lecturas, sin asociar ni reiniciar el agente. Permanecen humanas la decisión de rutas adicionales, la revisión de archivos en claro, la posesión de la llave, la autorización separada de M5 y el merge.
  - **Evidencia**: `t075/{before-reset.json,before-reset.patch,commit1.json,commit2.json,feat-final.json,split-red.tap,split-bash5.*,split-bash32.*,feat-byte-audit.txt,index-whitespace-check.json}`. Las suites largas de T074 no se repiten por cambios de metadata y documentación; su runtime y pruebas están verificados sin cambios.
- **T076 hecha y T081 preparada como borrador (16-11-2026, 04:47 Santiago)**: aplicando la instrucción de avanzar con la mayor autonomía posible, se publicaron por HTTPS los tres commits de T075: `679b313`, `f30ad4c` y `9ed154b`. La cabeza remota se consultó de nuevo y coincide con `9ed154bd4fba6bbc0d0514fba1e68b00d7de97bf`. El conector GitHub devolvió 401; se usó `gh`, autenticado como `rodrigo-hinojosa`, y el ayudante de credenciales indicado en el traspaso. `main` remoto sigue en `9608e4a`.
  - **PR**: [#135](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/135), contra `main`, en borrador y sin merge. Se abrió antes del gate de linus solo para adelantar CI; FR-022 y T077 a T081 siguen pendientes. La plataforma reportó `MERGEABLE`, que solo habla del merge textual y no satisface el gate.
  - **CI iniciada**: [tests, run 43826260402](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43826260402), con ambos bash; [shellcheck, run 43826260518](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43826260518), ya correcto. Además se lanzó [docker-e2e, run 43826397011](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43826397011), normal y sin ensayo de avisos, para probar los ocho casos nuevos en amd64 antes del gate real. Son runners separados; no hubo dos bats concurrentes en el worktree local.
  - **Preparación de T077, solo lecturas**: GitHub confirmó `linus-workspace-agent-admin` privado, no fork, `main=597033e5d6f4d2f914fcd7e76ddc54ddfecdd285`, y ninguna rama de respaldo. Donna también sigue privada, con `main=f7a4711b3dc2d432e836dc2517d9fe64711f1f09` y `002-registro-costos=59745902ec39de52d15364cf3e7d1467211c643f`. Son observaciones a las 04:47; se deben refrescar inmediatamente antes de asociar cada agente.
  - **Acceso a ferrari**: la única consulta SSH, para inspeccionar metadata de linus, terminó con rc 255, `websocket: bad handshake` y `Connection closed by UNKNOWN port 65535`. No se obtuvo inventario vivo ni estado del contenedor. No se infiere que linus esté caído, ni se atribuye una causa sin medirla. No hubo cambios en ferrari, en agentes ni en las ramas de sus repositorios.
  - **Decisiones preparadas**: [operator-review.md](operator-review.md) reúne el acceso pendiente, las cinco huellas públicas de GitHub, las listas candidatas en claro y el orden para retomar. Ninguna llave privada se leyó ni se seleccionó por inferencia. Se pidió al operador restablecer SSH y confirmar la huella de una parte privada disponible; faltan el inventario y su revisión antes de asociar linus. M5 conserva su autorización separada.
  - **T086, solo preparación**: hay seis borradores locales en `<directorio-de-cierre>/publication/follow-up-issues/`, incluido el procesamiento archivo por archivo que T073 dejó para un issue y que faltaba en la lista de T086. No se publicaron issues ni se ejecutó el cierre posterior al merge.
  - **Evidencia**: `t075/{commits.json,push.json,pr-body.md,pr-url.txt}`, `publication/{pr-initial.json,linus-repo-before.json,donna-repo-before.json,public-key-fingerprints.json,linus-access.json,ci-current.json}` y las carpetas `publication/run-<id>/`. El verificador de CI exige plan, numeración completa y presencia sin salto de las 124 pruebas nuevas del host o las ocho e2e, según el job; un estado del workflow sin ese contraste no se cuenta como validación de los tests.
- **Primera CI sobre `9ed154b`, hallazgos antes de corregir (16-11-2026)**: shellcheck pasa. Ubuntu, bash 5.3.9/bats 1.11.0: 2104 ok y 0 fallas, 64 saltadas, ninguna de las 124 nuevas; job 837 s (13 min 57 s). macOS, bash 3.2.57/bats 1.14.0: 2103 ok y una falla, 72 saltadas, ninguna nueva saltada; job 2183 s (36 min 23 s). Falla TA06 dentro de `_ta_regen`, antes de comparar el dorado; el helper descartaba stdout/stderr y no dejó la causa. No se atribuye el rojo a la comparación de archivos ni a la versión de bats sin prueba.
  - **E2E amd64**: run `43826397011`, 55/62, 0 saltadas y 1806 s (30 min 6 s). TE1 a TE7 fallan; TE8 pasa. Los otros 54 casos pasan, incluido el smoke. El primer fallo es `Permission denied` al crear el caché, con UID 1001; no es evidencia de un rechazo de la credencial. Los informes conservan `valid: false`.
  - **Causa aislada del caché**: el override del arnés introducía un volumen hijo para resolver el problema medido de Docker Desktop. El producto solo monta el directorio de estado. Una sonda real con Alpine, usuario `agent` UID 1001, `cap_drop: ALL` y `no-new-privileges` mostró home 1001:1001 pero volumen hijo 0:0, no escribible; sin ese volumen, el mismo usuario crea el caché. La revisión de solo lectura corroboró la cadena del código: el entrypoint conserva un home que ya pertenece al agente. No se amplió su guardia ni se cambiaron privilegios.
  - **Arreglo test-first, solo arnés**: la comprobación del override para Linux cayó en ambos bash con el volumen incondicional. Se limitó el volumen a Darwin; Linux usa el bind real del producto. Linux sin volumen y Darwin con él pasan en ambos bash. El volcado al fallar incluye ahora home y caché, que antes faltaban. Runtime, compose del producto, Dockerfile y las unidades no cambian.
  - **Repetición local, rojo distinto**: TE1 a TE5, TE7 y TE8 pasan; TE6 no encontró `backup-memory.log` durante sus 150 s. Duración 181,927 s y stderr vacío. El caché es 501:20 y escribible; no se atribuye esta falla a la del volumen. Una copia temporal que captura, solo al fallar, staging y crontab vivo, permisos, procesos y log del daemon pasó 8/8 en 43,941 s; no activó su captura. Se ejecuta una serie acotada adicional, en secuencia y con parada en la primera falla. No se aumentó el plazo ni se relajó la aserción.
  - **TA06, diagnóstico sin arreglo de producto**: una copia temporal dio 100/100 en bash 3.2, `CI=1`, con yq 4.52.5 (242,613 s), y otras 100/100 con el yq 4.44.3 de CI, verificado contra checksums oficiales (239,508 s). La falla de CI sigue sin causa confirmada. El helper original incorpora captura solo al fallar, redacción antes de truncar y retorno del mismo rc. Una falla sintética con rc 17 demostró primero que la versión anterior ocultaba el mensaje; el nuevo helper conserva 17, imprime el diagnóstico y redacta el centinela, en ambos bash. Las aserciones de TA06 no cambian. Se preparó bats 1.14.0 oficial para contrastar también esa diferencia con el 1.13.0 local.
  - **Estado de gates**: T072 y T074 se reabren para la validación del arnés y helper actuales. Se conserva toda la evidencia previa como histórica. Las 167 mutaciones y los demás oráculos no cambian; se verificará la equivalencia de las fuentes y se repetirá lo afectado, además de la matriz completa de CI y el e2e amd64. No se reescribe la historia ya publicada ni se hace force push.
  - **Acceso**: `cloudflared access login --quiet --auto-close` terminó con 0, sin imprimir el JWT. La consulta SSH siguiente volvió a terminar con el mismo `websocket: bad handshake`. La interfaz de navegador no estuvo disponible. No hay inventario vivo ni cambios en agentes; no se ha confirmado la causa del transporte.
  - **Evidencia**: `publication/run-{43826260402,43826397011}/`, `cache-volume-diagnosis/{plain.out,volume.out,*-red.*, *-green.*,mac-e2e.*}`, `ta06-diagnosis/{results.json,ci-yq-results.json,helper-proof/,ci-bin/verified.json}` y `te6-diagnosis/`. Todos bajo el directorio de cierre ya indicado.
- **Corrección del arnés y validación focal posterior (16-11-2026)**: la revisión independiente de solo lectura del diff no encontró hallazgos ni cambios de privilegios. El único arreglo de comportamiento es el volumen de test limitado a Darwin; las demás ediciones son diagnósticos que se ejecutan solo al fallar. El producto sigue idéntico al validado en T074.
  - **TA06**: también pasó 100/100 con bats 1.14.0 oficial, bash 3.2 y yq 4.44.3 (249,307 s). Son 300 intentos en total sin reproducir el rc no cero del CI original; no se atribuye una causa ni se declara un arreglo de producto. La versión 1.14.0 corresponde al commit oficial `eb7f42f8d608ac693d7a4b67474f6714ea68cfc5`.
  - **Archivo de superficie completo, con SIGPIPE ignorada, bats 1.14.0 y yq de CI**: 20/20 en bash 5.3.15 (81,058 s) y 3.2.57 (89,387 s), sin saltadas y stderr de 0 bytes. El archivo e2e, sin Docker habilitado, carga y da sus ocho saltadas previstas en ambos bash, también con stderr vacío.
  - **Mutaciones afectadas**: M113, M114, M121 y M122 vuelven a caer en todas sus pruebas previstas, en ambos bash, sin timeout ni errores del TAP. Las 167 anclas siguen válidas. No se repitió sin motivo el resto del catálogo, cuyos archivos y aserciones no cambiaron.
  - **E2E local actual**: cinco corridas completas consecutivas, cada una 8/8 y stderr vacío, con parada prevista ante la primera falla; duraciones 55,503 s, 61,666 s, 58,941 s, 119,171 s y 61,432 s. TE6 no volvió a fallar ni activó la captura; su falla previa sigue con causa desconocida. No se aumentó el límite de 150 s. El volcado queda en el original para la siguiente CI, antes de que teardown cambie el schedule.
  - **Huella y alcance**: `publication/validated-post-ci-hashes.json` compara cada archivo con T074 y solo difieren `tests/agent-repo-surface.bats` y `tests/docker-e2e-backup-repo.bats`. Su mapa completo de hashes tiene SHA-256 `e1fb2fe5b5da8c39cba2fdb2eb1dc1f929b8d7f5120f9fb5fbcd6cf187e4b5d9` (JSON canónico, algoritmo indicado en el informe). Runtime, plantillas, workflow y las otras cinco suites nuevas siguen iguales. La auditoría de líneas agregadas y del documento nuevo da 0 hallazgos; `git diff --check` no da avisos en este cambio.
  - **Siguiente**: publicar este ajuste de pruebas y el registro, y repetir la matriz completa y el e2e amd64 sobre la nueva cabeza. T072/T074 siguen abiertas hasta esa comprobación; T077 a T081 siguen pendientes del gate real y las decisiones del operador. Evidencia adicional en `publication/{post-ci-*.json,post-ci-*.tap,post-ci-*.err,current-source-bridge.json,affected-mutations.json,post-ci-mutations/}` y `ta06-diagnosis/bats14-results.json`.
- **Ajuste publicado para la segunda CI (16-11-2026)**: commit `d711942dff7e7fa66a7325d33f29372036cf32da`, `test: limita el caché del e2e a Darwin y conserva los diagnósticos`. Push normal por HTTPS, sin reescribir historia, con cabeza remota comprobada. `main` continúa en `9608e4a`. El PR #135 sigue en borrador y se actualizó su descripción con los hallazgos y las limitaciones.
  - **Corridas**: [tests 43835652178](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43835652178), [shellcheck 43835652287](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43835652287) y [e2e amd64 43835646803](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43835646803). Pendientes de conclusión al iniciar esta entrada; se contrastarán sus logs, no solo el estado agregado.
  - **Evidencia**: `publication/{fix-commit.json,retry-runs.json,pr-body-current.md,retry-ci-final.json}` y `publication/run-<id>/`. `retry-ci-final.json` solo se escribe si terminaron todas las corridas, con TAP verificados y sin fallas; no tomar su ausencia como verde.
- **Preflight adicional de linus, solo lectura (16-11-2026)**: `git ls-remote --heads` anónimo fue rechazado y la misma lectura con el ayudante de `gh` de este Mac funcionó, conservando `main=597033e5d6f4d2f914fcd7e76ddc54ddfecdd285`. No se comprobó la credencial del agente ni se escribió en su repositorio. Evidencia: `publication/linus-git-preflight.json`. HTTPS anónimo a la entrada de ferrari devolvió 302; SSH sigue fallando después de la renovación, sin causa de transporte confirmada.
  - **Punto del inventario**: `operator-review.md` aclara que incluir el clon antiguo como extra no conserva `.git`; su commit local se debe revisar antes de sustituir ese clon. Es una lectura de `_memory_find_files`, no una verificación del estado vivo de linus.
- **Segunda CI, resultado y causa confirmada de TA06 (16-11-2026)**:
  - **Ubuntu**: 2104 ok, 0 fallas, 64 saltadas, ninguna de las 124 nuevas saltada; 1085 s (18 min 5 s). **Shellcheck** pasa.
  - **E2E amd64**: run `43835646803`, 62/62, 0 saltadas, 1553 s (25 min 53 s), margen de 19 min 7 s sobre su tope de 45 min. Los ocho casos de 046 pasan. `qmd real (041)` deja sus ocho fases en orden: `models-seed`, `boot`, `setup`, `vector-extension`, `reindex`, `semantic-search`, `mcp`, `models-untouched`; el resumen dice `total=62 executed=62 skipped=0 failed=0`. La corrección del volumen del arnés queda confirmada en Linux real. T072 se vuelve a cerrar con esta evidencia, las cinco corridas locales 8/8 y la regresión local histórica 61/62 con el smoke previo; no se presenta esa regresión local como un 62/62 verde.
  - **macOS**: 2103 ok y una falla, TA06; 72 saltadas, ninguna nueva saltada; 2552 s (42 min 32 s), sin timeout. El diagnóstico añadido capturó `cp: /etc/systemd/system/agent-dockbot.service: No such file or directory`, después de renderizar los archivos. El fixture tiene `deployment.install_service: true`; `install_service` entra a copiar la unidad si `sudo -n true` funciona. Este Mac devuelve 1 en esa sonda, mientras el runner alcanzó la copia. La prueba anterior no era hermética respecto de sudo/systemd: las 300 repeticiones no habían simulado esa condición.
  - **Reproducción segura antes del arreglo**: un `sudo` falso en PATH devuelve 0 para `-n true` y bloquea cualquier instalación con rc 86, sin ejecutar comandos reales. TA06 cae en bash 5 y 3.2 por su propio `_ta_regen`, con `TA_REGEN_DIAG rc=86` y la marca de intento de instalar. No se tocó `/etc`.
  - **Arreglo de la prueba, no del producto**: solo TA06 fija `.deployment.install_service = false` en su copia del fixture. Conserva un stub de sudo que simula el acceso sin contraseña y bloquea los demás comandos, y exige que ni siquiera haya sido invocado. El dorado y todas sus comparaciones permanecen iguales. TA06 pasa en ambos bash; al plantar la omisión del flag, vuelve a caer con 86 en ambos. La revisión independiente del diff no encontró hallazgos. La causa capturada de TA06 deja de ser desconocida; no se corrigió ni se atribuyó un defecto al render de respaldos.
  - **Validación focal**: archivo de superficie 20/20 con SIGPIPE ignorada, bats 1.14.0 y yq 4.44.3, en bash 5.3.15 (72,633 s) y 3.2.57 (75,259 s), stderr vacío. Se repite M113 para comprobar que la comparación de secciones sigue cayendo ante su defecto. Runtime y archivo e2e siguen idénticos a `d711942`, por lo que el 62/62 de amd64 conserva su alcance.
  - **Recolector**: una prueba sintética mostró que podía aceptar una saltada de un e2e antiguo, aunque no de los ocho nuevos. Se vio el control en ROJO antes de endurecerlo: ahora exige cero saltadas en los 62 y el resumen completo exacto. El control de saltada y el del smoke real fallido son rechazados; el positivo sintético se acepta. Esos controles se identifican como sintéticos y no se cuentan como pruebas ejecutadas. Los logs reales del 62/62 cumplen ambas exigencias.
  - **Evidencia**: `publication/run-{43835652178,43835646803,43835652287}/`, `ta06-diagnosis/{bash*-passwordless-red.*,bash*-passwordless-green.*,bash*-service-flag-mutant.*}`, `publication/service-fix-bash*.{json,tap,err}`, `publication/parser-controls-strict.json`. T074 permanece abierta hasta repetir la matriz completa sobre esta corrección de TA06; no se repite el e2e que no cambió. TE6 conserva su falla local histórica sin causa confirmada y su diagnóstico para recurrencia.
- **Corrección de TA06 publicada y preparación del gate (16-11-2026)**: commit `b3eb8c4141531f62017d07c212b2c96bcdcd1e51`, con la cabeza remota comprobada y push normal por HTTPS. La nueva matriz del host corre en [43843656236](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43843656236) y shellcheck en [43843656169](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43843656169). Se verificará su conclusión y cada TAP antes de cerrar T074; no basta una corrida iniciada. `publication/validated-service-fix-hashes.json` compara los 47 archivos con la evidencia anterior: solo cambia `tests/agent-repo-surface.bats` respecto de `d711942`, con mapa SHA-256 `e41c4ccbf594bbde6913263ee350a9e3901d0b686ce31a799c0263d8595f2e85`. M113 sigue detectada por TA06 y TA07 en ambos bash.
  - **Paquete de sistema, sin aplicar**: `publication/deployment-preparation/046-system-b3eb8c4.tar`, 1.310.720 bytes, 138 archivos de sistema rastreados, SHA-256 `03705882b2899ab9fa98464b8f6645592b7c5ede55481f350a1d6dfb828ae6a5`. `manifest.json` coteja todos sus contenidos y modos contra los blobs de `b3eb8c4` y registra tamaños y hashes. La primera verificación de modos detectó 0664 por la umask predeterminada de `git archive`; se regeneró con `git -c tar.umask=022 archive` y se comprobaron los modos 0644/0755 explícitos. Incluye solo `setup.sh`, `VERSION`, `.gitignore`, `LICENSE`, `modules/`, `scripts/` y `docker/`, según el README; no incorpora estado de agentes ni se ha transferido o instalado. El procedimiento conserva el estado vivo bajo `scripts/`; no extraer directamente sobre el workspace como sustituto del procedimiento.
  - **Pendientes humanos sin cambios**: transporte SSH, inventario vivo y decisión de rutas, revisión de los archivos en claro, posesión de la llave privada, autorización separada de M5 y merge. El PR #135 permanece en borrador. Evidencia adicional: `publication/{service-fix-commit.json,service-fix-runs.json,service-fix-ci-final.json}`; este último solo se genera si toda la nueva CI concluye en verde con TAP válidos.
- **T074 cerrada de nuevo, tercera CI completa (16-11-2026, verificación a las 07:29:29 de Santiago)**: sobre `b3eb8c4`, [tests 43843656236](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43843656236) y [shellcheck 43843656169](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43843656169) concluyeron en verde. Se verificaron los planes `1..2104`, la numeración completa y las 124 pruebas nuevas del host presentes, sin fallas ni saltadas, en ambos brazos.
  - **Ubuntu**: 2104 ok, 0 fallas, 64 saltadas del host (56 de suites existentes y las ocho e2e de 046), 838 s (13 min 58 s); bash 5.3.9, bats 1.11.0, yq 4.44.3.
  - **macOS**: 2104 ok, 0 fallas, 72 saltadas del host (64 de suites existentes y las ocho e2e de 046), 2211 s (36 min 51 s); bash 3.2.57 arm64, bats 1.14.0, yq efectivo 4.54.1. Margen de 8 min 9 s sobre el tope de 45 min. TA06 pasa con la instalación deshabilitada y su guardia contra sudo.
  - **Precisión de dependencias**: los logs de las tres corridas macOS reportan yq 4.54.1, aunque el paso del workflow descarga 4.44.3. Las repeticiones y controles locales con yq 4.44.3 son evidencia adicional de compatibilidad, no una réplica exacta de la versión efectiva del runner. Se corrige aquí la atribución previa de 4.44.3 como versión de CI macOS; no se altera el registro histórico de las pruebas ejecutadas ni el workflow en esta feature.
  - **Alcance del cierre**: la base local completa de 2104 por bash y las 124 con SIGPIPE ignorada y stderr vacío se conservan como históricas. Tras los cambios de los dos archivos de pruebas se repitieron las comprobaciones afectadas: cinco e2e locales 8/8, superficie 20/20 por bash con SIGPIPE ignorada y stderr vacío, y las mutaciones afectadas, incluido M113 después del ajuste de sudo. La matriz completa de CI verifica el árbol de código actual. No se atribuye stderr separado a la CI, que combina los flujos. Las estáticas y los renders siguen aplicando por identidad de fuentes; los 47 hashes coinciden con `validated-service-fix-hashes.json`.
  - **T072 conserva su alcance**: runtime y archivo e2e idénticos a `d711942`, del 62/62 amd64 sin saltadas y con las ocho fases de QMD 041; no se repitió ese gate sin un cambio de fuente que lo justificara. Las fallas históricas de TU16 y TE6 conservan causa desconocida y diagnósticos para recurrencia; no se declara un arreglo de producto.
  - **Estado remoto**: los tres checks del PR #135 están en verde, el PR sigue abierto y en borrador y GitHub lo reporta `MERGEABLE`. `main` sigue en `9608e4a`. T077 a T081 permanecen abiertas por el gate real de linus. Se publicará este registro con cambios solo documentales, y se comprobarán los checks automáticos de esa cabeza sin modificar otra vez el código validado.
  - **Evidencia**: `publication/service-fix-ci-final.json`, `publication/run-43843656236/` (logs y verificaciones por job), `publication/run-43843656169/` y `publication/pre-doc-commit-remote.json`. El último commit documental se identifica con `git log`; su comprobación final se conserva en `publication/final-doc-ci-final.json` cuando concluya, sin generar otro commit para registrar su propio SHA.
