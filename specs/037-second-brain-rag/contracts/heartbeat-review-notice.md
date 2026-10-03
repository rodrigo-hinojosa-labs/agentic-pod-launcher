# Contract: aviso semanal de revisión por heartbeat (docker, opt-in)

Norma para `docker/scripts/heartbeatctl` (`cmd_reload`, `cmd_status`), `setup.sh` (default del prompt),
`modules/claude-md.tpl` y tests. **`scripts/heartbeat/heartbeat.sh` no cambia**: ya parsea `--prompt` y
`--trigger` (`heartbeat.sh:37-43`; precedente `heartbeatctl cmd_test` `:559-561`). `docker/crontab.tpl` no
cambia (es solo el pre-render del boot; el crontab real lo escribe `cmd_reload`, `start_services.sh:151`).
Decisiones del operador que fija este contrato: entrada semanal aparte (no mapa por día) y línea "sin
pendientes" con cola vacía (clarify 2026-09-26).

## 1. Configuración

```yaml
features:
  heartbeat:
    review:
      enabled: false
      schedule: "7 9 * * 1"
      prompt: ""          # vacío = default generado por setup.sh según user.language
```

- `enabled` → `scripts/lib/schema.sh::_SCHEMA_BOOLEANS`; `schedule`/`prompt` → `_SCHEMA_OPTIONAL_NONEMPTY`
  **no** (el prompt vacío es legal: significa default). Solo `schedule` entra a `_SCHEMA_OPTIONAL_NONEMPTY`.
- Default de `schedule` `7 9 * * 1` (lunes 09:07): minuto **fuera de la rejilla** `*/N` de los intervalos
  usuales (5, 10, 15, 30, 60) para no colisionar con el tick regular, cuyo perdedor sale `skipped` **sin
  notificar** (`heartbeat.sh:57-59`, `:252-255`, `:303`; riesgo K-11). Documentado en `docs/heartbeatctl.md`:
  "pick a minute that is not a multiple of your heartbeat interval".
- Día de semana permitido: es una línea de crontab docker (busybox crond); `local_schedule.sh` no se toca
  (la entrada no existe en local).

## 2. `cmd_reload` (`heartbeatctl:173-331`)

1. Lee `review_enabled`, `review_schedule`, `review_prompt` con `_yq` junto a las cinco claves de `:178-184`.
2. Si `review_enabled != true`: no escribe `review-prompt.txt`, no emite línea; el heredoc del crontab
   `:304-313` queda **byte-idéntico** al actual (oráculo).
3. Si `true`:
   - valida `review_schedule` con `_v_cron5` (nuevo): exactamente 5 campos separados por espacios; campos
     2-5 con la forma `^(\*|\*/[0-9]+|[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)$` y valores en rango (hora 0-23,
     día 1-31, mes 1-12, día de semana 0-7); el campo minuto NO admite `*` ni `*/N` (rompería "a lo más un
     aviso por semana", SC-007) y va en 0-59; inválido → WARN al log que nombra
     `features.heartbeat.review.schedule`, línea omitida, el resto del reload sigue (Principio IV). Las siete
     entradas actuales del crontab siguen verbatim (las seis con `schedule` heredado no se validan, como hoy);
     solo la octava pasa por `_v_cron5`.
   - resuelve el prompt efectivo: `review_prompt` si no vacío, si no el default (§3); sustituye el token
     `{{VAULT_DIR}}` por la ruta del vault dentro del contenedor (`vault_resolve_root`, definida en
     `scripts/lib/backup_vault.sh:26` y ya sourceada por `heartbeatctl:35-40`, con fallback a
     `scripts/lib/` para bats) y `{{WORKSPACE}}` por `/workspace`.
   - escribe `/workspace/scripts/heartbeat/review-prompt.txt` con tmp+mv (molde `heartbeat.conf`
     `:198-215`). Motivo: hasta 4000 chars con comillas dobles y `$` no caben legibles ni seguros en una
     línea de crontab, y el archivo sigue el molde de `heartbeat.conf`. Medido en la imagen (BusyBox
     1.37.0, refutación N §4): `%` NO es salto de línea en busybox crond y `$(cat …)` se expande en
     `/bin/sh -c`; el archivo se justifica por legibilidad y tamaño, no por `%`.
   - construye `review_line` con un salto de línea INICIAL embebido y la concatena en la MISMA línea del
     heredoc `:304-313` que `${wiki_graph_line}` (`${wiki_graph_line}${review_line}`):

     ```bash
     review_line=$'\n'"$schedule HEARTBEAT_TRIGGER=review /workspace/scripts/heartbeat/heartbeat.sh --trigger review --prompt \"\$(cat /workspace/scripts/heartbeat/review-prompt.txt)\" >> /workspace/scripts/heartbeat/logs/review.log 2>&1"
     ```

     Con `enabled: false`, `review_line=""` y el crontab es **byte-idéntico** al de v0.26.0. Una línea
     propia en el heredoc agregaría una línea en blanco cuando está deshabilitado y rompería ese oráculo
     (refutación N C1). crond ejecuta cada comando con `/bin/sh -c`; `$(cat …)` se expande ahí.
4. `heartbeat.conf` no gana claves (el aviso no altera el tick regular).
5. La línea de revisión se emite con independencia de `features.heartbeat.enabled` (misma semántica que
   las otras seis líneas de mantenimiento, que no dependen de `heartbeatctl pause`); `pause` sigue
   comentando solo la línea principal (`:227`). Documentado; oráculo en `heartbeatctl.bats`.

## 3. Prompt por defecto (`heartbeatctl`, molde de localización `voice_signoff_default` de 034)

`heartbeat_review_prompt_default <lang>` vive en `docker/scripts/heartbeatctl` (image-baked: es quien
escribe `review-prompt.txt` y ya lee `agent.yml` con `_yq`, incluido `user.language`); `mixed` → español
(precedente 034). `setup.sh` no lo renderiza: solo lo documenta en `NEXT_STEPS`. Texto canónico:

- **es** (CANON-H1-es):

  ```
  Aviso semanal de revisión del vault. Lee con la herramienta Read los archivos {{VAULT_DIR}}/.graph/findings.json y {{WORKSPACE}}/scripts/heartbeat/wiki-graph.json. No uses ninguna otra herramienta y no escribas nada. Responde en texto plano, sin markdown, en menos de 600 caracteres: una linea por cada contador distinto de cero entre review_due, project_overdue, project_incomplete, pending_ingest, archive_candidate, schema_delta_pending y problem_unfed, y luego a lo mas tres items (pagina y detalle), los mas atrasados primero. Si todos los contadores son cero, responde exactamente: sin pendientes
  ```

- **en** (CANON-H1-en): misma estructura en inglés con los mismos siete contadores en el mismo orden;
  cierre `If every count is zero, reply exactly: nothing pending`.

Literales de cola vacía: CANON-H2-es `sin pendientes`, CANON-H2-en `nothing pending`. El prompt evita
tildes a propósito (viaja por heredoc → yq → crontab file; la regla de bytes de 033/034 sigue vigente:
`LC_ALL=C grep -c $'\xcc\x80'` = 0 sobre `setup.sh` y bats).

El prompt lee los JSON **por ruta** y no depende de que la sesión del heartbeat cargue los MCP `vault`/`qmd`
(Fase 0 Q3 no medible sin flota; el diseño no lo necesita).

## 4. Ejecución y registro

| Aspecto | Comportamiento |
|---|---|
| Sesión | La misma que el tick regular (`heartbeat.sh:126-172`: config aislado, sin plugins, `claude --print`), con `TRIGGER=review` |
| `runs.jsonl` | una línea con `trigger: "review"` (`heartbeat.sh:308`, `:315`), `status`, `duration_ms`, `prompt` (primeros chars) |
| `state.json` | `prompt` y `last_run` reflejan el último tick que corrió, sea regular o de revisión (`:375`); `heartbeatctl status` `:371` mostrará ese prompt hasta el siguiente tick regular. Cosmético; documentado (riesgo K-12) |
| Timeout | `HEARTBEAT_TIMEOUT` global (`:30`, default 300 s); no hay `--timeout` por invocación. FR-032 "< 60 s" se **mide** (SC-007, `duration_ms`) no se impone por config |
| Colisión | si un tick regular está vivo, la revisión sale `skipped` sin notificar (y viceversa). Mitigación: minuto por defecto fuera de la rejilla; documentado |
| Notifier | el configurado (`none`/`log`/`telegram`); la salida del prompt viaja verbatim como cualquier tick |
| Escritura | ninguna: el prompt prohíbe herramientas distintas de Read; el runner del heartbeat no toca el vault (verificado en 014/C) |

## 5. Local

Sin entrada: `modules/local-*.tpl` no ganan unit ni timer; `modules/claude-md.tpl:92` sigue diciendo que
el heartbeat no aplica en local y gana una frase: "the weekly review notice is docker-only; in local mode
the queue is offered at the start of each conversation".

## 6. Oráculos

| Oráculo | Dónde |
|---|---|
| `enabled: false` → crontab renderizado byte-idéntico al de v0.26.0 (golden en el test) y `review-prompt.txt` ausente | `heartbeatctl.bats` (molde `:299-327`) |
| `enabled: true` + schedule default → línea presente con `--trigger review` y `--prompt "$(cat …review-prompt.txt)"`; archivo presente con el prompt efectivo y `{{VAULT_DIR}}` sustituido | `heartbeatctl.bats` |
| schedule malformado (`"9 * *"`, `"a b c d e"`, `"0 9 * * 8x"`, `"* 9 * * 1"` (minuto `*`), `"*/5 9 * * 1"`, `"0 25 * * 1"`) → WARN que nombra la clave, línea ausente, resto del crontab intacto | `heartbeatctl.bats` |
| prompt custom en `agent.yml` gana al default; prompt vacío → default del idioma del agente (`es`/`en`/`mixed`→es) | `heartbeatctl.bats` + `voice-config.bats`-style test en `setup.sh` |
| `runs.jsonl` acepta `trigger: review` (el runner no filtra el valor) | `heartbeat-runs-jsonl.bats:62` |
| `docker/crontab.tpl` intacto | `docker-render.bats:132-137` |
| Modo local: cero `review` en artefactos runtime | `local-render.bats` (extensión del oráculo FR-011 de 032) |
| DOCKER_E2E: con `enabled: true`, `heartbeatctl reload` dentro del contenedor deja en `/etc/crontabs/agent` (tras el sync loop, `cmp -s`) exactamente una línea no comentada que contiene `--trigger review` (`grep -c -- '--trigger review' /etc/crontabs/agent \|\| true` = 1); con `false`, 0. Nunca contar líneas físicas: el crontab actual ya tiene líneas en blanco entre entradas | `docker-e2e-heartbeat.bats` (+1) |
| `features.heartbeat.enabled: false` + `review.enabled: true` → la línea de revisión se emite igual y la principal queda comentada como hoy | `heartbeatctl.bats` |
| Bytes: cero marcas combinantes en `setup.sh`, `heartbeatctl` y bats | auditoría |
