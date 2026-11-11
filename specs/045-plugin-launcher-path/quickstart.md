# Quickstart: validar la feature 045

**Feature**: `045-plugin-launcher-path` | Guía de validación. El detalle de cada prueba está en `contracts/host-oracle.md` y `contracts/e2e-and-gate.md`.

Todo se corre desde el worktree `.claude/worktrees/045-plugin-launcher-path`. En el Mac, `bats`, `yq`, `gpg` y `tmux` necesitan `/opt/homebrew/bin` en el PATH.

## V1. Línea base del host

Antes de tocar código, mide la suite sobre una copia aislada de `origin/main`, en los dos bash y en secuencia (nunca en paralelo):

```bash
export PATH=/opt/homebrew/bin:$PATH
bats tests/ 2>/dev/null | grep -c '^ok '                          # bash 5.x
PATH=/bin:$PATH bats tests/ 2>/dev/null | grep -c '^ok '          # bash 3.2.57
```

Se registran los `ok`, los `not ok` y los saltados de cada bash. El esperado final es esa línea base más 18: las 13 pruebas del oráculo y las 5 del e2e nuevo, que en el host salen saltadas.

## V2. ROJO y después VERDE del oráculo

```bash
bats tests/agent-user-bin-path.bats                     # contra el código actual: 11 rojas, 2 verdes (H2, G1)
# ... implementación ...
bats tests/agent-user-bin-path.bats                     # 13 de 13
PATH=/bin:$PATH bats tests/agent-user-bin-path.bats     # 13 de 13 en bash 3.2
bats tests/agentctl.bats                                # incluida la prueba actualizada de agentctl mcp
```

## V3. Mutaciones

Se aplican M1 a M18 de `contracts/host-oracle.md`, cada una sobre una copia aislada, y se corre el oráculo en los dos bash. Cada mutación tiene que hacer caer su prueba. P5 y M7 se repiten en `ubuntu:24.04` como no root, con el repo copiado y no montado.

## V4. Gate completo del host

```bash
shellcheck -S error docker/scripts/lib/agent_path.sh docker/scripts/start_services.sh scripts/heartbeat/heartbeat.sh scripts/agentctl
bats tests/                      # línea base + 18 (13 del oráculo y 5 e2e saltadas), 0 not ok
PATH=/bin:$PATH bats tests/      # ídem en bash 3.2
```

Además, `git diff origin/main -- modules/ setup.sh docker/entrypoint.sh` debe quedar vacío (FR-005 y FR-006; `modules/` incluye `docker-compose.yml.tpl` y las plantillas del modo local), y `VERSION` debe decir 0.31.0, verificado contra `git show origin/main:VERSION`.

## V5. Contenedor real (COMPUERTA)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-user-bin-path.bats   # E1 a E5
DOCKER_E2E=1 bats tests/docker-e2e-*.bats               # suite e2e entera: 49 + 5
```

## V6. Gate en cbum antes del merge (COMPUERTA)

Pasos de la sección G de `contracts/e2e-and-gate.md`. Resultado esperado:

- antes del reinicio, el conteo de registros `hook_non_blocking_error` con `Executable not found in $PATH: "claude-mem"` en el transcript da 3 o más (el control positivo);
- después del reinicio y de tres prompts, el mismo conteo limitado a la hora posterior al reinicio da 0;
- sin el enlace manual;
- el PATH del pane termina en `/home/agent/.local/bin`;
- claude-mem registró la sesión: el worker sigue vivo y `~/.claude-mem/claude-mem.db-wal` cambió;
- 0 reinicios.

## V7. Después del merge

Se reconstruyen donna y linus (sección D) y se registran sus primeras 24 h. Además se actualizan la ficha de cbum, la memoria y la página del equipo en Confluence (el pendiente operativo «claude-mem 15.x»). La actualización en Confluence sale del equipo y requiere confirmación.
