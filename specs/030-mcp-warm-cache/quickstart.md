# Quickstart / validación — 030 warm cache

Orden de gates: host bats (hermético) → shellcheck → DOCKER_E2E (host Docker) → hardware (ferrari).

## 1. Suite host (hermética, sin Docker)

```bash
bats tests/                      # completa; baseline previo + los tests nuevos, 0 not ok
bats tests/mcp-warm.bats         # derivación pura (los 12 casos de contracts/warm-derivation.md)
```

Correr en los dos shells (regla del repo):

```bash
bats tests/                                  # env bash → 5.x
PATH=/bin:$PATH bats tests/                  # fuerza /bin/bash 3.2.57 (macOS)
```

Ambos: mismo conteo, `0 not ok`.

## 2. Derivación (unidad)

`mcp_warm_targets` sobre fixtures con las 6 formas de `.mcp.json` (uvx directo, npx con `-y`, npx sin
flag, wrapper `seed-*.sh` con uvx anidado — el caso google-workspace —, npx `-p`, binario omitido).
Aserta salida byte-exacta `runtime\tpackage` deduplicada.

## 3. Mutación (host)

- Revertir la derivación a `command`-only → cae ≥1 test (casos 5 y 7 de `warm-derivation.md`).
- Revertir el fix de `provision_uv_tools` al selector viejo → cae el test que asegura que el wrapper
  google-workspace se deriva en local.
- Quitar la línea de mirror/COPY de la lib a docker → cae el test/verificación de distribución.

## 4. shellcheck (comando de CI)

```bash
shellcheck -S error scripts/lib/mcp_warm.sh docker/scripts/start_services.sh <libs tocadas>
```

## 5. DOCKER_E2E (host Docker, diferido)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-warm-cache.bats
```

Tiers en `contracts/docker-e2e-tiers.md`: E1 GREEN (warm cubre `workspace-mcp` offline), E2 RED
(build-arg off → falla), E3 no-regresión del catálogo, E4 verificación previa del offline de `uv`.

## 6. Gate de hardware (ferrari, diferido, gateado por operador)

Recrear el contenedor de `donna` con la red a PyPI cortada; verificar que `google-workspace` conecta
(el paquete estaba tibio) en vez del estado muerto del 16-08-2026. Cierra SC-001 en hardware real. Se
hace en el despliegue de esta versión.

## Regenerate-safety

Dos `./setup.sh --regenerate` seguidos dejan `.mcp.json` y los derivados byte-idénticos (la lista de
warm se re-deriva, no se persiste). Un agente sin MCP de overlay no cambia su comportamiento (FR-009).
