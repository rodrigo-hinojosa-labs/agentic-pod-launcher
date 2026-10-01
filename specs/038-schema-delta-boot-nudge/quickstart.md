# Quickstart: aviso automatico de integracion de delta al arrancar

## 1. Validacion manual — deteccion (`vault_pending_deltas`)

Sobre un vault fixture desechable:

```bash
mkdir -p /tmp/v38/_templates
echo "# CLAUDE.md sin PARA" > /tmp/v38/CLAUDE.md
source scripts/lib/vault.sh
vault_pending_deltas /tmp/v38          # vacio: sin .applied, nada pendiente

: > /tmp/v38/_templates/.schema-updates-0.27.0.applied
vault_pending_deltas /tmp/v38          # imprime: 0.27.0

echo "## Actionability (PARA)" >> /tmp/v38/CLAUDE.md
vault_pending_deltas /tmp/v38          # vacio otra vez: integrado
```

## 2. Validacion manual — aviso activo (modo docker)

Sobre un agente docker de prueba con el delta 0.27.0 ya depositado pero sin integrar:

1. `docker compose restart <agent>`.
2. `docker logs <agent> | grep "schema delta: nudge dispatched"` — debe aparecer UNA vez.
3. `docker exec -u agent <agent> cat /home/agent/.vault/_templates/.schema-updates-0.27.0.nudged`
   — debe existir.
4. Revisar el canal (Telegram) — debe llegar un mensaje del turno de heartbeat mencionando el
   delta pendiente.
5. `docker compose restart <agent>` de nuevo (sin integrar el delta todavia) —
   `docker logs` NO debe mostrar un segundo "nudge dispatched" para la misma version (FR-003).
6. Integrar el delta a mano (agregar `## Actionability (PARA)` a `CLAUDE.md`), reiniciar de nuevo —
   `agentctl doctor`/`heartbeatctl status` deben mostrar "Schema delta: none pending".

## 3. Validacion manual — aviso pasivo (`agentctl doctor`)

- **Modo local**: sobre un workspace con el delta depositado sin integrar, `./scripts/agentctl
  doctor` debe mostrar la linea WARN nueva ("Schema delta pending integration: 0.27.0"), NO la
  linea informativa generica de `wiki-graph queue`. Debe seguir apareciendo en corridas
  posteriores de `doctor` hasta integrar el delta (no se auto-silencia).
- **Modo docker**: mismo chequeo via `docker exec -u agent <agent> heartbeatctl status` o
  `agentctl doctor <agent>` desde el host — la linea debe aparecer ademas del aviso activo (no en
  su reemplazo).

## 4. DOCKER_E2E (obligatorio — toca `start_services.sh`, image-baked)

Extender `tests/docker-e2e-vault.bats` o crear `tests/docker-e2e-schema-delta-nudge.bats`:

- E1: contenedor arranca con un delta pre-sembrado sin integrar (fixture montado en
  `.state/.vault`) → log contiene "schema delta: nudge dispatched"; marcador `.nudged` presente.
- E2: segundo `docker compose restart` sin integrar → NO hay un segundo dispatch; log limpio de
  esa linea en la segunda pasada.
- E3: delta ya integrado desde el inicio (fixture con `## Actionability (PARA)` ya en `CLAUDE.md`)
  → ningun dispatch, ningun marcador `.nudged` creado.
- E4: `heartbeatctl status` dentro del contenedor muestra la linea pasiva correcta en los tres
  casos de arriba.

## 5. Tabla de mutacion (candidatos — completar contra la implementacion real en T de tasks.md)

| # | Mutacion | Test que debe cazarla |
|---|---|---|
| M1 | `vault_pending_deltas` deja de chequear `.applied` (reporta pendiente aunque el delta nunca se deposito) | test de deteccion: vault sin `.applied` debe dar vacio |
| M2 | `vault_pending_deltas` deja de chequear el checkpoint text (reporta pendiente aunque ya este integrado) | test de deteccion: vault con checkpoint presente debe dar vacio |
| M3 | El dispatch en `boot_side_effects` no respeta el marcador `.nudged` (re-avisa cada boot) | DOCKER_E2E E2 |
| M4 | El dispatch no escribe el marcador `.nudged` tras disparar | DOCKER_E2E E1 (marcador ausente) |
| M5 | El dispatch bloquea el boot (no corre en background) | test host con `START_SERVICES_NO_RUN=1` midiendo que `boot_side_effects` retorna sin esperar el subshell |
| M6 | La linea de `agentctl doctor` (local) usa `_doctor_pass` en vez de `_doctor_warn` | bats de doctor local: aserta `not ok`/exit relevante para WARN, o el conteo de `_doctor_warn_count` |
| M7 | El prompt del disparo ignora `user.language` (siempre en un idioma) | test de `heartbeat_schema_delta_prompt_default` con `en`/`es`/`mixed` |

## 6. Gate de hardware (antes del merge; precedente 024/037)

Esta feature depende de `037-second-brain-rag` — el gate de hardware corre DESPUES de que 037 este
mergeada a `main` y esta rama se haya rebasado sobre ella (verificar `VERSION` contra
`origin/main` a mano tras el rebase, leccion de "REBASE SOBRE 022").

1. Un agente docker real con un delta pendiente (puede reusar el mismo estado en el que quedaron
   linus/donna el 2026-09-29/30 si para entonces siguen sin integrar) — confirmar el aviso activo
   llega por Telegram sin que el operador pida nada.
2. Un agente local real (mclaren) con un delta pendiente — confirmar la linea WARN en
   `agentctl doctor`.
3. Registrar en Notes de `tasks.md` con fecha; solo entonces PR (que a su vez espera el merge de
   037 primero).

## 7. Checklist de cierre

- [ ] Suite dual (bash 3.2.57 y 5.x) en 0 `not ok`; `shellcheck -S error` limpio.
- [ ] DOCKER_E2E verde (los 4 casos de la seccion 4).
- [ ] Mutacion de la tabla de la seccion 5 corrida contra la implementacion real.
- [ ] `CHANGELOG.md`, `VERSION` (verificado contra `origin/main` — recordar que esta rama parte de
      037, no de main), `docs/vault.md` o `docs/heartbeatctl.md` si corresponde.
- [ ] Gate de hardware de la seccion 6 registrado con fecha.
- [ ] Commit + PR solo con confirmacion del operador; el PR en si espera a que 037 mergee primero.
