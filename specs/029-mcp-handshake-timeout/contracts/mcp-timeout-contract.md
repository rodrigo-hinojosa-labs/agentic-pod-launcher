# Contrato: ventana de handshake MCP configurable

Define la interfaz observable de la feature 029. Los tests `bats` verifican cada cláusula.

## C1. Campo de configuración (`agent.yml`)

- **C1.1** El campo es `claude.mcp_timeout_ms`, un entero en milisegundos.
- **C1.2** El heredoc del wizard (`setup.sh`) emite `mcp_timeout_ms: 120000` dentro del bloque
  `claude:` en cada scaffold nuevo.
- **C1.3** Un `agent.yml` sin `claude.mcp_timeout_ms` (agente anterior a la feature) recibe
  `claude.mcp_timeout_ms: 120000` por backfill en `regenerate()`, detectando ausencia con
  `(.claude | has("mcp_timeout_ms"))` (no con `//`).
- **C1.4** El backfill es idempotente: no sobrescribe un valor ya presente (incluido `0`); dos
  `--regenerate` seguidos dejan el `agent.yml` byte-estable.

## C2. Saneo del valor efectivo (en el render, host)

- **C2.1** El valor efectivo se calcula en `setup.sh` antes de escribir cualquier artefacto.
- **C2.2** Entrada válida (`^[0-9]{1,7}$` y `> 0`) → el valor efectivo es esa entrada.
- **C2.3** Entrada inválida (vacía, no numérica, `0`, negativa, > 7 dígitos) → el valor efectivo es
  `120000` (default). El render **no falla**.
- **C2.4** El valor efectivo escrito nunca es `≤ 0`.
- **C2.5** El valor efectivo se expone a las plantillas como el placeholder `{{CLAUDE_MCP_TIMEOUT_MS}}`
  (re-exportado saneado; ambos modos leen el mismo).

## C3. Entrega — modo docker

- **C3.1** `modules/docker-compose.yml.tpl` declara, en el bloque `environment:`, una línea
  `MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"`.
- **C3.2** Tras `--regenerate` en modo docker, el `docker-compose.yml` renderizado contiene
  `MCP_TIMEOUT: "<valor efectivo>"` en `environment:`.
- **C3.3** El cambio no toca ningún archivo bajo `docker/` (Dockerfile, entrypoint.sh, start_services.sh):
  solo `modules/docker-compose.yml.tpl`. (Verificado: el env del compose llega intacto a `claude`.)

## C4. Entrega — modo local

- **C4.1** `modules/remote-control.env.tpl` declara una línea `MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}`.
- **C4.2** Tras `--regenerate` en modo local, `.state/remote-control.env` contiene
  `MCP_TIMEOUT=<valor efectivo>`.
- **C4.3** El valor entra al proceso `claude remote-control` por el `EnvironmentFile` de la unit de
  sesión (`systemd-remote-control.service.tpl:21`), que gana en precedencia sobre el `.env`.
- **C4.4** El unit file (`.service`) no cambia; el valor viaja por `remote-control.env` (re-rendeado en
  cada `--regenerate` sin `sudo`).

## C5. Fuente única e idempotencia

- **C5.1** El literal del valor no aparece duplicado entre `docker-compose.yml.tpl` y
  `remote-control.env.tpl`; ambos referencian `{{CLAUDE_MCP_TIMEOUT_MS}}`.
- **C5.2** Cambiar `claude.mcp_timeout_ms` y re-renderizar actualiza ambos artefactos al mismo valor.
- **C5.3** Dos `--regenerate` consecutivos producen artefactos byte-idénticos (docker y local).

## C6. No-regresión

- **C6.1** El modelo de privilegios del contenedor (Principio II) no cambia: solo se agrega una env var.
- **C6.2** Un agente que no fija `claude.mcp_timeout_ms` obtiene `120000` sin intervención ni migración.
- **C6.3** El binario `claude`, al recibir `MCP_TIMEOUT=<v>` con `v > 0`, aplica `v` como ventana de
  arranque (getter `e && e>0 ? e : 30000`), reemplazando el default de 30000.
