# Research: Aviso de actualización de conocimiento al iniciar sesión

Fase 0 del plan. Cada sección: decisión, porqué, alternativas descartadas. Lo medido se marca como tal; lo
inferido también.

## R0. Diagnóstico: dos capas, no una (medido, 30-09-2026)

| Medición | donna | linus |
|---|---|---|
| `## Actionability (PARA)` en el `CLAUDE.md` del vault | 0 | 0 |
| Marcadores en `_templates/` | `.applied` 0.8.0 y 0.27.0 | `.applied` 0.8.0 y 0.27.0 |
| `CLAUDE.md` del workspace: "derives three JSON artifacts" (pre-037) | 1 | 1 |
| `CLAUDE.md` del workspace: `policy.json` (037) | 0 | 0 |
| "Reglas de trabajo" en `personas/<agente>.md` | 1 | 1 |
| `meta.launcher_version` | 0.27.0 | 0.27.0 |

Render de la plantilla actual (0.27.0) con el `agent.yml` y `personas/donna.md` reales, en un directorio
desechable de este host, contra el `CLAUDE.md` vivo de donna: 52 líneas de diff, todas explicadas por (a) los
hunks de 037 en `modules/claude-md.tpl` y (b) la sección `## Heartbeat`, que existe en el archivo vivo pero no
en el render porque `features.heartbeat.enabled` hoy es `false`. La persona sale idéntica. **Conclusión**: el
archivo no tiene ediciones propias; está viejo respecto de la plantilla y de su propio `agent.yml`.

Causa de la preservación: `setup.sh:2680-2700` renderiza `CLAUDE.md` solo si falta, con `--force-claude-md`
(que además pide confirmación interactiva), o en modo local si es el `CLAUDE.md` del propio launcher (027). En
cualquier otro caso imprime "preserved". La persona entra por `agent.role_file`
(`scripts/lib/render.sh:63-73`), así que forzar el re-render no la pierde.

## R1. Mecanismo de entrega: hook `SessionStart`

**Decisión**: un hook `SessionStart` registrado en el `settings.json` de la sesión interactiva, que devuelve
`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}` cuando hay pendientes y no
imprime nada cuando no los hay. Sin matcher, para que dispare en todos los inicios de sesión: `startup` y
`resume` (medidos abajo), y `clear` y `compact` (según la documentación de Claude Code; no medidos, se verifican
en el gate G1).

**Medido** (Claude Code 2.1.280, `claude -p --settings <tmp>` en un directorio desechable):

- Arranque: el hook recibe `source=startup` y el modelo repite literalmente el texto inyectado.
- `--continue`: el hook recibe `source=resume`; el modelo ve el texto de ambos inicios (el del arranque queda en
  el historial). El payload de `resume` trae además `context_tokens`, `seconds_since_last_response` y
  `prompt_cache_likely_expired`.
- Una sesión reanudada con `--continue` carga el `CLAUDE.md` vigente del disco (un marcador cambiado entre
  corridas aparece con su valor nuevo).

**Porqué**: es la única superficie que llega a la sesión que conversa con el operador, que es donde falló
donna, y funciona igual en ambos modos. El repo ya instala hooks antes de la sesión en ambos modos
(`start_services.sh:791-805`, `local-login.sh.tpl:68-88`); los hooks se toman como snapshot al arrancar, por
eso se instalan antes de lanzar `claude`.

**No verificado**: el comportamiento en el piso del launcher (`AGENTIC_FLOOR_CLAUDE_CODE=2.1.170`) y en la
versión pineada de cada imagen. DOCKER_E2E no lo mide: el arnés no tiene OAuth y no abre una sesión de Claude,
solo verifica la instalación del hook y su salida. La inyección real en el modelo se mide únicamente en el gate
G1, que registra la versión de `claude` del contenedor. Si una imagen trae una versión sin `additionalContext`
para `SessionStart`, el aviso no llega pero nada falla y doctor sigue reportando. Remote Control: ver R7.

**Alternativas descartadas**:

- *Turno aislado de heartbeat en docker* (borrador previo): la integración ocurre en una sesión desatendida que
  edita el `CLAUDE.md` del vault sin nadie presente, su salida depende del notifier configurado (`none`/`log`
  no llega a nadie), no existe en modo local y deja intacto el contexto de la sesión interactiva.
- *`UserPromptSubmit`*: inyectaría el aviso en cada mensaje; más costo de contexto sin beneficio.
- *Escribir el aviso en un archivo que la sesión carga* (`CLAUDE.md` o similar): contamina un archivo derivado
  o del agente para comunicar estado efímero.

## R2. Capa vault: tabla explícita de hitos

**Decisión**: tres funciones en `scripts/lib/vault.sh`:

- `vault_delta_versions`: lista las versiones conocidas en orden ascendente (`0.8.0`, `0.27.0`).
- `vault_delta_checkpoint <versión>`: devuelve el hito literal; versión desconocida → código 1.
- `vault_pending_deltas <vault_root>`: imprime una versión por línea si su `.applied` existe y su hito no
  aparece (`grep -F`) en `<vault_root>/CLAUDE.md`. Siempre código 0.

| Versión | Hito | Fuente |
|---|---|---|
| 0.8.0 | `wiki/normalization/` | No declarado por el delta. Medido: presente 4 veces en los vaults de donna, linus y rodri-cenco-admin, los tres con 0.8.0 integrado. Presente en el skeleton (`modules/vault-skeleton/CLAUDE.md:106`). |
| 0.27.0 | `## Actionability (PARA)` | Declarado por el propio delta (`modules/vault-deltas/schema-updates-0.27.0.md:11-13`) y usado por `wiki_graph.sh:458`. |

**Guardias de deriva** (tests, no código): (1) cada `modules/vault-deltas/schema-updates-*.md` tiene fila en la
tabla y viceversa; (2) el skeleton contiene todos los hitos, lo que garantiza SC-007 (un vault nuevo nunca está
pendiente; ojo: `vault_seed_if_empty` escribe el `.applied` de 0.27.0 en todo vault nuevo, `vault.sh:56`); (3)
el literal de `wiki_graph.sh` coincide con la fila 0.27.0; (4) el documento 0.27.0 contiene su hito.

**Porqué una tabla y no derivarlo del documento**: el agente puede borrar el delta depositado tras integrarlo
(el propio documento lo autoriza) y el hito de 0.8.0 no está declarado en ninguna parte; una tabla explícita
es testeable y las guardias evitan que diverja. **Porqué no refactorizar `wiki_graph.sh`**: 037 lo dejó
mutation-tested; la duplicación de un literal queda vigilada por la guardia (3).

**Convención nueva** para autores de deltas: todo delta futuro declara su hito en su encabezado y agrega su
fila a la tabla; la guardia (1) falla si se olvida.

## R3. Capa workspace: render vigente + línea base

**Decisión**: `--regenerate` siempre escribe el render vigente en `.state/launcher/claude-md.upstream.md`.
Con `C` = `CLAUDE.md`, `U` = upstream y `B` = `.state/launcher/claude-md.baseline.md`, decide por `cmp -s`:

| Situación | Acción | Resultado |
|---|---|---|
| `C` no existe | render | `C=U`, `B=U` |
| `--force-claude-md` confirmado | render | `C=U`, `B=U` |
| `C` es el `CLAUDE.md` del launcher (local, 027) | render | `C=U`, `B=U` |
| `B` existe, `C=B`, `C≠U` | **refresh** | `C=U`, `B=U`, línea "refreshed" |
| `C=U`, `B` ausente o distinta | adopt | `B=U` |
| `C=U`, `B=U` | nada | sin cambios |
| cualquier otro | preserve | `C` intacto, desfase reportado |

Estado para el aviso y para doctor (`claude_md_state`): `in_sync` (`C=U`), `customized` (`C≠U`, `B=U`: las
diferencias son ediciones propias y la plantilla no cambió; no es pendiente), `pending_template` (`C≠U`,
`B≠U`: la plantilla cambió desde lo último integrado; el diff exacto es `B→U`), `pending_no_baseline`
(`C≠U`, sin `B`: toda la flota hoy), `unknown` (sin `U`: workspace que aún no corrió un regenerate post-038; no
se avisa).

**Confirmación manual** (FR-006b): tras integrar a mano, `cp <U> <B>`. El aviso y doctor muestran el comando
con rutas absolutas. Se elige `cp` y no un subcomando porque en docker el agente no puede correr `agentctl`
(host) y `heartbeatctl` es image-baked: agregarle un subcomando exigiría rebuild para algo que es una copia.

**Porqué una copia completa y no un hash**: además de decidir, la línea base es la base del diff que el agente
necesita en `pending_template`; y `cmp -s` evita depender de `sha256sum` vs `shasum` entre Linux y macOS.

**Porqué `.state/launcher/`**: gitignoreado por `/.state/`, viaja con el workspace, y es visible en el
contenedor como `/workspace/.state/launcher/` (bind-mount `./:/workspace`, `docker-compose.yml.tpl:55`).
`scripts/heartbeat/` no sirve: su contenido no está gitignoreado salvo `logs/` y `heartbeat.conf`. El nombre
`claude-md.*.md` evita que Claude Code lo trate como un `CLAUDE.md` anidado.

**Alternativas descartadas**: re-render siempre (borra sin aviso ediciones hechas directo en `CLAUDE.md`);
solo aviso (cada upgrade exige trabajo manual aunque el archivo no tenga ediciones, que es el caso medido);
detectar "viejo pero sin ediciones" sin línea base (no hay forma de probarlo: no se guardó el render antiguo);
separar plantilla y persona en archivos distintos (arreglo de raíz, pero choca con la feature 004 de
custom-config; queda para otra feature).

## R4. Instalación y ciclo de vida del hook

- **Render**: `modules/upgrade-notice.sh.tpl` → `scripts/hooks/upgrade-notice.sh` y
  `modules/upgrade-notice-install.sh.tpl` → `scripts/hooks/install-upgrade-notice-hook.sh`, en todo
  regenerate, sin gate. El interruptor `features.upgrade_notice.enabled` queda horneado en el hook: apagado,
  el hook sale en silencio. Así apagarlo nunca deja en `settings.json` una referencia a un archivo borrado.
- **Docker**: `pre_install_upgrade_notice_hook` en `start_session`, junto a `pre_install_stop_hook` y
  `pre_install_askq_hook`: corre en el boot y en cada respawn del watchdog, idempotente. Workspace sin el
  instalador (pre-038) → no-op.
- **Local**: paso 4e en `local-login.sh.tpl` para logins nuevos, y además `setup.sh --regenerate` ejecuta el
  instalador contra `<ws>/.state/.claude/settings.json`. Lo segundo es lo que alcanza a los agentes locales
  existentes, que se actualizan con regenerate y no vuelven a hacer login.
- **Instalador**: merge aditivo de `.hooks.SessionStart` con dedupe por comando y `timeout: 10`; preserva
  cualquier otro hook. Mismo molde que `stop-hook-install.sh.tpl`.
- **Heartbeat**: `scripts/heartbeat/heartbeat.sh:151` agrega `del(.hooks.SessionStart)` al aislamiento, igual
  que 028 y 031 descartan `Stop` y `PreToolUse`.

## R5. Texto del aviso

- Idioma por `user.language`: `en` → inglés; cualquier otro valor (`es`, `mixed`) → español, mismo mapeo que
  `heartbeat_review_prompt_default` (`docker/scripts/heartbeatctl:251-261`). Sin tildes ni caracteres fuera de
  ASCII, por la regla de bytes de 033/034/037. Textos canónicos en `contracts/upgrade-notice-hook.md`.
- Por cada delta: versión, ruta del documento (la copia del vault si existe; si el agente la borró, la del
  launcher en `<ws>/modules/vault-deltas/`, presente en ambos modos porque el scaffold copia `modules/`) e hito.
- Para el workspace: ruta del render vigente, instrucción de tratarlo como autoritativo para la maquinaria del
  launcher hasta actualizarlo, y el remedio según el estado (`--force-claude-md` por el operador si no hay
  contenido propio; integrar y confirmar con `cp` si lo hay; `diff B U` en `pending_template`).
- Cierre: no bloquear la primera petición del operador para integrar, salvo que dependa de la base de
  conocimiento. Motivo: el parche de typing v4 avisa al chat que algo falló a los 5 minutos, e integrar el
  delta 0.27.0 (360 líneas) puede acercarse a eso.
- Tamaño acotado: peor caso (dos deltas + workspace) bajo 2 KB.

## R6. Superficie para el operador: `agentctl doctor`

**Decisión**: una función `_upgrade_notice_doctor <ws> <vault_root>` llamada desde el doctor docker (tras la
sección 11, vault) y desde el doctor local. Corre del lado del host en ambos modos, con las librerías del
workspace: en docker la raíz del vault en el host es `<ws>/<vault.path>` (default `.state/.vault`). No corre con
el contenedor caído: el doctor docker termina antes (`exit 2`) si el daemon no responde o el contenedor no
existe o no está corriendo (`scripts/agentctl:343-376`), y esta feature no cambia ese orden. Dos líneas: vault (WARN con versiones pendientes o PASS) y
workspace (WARN con estado y remedio, o PASS). Persisten en cada corrida hasta resolverse.

**Descartado**: `heartbeatctl status` (image-baked y centrado en el heartbeat; doctor ya cubre ambos modos);
leer `schema_delta_pending` desde `wiki-graph.json` (caché con hasta 6 h de atraso y 14 días de gracia; además
solo conoce 0.27.0).

## R7. Remote Control (modo local): gate de factibilidad

**No verificado**: si las sesiones que `claude remote-control --spawn=session` crea ejecutan los hooks
`SessionStart` del `CLAUDE_CONFIG_DIR` de la unit. Inferencia: Remote Control corre la sesión en el host y el
cliente solo la controla, así que debería; no hay medición.

**Gate G0** (barato, antes de implementar US4): en ferrari-admin (local, SSH directo), registrar un hook sonda
que anote su payload en un archivo, abrir una sesión desde el cliente y revisar el archivo. Si no dispara: el
modo local queda cubierto solo por doctor, US4 se marca como no factible y la brecha se documenta. El resto de
la feature no cambia.

## R8. Estrategia de pruebas

- Host, sin Docker: matriz de `vault_pending_deltas` y guardias de deriva; matriz completa de R3 sobre
  `regenerate` real en un workspace temporal (incluida la idempotencia: dos regenerate seguidos son
  byte-idénticos); hook renderizado en modo docker y local, ejecutado con stdin falso, comparando su salida
  (SC-006); fallas inyectadas (SC-005); instalador; aislamiento de heartbeat; doctor en ambos modos.
- DOCKER_E2E (obligatorio, `start_services.sh` es image-baked): fixture de vault pendiente pre-sembrado en
  `.state/.vault` antes de `up` (lección de 037), boot real, `settings.json` con el hook, hook ejecutado como
  `agent` con salida que nombra 0.27.0, y respawn sin duplicar la entrada.
- La inyección en el modelo dentro del contenedor no se puede probar sin OAuth: queda en el gate de hardware.
- Mutación: tabla de `quickstart.md` §5 contra la implementación real.

## R9. Interacciones con otras features

- **custom-config 004** (reglas de persona, en curso en otra sesión): debe escribir en `personas/<agente>.md`.
  Si escribiera en `CLAUDE.md`, ese archivo dejaría de coincidir con su línea base y el re-render automático se
  detendría para siempre en ese agente. Avisar a esa sesión.
- **`custom-apply.sh`**: corre `--regenerate` y luego solo toca `.mcp.json`; compone sin cambios.
- **037**: no se toca `wiki_graph.sh` ni `schema_delta_pending` ni su gracia de 14 días.
- **036** (resiliencia de boot): la instalación del hook es una llamada más con `|| true` dentro de
  `start_session`; no toca `_run_watchdog` (congelado por oráculo sha).
