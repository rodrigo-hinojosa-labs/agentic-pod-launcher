# Contract: local-ops-parity (US3 — FR-008..FR-013)

El operador local ve y controla el RAG/backup con la misma honestidad que en docker.

## Kill-switch (FR-008)

- `AUX_UNITS` en `local-killswitch.sh.tpl` = `qmd-reindex.timer qmd-watch.service vault-backup.timer healthcheck.timer` (+ la sesión que ya maneja aparte). Stop/disable best-effort (`|| true`) se conserva — hosts sin alguna unit no fallan.
- Postcondición (SC-004): tras activar el kill switch, cero ejecuciones de CUALQUIER unit del agente en las siguientes ventanas de timer; cero pushes al fork.

## Doctor / status honestos (FR-009, FR-013)

- `_local_vault_qmd_doctor`: si `qmd-index.json.last_status == "error"` ⇒ `_doctor_warn` (o fail si además no hay índice); staleness del vault backup vía `_check_backup_freshness <agent> vault 25` (reuso, cero cambios docker); `systemctl is-failed` de la unit qmd-watch ⇒ warn (tercer escenario de SC-005 — analyze G1); reporta `qmd-schedule.fallback` si existe; el reporte "staged (run --login)" heredado de 012 (`agentctl:947-952`) se conserva y se asevera en la suite (analyze G2).
- `_local_vault_qmd_status`: agrega `last_run` (frescura), no solo presencia; reporta fallback de schedule.
- `cmd_local_doctor`: epílogo de exit codes replicando `cmd_doctor` (0 sano / 1 warn / 2 fail) usando los contadores compartidos.

## Acciones manuales (FR-010 — R9)

- Dispatch local en `agentctl`: `heartbeat qmd-reindex` → exec `<ws>/scripts/local/agent-qmd-reindex.sh`; `heartbeat backup-vault` → exec `<ws>/scripts/local/agent-vault-backup.sh`; ambos como el operador (sin systemctl/sudo). Política de flags (analyze U3): `--dry-run` se pasa SOLO a backup-vault (único script que lo soporta); `qmd-reindex --dry-run` ⇒ error explícito sin ejecutar (nunca un reindex real bajo apariencia de dry-run). El resto de subcomandos docker-only mantienen su error con hint.

## Healthcheck (FR-011)

- `local-healthcheck.sh.tpl`: si `/etc/systemd/system/agent-${AGENT_NAME}-qmd-watch.service` existe Y `systemctl is-failed --quiet` ⇒ WARN `qmd watcher failed (start-limit?)`. Nunca DEGRADED por esto (el timer backstop preserva frescura). Degrada silencioso si systemctl no está.

## NEXT_STEPS (FR-012)

- `next-steps.{en,es}.tpl`, dentro del `{{#unless DEPLOYMENT_MODE_IS_DOCKER}}` existente: bloque `{{#if VAULT_QMD_ENABLED}}` (journal de qmd-reindex y qmd-watch + `systemctl list-timers 'agent-<n>-*'`) seguido de un bloque **HERMANO** `{{#if VAULT_ENABLED}}` con la línea de vault-backup. PROHIBIDO anidar if-dentro-de-if (el regex non-greedy de `render.sh:126` cierra el bloque externo con el `{{/if}}` interno — analyze U2); if-dentro-de-unless sí es válido (el pass de `#if` precede al de `#unless`). El render docker de NEXT_STEPS queda byte-idéntico a v0.6.0 (aserción en suite).

## Fallback de schedule (FR-013 — R10/D10)

- `scripts/lib/local_schedule.sh` expone la señal `CRON_FALLBACK=0|1` (rc/stdout intactos; `*/5 * * * *` convierte exacto al default ⇒ señal 0, sin falso positivo — analyze U1). `setup.sh` crea/borra `<ws>/scripts/heartbeat/qmd-schedule.fallback` según la señal en el render local, y lo borra incondicionalmente en el render docker (mode-switch sin huérfanos — analyze C1); status/doctor lo muestran con el schedule original y el aplicado.

## Tests (test-first)

1. Render killswitch: AUX_UNITS contiene las 4 units auxiliares.
2. Doctor con state `last_status=error` (fixture): warn + exit 1; backup stale >25h: warn staleness; unit qmd-watch failed (systemctl stub): warn + exit 1; units staged: reporte "staged"; sano: exit 0.
3. `agentctl heartbeat qmd-reindex` en workspace local (stub del script): lo ejecuta y NO imprime "Docker-mode command"; `backup-vault --dry-run` pasa el flag; `qmd-reindex --dry-run` → error sin ejecutar; en docker sigue el camino heartbeatctl.
4. Render healthcheck: bloque is-failed presente y gated por existencia de la unit.
5. Render NEXT_STEPS en/es: qmd on+vault on / qmd on+vault off / qmd off (bloques hermanos correctos); render docker byte-idéntico a v0.6.0.
6. Señal `CRON_FALLBACK`: 0 con `*/5` (conversión exacta), 1 con forma no soportada; marker creado solo con señal 1, borrado con señal 0 y en render docker.
7. Wizard warning (D13): local + qmd on + servicio no instalado → advertencia presente; en los demás casos, ausente.
