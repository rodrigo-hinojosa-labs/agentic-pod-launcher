# Data Model: 048-fleet-backup-main

## 1. Layout en `main` del repositorio del agente

```text
<raíz de main>/                       # trabajo del agente y del operador (no lo toca ningún respaldo)
└── .agent-backup/
    ├── README.md                     # dueño: unidad config (R8)
    ├── identity/                     # dueño: unidad identity
    │   ├── .agentic-pod-backup.json  # marca de propiedad {schema:1, agent, unit}
    │   └── <mismo contenido que la raíz de backup/identity en 046>
    ├── vault/
    ├── config/
    ├── memory/
    └── history/
```

- El contenido de cada `<unidad>/` es byte a byte el árbol que 046 dejaba en la raíz de `backup/<unidad>` (archivos en claro permitidos, `store/` cifrado, marca). Ningún formato cambia (FR-004).
- La marca vive dentro del directorio de la unidad; `backup_dest_check_owner` pasa a leer `<ref>:.agent-backup/<unidad>/.agentic-pod-backup.json` en el camino de `main` y conserva la lectura de la raíz para la rama heredada.

## 2. Caché de cada unidad (`/home/agent/.cache/agent-backup/<unidad>-main`, identity en `identity-backup/identity-main`)

| Propiedad | Valor |
| --- | --- |
| Rama local | `main`, sin seguimiento |
| Clon | `--filter=blob:none`, `fetch --depth 1 origin main` |
| Checkout parcial | modo NO cono, patrón `/.agent-backup/<unidad>/` (config: además `/.agent-backup/README.md`); medido en T002 que el modo cono baja los archivos de la raíz |
| Mapa de bloques, mapas de la unidad | junto a la caché, fuera del árbol, con prefijo `<unidad>-main`; el mapa de bloques de 046 (`<unidad>-repo.blockmap`) NO se reutiliza, así que el primer ciclo tras actualizar es una subida completa del almacén (costo aceptado, como D37 de 046; M3 lo mide) |
| Caché de 046 (`<unidad>-repo`) | se conserva mientras exista la rama heredada; se borra cuando la rama se borra (R6) |

El nombre nuevo (`-main`) evita reutilizar una caché cuya `HEAD` apunta a `backup/<unidad>`.

## 3. Estado de la unidad (`scripts/heartbeat/<unidad>-backup.json`)

Campos de 046 que siguen igual: `hash`, `last_commit`, `last_push`, `store_recipient`, y los del último intento (`last_attempt`, `last_attempt_epoch`, `last_result`, `attempt_hash`).

Campos nuevos (solo camino de repositorio):

| Campo | Tipo | Significado |
| --- | --- | --- |
| `location` | `"main"` \| `"branch"` | dónde quedó el último respaldo aceptado |
| `last_tree` | sha | id del árbol `.agent-backup/<unidad>` que la unidad empujó (R3) |
| `legacy_branch` | `"present"` \| `"deleted <ISO>"` \| `"none"` \| `"kept: <motivo>"` | estado de `backup/<unidad>` (R6) |
| `pr_fallback` | objeto o ausente | `{number, result, at}` del último camino de pull request (R7) |

Resultados nuevos de `last_result`: `main-busy` (R4), `main-protected` (R7), `legacy-kept` (la rama heredada no se borró y por qué; no es un fallo del respaldo). Los de 046 se conservan.

## 4. Commit de respaldo

| Elemento | Valor |
| --- | --- |
| Autor y committer | `agentic-pod-backup <backup@agentic-pod.invalid>` |
| Asunto | `backup(<unidad>): <agente> <ISO-8601 UTC> [skip ci]` |
| Trailer | `Agentic-Pod-Backup: <agente>/<unidad>` |
| Padre | la punta de `main` vigente al construirlo (R1) |
| Árbol | el de esa punta con `.agent-backup/<unidad>` (y, para config, `.agent-backup/README.md`) reemplazado |

## 5. Transiciones de una unidad por ciclo

```text
begin (candado, credencial)
  -> verify (privacidad; heads)                                   [falla: igual que 046]
  -> owner check en main:.agent-backup/<unidad>/                  [ajeno u otro agente: foreign-dir / other-agent]
  -> ¿hash igual y subárbol remoto == last_tree?
        sí -> no-change -> migrate-legacy?
        no -> stage en el directorio -> build commit sobre la punta
              -> push main
                   aceptado        -> verify-after -> write state -> migrate-legacy?
                   no fast-forward -> refetch punta, rebuild (hasta 5) -> main-busy
                   protegido       -> camino PR (R7) -> ok | main-protected
migrate-legacy: backup/<unidad> en heads y marca de este agente y subárbol verificado
        -> delete rama -> legacy_branch="deleted <ISO>" ; borrar caché <unidad>-repo
        si no -> legacy_branch="kept: <motivo>" (no-mark, other-agent, not-verified, delete-failed)
```

## 6. Clon de trabajo (`/workspace/agent-repo`)

Se suma a los dos ajustes de 046 (sin fetch de `backup/*`, helper de credencial por servidor):

| Ajuste | Valor |
| --- | --- |
| Checkout parcial | no cono: `/*` y `!/.agent-backup/` |
| Filtro | `remote.origin.promisor=true`, `remote.origin.partialclonefilter=blob:none` |
| Hook | `.git/hooks/pre-commit` del launcher: rechaza rutas preparadas bajo `.agent-backup/`; reemplaza solo un hook que lleve la marca del launcher, nunca uno ajeno (si existe uno ajeno, lo deja y lo registra en `agent-repo.log`) |

## 7. Sondas y doctor

| Elemento | Antes | Después |
| --- | --- | --- |
| `probe_atlassian` | 1 consulta a Jira | Jira; si 404, Confluence (`/wiki/rest/api/user/current`) |
| Mensaje de la sonda en `ok` por Confluence | — | `via confluence` |
| `probe_claude_oauth` con `CLAUDE_CODE_OAUTH_TOKEN` | mira el archivo de login | `skipped 000 0 login by environment token (expiry not observable)` |
| Doctor, estado del heartbeat | `scripts/heartbeat/logs/state.json`, `.last_run.ended_at` | `scripts/heartbeat/state.json`, `.last_run.ts` |
| `backup-status`, columna nueva | — | `location` (`main:.agent-backup/<unidad>` o `branch:backup/<unidad>`) y `legacy` |
| Doctor, peso del respaldo | cachés > 800 MB | además, tamaño del repositorio (API de GitHub, `size` en KB) > 1 GB: aviso |
