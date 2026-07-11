# Quickstart: validar 017 (qmd sqlite-vec en musl)

## 1. Suite host (sin Docker) — gate rápido
```bash
bats tests/                              # suite completa verde (incluye guardrail + swap unit)
bats tests/qmd-sqlite-vec.bats           # solo el guardrail de versión + lógica de swap
shellcheck -S error scripts/lib/qmd_index.sh docker/scripts/lib/qmd_index.sh docker/scripts/build-sqlite-vec.sh
```
Esperado: verde; el guardrail falla solo si alguien cambió el par qmd/sqlite-vec sin actualizar el contrato.

## 2. DOCKER_E2E — embed real (gate del fix)
```bash
# Tier build + léxico + RED
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
# Tier embed real (descarga modelo ~333MB en el primer embed)
DOCKER_E2E=1 QMD_EMBED_E2E=1 bats tests/docker-e2e-qmd.bats
```
Esperado: el pipeline `collection add → update → embed → vsearch` cierra con "Embedded N chunks" y un hit semántico; el build con `--build-arg QMD_NATIVE_TOOLCHAIN=0` detecta RED.

## 3. Verificación manual del binario (opcional, dentro de la imagen)
```bash
docker run --rm --entrypoint bash -u agent agent-admin:<tag> -lc '
  ldd /opt/agent-admin/sqlite-vec/vec0.so            # debe mencionar ld-musl, NO ld-linux
  ! strings /opt/agent-admin/sqlite-vec/vec0.so | grep -q GLIBC_   # sin símbolos glibc
'
```

## 4. Gate confirmatorio en ferrari (hardware real, tras merge)
Tras desplegar la imagen reconstruida en ferrari (docker/musl, vault ~2696 páginas):
- `heartbeatctl qmd-reindex` (o el ciclo del heartbeat) embebe de verdad sobre el vault real; el estado de reindex reporta éxito del embed (no "sqlite-vec unavailable").
- Una búsqueda semántica (MCP de qmd / `qmd query`) devuelve resultados por significado.
- El wiki-graph sigue correcto sobre ~2696 páginas; `/tmp` no se llena (sin ENOSPC).

## Referencia de comportamiento esperado
End-to-end ya verificado en musl en esta sesión: `✓ Done! Embedded 2 chunks from 2 documents in 24s` + `vsearch "animal encima del pc"` → "El gato duerme sobre el teclado del computador" (Score 42%, match semántico).
