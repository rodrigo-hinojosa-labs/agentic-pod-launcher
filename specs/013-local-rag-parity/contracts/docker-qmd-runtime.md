# Contract: docker-qmd-runtime (FR-016 — Clarify Q4)

QMD en modo docker funciona contra binarios reales. Bug confirmado en research R3: la imagen instala solo `bun`; `qmd_index.sh:88,137,215` y el MCP qmd (`mcp-json.tpl` `command: bunx`) exigen `bunx`; `docker-e2e-qmd.bats:78-97` lo stubea y enmascaró la ausencia desde 010.

## Dockerfile (única línea docker de 013)

- En el bloque RUN de instalación de bun (`docker/Dockerfile:105-124`), tras `chmod +x /usr/local/bin/bun`:
  `ln -s /usr/local/bin/bun /usr/local/bin/bunx; \`
- Sin pin nuevo (reusa `BUN_VERSION` existente); sin cambios de caps/usuario (Principle II intacto).

## Aserción e2e (el stub no puede volver a mentir)

- `docker-e2e-qmd.bats` agrega una aserción contra la IMAGEN real, independiente del PATH del stub:
  `docker exec -u agent <c> sh -c 'test -x /usr/local/bin/bunx && readlink /usr/local/bin/bunx'` → apunta a `bun`.
- El stub de bunx para la orquestación del pipeline se conserva (el e2e no descarga modelos reales); la nueva aserción cubre exactamente lo que el stub oculta: la existencia del binario en la imagen.

## Gates

- Rebuild de imagen + `DOCKER_E2E=1` verde (qmd + vault + smoke).
- CHANGELOG declara el cambio docker (agentes existentes lo reciben con su próximo `docker compose build`).
- Validación viva post-merge: habilitar qmd en ferrari (runbook actualizado) — `claude mcp list` muestra qmd Connected con bunx real.

## Tests (test-first)

1. bats host: `grep` del Dockerfile — línea `ln -s` presente dentro del bloque bun (drift-guard barato sin Docker).
2. DOCKER_E2E: aserción de symlink en imagen real (arriba).
