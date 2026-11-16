# Traspaso de 046 a Codex (actualizado el 16-11-2026)

Propósito: que Codex termine la feature 046 (agent-backup-repo) desde donde quedó, sin rehacer lo hecho ni reabrir decisiones del operador. Fuente de verdad del trabajo: [`tasks.md`](tasks.md) (tareas, catálogo de mutaciones y **Registro**). Este archivo es el mapa para retomar; no reemplaza al Registro.

## 1. Dónde está

| Dato | Valor |
| --- | --- |
| Worktree | `/Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher/.claude/worktrees/046-agent-backup-repo` |
| Rama | `046-agent-backup-repo`, publicada por HTTPS el 16-11-2026; [PR #135](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/135) en borrador |
| Base | `origin/main` = `10f22a7` al crear la rama. Rebase completado el 15-11-2026 sobre `9608e4a` (PR #134, sube el tope del job `bats` a 45 min) |
| Commits | `0f41236` (artefactos de spec-kit), `679b313` (constitución), `f30ad4c` (implementación y pruebas), `9ed154b` (documentos), `d711942` (ajuste del arnés y diagnósticos) y `b3eb8c4` (aislamiento de sudo en TA06), publicados |
| VERSION | 0.32.0 (`main` tiene 0.31.0) |
| Constitución | 1.1.0 (enmienda E1 a E6, hecha en T005) |

**T075 hecha**: el WIP `3f11357` se sustituyó con `git reset --soft 0f41236` y los tres commits atómicos previstos, sin perder archivos ni cambiar la huella de runtime y pruebas validada en T074. El WIP sigue siendo solo un punto histórico de restauración. Las dos guías rápidas ES/EN acompañan al feat para que el test de documentación no falle en ese commit intermedio; la separación se probó antes de commitear.

**Estado de validación al 16-11-2026, 07:29 Santiago**: T072 y T074 cerradas. La tercera CI, sobre `b3eb8c4`, dio 2104/2104 tanto en Ubuntu (13 min 58 s) como en macOS (36 min 51 s), con las 124 nuevas ejecutadas y shellcheck correcto. [Tests 43843656236](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/43843656236). El e2e amd64 sobre `d711942` dio 62/62 sin saltadas, con las ocho fases de QMD 041; runtime y archivo e2e siguen idénticos. El Registro distingue esa evidencia de la regresión local histórica 61/62 con el smoke previo. TU16 y TE6 conservan sus fallas históricas con causa desconocida y capturas para recurrencia; no se declara un arreglo de producto.

**Siguiente: T077, pendiente de acceso y decisiones humanas**. TA06 quedó corregida y confirmada por la tercera CI: deshabilita la instalación de servicios en su copia del fixture y conserva una guardia contra sudo. Su causa se reprodujo antes con un sudo falso, sin tocar `/etc`. macOS usó yq 4.54.1; los controles locales con 4.44.3 son cobertura adicional, no la versión efectiva de ese runner. No repetir gates largos sin un cambio que lo justifique. Las decisiones concretas y el paquete de actualización sin aplicar están en [operator-review.md](operator-review.md). El último commit solo registra documentación; recoger sus checks en `publication/final-doc-ci-final.json`, si aún están corriendo.

## 2. Reglas del operador (no negociables)

- **Idioma**: español de Chile, con tuteo y nunca voseo; sin emojis en ningún lado. El código, los identificadores y los mensajes de log siguen en inglés.
- **No inventar**: distinguir medido, leído del código e inferido, y citar la fuente.
- **Secretos**: nunca leer, mostrar, registrar ni copiar el contenido del archivo de secretos del workspace, de su copia cifrada, de llaves privadas, de `~/.ssh` ni de archivos de credenciales. Las pruebas que los nombran ya existen; no se imprimen valores.
- **COMPUERTAS**: cada una necesita el visto bueno explícito del operador, cada vez. Son el commit, el push, crear o borrar ramas remotas, el PR, el merge (que es siempre del operador), DOCKER_E2E, todo lo que toque a los agentes en ferrari, abrir issues y escribir en Confluence.
- **Lo ya autorizado**: el DOCKER_E2E local de T072, ya ejecutado; y el 16-11-2026 los commits de T075 y avanzar con la mayor autonomía posible mientras el operador duerme. Esa instrucción permite preparar y publicar la rama y un PR borrador para adelantar la CI. No sustituye su revisión del inventario, de los archivos que viajan en claro, la confirmación de posesión de la llave privada, la autorización separada de M5 ni el merge. No asociar ni reiniciar linus antes de resolver esas decisiones. La pata Linux (T070) no tiene compuerta, pero se le avisa al operador antes de empezar.
- **Decisiones**: lo que le toca al operador se le pregunta con opciones, la recomendada primero y con su porqué. No se reabre lo ya decidido (sección 4).
- **Test-first**:
  - cada cambio de código lleva su prueba, vista en ROJO por su propia afirmación antes del arreglo;
  - todo se verifica en bash 5.x y en 3.2 (`PATH=/bin:$PATH bats ...` en el Mac);
  - nunca dos corridas de bats a la vez en el worktree: hay pruebas sensibles al tiempo, y un rojo por contención esconde un mutante sobreviviente;
  - antes de llamar "flake" a algo, medirlo (correrlo solo, varias veces).
- **Contenedores**: todo `docker exec` lleva `-u agent`; las sondas a agentes son de solo lectura; nada temporal en el `/tmp` del contenedor.
- **Commits**:
  - mensaje en español, imperativo, `tipo: descripción`, sin líneas de atribución;
  - identidad `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME="Rodrigo Andres Hinojosa Acuña"` y `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL=rodrigo.hinojosa.developer@gmail.com`;
  - `CLAUDE.md` está en `.gitignore` y se agrega con `git add -f CLAUDE.md`.
- **Push**: por HTTPS, con `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git <rama>`; el remoto ssh de `origin` usa otra cuenta.
- **Al cerrar cada entrega**: decir qué cambió, cuándo, por qué y cuál es el siguiente paso.

**Guía del proyecto**: el `CLAUDE.md` de este worktree es la vigente. Codex la carga sola, por `project_doc_fallback_filenames` en `~/.codex/config.toml`, configurado el 15-11-2026. Las secciones "Backup model", "Common gotchas" y el bloque de 046 son las relevantes. No crees un `AGENTS.md` en el repo: lo que cambie va en `CLAUDE.md`, que es la fuente única para Claude y para Codex. El `AGENTS.md` viejo de la copia principal se retiró a `~/.codex/backups/20261115/`.

**Contexto compartido con Claude**:

- **Instrucciones globales**: `~/.codex/AGENTS.md` se genera desde las de Claude (`~/.claude-personal/bin/sync-codex-context.sh`) y no se edita a mano.
- **Memoria del proyecto**: la de Claude, que se lee y se escribe con su mismo formato (está descrito en `~/.codex/AGENTS.md`).
- **Skills de spec-kit**: `.agents/skills/` enlaza a `.claude/skills/`; los dos directorios quedan fuera de git.

## 3. Qué está hecho

- **T001 a T067**: US1 a US5, Polish y documentos. Seis suites nuevas con 124 pruebas del host (TD 18, TS 22, TU 40, TR 14, TA 20 y TB 10) y un e2e con 8 casos (TE1 a TE8).
- **T073, revisión independiente**: 2 ALTAS, 3 MEDIAS y 11 BAJAS, corregidas test-first. El detalle está en el Registro de `tasks.md` y en estas fuentes:
  - D37 de [`research.md`](research.md): los bloques se nombran por el SHA-256 del archivo cifrado, con un mapa local (`--block-map`) para reutilizarlos;
  - R9 de [`contracts/restore.md`](contracts/restore.md): qué puede escribir una restauración;
  - `memory_extra_path_reserved` en `docker/scripts/lib/backup_memory.sh`: las rutas reservadas del launcher, una sola fuente para el respaldo y la restauración.
- **Checkpoint `t073b` cerrado (15-11-2026)**: 334 de 334 en bash 5.3.15 y 3.2.57, sin saltadas y stderr vacío. Confirma TU33 y TU40 después de D37.
- **TU16**: la serie original dio 4 de 5; la primera falló comparando el mensaje `no-recipient`, sin capturar unidad ni texto recibido. Después pasó 20 veces sola y 100 veces en una copia instrumentada, sin reproducir. La causa sigue abierta. La captura solo al fallar se incorporó al original para los gates posteriores, sin cambiar sus aserciones ni aplicar un arreglo al producto.
- **SC-007 repetido (15-11-2026)**: 30 ciclos, 15,4 MiB al ciclo 1 y 101,8 MiB al 30, frente a 102,5 MiB de T039; rc 0, bajo 1 GB. Ver el Registro para el alcance sintético de la medición.
- **T068 cerrada (16-11-2026)**: M1 a M167 tienen anclas válidas y cubren las 124 pruebas. Control sin mutar: 124 de 124 en ambos bash. El corredor verifica la integridad del TAP, rechaza saltadas, resultados incompletos y timeout, y se detiene ante un sobreviviente. Diez pruebas auxiliares del corredor pasan, con los defectos demostrados en ROJO antes de corregirlos.
- **T069 cerrada (16-11-2026)**: M1 a M167 detectadas en ambos bash; cobertura de 124 de 124 pruebas. M0 final, después de endurecer los tests, dio exactamente las 116 fallas y ocho verdes previstas en ambos bash. Las cuatro brechas de los oráculos (M15/TU22, M60/TR12, M62/TS14 y M132/TB04) se diagnosticaron y presentaron antes de editar, se vieron en ROJO contra el mutante y en VERDE sin mutar. No cambió el producto ni el número de pruebas. La tabla de T069 y el Registro de `tasks.md` contienen resultados y tiempos. Evidencia consolidada: `/Users/rodrigo-hinojosa/.cache/agentic-046/closure-20261115T235851-obh9ouin/mutations-final.json` y `mutations/results-final.md`.
- **T070 cerrada (16-11-2026)**: Ubuntu 24.04, 124 de 124; Alpine 3.24.1/Python 3.14.5, 40 de 40; TU02 consecutiva sin candado retenido, y consulta con un git que ignora TERM terminada por BusyBox en 12,132 s (límite 2 s más 10 s hasta KILL). Usuario no root, `CI=1`, repo copiado y sin saltadas. El primer Alpine carecía de dos dependencias: se completó la imagen desechable y se repitió sobre el mismo tar. Ver el Registro y `ubuntu.json`, `alpine.json`, `alpine-lock.json`, `alpine-ignore-term.json` en el directorio de cierre.
- **T071/T072 cerradas con la excepción previa del smoke (16-11-2026)**: los ocho e2e de 046 pasaron solos y dentro de la regresión completa. Esta ejecutó 62 casos, 61 en verde y el smoke en rojo en la línea 79, sin saltadas y stderr vacío, en 1.343,572 s. Se confirmó el mismo rojo sobre `10f22a7`, cuyo runtime y tests son idénticos a `origin/main=9608e4a`. El informe conserva rc 1; no es un 62/62 verde. QMD 016 y 041 pasaron, esta última con sus ocho fases y modelos sin cambios. Los arreglos fueron del arnés e2e, sin cambios de runtime; ver el Registro y `e2e-all.*`, `baseline-smoke.*`.
- **T074 cerrada (16-11-2026, 03:15:39 Santiago)**: 2104 ok y 0 fallas en ambos bash, con las 69/70 saltadas previstas y stderr vacío; las 124 con SIGPIPE ignorada pasan en ambos, sin saltadas y stderr vacío; TU16 sola da cinco verdes consecutivos, sin diagnóstico ni stderr. La falla original de 4/5 sigue no reproducida y con causa desconocida: no se declara corregida. `T074-verified.json` verifica TAP completos y huellas sin cambios; `host-active.json` dice complete. La base temporal propia fue retirada limpia, sin fuerza; para repetir M0/T067 se recrea sobre `10f22a7`.
- **T075/T076 hechas (16-11-2026)**: constitución `679b313`, implementación `f30ad4c` y documentos `9ed154b`, publicados; auditoría de bytes de líneas nuevas sin hallazgos y scripts de credenciales en 100755. El árbol intermedio del feat pasa las nueve pruebas de `quickstart-doc` en ambos bash, con stderr vacío. Huella de T074 conservada. PR #135 en borrador para adelantar CI, con FR-022 pendiente y sin cambios en agentes reales.
- **T077 pendiente de acceso y decisiones humanas**: SSH a ferrari terminó con `websocket: bad handshake` antes de inspeccionar linus; no hay inventario vivo nuevo. Privacidad y cabezas remotas verificadas en GitHub, sin escribir en esos repositorios. Las cinco huellas públicas y los puntos que se deben resolver están en [operator-review.md](operator-review.md). No asociar ni reiniciar el agente hasta revisar inventario, archivos en claro y llave. Se prepararon seis borradores de issues locales, sin publicarlos.

## 4. Decisiones del operador que no se reabren

- **13-11-2026**:
  - la cobertura es total;
  - el cifrado es por agente, con la marca `backup.sensitive`;
  - la credencial es la amplia, `GITHUB_PAT`;
  - el estado propio del agente entra, y el login de `/login` queda fuera;
  - se entrega en un solo PR.
- **14-11-2026**:
  - una llave de datos por almacén;
  - en un agente sensible, la configuración viaja cifrada;
  - la llave se fija con un paso explícito (`--configure-key`, que muestra la huella);
  - SC-002 se acota a lo que se mide.
- **15-11-2026**:
  - los nombres de bloque no delatan el contenido (D37). Se pidió un HMAC con la llave de datos, pero no es posible porque `pack` nunca tiene su parte privada; se implementó la forma equivalente;
  - con repositorio, el supervisor respeta `features.identity_backup.enabled: false`; con fork, como en `main`;
  - procesar archivo por archivo en `backup_store.py` queda para un issue (T086);
  - se acepta el costo de D37: perder la caché, o la primera corrida tras una restauración, sube todo una vez (en donna, unos 55 MB);
  - el tope del job `bats` sube a 45 min (PR #134, ya mergeado).
- **16-11-2026**: autoriza T075 y pide avanzar con la mayor autonomía posible mientras duerme, dejando solo validaciones y decisiones estrictamente humanas. Se prepara un PR borrador para correr CI; FR-022 sigue siendo obligatorio antes del merge.
- **Defaults declarados al operador**:
  - un agente sensible con fork y sin repositorio no empuja su vault;
  - al restaurar, toda pieza cifrada prueba la llave indicada y después las llaves ssh por defecto.

## 5. Qué sigue, en orden

1. **Llevar la rama sobre `main` (`9608e4a`) — Hecho el 15-11-2026**:
   - `git rebase origin/main` terminó sin conflictos; en ese momento la rama seguía sin push;
   - Git integró automáticamente `CHANGELOG.md`: conserva la entrada de `main` en `### Changed` y las de 046 en `### Added` y `### Fixed`;
   - verificado `VERSION`: `git show origin/main:VERSION` da 0.31.0 y la rama conserva 0.32.0;
   - `git range-diff 10f22a7..8463586 9608e4a..HEAD` muestra los dos parches equivalentes. Los commits ahora son `0f41236` y `3f11357`; ver el Registro de `tasks.md`.
2. **Checkpoint de T073 — Hecho**: 334 de 334 por bash y stderr vacío. La serie de TU16 y su diagnóstico están registrados; conservar la falla original como no reproducida, sin afirmar que está corregida.
3. **SC-007 — Hecho**: 30 ciclos, 101,8 MiB al final, comparado con T039 en el Registro.
4. **T068 y T069 — Hechas**: 167 anclas válidas, control sin mutar de 124 de 124 por bash, M0 final conforme y 167 mutaciones detectadas en ambos bash. No repetir el catálogo completo sin un cambio que lo justifique; conservar las cuatro correcciones de pruebas y sus evidencias.
5. **T070 — Hecha**: Ubuntu 124/124, Alpine 40/40, candado y TERM/KILL conformes. Evidencia en el Registro.
6. **T072, DOCKER_E2E — Hecha, con el alcance local y remoto distinguido**:
   - huellas en `pre-e2e-hashes.json` y `validated-046-hashes.json`; entre ellas solo cambió el arnés e2e;
   - `tests/docker-e2e-backup-repo.bats`, 8 de 8. T071 marcada;
   - regresión local completa histórica: 61 de 62; mismo smoke en rojo confirmado en la base, con runtime/tests idénticos a `origin/main`. Después del ajuste del arnés: cinco corridas completas locales 8/8 y regresión amd64 62/62, cero saltadas. Evidencia y alcance calificado en el Registro.
7. **T074 — Cerrada tras la tercera CI**: 2104/2104 en cada brazo y ninguna nueva saltada; TA06 corregida y confirmada. Se conservan la base local completa, las comprobaciones focales posteriores con SIGPIPE ignorada y stderr vacío, los cinco TU16 verdes y las estáticas conformes, con el puente de hashes explicado en el Registro.
8. **T075 — Hecha**: WIP sustituido por tres commits. Las dos guías rápidas van en el feat por la dependencia demostrada de `quickstart-doc`; 9/9 en ambos bash, stderr vacío. Modos y huellas conformes.
9. **Lo que sigue, según la autorización del 16-11 y las decisiones humanas pendientes**:
   - T076 y apertura del PR borrador #135, hechos; la CI de ambos bash y el e2e amd64 están verificados en los runs enlazados en el Registro; comprobar también la última cabeza solo documental;
   - preparar T077 con lecturas e inventario, y dejar al operador las decisiones sobre rutas, archivos en claro y la llave; después ejecutar T077 a T080;
   - T081 sigue abierta hasta adjuntar la evidencia real de linus y dejar el PR listo para revisión; no marcarla hecha solo por abrir el borrador;
   - T082 a T089, después del merge del operador: el despliegue en linus, donna y cbum, los issues y el cierre.

## 6. Herramientas

Están en `specs/046-agent-backup-repo/tools/`. Leen dos variables:

- `BR046_REPO`: el worktree; por defecto, tres niveles sobre `tools/`;
- `BR046_WORK`: el directorio de trabajo; por defecto, `~/.cache/agentic-046`.

| Herramienta | Uso |
| --- | --- |
| `run_checkpoint.sh TAG SUITE...` | Las suites en bash 5 y en 3.2, en secuencia; deja un resumen en `$BR046_WORK/checkpoints/TAG-bash{5,32}.sum` |
| `mutate.py [--check] [--only M1,M2] [--from M10]` | El corredor de mutaciones (T068) |
| `t067_render_diff.sh` | T067: el render y el crontab de la rama, comparados con los de `10f22a7` |
| `audit_added.py WORKTREE BASE RUTAS...` | La auditoría de bytes de las líneas agregadas: marcas combinantes, caracteres de control y emojis |
| `byte_audit_files.py ARCHIVOS...` | La misma auditoría sobre archivos enteros (para los nuevos, sin rastrear) |
| `check_doc_strings.py` | Cruza las cadenas citadas en los documentos con el código |
| `sc007_sim.py` | SC-007, el crecimiento del repositorio en 30 ciclos |

La lista de suites del checkpoint de T073:

```text
tests/backup-dest.bats tests/backup-store.bats tests/backup-repo-units.bats tests/backup-repo-restore.bats
tests/agent-repo-surface.bats tests/backup-status.bats tests/backup-config.bats tests/backup-identity-cmd.bats
tests/backup-identity-git.bats tests/backup-identity-lib.bats tests/backup-trigger-plugin-install.bats
tests/backup-vault-cmd.bats tests/backup-vault-git.bats tests/backup-vault-lib.bats tests/heartbeatctl.bats
tests/local-vault-backup.bats tests/restore-from-fork.bats tests/restore-unified.bats tests/start-services-*.bats
```

Requisitos del host:

- `bats` 1.13, `bash` 5.3 y `/bin/bash` 3.2, `yq` 4, `jq`, `git` con `git-http-backend`, `age` y `age-keygen`, `python3` 3.9, `ssh-keygen`, `shellcheck` y `perl`;
- `PATH` debe incluir `/opt/homebrew/bin`;
- el Mac no tiene `timeout` ni `flock`: las pruebas traen sus dobles en `tests/fixtures/backup-repo/bin/`.

## 7. Gotchas que costaron en esta feature

- Un tab es separador de espacio para `read`: un campo vacío colapsa con el siguiente. Hay que separar con `|`.
- El `dirname` del Mac trata como opción una ruta que empieza con `-`. Hay que pasarle la ruta absoluta.
- `setup.sh` vacía `RESTORE_IDENTITY_KEY` al cargarse: las pruebas la fijan después del `source`.
- Sin terminal, `read -p` no imprime su pregunta. Las pruebas del wizard reconocen el paso por su encabezado.
- En `main`, `_bi_run` del fork sale con 0 aunque el empuje falle. Es lateral y va a T086.
- Un parche en Python con formato `%` convierte `${x%%/*}` en `${x%/*}` en silencio. No hay que formatear con `%` un texto de shell.
- Con `?` en la ruta, una URI `file:` de SQLite sin escapar abre otro archivo vacío y la copia "pasa". La prueba tiene que mirar el contenido.
- Si un test no puede caer porque el código no puede producir el estado que vigila, la guardia es redundante. Hay que agregarle una pierna que la ejerza o quitarla (TR11 tiene la de un enlace que ya está en el destino).
- El `timeout` de BusyBox solo señala al hijo, y el doble de las pruebas señala al grupo, como GNU. La pata Alpine de T070 es la que lo mide.
