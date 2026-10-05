# Quickstart: Aviso de actualización de conocimiento al iniciar sesión

Validación manual, suites, DOCKER_E2E, mutación y gates de hardware. Los textos esperados del aviso son los
CANON de `contracts/upgrade-notice-hook.md`.

## 1. Capa vault (`vault_pending_deltas`)

```bash
v=$(mktemp -d); mkdir -p "$v/_templates"; echo "# vault" > "$v/CLAUDE.md"
source scripts/lib/vault.sh
vault_pending_deltas "$v"                                    # vacío: nada depositado
printf 'deposited: 2026-09-30\n' > "$v/_templates/.schema-updates-0.27.0.applied"
: > "$v/_templates/.schema-updates-0.8.0.applied"
vault_pending_deltas "$v"                                    # 0.8.0 y 0.27.0, en ese orden
echo 'see wiki/normalization/' >> "$v/CLAUDE.md"
vault_pending_deltas "$v"                                    # solo 0.27.0
echo '## Actionability (PARA)' >> "$v/CLAUDE.md"
vault_pending_deltas "$v"; echo "rc=$?"                      # vacío, rc=0
vault_pending_deltas /no/existe; echo "rc=$?"                # vacío, rc=0
```

## 2. Capa workspace (regenerate)

Sobre un workspace scaffoldeado desechable:

1. Recién scaffoldeado: `cmp .state/launcher/claude-md.upstream.md CLAUDE.md` y
   `cmp .state/launcher/claude-md.baseline.md CLAUDE.md` → ambos iguales.
2. Cambiar `agent.yml` (por ejemplo `features.heartbeat.enabled`) y `./setup.sh --regenerate` → salida
   `CLAUDE.md (refreshed: ...)`; `CLAUDE.md` igual al nuevo upstream; la persona sigue presente.
3. Editar `CLAUDE.md` a mano, cambiar `agent.yml`, regenerate → `preserved: differs from the current template`;
   `CLAUDE.md` byte-idéntico a antes; `agentctl doctor` muestra WARN `template changed since the last
   integration`.
4. `cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md` → doctor pasa a
   `local edits on the current template` (PASS).
5. Borrar `.state/launcher/claude-md.baseline.md` y regenerate → `preserved`; doctor WARN `(no baseline)`.
6. Dos regenerate seguidos sin cambios → `C`, `U` y `B` byte-idénticos entre corridas.

## 3. Hook

```bash
echo '{"source":"startup"}' | ./scripts/hooks/upgrade-notice.sh                # con pendientes: un JSON
echo '{"source":"startup"}' | ./scripts/hooks/upgrade-notice.sh | wc -c        # sin pendientes: 0
echo '{}' | ./scripts/hooks/upgrade-notice.sh | jq -r '.hookSpecificOutput.additionalContext'
```

- Con `features.upgrade_notice.enabled: false` y regenerate → 0 bytes aunque haya pendientes.
- Con `vault.enabled: false` y regenerate, y un delta depositado sin integrar en disco → la capa vault no
  habla (solo la del workspace); `agentctl doctor` muestra `Vault schema deltas (skipped — vault disabled)`.
- Fallas: renombrar `scripts/lib/vault.sh`, quitar `jq` del PATH, `chmod 000` al `CLAUDE.md` del vault, escribir
  basura en la línea base → siempre exit 0, nunca salida parcial.
- `LC_ALL=C grep -c '[^ -~]'` sobre la salida → 0 (ASCII puro).

## 4. Suites de host

```bash
bats tests/                                   # bash 5.x
PATH=/bin:$PATH bats tests/                   # bash 3.2.57; secuencial, nunca en paralelo con la anterior
shellcheck -S error <comando exacto de CI>
LC_ALL=C grep -c $'\xcc\x80' specs/038-schema-delta-boot-nudge/*.md modules/upgrade-notice*.tpl   # 0
```

## 5. DOCKER_E2E (obligatorio: `start_services.sh` es image-baked)

`tests/docker-e2e-upgrade-notice.bats`. Pre-sembrar el fixture en `.state/.vault` antes de `docker compose up`
(lección de 037) y esperar el symlink `/home/agent/vault` como señal de boot completo.

| Caso | Fixture | Esperado |
|---|---|---|
| E1 | vault con `.applied` 0.27.0 sin hito | `settings.json` del agente con una entrada `SessionStart` al comando del hook; el hook, corrido como `agent`, emite JSON que contiene `0.27.0` |
| E2 | igual, tras `docker compose restart` (el boot vuelve a correr `start_session`) | sigue habiendo una sola entrada (idempotencia) |
| E3 | vault con el hito presente y `CLAUDE.md` = upstream | el hook emite 0 bytes |
| E4 | copia aislada de heartbeat | su `settings.json` no tiene `.hooks.SessionStart` |

La inyección real en el modelo no se prueba aquí (sin OAuth en el arnés): queda en G1.

## 6. Mutación (contra la implementación real)

| # | Mutación | Test que debe cazarla |
|---|---|---|
| M1 | `vault_pending_deltas` ignora el `.applied` | vault sin marcador debe dar vacío |
| M2 | ignora el hito | vault con hito debe dar vacío |
| M3 | quita la fila 0.8.0 de la tabla | guardia de deriva (1) |
| M4 | cambia el literal 0.27.0 | guardias (2), (3), (4) |
| M5 | `refresh` sin exigir `C = B` | `CLAUDE.md` editado debe quedar byte-idéntico |
| M6 | `render` (force) no actualiza `B` | tras force, estado `in_sync` y `B = U` |
| M7 | `adopt` no escribe `B` | sin línea base y `C = U`, el siguiente cambio debe dar `refresh` |
| M8 | el hook ignora el interruptor | `enabled: false` → 0 bytes |
| M9 | el hook trata `customized` como pendiente | `customized` → 0 bytes |
| M10 | heartbeat no descarta `SessionStart` | `heartbeat-isolation.bats` |
| M11 | instalador sin dedupe | N corridas → una entrada |
| M12 | doctor usa `_doctor_pass` para un pendiente | test de doctor: WARN y contador |

## 7. Gates de hardware

**Mantener un fixture vivo**: no pedirle a linus que integre el delta 0.27.0 ni forzar su `CLAUDE.md` antes del
deploy de 038. Su estado actual (ambas capas pendientes) es el caso de SC-001.

**G0. Remote Control ejecuta `SessionStart`** (ferrari-admin, modo local, SSH directo; US4 se implementó
igual porque es inocua si no dispara, pero NO se debe afirmar entrega en sesión en modo local hasta medir
esto). Reversible, sin secretos (el payload del hook trae ids y rutas, no credenciales):

```bash
# 1. en ferrari, sin sudo (ssh ferrari):
WS=~/Documents/Personal/Claude/Agents/ferrari-admin
cp "$WS/.state/.claude/settings.json" "$WS/.state/.claude/settings.json.pre-g0"
printf '%s\n' '#!/bin/bash' '{ date -u +%FT%TZ; cat; echo; } >> "$(dirname "$0")/g0-probe.log"' 'exit 0' > "$WS/.state/g0-probe.sh"
chmod +x "$WS/.state/g0-probe.sh"
jq --arg c "$WS/.state/g0-probe.sh" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks:[{type:"command",command:$c,timeout:10}]}])' \
  "$WS/.state/.claude/settings.json.pre-g0" > "$WS/.state/.claude/settings.json"

# 2. reiniciar la sesion (necesita sudo):   sudo systemctl restart agent-ferrari-admin.service
# 3. desde el cliente de Remote Control, abrir o continuar la sesion; esperar un minuto
# 4. leer:   cat "$WS/.state/g0-probe.log"
#      una linea con "source":"startup" o "resume"  => DISPARA   (anotar fecha y `claude --version`)
#      archivo ausente o vacio                      => NO dispara (local queda solo con doctor)
# 5. retirar la sonda:
cp "$WS/.state/.claude/settings.json.pre-g0" "$WS/.state/.claude/settings.json"
rm -f "$WS/.state/g0-probe.sh" "$WS/.state/g0-probe.log" "$WS/.state/.claude/settings.json.pre-g0"
```

Resultado, con fecha, en Notes de `tasks.md`. Si dispara, quitar la reserva "no medido" de CHANGELOG, README,
`docs/architecture.md` y `CLAUDE.md`; si no, dejarla y documentar que local se cubre con doctor.

**G1. Docker** (linus, desde la rama 038 y antes de cualquier merge, por decisión del operador del 02-10-2026;
lo ejecuta el operador). Parámetros de linus en ferrari, medidos en el despliegue de 037: workspace
`/home/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/linus`, contenedor `linus`, clon del launcher
`~/apl-src`. El alias de SSH hacia ferrari está por confirmar (`ssh ferrari` en G0; `ssh-ferrari` en notas
anteriores).

```bash
WS=/home/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/linus
SRC=~/apl-src
BR=038-schema-delta-boot-nudge
```

**Fase 0. Llevar la rama a ferrari.** El clon solo sigue `main` en su refspec, así que una rama se trae con un
fetch explícito que cree la rama local.

- Con la rama en el remoto: `git -C "$SRC" fetch origin "$BR:$BR"`.
- Sin subirla (bundle): en la Mac, `git bundle create /tmp/038.bundle 70214d9..038-schema-delta-boot-nudge` y
  `scp /tmp/038.bundle ferrari:/tmp/`; en ferrari, `git -C "$SRC" bundle verify /tmp/038.bundle` y luego
  `git -C "$SRC" fetch /tmp/038.bundle "$BR:$BR"`. Requiere que el clon tenga `70214d9`, el `main` anterior al
  merge de 037 (`git -C "$SRC" cat-file -t 70214d9` debe decir `commit`). El bundle lleva tres commits: el squash
  de 037 (`6a6ce54`) y los dos de 038.

**Fase A. Despliegue.** En un `tmux` de ferrari, o con `nohup`: la espera de 150 s no debe morir con la sesión SSH.

```bash
# A1. Estado previo, solo lectura. Esperado: 0.27.0, contenedor healthy, delta depositado y sin hito.
cat "$WS/VERSION"; docker ps --filter name='^linus$' --format '{{.Names}} {{.Status}}'
VAULT="$WS/.state/.vault"
test -f "$VAULT/_templates/.schema-updates-0.27.0.applied" && echo "delta 0.27.0 depositado"
grep -c -F '## Actionability (PARA)' "$VAULT/CLAUDE.md"      # 0 = sin integrar (el fixture de SC-001)
git -C "$SRC" status --short                                  # vacío

# A2. Backup liviano: el swap no toca .state ni el archivo de entorno, así que no entran en la copia.
#     El umask va en un subshell: si quedara activo, lo que crean A3 y el regenerate saldría con modo 0600.
cd "$(dirname "$WS")" && ( umask 077; tar czf "$HOME/linus-pre038-$(date +%Y%m%d-%H%M%S).tar.gz" \
  linus/setup.sh linus/VERSION linus/modules linus/docker linus/scripts linus/CLAUDE.md linus/agent.yml \
  linus/docker-compose.yml linus/.mcp.json )

# A3. Swap de archivos de sistema (README, "Upgrade an existing agent"), desde la rama.
cd "$SRC" && git checkout "$BR" && git log --oneline -1 && cat VERSION      # 0.28.0
cp setup.sh VERSION .gitignore LICENSE "$WS/"
for d in modules docker; do [ -d "$d" ] && { rm -rf "${WS:?}/${d:?}"; cp -R "$d" "$WS/"; }; done
cp -R scripts "$WS/"

# A4. Re-render SIN forzar: preserva CLAUDE.md, lo reporta y deja el render vigente en .state/launcher/.
cd "$WS" && ./setup.sh --regenerate < /dev/null 2>&1 | tee /tmp/linus-regen1.log | tail -25
#   esperado: "✓ scripts/hooks/ (upgrade-notice.sh + install-upgrade-notice-hook.sh)" y
#             "◦ CLAUDE.md (preserved: differs from the current template; compare with ...)"

# A5. Build y reinicio con la cadencia anti-flap (stop, ~150 s, start).
docker compose build            # ~30 s: el Dockerfile no cambió, sin recompilar el toolchain nativo
docker compose stop && sleep 150 && ./scripts/agentctl up
```

**Fase B. Medición con las dos capas pendientes.** No integrar ni forzar nada todavía.

```bash
./scripts/agentctl doctor | grep -E 'Vault schema|Workspace CLAUDE.md'
#   esperado: dos WARN: "Vault schema delta pending integration: 0.27.0" y
#             "Workspace CLAUDE.md differs from the current template (no baseline)"
jq '.hooks.SessionStart' "$WS/.state/.claude/settings.json"
#   esperado: una entrada, command /workspace/scripts/hooks/upgrade-notice.sh, timeout 10, sin matcher
docker exec -u agent linus /workspace/scripts/hooks/upgrade-notice.sh < /dev/null | jq -r '.hookSpecificOutput.additionalContext'
#   esperado: el aviso, que empieza "Aviso del launcher al iniciar sesion: tienes conocimiento pendiente de actualizar."
docker exec -u agent linus claude --version     # anotar: la inyección se midió en 2.1.280; el piso del launcher es 2.1.170
```

1. **SC-001.** Por Telegram, sin mencionar el upgrade: "resume tu sistema de conocimiento". Pasa si la respuesta
   menciona la integración pendiente (delta 0.27.0, PARA, `CLAUDE.md` desactualizado) o ya refleja 0.27.0. Anotar
   el texto literal.
2. **Compactación.** `./scripts/agentctl attach`, `/compact` y preguntar "¿tienes pendientes de actualización de
   conocimiento?". Confirma que el aviso vuelve tras una compactación (no medido en host). Salir con `Ctrl-b d`.

**Fase C. Resolver las dos capas.**

```bash
cd "$WS" && printf 'y\n' | ./setup.sh --regenerate --force-claude-md 2>&1 | tail -15   # esperado: "✓ CLAUDE.md (overwritten)"
```

Siempre por stdin: con `< /dev/null` toma el default `n` y no hace nada. linus NO tiene overlay de MCPs: en
`agentic-pod-launcher-custom-config` solo `donna` tiene `overlay.yml`; `linus` y `ferrari-admin` solo tienen
`syncthing.yml`, que consume otro script. En donna, un regenerate pelado le borra sus 4 MCP inyectados, y el orden
es el mismo seguido de `<custom-config>/bin/custom-apply.sh <ws> --agent donna --no-regenerate`, dentro de
`bash -lc` para tener `yq`/`jq`.

1. Pedirle a linus por Telegram que integre el delta 0.27.0 de su vault. Luego, `agentctl doctor`: los dos PASS.
2. Reiniciar con la cadencia anti-flap (`docker compose stop && sleep 150 && ./scripts/agentctl up`) para que la
   sesión nueva cargue el `CLAUDE.md` vigente.

**Fase D. Silencio (SC-003).** Con la sesión nueva, `docker exec -u agent linus /workspace/scripts/hooks/upgrade-notice.sh < /dev/null | wc -c`
debe dar `0`, `agentctl doctor` debe mostrar los dos PASS, y al preguntarle "¿tienes pendientes de actualización de
conocimiento?" no debe mencionar ninguno.

**Registro.** Pasar las salidas de doctor de antes y después, las respuestas de linus (SC-001 y compactación),
`claude --version` y el `wc -c` de la fase D. Se anotan con fecha en Notes de `tasks.md` (T044).

**Reversa.** Para silenciar sin tocar código: `yq -i '.features.upgrade_notice.enabled = false' "$WS/agent.yml"` y
`./setup.sh --regenerate` (el aviso queda registrado pero no emite nada). Para volver a 037:

```bash
BK=$(ls -t ~/linus-pre038-*.tar.gz | head -1)            # el backup más reciente de A2
tar xzf "$BK" -C "$(dirname "$WS")"
rm -f "$WS/scripts/hooks/upgrade-notice.sh" "$WS/scripts/hooks/install-upgrade-notice-hook.sh"
t=$(mktemp) && jq --arg c /workspace/scripts/hooks/upgrade-notice.sh '
  if ((.hooks.SessionStart // []) | length) == 0 then .
  else .hooks.SessionStart |= map(select(([.hooks[]?.command] | index($c)) | not))
       | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
  end' "$WS/.state/.claude/settings.json" > "$t" && cp "$t" "$WS/.state/.claude/settings.json"; rm -f "$t"
cd "$WS" && docker compose build && docker compose stop && sleep 150 && ./scripts/agentctl up
```

**G2. Local** (ferrari-admin o mclaren, si G0 pasó): las mediciones de la fase B (doctor y la pregunta de SC-001)
y la fase D, desde Remote Control.

**Rollout a la flota**: tras el deploy, todos los agentes mostrarán el WARN de workspace sin línea base. Forzar
el re-render una vez por agente con el orden de la fase C (`custom-apply` solo en donna, la única con
`overlay.yml`). Medido en donna: la persona sale idéntica.

## 8. Cierre

- [ ] Suites en 0 `not ok` en bash 3.2.57 y 5.x; `shellcheck -S error` limpio.
- [ ] DOCKER_E2E E1-E4 verdes.
- [ ] Revisión del diff de `docker/` contra el Principio II registrada (gate de privilegios de la constitución).
- [ ] Mutación M1-M12 corrida; cualquier sobreviviente endurece el oráculo antes de seguir.
- [ ] Auditoría de bytes en 0 (artefactos, plantillas, bats).
- [ ] `VERSION` 0.28.0 verificada a mano contra `origin/main` tras el rebase sobre 037 mergeada; `CHANGELOG.md`,
      `docs/vault.md` (convención de hitos para autores de deltas), `docs/architecture.md` (capa workspace).
- [ ] G0, G1 y G2 registrados con fecha en Notes de `tasks.md`.
- [ ] PR solo con confirmación del operador (037 mergeó el 03-10-2026, #100); su merge, después de G1.
