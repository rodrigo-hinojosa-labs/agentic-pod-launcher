# Quickstart: validar que las secciones con lock de qmd sueltan `.reindex.lock`

**Feature**: `044-qmd-lock-fd-leak` | **Contratos**: [lock-release](contracts/lock-release.md), [host-oracle](contracts/host-oracle.md), [evidence-protocol](contracts/evidence-protocol.md)

Escenarios ejecutables, en el orden del protocolo de evidencia. Se corren desde el worktree de 044.

## Requisitos previos

- `bats`, `jq`, `yq` v4+ y `perl` en el host.
- `flock` y `timeout` no hacen falta en el host: las pruebas traen sus fixtures.
- Docker Desktop, solo para V4 y V5.

## V1. El oráculo cae contra el código actual y pasa con el arreglo (host, sin Docker)

```bash
# Con el arreglo todavía sin aplicar (código de origin/main):
bats tests/qmd-lock-release.bats                 # bash del PATH (5.x)
PATH=/bin:$PATH bats tests/qmd-lock-release.bats # bash 3.2.57
```

Esperado, antes del arreglo:
- caen L1, L2, L3, L4, L7 y G1: el `flock -n` posterior a la sección falla mientras dura el vigilante falso, y G1 no encuentra el `flock -u 9` final;
- pasan L5, L6, L8 y G2.

Esperado, con el arreglo: 10 de 10 en los dos bash.

## V2. Cada prueba puede fallar (mutaciones)

Se aplica cada mutación M1 a M9 de `contracts/host-oracle.md` §3 a una copia aislada del árbol, con un corredor del scratchpad. Se corre `tests/qmd-lock-release.bats` en los dos bash, y en la pata Linux (`ubuntu:24.04`, no root) para el `flock` real. Antes se corre el control M0: el archivo final contra el `qmd_index.sh` de `origin/main`.

Esperado: en M0 caen L1, L2, L3, L4, L7 y G1, y pasan L5, L6, L8 y G2; cada mutación M1 a M9 cae por las pruebas de su fila.

## V3. La suite completa (gate)

```bash
bats tests/                        # bash 5.x
PATH=/bin:$PATH bats tests/        # bash 3.2.57
```

Esperado: la línea base medida más 10, 0 `not ok` y la salida de error vacía en los dos bash. `shellcheck -S error` del comando de la CI en 0.

## V4. El BusyBox real suelta el lock (contenedor desechable)

Es la medición de `research.md` M1, repetida sobre el árbol final: las secciones reales con el motor falso, y el `timeout` y el `flock` de `alpine:3.24.1` (BusyBox 1.37.0) y de `alpine:3.20` (1.36.1).

Esperado:
- 0 sondeos de 100 ms tras el setup, el reindex y el reindex con migración, en 3 de 3 repeticiones;
- un perdedor que encuentra el lock tomado se salta con rc 0 y `already running`;
- una llamada colgada con `QMD_CMD_TIMEOUT=2` termina con 143 en BusyBox y con 124 en GNU (`ubuntu:24.04`), igual que con `origin/main` (SC-004), y el lock queda libre en el primer sondeo tras esa sección;
- en BusyBox, un SIGTERM al subshell de la sección mientras el motor está colgado deja el lock tomado mientras viva el motor, igual que con `origin/main` (`research.md` M8). La variante descartada del `trap` lo suelta, y se mide como referencia.

Con el código de `origin/main` la misma medición da 10 sondeos.

## V5. El DOCKER_E2E de qmd (COMPUERTA)

```bash
DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR="$HOME/.cache/agentic-qmd-e2e/models-041" \
  bats --tap tests/docker-e2e-qmd.bats
```

Esperado:
- 5 de 5, con `qmd real (041)` y sus ocho marcas;
- en el segundo tick de la prueba 13, sin el aviso `reindex lock busy` con dueños `timeout 900 .../qmd`. Es una observación: el ayudante de 043 sigue reintentando ante cualquier otro dueño.

## V6. La corrida manual de CI (COMPUERTA de push y de dispatch)

`docker-e2e.yml` sobre la rama, en amd64.

Esperado:
- `e2e summary: total=49 executed=49 skipped=0 failed=0`;
- `ok 16 qmd real (041)` ejecutada;
- la duración del job y su margen frente a 45 minutos;
- el segundo tick de la prueba 13 sin R-BUSY de vigilantes.

## V7. Las noches posteriores al merge

Las cinco primeras nocturnas se registran como en T046 de 043: run, job, margen, `e2e summary:`, la línea TAP 16 y los avisos de lock con sus dueños.

Esperado: el segundo tick de la prueba 13 deja de reportar vigilantes `timeout 900 .../qmd` (hoy lo hace en 5 de 5 noches).
