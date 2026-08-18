# Quickstart — ventana de handshake MCP configurable

## Qué resuelve

Un MCP cuyo primer arranque tarda (descarga en frío de su paquete, host lento, muchos MCPs) puede
exceder la ventana de handshake de Claude Code (default 30 s) y quedar **muerto por el resto de la
sesión**, sin reintento. Esta feature hace la ventana configurable desde `agent.yml`, con default 120 s,
en docker y en local.

## 1. Configurar

En `agent.yml`, bloque `claude:`:

```yaml
claude:
  config_dir: "/home/agent/.claude"
  profile_new: false
  mcp_timeout_ms: 120000   # ventana de handshake de arranque MCP, en ms (default 120000)
```

- **Ausente** → el backfill de `--regenerate` lo pone en `120000`.
- **Valor inválido** (vacío, no numérico, `0`, negativo) → degrada a `120000` sin fallar el render.
- Para un host muy lento o un MCP de descarga pesada, súbelo (p. ej. `180000`).

Aplicar:

```bash
./setup.sh --regenerate
```

## 2. Verificar — modo docker

```bash
# El valor quedó en el compose renderizado:
grep MCP_TIMEOUT docker-compose.yml
#   environment:
#     MCP_TIMEOUT: "120000"

# Y llega al proceso dentro del contenedor:
./scripts/agentctl up
docker exec -u agent <container> printenv MCP_TIMEOUT     # -> 120000
```

## 3. Verificar — modo local (systemd)

```bash
# El valor quedó en el EnvironmentFile de la sesión:
grep MCP_TIMEOUT .state/remote-control.env
#   MCP_TIMEOUT=120000

# Y systemd lo entrega a la sesión (tras reinstalar/reiniciar la unit):
systemctl show -p Environment agent-<name>.service   # o inspeccionar /proc/<pid>/environ
```

En local, si `install_service:true` y hay `sudo`, `--regenerate` reinstala la unit; si no, corre el
paso de login/instalación documentado. `remote-control.env` se re-rendea siempre en `--regenerate`
(solo requiere `systemctl restart` para que la sesión recoja el nuevo valor).

## 4. Diagnóstico — distinguir un MCP lento de uno roto

Ampliar la ventana absorbe arranques lentos, pero no debe esconder un MCP genuinamente roto (secreto
faltante, binario ausente, mala config). Cómo separarlos:

- **Lento pero sano**: el proceso del MCP aparece en el contenedor/host tras unos segundos y `claude`
  lo lista como conectado. Con cache caliente el segundo arranque es rápido (el incidente de `donna`:
  3 s con cache vs ~50 s en frío).
- **Roto**: el proceso del MCP no arranca ni manualmente. Verificación directa:
  ```bash
  # docker
  docker exec -u agent <container> pgrep -af <mcp-binario>     # ausente = no arrancó
  # arranque manual para ver el error real (sin la ventana de handshake de por medio):
  docker exec -u agent <container> <comando-del-mcp-en-.mcp.json>
  ```
  Si el arranque manual falla, el problema no es la ventana: es el MCP. Si el arranque manual levanta
  en pocos segundos pero bajo `claude` quedaba muerto, la ventana era la causa → súbela.

## 5. Deploy del incidente (donna)

Tras desplegar la feature a `donna` (re-scaffold o `--regenerate` + rebuild/recreate), recrear el
contenedor con el cache de `workspace-mcp` frío debe dejar `google-workspace` **conectado** (la descarga
de ~50 s cabe en los 120 s), en vez del estado muerto del 16-08-2026.
