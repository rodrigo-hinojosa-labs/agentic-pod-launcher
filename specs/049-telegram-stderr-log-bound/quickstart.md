# Quickstart: validar la feature 049

**Prerrequisitos en el host**: `bats-core`, `python3`, `jq` y `yq` v4+. Para las pruebas de comportamiento hace falta además `bun`: la imagen fija 1.3.14 y esta Mac tiene 1.3.12. Para la sección 3, Docker.

## 1. Suite del host

```bash
bats tests/apply-telegram-patches.bats      # S1-S9 (S9 se salta sin bun)
bats tests/telegram-stderr-hook.bats        # H1-H10 y H2a (toda la suite se salta sin bun)
bats tests/agentctl-doctor-telegram-patches.bats -f "stderr log"    # A1-A5
PATH=/bin:$PATH bats tests/apply-telegram-patches.bats tests/telegram-stderr-hook.bats   # bash 3.2.57
```

**Esperado**: todo verde en los dos bash, con stderr vacío.

**ROJO previo**: con la implementación sin hacer, H1 tiene que fallar contra el hook v1. Ese ROJO se registra en el Registro de `tasks.md`.

## 2. Gate completo

```bash
bats tests/                                  # bash 5.x
PATH=/bin:$PATH bats tests/                  # bash 3.2.57
```

**Esperado**: la línea base medida al empezar más las pruebas nuevas, y 0 `not ok`.

Correr las dos suites en serie, nunca en paralelo (ver la memoria *measure flakes before naming them*).

## 3. DOCKER_E2E

```bash
DOCKER_E2E=1 bats tests/docker-e2e-stderr-log.bats
```

**Esperado**:

- el patcher de la imagen sube el dorado 0.34.0 a v2;
- una segunda pasada imprime `all patch groups already present`;
- con el bun de la imagen y stderr a un pipe cerrado, el log tiene una sola línea `[stderr-closed] EPIPE` y ninguna `uncaught exception: Error: EPIPE`;
- con un umbral chico, el tope se respeta.

Antes del PR, correr también `tests/docker-e2e-voice.bats`, porque toca el mismo patcher.

## 4. Despliegue y verificación en la flota (compuerta del operador)

Por agente, empezando por **cbum** como canario y siguiendo con linus y donna, con el runbook *Upgrade an existing agent* del README: copiar los archivos de sistema, `--regenerate`, build, stop, 150 s, up.

Verificación sin leer contenidos:

```bash
./scripts/agentctl heartbeat token-check
./scripts/agentctl doctor                    # "Telegram plugin patches" OK y "✓ Telegram stderr log: <N> MiB"
docker exec -u agent <agent> grep -c 'stderr-capture patch v2' \
  /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts   # 1
docker exec -u agent <agent> grep -c 'stderr-capture patch v1' \
  /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts   # 0
ls -l scripts/heartbeat/logs/telegram-mcp-stderr.log*
```

Después del despliegue, mandar un mensaje por Telegram y confirmar que el agente responde: el canal no entró en flap.

## 5. Medición opcional del tope en vivo

No hace falta forzarla en producción. Si alguna vez se ve una línea `[stderr-closed]` en el log de un agente, anotar la fecha y el contexto en el Registro: es la primera observación real del disparador inferido.
