# Contract M: una unidad respalda en `main`

Aplica solo cuando `backup_dest_resolve` responde `repo`. Con `fork` o `none` no corre ninguna línea de este contrato (FR-019).

## M1. Entradas y salidas

- Entradas: las mismas de 046 por unidad (mapas, hash de contenido, destinatario, estado), más `last_tree` del estado.
- Salida en stdout, una línea, con los mensajes de 046 y los nuevos:

| Resultado | Mensaje | rc |
| --- | --- | --- |
| ok | `backup-<u>: <sha8> pushed` (el mismo texto de 046; el destino lo dice `backup-status`) | 0 |
| no-change | `backup-<u>: no changes since last backup (hash <h>)` | 0 |
| main-busy | `backup-<u>: main kept moving - nothing pushed, retrying next cycle` | 2 |
| main-protected | `backup-<u>: main is protected and the pull request could not be merged - nothing pushed` | 2 |
| foreign-dir | `backup-<u>: .agent-backup/<u> exists in main and is not a launcher backup - refusing to write` | 0 |
| other-agent | `backup-<u>: .agent-backup/<u> in main belongs to another agent - refusing to write` | 0 |
| no-main | `backup-<u>: the repository has no main branch - nothing pushed` | 0 |

Los resultados de 046 (`no-credential`, `no-recipient`, `not-private`, `unverified`, `unreachable`, `push-failed`, `error`) conservan su texto y rc.

## M2. Pasos

1. `_repo_begin` y `_repo_verify` como en 046. Del archivo de heads se leen `refs/heads/main` (si falta: `no-main`) y `refs/heads/backup/<u>` (para M8).
2. Preparar la caché `<u>-main` (data-model §2): `init`, remoto, filtro `blob:none`, checkout parcial; `fetch --depth 1 origin main`.
3. Leer el subárbol remoto `R = rev-parse FETCH_HEAD:.agent-backup/<u>` (vacío si no existe) y la marca, si existe, desde `FETCH_HEAD:.agent-backup/<u>/.agentic-pod-backup.json` (un blob). Marca ausente con directorio presente: `foreign-dir`; de otro agente o unidad: `other-agent`.
4. Idempotencia (R3): si `hash == state.hash` y `R == state.last_tree` y `R` no está vacío: `no-change` y pasar a M8.
5. Si `R` no está vacío y `R != state.last_tree` y `state.last_tree` no está vacío: escribir `backup-<u>: .agent-backup/<u> in main was changed outside the launcher - restoring it` en stderr (FR-008).
6. Checkout del directorio de la unidad (baja solo sus blobs), vaciarlo (conservar `store/` cuando 046 lo conserva), preparar el contenido con las funciones de 046 apuntando a `<caché>/.agent-backup/<u>/`, escribir la marca y, para config, `.agent-backup/README.md`.
7. Construir el commit (R1): (a) árbol de la unidad con un índice temporal que contiene solo sus rutas (`GIT_INDEX_FILE` aparte, `add` de `.agent-backup/<u>/`, `write-tree --prefix=.agent-backup/<u>/`); (b) árbol `.agent-backup` = `ls-tree FETCH_HEAD:.agent-backup` con la entrada `<u>` reemplazada (y `README.md` para config), por `mktree --missing`; (c) árbol raíz = `ls-tree FETCH_HEAD` con la entrada `.agent-backup` reemplazada, por `mktree --missing`; (d) `commit-tree -p FETCH_HEAD` con autor, asunto y trailer de data-model §4. Ningún paso lee blobs fuera del directorio de la unidad.
8. Empujar `<commit>:refs/heads/main` sin `--force`.
   - Aceptado: seguir.
   - Rechazo por no fast-forward: `fetch --depth 1 origin main` y repetir 7 y 8, hasta 5 intentos con espera aleatoria de 1 a 5 s; agotados: `main-busy`.
   - Rechazo por protección: contrato P.
9. Verificar después (R6): nuevo `fetch --depth 1 origin main` y `rev-parse FETCH_HEAD:.agent-backup/<u>` debe ser igual al árbol empujado. Si difiere (otra persona ya lo cambió en el instante siguiente), el respaldo cuenta como `ok` pero `legacy_branch` no avanza este ciclo.
10. Estado: `hash`, `last_commit`, `last_push`, `last_tree`, `location: main`, `store_recipient`; `backup_dest_record <u> ok`.
11. Migración de la rama heredada: contrato L.

## M3. Invariantes que prueban los tests

- I1: `git diff --name-only <padre> <commit>` solo lista rutas bajo `.agent-backup/<u>/` (y `.agent-backup/README.md` para config). Nunca otra.
- I2: ningún empuje usa `--force`, `+refspec` ni borra `main`.
- I3: todo commit ajeno que estaba en `main` antes del empuje sigue siendo ancestro de `main` después.
- I4: con el mismo contenido y sin cambios ajenos en el directorio, la segunda corrida no crea commits.
- I5: nada que 046 cifra aparece en claro bajo `.agent-backup/` (mismo oráculo de 046 sobre la nueva raíz).
- I6: con fork o sin destino, salidas, códigos, estado y crontab iguales a los dorados de 046.
- I7: el token nunca aparece en `argv`, en la URL del remoto ni en `.git/config` de la caché (oráculos de 046).
- I8: un ciclo con cambios no pide al servidor ningún blob fuera de `.agent-backup/<u>/` (log del servidor de prueba).
