# Contrato: destino, credencial, privacidad y pertenencia

**Feature**: `046-agent-backup-repo` | Cubre FR-002, FR-004, FR-005, FR-006, FR-007, FR-013 y FR-018.

Todo lo de este contrato vive en una librería nueva, `docker/scripts/lib/backup_dest.sh`, y en un script horneado, `docker/scripts/git-askpass-agent.sh`. Los dos llevan su línea `COPY` en `docker/Dockerfile`.

La librería no arma árboles, no hace commits, no empuja y no calcula el hash de ninguna unidad. Lo único que escribe en el archivo de estado de una unidad es el registro de su último intento (C5).

## C1. Regla de destino

```text
backup_dest_resolve [AGENT_YML]
  stdout: "<tipo>\t<url>"     tipo: repo | fork | none   (url vacía con none)
  rc: 0 siempre
```

| Entrada | Salida |
| --- | --- |
| `backup.repo.url` no vacío y distinto de `null` | `repo` y esa URL |
| En otro caso, `scaffold.fork.url` no vacío y distinto de `null` | `fork` y esa URL |
| En otro caso | `none` |

- `AGENT_YML` vale `/workspace/agent.yml` por defecto. La variable `BACKUP_DEST_AGENT_YML` lo reemplaza en las pruebas.
- Un `agent.yml` ausente o ilegible da `none`.
- La función es de solo lectura.

**Quién la llama**: los tres comandos de respaldo que ya existen en `heartbeatctl`, los dos nuevos, `backup-status`, y `_identity_backup_fork_configured` de `start_services.sh` (`:1123`). Esta última conserva su nombre y solo cambia por dentro: la llama `_check_identity_backup` (`:1145`), que corre desde `_run_watchdog` (`:1280`), y el cuerpo de `_run_watchdog` está congelado por un oráculo de sha.

**Lo que no cambia**: `modules/local-vault-backup.sh.tpl` sigue leyendo `scaffold.fork.url` por su cuenta. El modo local queda fuera de esta feature (FR-019).

## C2. Entorno de git

Los tres envoltorios de git que ya existen (`_identity_git`, `_vault_git` y `_config_git`) **no cambian**. El camino `fork` los sigue usando tal cual.

El camino `repo` de cada unidad usa un envoltorio propio y nuevo (`_identity_repo_git`, `_vault_repo_git`, `_config_repo_git`, `_memory_repo_git` y `_history_repo_git`). Todos fijan lo mismo:

| Variable | Valor | Para qué |
| --- | --- | --- |
| `GIT_TERMINAL_PROMPT` | `0` | Nunca pregunta por la terminal |
| `GIT_ASKPASS` | La salida de `backup_dest_askpass` | La credencial llega por el askpass |
| `GIT_CONFIG_GLOBAL` | `/dev/null` | El `~/.gitconfig` del agente no altera el respaldo (D32 de [research.md](../research.md)) |
| `GIT_CONFIG_NOSYSTEM` | `1` | Lo mismo para la configuración de sistema |
| `LC_ALL` | `C` | Los mensajes de git no se traducen, y C3 los puede reconocer |

Además, todos envuelven la llamada en `timeout -k 10 N` cuando `timeout` existe (C6). Los commits del camino `repo` también pasan por ese envoltorio.

```text
backup_dest_askpass TIPO
  stdout: ruta del askpass
```

| Tipo | `GITHUB_PAT` | Salida |
| --- | --- | --- |
| `repo` | No vacía | `${BACKUP_ASKPASS_OVERRIDE:-/opt/agent-admin/scripts/git-askpass-agent.sh}` |
| `repo` | Vacía o ausente | `/bin/true` |
| `fork` o `none` | Cualquiera | `/bin/true` |

### El askpass

`docker/scripts/git-askpass-agent.sh`, en `sh` POSIX (la extensión hace que el job `shellcheck` de la CI lo revise):

```sh
#!/bin/sh
# Answers git's credential prompts from the environment. Prints nothing else.
case "$1" in
  Username*) printf '%s\n' "x-access-token" ;;
  Password*) printf '%s\n' "${GITHUB_PAT:-}" ;;
esac
```

- No escribe en stderr ni en ningún archivo.
- El valor no pasa por argumentos, URL ni configuración de git (medido en M2 y M3 de [research.md](../research.md)).

## C3. Privacidad y cabezas del repositorio

```text
backup_dest_verify URL [ARCHIVO_DE_CABEZAS]
  stdout: private | unverified-allowed | unverified | public | unreachable
  efecto: actualiza scripts/heartbeat/backup-dest.json; si recibe ARCHIVO_DE_CABEZAS,
          deja ahí la salida de la consulta autenticada
```

0. **Regla de la URL**: si la URL no cumple la regla de `backup.repo.url` de [data-model.md](../data-model.md), el veredicto es `unreachable` y no se hace ninguna consulta.
1. **Sonda anónima**, solo cuando hace falta: `git -c credential.helper= ls-remote --heads URL`, con `GIT_ASKPASS=/bin/true` y un tope de 60 segundos. Se omite cuando el registro tiene la misma URL, el veredicto `private` y menos de 86.400 segundos desde `anon_checked_epoch`. Su resultado se lee así:

   | Resultado de la sonda | Significa |
   | --- | --- |
   | Termina con 0 | El repositorio es público. Veredicto `public`; no se sigue |
   | Falla, y su stderr trae `Authentication failed`, `could not read Username` o `terminal prompts disabled` | El servidor pide credencial: es lo que se espera de un repositorio privado |
   | Falla por cualquier otra razón, o agota su tope | No se pudo comprobar |

2. **Consulta autenticada**, en cada corrida: el mismo comando con el askpass de C2 y el mismo tope. Si falla, el veredicto es `unreachable`.
3. **Veredicto**, si la consulta autenticada funcionó:

   | Sonda anónima | `allow_unverified` | Veredicto |
   | --- | --- | --- |
   | El servidor pidió credencial (ahora, o en una sonda vigente) | Cualquiera | `private` |
   | No se pudo comprobar | `false` | `unverified` |
   | No se pudo comprobar | `true` | `unverified-allowed` |

```text
backup_dest_branch_head ARCHIVO_DE_CABEZAS RAMA
  stdout: el commit de refs/heads/RAMA, o vacío si la rama no existe
```

- La consulta autenticada es la comprobación previa de cada unidad, y corre también cuando no hay cambios (D20 de [research.md](../research.md)). Por eso una credencial que dejó de servir se ve en el ciclo siguiente.
- `allow_unverified` no salta la sonda anónima y nunca habilita un repositorio que respondió sin credencial (D31).
- El plazo de la sonda anónima se cuenta desde la última sonda anónima, no desde la última corrida. Si se contara desde la última corrida, la sonda no se repetiría nunca.
- El archivo de cabezas se escribe dentro de la caché de la unidad, nunca en `/tmp`.
- Con `BACKUP_DEST_ALLOW_HTTP=1` la regla de la URL admite además `http://` hacia `127.0.0.1`, `localhost` y `host.docker.internal`. Existe para las pruebas, que usan un servidor local.

## C4. Marca de pertenencia

```text
backup_dest_check_owner CLONE_DIR RAMA AGENTE UNIDAD
  stdout: new | ok | foreign | other-agent
```

| Situación | Salida |
| --- | --- |
| `origin/RAMA` no existe | `new` |
| Existe, y su `.agentic-pod-backup.json` nombra a `AGENTE` y `UNIDAD` | `ok` |
| Existe y no tiene ese archivo | `foreign` |
| Existe y el archivo nombra a otro agente o a otra unidad | `other-agent` |

La marca se lee con `git show origin/RAMA:.agentic-pod-backup.json`, sin extraer el árbol. Solo se usa con el tipo `repo`.

## C5. Registro del intento

```text
backup_dest_record UNIDAD RESULTADO [HASH_INTENTADO]
```

Fusiona `last_attempt`, `last_attempt_epoch`, `last_result` y `attempt_hash` en `scripts/heartbeat/UNIDAD-backup.json`. Si no recibe el hash, porque el intento terminó antes de calcularlo, deja `attempt_hash` vacío. Conserva los demás campos y escribe de forma atómica (archivo temporal y `mv`). Solo se llama con el tipo `repo`. Los resultados y sus códigos de salida están en la sección 4 de [data-model.md](../data-model.md).

No toca `hash`, `last_commit` ni `last_push`: esos son de la unidad.

## C6. Tiempos máximos

| Operación | Tope |
| --- | --- |
| La sonda anónima y la consulta autenticada de C3 | 60 s cada una (`BACKUP_PROBE_TIMEOUT_S`) |
| `fetch` y `push` de `identity`, `vault` y `config` | 60 s cada uno (`BACKUP_GIT_TIMEOUT_S`) |
| `fetch` y `push` de `memory` y de `history` | `BACKUP_PUSH_TIMEOUT_S`, 900 s por defecto |
| El disparador del supervisor para `identity` | 300 s con `-k 10` con un repositorio asociado; 90 s con fork, como hoy |

- Dentro del contenedor el tope se aplica con `timeout -k 10 N`: el `timeout` de BusyBox solo envía TERM, y un hijo que lo ignora bloquearía el tope (gotcha de 041).
- **Donde no existe `timeout`**, como en el Mac, no hay tope. La imagen lo trae (M20 de [research.md](../research.md)), y las pruebas del host ponen uno propio en el PATH.
- **La comprobación previa** (pasos 1 y 2 de C3) termina en 120 segundos como máximo. Es lo que acota SC-006: con la credencial inválida o el destino inalcanzable, ninguna unidad pasa de ahí.
- **El peor caso de `identity`** suma 240 segundos (dos consultas, un `fetch` y un `push`), bajo los 300 del disparador. Así el supervisor nunca corta la unidad antes de que registre su resultado.
- **El `fetch` de `memory` y de `history`** usa el tope largo porque, tras una restauración o si se pierde la caché, baja el almacén entero.

## C7. Un candado por unidad

Cada corrida con el tipo `repo` toma un candado propio de su unidad antes de hacer nada:

```text
flock -n 9   sobre   scripts/heartbeat/.backup-<unidad>.lock
```

- Si el candado está tomado, la corrida imprime `backup-<unidad>: another run holds the lock - skipping`, sale con 0 y no registra ningún resultado.
- La corrida suelta el candado de forma explícita al terminar (`flock -u 9`). Sin eso, un hijo del `timeout` de BusyBox lo retiene cerca de un segundo más (lección de 044).
- Donde no existe `flock`, como en el Mac, la unidad corre sin candado. Las pruebas del host ponen uno propio en el PATH.

## C8. Invariantes

- **I1**: con el tipo `fork` o `none`, ninguna unidad ejecuta código de C2 (envoltorios nuevos), C3, C4, C5 ni C7. Sus mensajes, sus códigos de salida y sus archivos de estado son los de hoy.
- **I2**: el valor de `GITHUB_PAT` no aparece en ningún argumento, URL, archivo de configuración de git, log ni archivo de estado.
- **I3**: ningún camino de este contrato pregunta nada por la terminal ni termina al supervisor.
- **I4**: con el veredicto `public`, `unverified` o `unreachable` no se ejecuta ningún `push`.
- **I5**: una sonda anónima que falla por la red nunca produce el veredicto `private`.
