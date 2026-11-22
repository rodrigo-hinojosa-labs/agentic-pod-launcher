# Contract D: doctor y sondas veraces

## D1. Sonda de Atlassian (`docker/scripts/lib/token_health.sh`, `probe_atlassian`)

| Jira `<base>/rest/api/3/myself` | Confluence `<base>/wiki/rest/api/user/current` | Salida |
| --- | --- | --- |
| 2xx | no se consulta | `ok <código> <ms>` (igual que hoy) |
| 401 / 403 | no se consulta | `auth_fail <código> <ms> HTTP <código>` (igual que hoy) |
| 5xx, 000, otro distinto de 404 | no se consulta | `network ...` (igual que hoy) |
| 404 | 2xx | `ok <código> <ms> via confluence` |
| 404 | 401 / 403 | `auth_fail <código> <ms> confluence HTTP <código>` |
| 404 | 404, 5xx, 000 | `network <código> <ms> jira HTTP 404, confluence <HTTP código o curl exit N>` |

- `<base>` es la URL configurada sin `/` final y sin un `/wiki` final.
- Latencia: la suma de las dos consultas. Las dos usan el límite de 10 s de `_th_run_probe`.
- El mismo usuario y token para las dos; el token solo en el `-u` que la sonda ya usa.

## D2. Sonda de Claude (`probe_claude_oauth`) y su llamada en `check_token_health.sh`

- Con `CLAUDE_CODE_OAUTH_TOKEN` no vacío: `skipped 000 0 login by environment token (expiry not observable)`, sin leer el archivo de login.
- Sin ese token: igual que hoy.
- `check_token_health.sh` llama la sonda si existe el archivo de login **o** si el token de entorno no está vacío.

## D3. Doctor docker, heartbeat (`scripts/agentctl`, bloque 10)

- Lee `/workspace/scripts/heartbeat/state.json` y los campos `.last_run.status`, `.last_run.ts` y `.last_run.duration_ms`.
- `ok` → `Heartbeat last run: ok @ <ts> (<ms>ms)`; vacío o archivo ausente → el aviso de hoy; otro estado → el fallo de hoy.

## D4. Doctor y `backup-status`, ubicación y peso

- `backup-status` suma por unidad `location` (`main:.agent-backup/<u>` o `branch:backup/<u>`) y `legacy` (data-model §3); `--json` los expone con los mismos nombres.
- El doctor conserva el aviso de cachés > 800 MB de 046 y suma uno: `heartbeatctl backup-status --json` incluye `repo_size_kb` (API `GET /repos/{owner}/{repo}`, campo `size`, consultada a lo sumo una vez por día y guardada en el registro del destino); por encima de 1.048.576 KB (1 GB) el doctor avisa: `Agent repository is <N> MB; backups in main cannot be pruned without rewriting history (see README, Backups)`.

## D5. Invariantes que prueban los tests

- D-I1: la tabla D1 completa, con un `curl` falso que responde por URL (SC-010).
- D-I2: las pruebas existentes de `token-health-lib.bats`, `token-health-cmd.bats`, `token-health-claude-oauth.bats` y `agentctl-doctor-token-health.bats` pasan sin editarse, salvo las aserciones que codificaban la ruta o el campo equivocados del heartbeat (que se corrigen declarándolo).
- D-I3: con un `state.json` real en su ruta, el doctor informa la corrida; sin él, el aviso de hoy.
- D-I4: con el token de entorno, la sonda de Claude no lee el archivo de login (un archivo ilegible no cambia la salida).
