# Research: aviso automatico de integracion de delta al arrancar

## R1. Deteccion generica de "delta sin integrar"

**Decision**: nueva funcion `vault_pending_deltas <vault_root>` en `scripts/lib/vault.sh`,
apoyada en una tabla chica y explicita (compatible bash 3.2, sin arrays asociativos):

```bash
# scripts/lib/vault.sh (nuevo, junto a vault_seed_missing — no lo modifica)
_vault_delta_known_versions() { printf '%s\n' 0.27.0; }

_vault_delta_checkpoint_text() {
  case "$1" in
    0.27.0) printf '%s' '## Actionability (PARA)' ;;
    *) return 1 ;;
  esac
}

vault_pending_deltas() {
  local vault_root="$1" version checkpoint
  [ -n "$vault_root" ] || return 0
  for version in $(_vault_delta_known_versions); do
    checkpoint="$(_vault_delta_checkpoint_text "$version")" || continue
    [ -f "$vault_root/_templates/.schema-updates-${version}.applied" ] || continue
    grep -F -q -- "$checkpoint" "$vault_root/CLAUDE.md" 2>/dev/null && continue
    printf '%s\n' "$version"
  done
}
```

Devuelve, una por linea, cada version cuyo delta esta depositado (`.applied` presente) Y sin
integrar (el texto de checkpoint declarado en el propio delta doc NO esta en `CLAUDE.md`). Vacio
si no hay ninguno pendiente. Cubre FR-001 y, por construccion (recorre TODAS las versiones
conocidas), FR-008 (mas de un delta pendiente a la vez).

**Rationale**: 037 YA resuelve esta deteccion — pero hardcodeada en `scripts/lib/wiki_graph.sh`
(`grep -F -q -- '## Actionability (PARA)'` en `:458`, marcador `.schema-updates-0.27.0.applied`
literal en `:680`, ruta y texto repetidos otra vez en el jq de `:888-889`) — solo para la
`schema_delta_pending` de esa feature. No hay ninguna funcion reusable hoy; construirla evita que
038 reimplemente la logica de deteccion con su propio hueco de bugs.

**Alternatives considered**:
- *Reusar wiki_graph.sh como fuente de verdad* (leer `.graph/findings.json` en vez de una funcion
  propia): descartado — wiki-graph corre en SU propio horario (`20 */6 * * *`, hasta 6h de
  staleness); justo despues de un `--regenerate`/boot que deposito el delta, el finding puede no
  existir todavia. El aviso de esta feature exige frescura inmediata, no la cadencia de wiki-graph.
- *Refactorizar `wiki_graph.sh` para que llame a esta misma funcion nueva* (eliminando la
  duplicacion del par version/checkpoint): descartado para esta iteracion. `wiki_graph.sh` esta
  mutation-tested a fondo por 037 (M1-M18, cerrado y gateado); reabrirlo para un refactor NO
  conductual, solo para evitar una linea de duplicacion, no vale el riesgo de reabrir esa
  superficie. Se acepta la duplicacion como tradeoff documentado — si se agrega una tercera
  version de delta en el futuro, agregarla en DOS lugares (esta tabla y el jq de wiki_graph.sh) en
  vez de uno. Riesgo bajo: un olvido es visible (el finding y el aviso divergen), no silencioso.

## R2. Disparo en modo docker

**Decision**: `docker/scripts/start_services.sh::boot_side_effects()` llama a
`vault_pending_deltas` inmediatamente despues de `seed_vault_if_needed` (mismo lugar donde hoy
corre `vault_seed_missing` via esa funcion). Por cada version pendiente SIN su marcador de aviso
ya escrito, dispara en background — mismo patron que el dispatch de qmd (`( … ) &` +
`log "…dispatched (background)"`) — `scripts/heartbeat/heartbeat.sh --trigger schema_delta
--prompt "<prompt localizado>"`, y escribe `_templates/.schema-updates-{version}.nudged` (hermano
del `.applied` existente, mismo mecanismo de sentinel — Principio IV: idempotencia por marcador
explicito, nunca mtime).

El prompt reusa el mismo mecanismo de `heartbeat_review_prompt_default` (037) pero con un texto
DISTINTO — le pide al agente INTEGRAR ahora, no solo reportar:

```
Hay un delta de schema del vault pendiente de integrar: _templates/schema-updates-{version}.md.
Leelo con la herramienta Read y sigue sus instrucciones para integrarlo en tu CLAUDE.md. Cuando
termines, confirma brevemente que fue integrado (el propio delta te dice si podes borrar el
archivo despues).
```

(version EN espejo, mismo patron `case "$lang"` de `heartbeat_review_prompt_default`, sin tildes
por la misma disciplina de bytes de 033/034/037.) Si hay MAS de una version pendiente a la vez, el
prompt las nombra todas en una sola linea (raro en la practica — solo pasa hoy con un unico delta
conocido, 0.27.0 — pero la funcion ya soporta el caso).

El turno corre en el contexto aislado `CLAUDE_CONFIG_DIR=$HOME/.claude-heartbeat` que
`heartbeat.sh` ya usa (010) — pero la edicion que hace a `CLAUDE.md` es sobre el ARCHIVO real del
vault, no sobre nada scoped a ese config dir; la sesion interactiva la ve en su proximo turno
porque `CLAUDE.md` se carga fresco. Este turno NO depende de `features.heartbeat.review.enabled`
(FR-004) — es un disparo independiente, del mismo modo que el disparo normal de heartbeat y el de
`review` son independientes entre si hoy.

**Rationale**: reusa integramente un mecanismo ya construido, probado y mutation-tested por 037 (el
propio `HEARTBEAT_TRIGGER`, la isolation de config dir, el patron de prompt localizado) en vez de
inventar un canal nuevo. El punto de disparo (`boot_side_effects`, no un cron) es lo unico
genuinamente nuevo, y es aditivo: no cambia nada de lo que `boot_side_effects` ya hace.

## R3. Disparo en modo local — decision del operador (2026-09-30)

**Contexto**: en modo local (Remote Control) NO existe un canal de notificacion separado como
Telegram — el operador conversa directo con la unica sesion viva. Un turno aislado de heartbeat
(como en R2) escribiria a un log que nadie mira; no llega a la sesion interactiva real, que es
distinta y no comparte contexto conversacional con el turno aislado.

**Decision (elegida sobre 3 opciones presentadas)**: el aviso en modo local se superficializa en
`agentctl doctor`/`agentctl status` — superficies que ya se consultan de rutina despues de
cualquier actualizacion — como una linea DEDICADA de WARN (`_doctor_warn`, no `_doctor_pass`),
separada de la linea informativa `wiki-graph queue` que ya existe (esa sigue siendo pasiva/
informativa por diseno de 037 — un backlog de revision no es un problema estructural). La nueva
linea usa `vault_pending_deltas` directamente (no el finding cacheado de wiki-graph, por la misma
razon de frescura de R1) dentro de `_local_vault_qmd_doctor()` en `scripts/agentctl`.

A diferencia de R2, esta superficie NO necesita su propio sentinel de "ya avisado": es un chequeo
PASIVO que el operador invoca el mismo, y el patron establecido de TODO el resto de `agentctl
doctor` es persistir el WARN hasta que la condicion se resuelva (igual que "Backup vault: never
pushed yet"), no auto-silenciarse tras la primera vez. FR-003 ("el aviso no se repite") aplica al
mecanismo ACTIVO de R2 (evitar spam de Telegram); no aplica de la misma forma a un pull pasivo que
el operador decide cuando consultar.

**Opciones descartadas**: construir un mecanismo de inyeccion nuevo hacia la sesion interactiva
(mayor costo/riesgo, sin precedente en el codigo hoy — `next_tmux_cmd` no tiene ningun punto de
inyeccion de prompt); o diferir modo local por completo (repetiria el alcance docker-only del
aviso semanal de 037, pero el propio spec de esta feature exige paridad — US3/FR-005 — asi que
reducir alcance ahi hubiera requerido autorizacion explicita, que el operador no dio: eligio la
primera opcion).

**Nota de alcance real**: dado que el deposito del delta en modo local ocurre en `setup.sh
--regenerate` (host, sincronico), NO en el arranque de la sesion del agente (a diferencia de
docker, donde `boot_side_effects` corre en cada boot del contenedor), esta feature NO necesita
tocar `modules/local-session-check.sh.tpl` ni ningun otro script de arranque de sesion local — el
chequeo de `agentctl doctor`/`status` es suficiente y mas simple.

## R4. Localizacion del prompt

Mismo patron que `voice_signoff_default` (034) y `heartbeat_review_prompt_default` (037):
`case "$lang" in en) …EN…; ;; *) …ES… ;; esac`, `mixed` cae al default espanol (mismo criterio que
el resto del proyecto para ese valor). Sin caracteres acentuados en ningun idioma (regla de bytes
de 033/034/037: heredoc -> yq -> archivo, verificado `LC_ALL=C grep -c $'\xcc\x80'` = 0 en cada
artefacto tocado).

## R5. Alcance de pruebas

- Unit/host (`bats`): `vault_pending_deltas` con fixtures (vault sin delta, vault con delta
  depositado sin integrar, vault con delta ya integrado, dos deltas simulados a la vez si el
  fixture lo permite sin inventar una tercera version real).
- `start_services.sh`: extender `tests/start-services-*.bats` (patron `START_SERVICES_NO_RUN=1` +
  stubs) para el dispatch nuevo y el sentinel `.nudged` — sin Docker.
- `scripts/agentctl` local doctor: extender el bats existente de doctor local con el caso WARN
  nuevo.
- DOCKER_E2E: obligatorio (toca `docker/scripts/start_services.sh`, image-baked) — un caso que
  deposita el delta de prueba, verifica el dispatch del trigger y el marcador `.nudged`, y que una
  segunda pasada de boot NO vuelve a disparar.
- Mutacion: como toda feature de este repo — revertir cada guardia (deteccion, sentinel,
  fail-soft) y confirmar RED antes de continuar (precedente 034 M6, 037 M1-M18).
