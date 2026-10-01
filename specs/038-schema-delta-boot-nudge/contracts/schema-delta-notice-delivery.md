# Contract: entrega del aviso (activo en docker, pasivo en ambos modos)

Dos superficies independientes, ambas alimentadas por `vault_pending_deltas`
(`contracts/vault-pending-deltas.md`). Ninguna de las dos tiene toggle en `agent.yml` — es
comportamiento base (data-model.md, "Sin cambios a entidades existentes").

## Superficie 1 — aviso ACTIVO (solo modo docker)

**Disparador**: `docker/scripts/start_services.sh::boot_side_effects()`, ejecutado en cada boot del
contenedor, inmediatamente despues del bloque de `seed_vault_if_needed`.

**Logica**:

```bash
# dentro de boot_side_effects(), despues de seed_vault_if_needed
if command -v vault_pending_deltas >/dev/null 2>&1; then
  for _pending_version in $(vault_pending_deltas "$vault_root" 2>/dev/null); do
    _nudge_marker="$vault_root/_templates/.schema-updates-${_pending_version}.nudged"
    [ -f "$_nudge_marker" ] && continue
    (
      _lang=$(yq -r '.user.language // "es"' "$agent_yml" 2>/dev/null)
      _prompt=$(heartbeat_schema_delta_prompt_default "$_lang" "$_pending_version")
      "$HEARTBEAT_SH" --trigger schema_delta --prompt "$_prompt"
    ) &
    touch "$_nudge_marker" 2>/dev/null || true
    log "schema delta: nudge dispatched for ${_pending_version} (background)"
  done
fi
```

(Nombres de variables ilustrativos — el detalle exacto de fuente de `HEARTBEAT_SH`/`agent_yml`
sigue la convencion ya usada por el bloque de qmd inmediatamente anterior en el mismo archivo.)

**Garantias**:
- Nunca bloquea el arranque: el turno de heartbeat corre en un subshell backgroundeado (`&`),
  igual que `qmd_setup_if_needed`.
- Nunca aborta el boot si falla: sin `set -e` implicito sobre este bloque; el `touch` tiene su
  propio `|| true`.
- Como maximo un turno de heartbeat por version pendiente por boot (nunca reintenta dentro del
  mismo boot); como maximo UN aviso por version en el tiempo, gracias al marcador `.nudged`
  (FR-003).
- Independiente de `features.heartbeat.review.enabled` (FR-004) — no lee ni escribe esa clave.

**Prompt** (`heartbeat_schema_delta_prompt_default`, nueva funcion en `docker/scripts/heartbeatctl`,
mismo molde que `heartbeat_review_prompt_default`):

- ES (default / `mixed`): `Hay un delta de schema del vault pendiente de integrar:
  _templates/schema-updates-{version}.md. Leelo con la herramienta Read y segui sus instrucciones
  para integrarlo en tu CLAUDE.md. Cuando termines, confirma brevemente que fue integrado.`
- EN: `There is a pending vault schema delta to integrate:
  _templates/schema-updates-{version}.md. Read it with the Read tool and follow its instructions
  to integrate it into your CLAUDE.md. When done, briefly confirm it was integrated.`
- Si hay mas de una version pendiente en el mismo boot, el prompt las lista todas separadas por
  coma en vez de disparar un turno por version (evita turnos concurrentes compitiendo por el mismo
  `CLAUDE.md`).

## Superficie 2 — aviso PASIVO (`agentctl doctor` / `status`, ambos modos)

**Ubicacion**: nueva linea dedicada en `_local_vault_qmd_doctor()` (modo local,
`scripts/agentctl`) y su equivalente docker-mode (mismo archivo, seccion de `cmd_doctor` que hoy
imprime `wiki-graph queue`) — ambas leen `vault_pending_deltas` directamente, NO el finding
cacheado de wiki-graph.

**Logica** (misma forma en ambos modos):

```bash
_pending=$(vault_pending_deltas "$vault_root" 2>/dev/null)
if [ -n "$_pending" ]; then
  _doctor_warn "Schema delta pending integration: $(echo "$_pending" | tr '\n' ' ' | sed 's/ $//')" \
    "read _templates/schema-updates-<version>.md and integrate it into CLAUDE.md"
else
  _doctor_pass "Schema delta: none pending"
fi
```

**Garantias**:
- Persiste (no se auto-silencia) mientras la version siga sin integrar — mismo patron que
  cualquier otro WARN de `agentctl doctor` (ej. "Backup vault: never pushed yet"). No usa ni
  necesita el marcador `.nudged` (ese es exclusivo de la superficie activa).
- En modo docker, esta linea es COMPLEMENTARIA al aviso activo — si el operador no vio la
  notificacion (Telegram apagado, mensaje perdido), `doctor` lo muestra igual la proxima vez que
  se consulta.
- En modo local, esta linea ES el mecanismo completo (no hay superficie activa — ver research.md
  R3).

## No incluido en este contrato

- Ningun cambio a `.graph/findings.json`, `wiki-graph.json` ni a la logica de
  `schema_delta_pending` de 037 (`scripts/lib/wiki_graph.sh`) — ver research.md R1, tradeoff
  aceptado explicitamente.
- Ninguna escritura automatica a `CLAUDE.md` por parte del sistema — la integracion la sigue
  haciendo el agente, en el turno de heartbeat (modo docker) o en su propia sesion cuando el
  operador la note via `doctor` (modo local).
