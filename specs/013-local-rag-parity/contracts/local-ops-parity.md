# Contract: local-ops-parity (US3 — FR-008..FR-013)

El operador local ve y controla el RAG/backup con la misma honestidad que en docker.

## Kill-switch (FR-008)

- `AUX_UNITS` en `local-killswitch.sh.tpl` = `qmd-reindex.timer qmd-watch.service vault-backup.timer healthcheck.timer` (+ la sesión que ya maneja aparte). Stop/disable best-effort (`|| true`) se conserva — hosts sin alguna unit no fallan.
- Postcondición (SC-004): tras activar el kill switch, cero ejecuciones de CUALQUIER unit del agente en las siguientes ventanas de timer; cero pushes al fork.

## Doctor / status honestos (FR-009, FR-013)

- `_local_vault_qmd_doctor`: si `qmd-index.json.last_status == "error"` ⇒ `_doctor_warn` (o fail si además no hay índice); staleness del vault backup vía `_check_backup_freshness <agent> vault 25` (reuso, cero cambios docker); reporta `qmd-schedule.fallback` si existe.
- `_local_vault_qmd_status`: agrega `last_run` (frescura), no solo presencia; reporta fallback de schedule.
- `cmd_local_doctor`: epílogo de exit codes replicando `cmd_doctor` (0 sano / 1 warn / 2 fail) usando los contadores compartidos.

## Acciones manuales (FR-010 — R9)

- Dispatch local en `agentctl`: `heartbeat qmd-reindex` → exec `<ws>/scripts/local/agent-qmd-reindex.sh`; `heartbeat backup-vault` → exec `<ws>/scripts/local/agent-vault-backup.sh`; ambos como el operador (sin systemctl/sudo), passthrough `--dry-run` si el subcomando lo trae. El resto de subcomandos docker-only mantienen su error con hint.

## Healthcheck (FR-011)

- `local-healthcheck.sh.tpl`: si `/etc/systemd/system/agent-${AGENT_NAME}-qmd-watch.service` existe Y `systemctl is-failed --quiet` ⇒ WARN `qmd watcher failed (start-limit?)`. Nunca DEGRADED por esto (el timer backstop preserva frescura). Degrada silencioso si systemctl no está.

## NEXT_STEPS (FR-012)

- `next-steps.{en,es}.tpl`, bloque local condicionado a `{{#if VAULT_QMD_ENABLED}}`: `journalctl -u agent-<n>-qmd-reindex.service`, `-qmd-watch.service`, `-vault-backup.service` (este último condicionado a `VAULT_ENABLED`), `systemctl list-timers 'agent-<n>-*'`.

## Fallback de schedule (FR-013 — R10)

- `setup.sh` crea/borra `<ws>/scripts/heartbeat/qmd-schedule.fallback` según el resultado de `cron_to_systemd_calendar` (derivado puro del regenerate); status/doctor lo muestran con el schedule original y el aplicado.

## Tests (test-first)

1. Render killswitch: AUX_UNITS contiene las 4 units auxiliares.
2. Doctor con state `last_status=error` (fixture): salida warn + exit 1; con backup stale >25h: warn staleness; sano: exit 0.
3. `agentctl heartbeat qmd-reindex` en workspace local (stub del script): lo ejecuta y NO imprime "Docker-mode command"; en docker sigue el camino heartbeatctl.
4. Render healthcheck: bloque is-failed presente y gated por existencia de la unit.
5. Render NEXT_STEPS en/es con qmd on/off: bloque presente/ausente.
6. Regenerate con schedule no soportado: marker creado con original+applied; con `*/5`: marker ausente (y borrado si existía).
