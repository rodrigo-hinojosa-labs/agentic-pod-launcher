# Data Model: aviso automatico de integracion de delta al arrancar

Sin base de datos ni entidades persistentes nuevas mas alla de dos marcadores de archivo
(sentinels), coherentes con el patron ya establecido por 014/037 para `.applied`.

## Entidad: Delta pendiente (conceptual, no persistida — derivada en runtime)

Calculada por `vault_pending_deltas`, no almacenada. Campos conceptuales:

| Campo | Origen | Notas |
|---|---|---|
| `version` | nombre de archivo `_templates/.schema-updates-{version}.applied` | una de `_vault_delta_known_versions` |
| `checkpoint_text` | tabla `_vault_delta_checkpoint_text(version)` | literal a buscar en `CLAUDE.md` del vault |
| `integrated` | `grep -F -q checkpoint_text CLAUDE.md` | boolean derivado, nunca guardado |
| `already_nudged` (solo docker) | existencia de `_templates/.schema-updates-{version}.nudged` | ver abajo |

## Marcador: `_templates/.schema-updates-{version}.nudged`

- **Proposito**: registra que el aviso ACTIVO (disparo de heartbeat, modo docker) ya se envio para
  esta version especifica. Hermano directo del `.applied` que 014/037 ya usan para "delta
  depositado" — mismo directorio, mismo estilo de nombre oculto.
- **Escritor**: `docker/scripts/start_services.sh::boot_side_effects()`, inmediatamente despues de
  lanzar en background el turno de heartbeat con `--trigger schema_delta`. Escritura best-effort
  (`|| true`) — un fallo al escribir el marcador NO debe abortar el boot (Principio IV); en el peor
  caso, el proximo boot reintenta el aviso, lo cual es preferible a que un fallo de escritura
  bloquee el arranque.
- **Lector**: la misma funcion, en cada boot posterior — si el marcador ya existe para una version,
  esa version se salta al decidir el dispatch, aunque `vault_pending_deltas` la siga reportando
  como pendiente (la version integrada la deja de reportar `vault_pending_deltas` una vez que el
  agente actualiza `CLAUDE.md`; el marcador `.nudged` solo evita RE-avisar mientras sigue pendiente).
- **Modo local**: NO se usa. El chequeo de `agentctl doctor`/`status` en modo local es pasivo y
  persiste hasta que la version deje de estar pendiente (ver research.md R3) — no necesita su
  propio marcador de "ya mostrado".
- **Ciclo de vida**: nunca se borra automaticamente por esta feature (igual que `.applied` no se
  borra). Si el operador quisiera forzar un reaviso, borrarlo a mano alcanza — comportamiento
  identico al que ya existe para forzar un re-deposito de delta hoy, documentado como tal.

## Sin cambios a entidades existentes

- `_templates/.schema-updates-{version}.applied` (014/037): sin cambios, solo lectura.
- `.graph/findings.json` / `wiki-graph.json` (`schema_delta_pending`, 037): sin cambios — esta
  feature NO lee de ahi (ver research.md R1, razon de frescura) ni escribe ahi.
- `agent.yml`: sin campos nuevos. Esta feature no tiene superficie de configuracion — no hay
  toggle de `enabled/disabled` (a diferencia de `features.heartbeat.review`): el aviso de
  integracion no es opt-in, es comportamiento base del ciclo de arranque, igual que el propio
  deposito del delta.
