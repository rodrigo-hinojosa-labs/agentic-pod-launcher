# Data Model — ventana de handshake MCP configurable

## Entidad: ventana de handshake de arranque MCP

Un único escalar de configuración, con fuente única en `agent.yml` y dos rutas de entrega (una por
modo de despliegue).

### Campo en `agent.yml`

| Propiedad | Valor |
|---|---|
| Path | `claude.mcp_timeout_ms` |
| Tipo | entero (milisegundos) |
| Default (backfill / heredoc) | `120000` |
| Bloque | `claude:` (config del binario Claude Code, cross-mode) |
| Flatten (`render_load_context`) | `CLAUDE_MCP_TIMEOUT_MS` |
| Obligatorio | No (opcional; ausencia → default por backfill) |

Ejemplo en `agent.yml`:

```yaml
claude:
  config_dir: "/home/agent/.claude"
  profile_new: false
  mcp_timeout_ms: 120000
```

### Variable de entorno resultante (ambos modos)

| Propiedad | Valor |
|---|---|
| Nombre | `MCP_TIMEOUT` (lo que el binario `claude` respeta para el arranque de MCP) |
| Unidad | milisegundos |
| Consumidor | binario `claude` nativo (`MCP_TIMEOUT` → getter `e && e>0 ? e : 30000`) |
| Default del binario si ausente | `30000` (30 s) — el que la feature reemplaza por 120000 |

### Reglas de validación / saneo (en el render, `setup.sh`)

Aplicadas al valor efectivo antes de escribir los artefactos (patrón
`docker/scripts/start_services.sh:726-728`):

| Entrada (`claude.mcp_timeout_ms`) | Valor efectivo escrito |
|---|---|
| entero > 0, ≤ 7 dígitos (`^[0-9]{1,7}$`) | el valor tal cual |
| ausente | `120000` (por backfill previo en `regenerate()`) |
| vacío, no numérico, `0`, negativo, > 7 dígitos | `120000` (degradación segura; nunca ≤ 0) |

- El saneo **no falla** el render ni el arranque (FR-006): degrada al default.
- No hay validación dura en `schema.sh` (haría fallar `--regenerate`, lo contrario de FR-006).

### Transiciones de estado (ciclo de vida del valor)

```
agent.yml (claude.mcp_timeout_ms)
   │  render_load_context  →  $CLAUDE_MCP_TIMEOUT_MS (flatten crudo)
   │  mcp_timeout_effective() (saneo: entero>0 → valor; inválido → 120000)
   ▼
$CLAUDE_MCP_TIMEOUT_MS (re-exportado, saneado)
   ├─ docker →  docker-compose.yml   environment:  MCP_TIMEOUT: "<v>"
   └─ local  →  .state/remote-control.env         MCP_TIMEOUT=<v>
   ▼
proceso `claude` (env MCP_TIMEOUT) → ventana de arranque de cada MCP server
```

### Backfill (agentes existentes, en `regenerate()`)

| Estado del `agent.yml` viejo | Acción |
|---|---|
| `claude` sin `mcp_timeout_ms` (ausente) | `yq -i '.claude.mcp_timeout_ms = 120000'` |
| `claude.mcp_timeout_ms` presente (cualquier valor, incl. `0`) | no se toca (lo maneja el saneo) |

Detección de presencia por `(.claude | has("mcp_timeout_ms")) // false` (evita el gotcha del `//` que
colapsaría un `0`). Idempotente: segunda pasada byte-estable.

## Artefactos derivados afectados

| Artefacto | Plantilla | Cambio |
|---|---|---|
| `docker-compose.yml` (docker) | `modules/docker-compose.yml.tpl` | +1 línea en `environment:`: `MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"` |
| `.state/remote-control.env` (local) | `modules/remote-control.env.tpl` | +1 línea: `MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}` |
| `agent.yml` (heredoc del wizard) | `setup.sh:1203-1205` | +1 línea en el bloque `claude:`: `mcp_timeout_ms: 120000` |

## Invariantes

- **INV-1** (fuente única): el literal del valor no se duplica entre plantillas; ambas usan el mismo
  placeholder `{{CLAUDE_MCP_TIMEOUT_MS}}` derivado del único campo `claude.mcp_timeout_ms`.
- **INV-2** (nunca ≤ 0): el valor efectivo escrito en cualquier artefacto es siempre un entero > 0.
- **INV-3** (degradación, no fallo): un valor inválido produce el default, nunca un error de render o
  de arranque.
- **INV-4** (idempotencia): dos `--regenerate` consecutivos producen artefactos byte-idénticos.
- **INV-5** (aislamiento de modo): el modo local no lee el compose y el modo docker no lee la unit; cada
  uno recibe la misma env var por su propio canal.
