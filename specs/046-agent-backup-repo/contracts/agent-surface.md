# Contrato: lo que ven el operador y el agente

**Feature**: `046-agent-backup-repo` | Cubre FR-001, FR-003, FR-010, FR-015, FR-016, FR-017, FR-018, FR-019 y FR-024.

## A1. Wizard

### Paso nuevo

Va justo después del paso del fork y antes del paso de las notificaciones del heartbeat. Solo aparece en modo docker, como el paso de voz (D25 de [research.md](../research.md)). Los textos van en inglés, como el resto del wizard. `[encabezado]` representa el prefijo que el wizard ya usa en el título de cada paso.

```text
[encabezado] Agent repository (private backup + the agent's own work)
  A private GitHub repository that belongs to this agent. The launcher backs
  up the agent's full state to it (backup/* branches) and the agent keeps its
  own work there. Create it with an initial commit on main.

Associate a private repository with this agent? [y/N]
Repository URL (https://github.com/<owner>/<name>):
Does this agent handle sensitive data (health, finance, legal)? [y/N]
```

- La primera pregunta tiene "no" por defecto. Si la respuesta es "no", las otras dos no se hacen.
- La URL se valida con `validate_backup_repo_url`, que aplica la regla de `backup.repo.url` de [data-model.md](../data-model.md).
- **Una URL inválida**: con terminal, se vuelve a pedir. Sin terminal, el wizard termina con código 1 y un mensaje que nombra la regla. La pregunta no usa `ask_validated`, que al llegar al fin de la entrada vuelve a preguntar para siempre (M21 de [research.md](../research.md)).
- La tercera respuesta fija `backup.sensitive`.

### Token

En el paso del MCP de GitHub:

- si el MCP se activa, el token se pide como hoy;
- si el MCP no se activa y hay un repositorio asociado, se pide con este texto:

```text
  The agent repository needs a GitHub token to push.
GitHub Personal Access Token for the agent repository:
  (Press Enter to skip — fill GITHUB_PAT in .env later.)
```

`GITHUB_PAT` se escribe en el archivo de secretos cuando el MCP está activo o cuando hay un repositorio asociado.

### Resumen y edición

El resumen final gana tres ítems, **al final de la lista**, para no cambiar el número de los que ya existen:

| Ítem | Muestra | Al editarlo |
| --- | --- | --- |
| 24 | El repositorio del agente: su URL, o que no hay | Vuelve a hacer la pregunta y la de la URL. Si queda con repositorio y no hay token, lo pide |
| 25 | Si el agente maneja datos sensibles | Vuelve a hacer la pregunta |
| 26 | Si hay un token para el repositorio: `set` o `not set`, nunca el valor | Lo vuelve a pedir |

En modo local los tres ítems no aparecen.

### Puntos de contacto de las pruebas

Agregar una pregunta al wizard rompe lugares conocidos. Todos se actualizan en la misma tarea:

1. `wizard_answers()` de `tests/helper.bash`: una respuesta `n` después de la del fork, solo cuando el modo es docker;
2. el arreglo de respuestas de `tests/e2e-smoke.bats`;
3. las dos listas `known_external` de `tests/schema.bats`, con los marcadores derivados;
4. la lista de claves de primer nivel de `tests/schema.bats`, que gana `backup` para `tests/fixtures/sample-agent-with-vault.yml`;
5. la lista de validadores de `tests/quickstart-doc.bats`, que gana `validate_backup_repo_url`, junto con la tabla de validaciones de los dos documentos de quickstart.

## A2. `agent.yml` y `--regenerate`

- El heredoc del wizard escribe las claves nuevas de la sección 1 de data-model, en los dos modos y con sus valores por defecto.
- `regenerate()` completa cada clave que falte con `has()` y sus valores por defecto. No toca una clave que ya existe, aunque valga `false` o esté vacía.
- Un agente que ya existe adopta la feature editando `agent.yml`, corriendo `./setup.sh --regenerate` y fijando su llave (más abajo). No hay que volver a crearlo.

### Avisos de `--regenerate`

`--regenerate` revisa lo que falta y lo dice por stderr. No elige ninguna llave ni escribe ningún secreto (D29 de [research.md](../research.md)). Las tres primeras filas valen con `backup.repo.url` no vacío.

| Situación | Línea |
| --- | --- |
| Modo docker, sin `backup.identity.recipient` | `WARN: backup.repo is set but there is no encryption key - encrypted backups will not run. Set one with: docker exec -u agent <agente> heartbeatctl backup-identity --configure-key "<public key>"` |
| Modo docker, sin `GITHUB_PAT` con valor en el archivo de secretos | `WARN: backup.repo is set but GITHUB_PAT is missing in .env - backups cannot push` |
| Modo local | `WARN: backup.repo is docker-only - ignored in local mode` |
| Modo docker, con `backup.sensitive: true` y sin `backup.repo.url` | `WARN: backup.sensitive is set but there is no agent repository - the vault will not be backed up` |
| Modo local, con `backup.sensitive: true` | `WARN: backup.sensitive is docker-only - the local vault backup stays in plaintext` |

- La segunda comprobación mira solo si el valor existe, con `env_file_get`, y nunca lo imprime.
- En modo local no cambia ningún archivo derivado.

### La llave del operador

- **En un agente nuevo**, el scaffold llama a `configure_identity_backup`, como hoy. El dueño sale del fork si existe y, si no, de la URL del repositorio asociado. Cuando fija una llave tomada de GitHub, imprime su huella y su comentario:

```text
  [ok] backup encryption: using SSH key from github.com/<owner>.keys
    SHA256:<huella>  <comentario>
    Confirm you hold the private half of this key: without it the encrypted
    backups cannot be restored. To use another key:
      heartbeatctl backup-identity --configure-key <path|pubkey>
```

- **En un agente que ya existe**, la llave se fija siempre con `heartbeatctl backup-identity --configure-key`, que muestra la huella (U2 de [backup-units.md](backup-units.md)).

## A3. Contexto del agente (`modules/claude-md.tpl`)

### Sin repositorio asociado

La sección `## Backups (what actually survives)` se renderiza **idéntica byte a byte** a la de `main`. Su texto sigue siendo verdadero para ese caso.

### Con repositorio asociado

Esa sección se reemplaza por esta, y se agrega la siguiente:

```markdown
## Backups (what actually survives)

Your state is backed up to your own private repository, `{{BACKUP_REPO_URL}}`, in independent orphan branches that belong to the launcher (each is hash-idempotent: no change, no commit):

| Branch | Content | Trigger |
|---|---|---|
| `backup/identity` | chat pairing, plugin config, settings and the encrypted `.env` (which holds your Claude token) | the supervisor pushes it when the identity hash changes (checked every 60s) and after plugin installs; daily 03:30 cron by default. Manual: `heartbeatctl backup-identity`. |
| `backup/vault` | the vault's markdown, encrypted when this agent is marked as sensitive | hourly cron by default (`vault.backup_schedule`). Manual: `heartbeatctl backup-vault`. |
| `backup/config` | `agent.yml`, your persona, `CLAUDE.md` and the workspace's `.claude/` project config; everything but `agent.yml` is encrypted when this agent is marked as sensitive | daily 03:30 cron by default. Manual: `heartbeatctl backup-config`. |
| `backup/memory` | your auto memory, the claude-mem store and any extra paths the operator declared (`backup.extra_paths`) | daily 03:40 cron by default. Manual: `heartbeatctl backup-memory`. |
| `backup/history` | your conversation transcripts, always encrypted | daily 03:50 cron by default. Manual: `heartbeatctl backup-history`. |

The operator can disable a unit or change its schedule in `agent.yml`. `heartbeatctl backup-status` shows which units are enabled and where each one stands. If the user asks how durable your state is, answer from that command, not from memory.

## Your repository

`{{BACKUP_REPO_URL}}` is yours, and it has two roles:

- **Work**: a clone lives at `{{BACKUP_REPO_WORKDIR}}`. Features you build for yourself go there, on working branches (`main` and feature branches). Push them with plain `git push` from that clone: its credential is already configured. Work that is not pushed is not backed up.
- **Backup**: the `backup/*` branches hold your recoverable state. They belong to the launcher. Never check them out, commit to them, rebase them or delete them, and do not fetch them into your clone.
- **Not covered**: state you keep anywhere else is not backed up. If you start keeping state in a new place (a config directory for a tool you built, a credentials store), tell the operator so they can add it to `backup.extra_paths` in `agent.yml`.
```

- **Las etiquetas van pegadas al texto**: el motor reemplaza por nada un bloque que no se renderiza y deja los saltos de línea que rodean a sus etiquetas (M21 de [research.md](../research.md)). Para que el caso sin repositorio no gane ni pierda una línea, la plantilla queda así, sin ningún salto de línea entre una etiqueta y el texto que encierra:

```text
{{#unless BACKUP_REPO_ENABLED}}## Backups (what actually survives)
...el texto de hoy, sin cambiar un byte...{{/unless}}{{#if BACKUP_REPO_ENABLED}}## Backups (what actually survives)
...el texto nuevo...{{/if}}
```

- El motor no admite `{{#if}}` anidados: los dos bloques van en el nivel superior de la plantilla.
- El texto es ASCII. Las horas del cron de la tabla son los valores por defecto; la plantilla no interpola los `schedule`, y por eso el texto remite a `backup-status` para saber qué unidades están habilitadas.

## A4. Clon de trabajo

Una librería nueva, `docker/scripts/lib/agent_repo.sh`, con su línea `COPY`, define `agent_repo_ensure`. La llaman dos lugares:

- `main()` de `start_services.sh`, una vez por arranque del contenedor, en segundo plano, después de `qmd_watch_start`. No se llama desde `_run_watchdog`, cuyo cuerpo está congelado;
- `heartbeatctl backup-config`, al terminar, con un repositorio asociado (U3 de [backup-units.md](backup-units.md)).

| Condición | Acción |
| --- | --- |
| El destino no es `repo` | Nada, sin log |
| Falta `GITHUB_PAT` | Nada; una línea de log |
| `/workspace/agent-repo` no existe | `git init`, remoto, las dos configuraciones de la sección 7 de data-model, `fetch` con un tope de 120 s y extracción de la rama de trabajo |
| Existe y es un repositorio git | Solo asegura las dos configuraciones |
| Existe y no es un repositorio git | Nada; una línea de log |

**Qué rama queda extraída**, en este orden:

1. la rama por defecto del remoto, si no es una rama `backup/*`;
2. `main`, si existe en el remoto;
3. la primera rama de trabajo del remoto, en orden alfabético;
4. si el remoto no tiene ninguna rama de trabajo (está vacío, o solo tiene ramas `backup/*`), una rama `main` local sin commits.

- Nunca se extrae una rama `backup/*`.
- La ruta del clon sale de `agent_repo_dir`, que vale `${AGENT_REPO_DIR:-${WORKDIR:-${HEARTBEATCTL_WORKSPACE:-/workspace}}/agent-repo}`: `start_services.sh` define `WORKDIR`, y `heartbeatctl` no.
- Todo corre como `agent`. Una falla se registra y no afecta al arranque ni a la unidad `config`.
- El `fetch` del clon de trabajo usa el ayudante de A5, no el askpass de los respaldos.
- Si la creación falla a medias, el directorio se borra, para que el intento siguiente parta de cero.

## A5. Ayudante de credenciales del clon de trabajo

`docker/scripts/git-credential-agent.sh`, en `sh` POSIX, con su línea `COPY`:

```sh
#!/bin/sh
# git credential helper for the agent's work clone. Answers `get` from the environment.
[ "${1:-}" = get ] || exit 0
[ -n "${GITHUB_PAT:-}" ] || exit 0
printf 'username=%s\npassword=%s\n' "x-access-token" "$GITHUB_PAT"
```

Se configura con `credential.<esquema>://<servidor>.helper`, así que git solo lo consulta para el servidor del repositorio del agente, precedido de un valor vacío que reinicia los ayudantes heredados (un `credential.helper=store` global guardaría el token en claro bajo `.state/`). La configuración del clon guarda la ruta del script, nunca el valor. El clon se crea sin el token en ningún argumento: `GITHUB_PAT` llega al ayudante por el entorno heredado (I2).

## A6. `heartbeatctl backup-status`

```text
heartbeatctl backup-status [--json]
```

Con `--json`:

```json
{
  "destination": { "kind": "repo", "url": "https://github.com/owner/name", "verdict": "private", "checked_at": "2026-11-13T15:00:00Z" },
  "credential": "present",
  "sensitive": false,
  "recipient": { "configured": true, "type": "ssh-ed25519", "fingerprint": "SHA256:...", "comment": "..." },
  "extra_paths": { "declared": 2, "missing": [], "bytes": 2306867 },
  "units": [
    { "unit": "identity", "enabled": true, "last_push": "...", "last_attempt": "...", "last_result": "ok", "max_age_hours": 48, "cache_bytes": 1048576 }
  ],
  "cache_bytes_total": 61865984,
  "work_clone": { "path": "/workspace/agent-repo", "present": true, "unpublished_commits": 0, "dirty_files": 0 }
}
```

- `credential` vale `present` o `missing`. El comando nunca imprime el valor.
- `units` trae las cinco unidades, cada una con el umbral que le corresponde: `identity` 48 h, `vault` 25 h, `config` 192 h, `memory` 49 h e `history` 49 h. Los tres primeros son los de hoy.
- `cache_bytes` es el tamaño de la caché de la unidad, que aproxima lo que su rama ocupa en el repositorio; `cache_bytes_total` es la suma (D35 de [research.md](../research.md)).
- `extra_paths.declared` es la cantidad de rutas de `backup.extra_paths`, `extra_paths.missing` lista las que no existen o no cumplen la regla, y `extra_paths.bytes` es el tamaño de las que existen.
- `work_clone.present` dice si el clon existe. `unpublished_commits` cuenta los commits de sus ramas locales que no están en ninguna rama remota.
- Sin `--json`, imprime una tabla legible con los mismos datos.
- Con el tipo `fork` o `none`, entrega el destino y las tres unidades de hoy, leídas de sus archivos de estado.
- El comando no toca la red y no modifica nada.

## A7. `agentctl doctor`

Con un repositorio asociado, la parte de respaldos del diagnóstico pasa a mostrar estas líneas. `[ok]` y `[aviso]` representan los prefijos que el diagnóstico ya usa:

```text
[ok]    Backup destination: repo https://github.com/owner/name (private, checked 2h ago)
[ok]    Backup identity: pushed 3h ago
[aviso] Backup history: last attempt failed (push-failed); last good push 3d ago
[aviso] Backup memory: never pushed yet
[ok]    Backup encryption key: ssh-ed25519 SHA256:... (comment)
[aviso] Agent repository clone: 2 unpublished commits, 1 uncommitted file
[aviso] Agent repository clone: missing at /workspace/agent-repo
[aviso] Backup extra paths: 1 of 2 declared paths is missing (.custom)
[aviso] Backup size: 0.9 GB in the backup caches - prune a backup branch (see README)
```

- Los datos salen de `heartbeatctl backup-status --json`, ejecutado con `docker exec -u agent`. Si el contenedor corre y ese comando falla, el diagnóstico lee los archivos de estado, como hoy. Con el contenedor caído no hay nada que cambiar: el diagnóstico ya termina antes de llegar a los respaldos.
- Una advertencia por cada una de estas situaciones:
  - el último intento falló;
  - el último respaldo correcto supera el umbral;
  - el veredicto no es `private` ni `unverified-allowed`;
  - falta la credencial;
  - falta la llave pública y hay algo que debe ir cifrado;
  - una ruta adicional declarada no existe;
  - el clon de trabajo falta, o tiene commits sin publicar o archivos sin commitear;
  - la suma de las cachés pasa de 800 MB.
- Sin repositorio asociado, la salida del diagnóstico es la de hoy, incluidas las tres advertencias de un agente sin fork.
- El diagnóstico no cambia su contrato de salida (0, 1 o 2): estas advertencias cuentan como las demás.

## A8. Otros archivos derivados, limpieza y documentos

- **`modules/next-steps.en.tpl` y `modules/next-steps.es.tpl`**: el bloque de docker de esas plantillas ya es un solo condicional, y el motor no admite anidarlos. El texto sobre el repositorio del agente (una fila y los comandos nuevos) llega por el marcador `{{BACKUP_REPO_NEXT_STEPS}}`, que `setup.sh` renderiza antes y que queda vacío sin repositorio.
- **`modules/env-example.tpl`**: la línea `GITHUB_PAT=` pasa a depender de `GITHUB_PAT_NEEDED`, que vale `true` con el MCP de GitHub activo o con un repositorio asociado. Sin repositorio, el archivo renderizado es el de hoy.
- **`.gitignore`** del launcher, que cada workspace hereda: se agrega `/agent-repo/`.
- **`./setup.sh --uninstall --nuke`**: si `agent-repo` tiene commits que no están en ninguna rama remota, o archivos sin commitear, lo dice antes de borrar el workspace. Con `--yes` lo dice y sigue.
- **Documentos**: `README.md`, `docs/architecture.md`, `docs/heartbeatctl.md`, `docs/getting-started.md`, `docs/creating-an-agent.md`, `docs/adding-an-mcp.md`, `docs/state-layout.md` y `docs/vault.md`. Cubren la regla de destino, las cinco unidades, el almacén y su llave de datos, la restauración, el recorte de una rama, cómo adoptar la feature en un agente que ya existe y que `GITHUB_PAT` ya no es solo del MCP.
