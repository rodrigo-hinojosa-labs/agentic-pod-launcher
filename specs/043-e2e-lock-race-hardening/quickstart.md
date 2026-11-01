# Quickstart: validar que los e2e de qmd ya no caen por el `.reindex.lock`

**Feature**: `043-e2e-lock-race-hardening` | **Spec**: [spec.md](spec.md) | **Contratos**: [reindex-wait.md](contracts/reindex-wait.md), [lock-owner-dump.md](contracts/lock-owner-dump.md), [host-oracle.md](contracts/host-oracle.md), [evidence-protocol.md](contracts/evidence-protocol.md)

Escenarios ejecutables, en el orden en que se corren. Los comandos que salen del Mac (V6) llevan COMPUERTA. Los números entre paréntesis son los criterios del spec que cada escenario prueba.

## Requisitos previos

- Host: macOS con `bats-core` (1.13 local; la CI usa 1.11 en Linux), `jq`, `yq` v4, `git`, `docker` con Compose v2 (solo V4 y V5) y bash 3.2 (el de `/bin`) y 5.x (el de Homebrew).
- Para V4 y V5: Docker Desktop encendido y los modelos de 041 en `~/.cache/agentic-qmd-e2e/models-041` (se conservaron en T036). Las imágenes de prueba se quitaron el 29-10-2026: el primer DOCKER_E2E reconstruye desde el caché de build (el costo no está medido).
- El árbol de trabajo es el worktree `.claude/worktrees/043-e2e-lock-race-hardening`; la línea base se mide en una copia aislada de `origin/main`.

## V1. El oráculo del host: ROJO antes, VERDE después (SC-004)

```bash
bats tests/qmd-e2e-lock.bats                    # bash 5.x
PATH=/bin:$PATH bats tests/qmd-e2e-lock.bats    # bash 3.2.57
bats tests/qmd-embed-nightly.bats               # P1 enmendada, P2, G1, G3 y K1 a K4 en verde
```

Antes de escribir el ayudante: L1 a L10, X1 a X6, O1, O2, D1 y D2 fallan porque `tests/helper-qmd-e2e.bash` no existe (O1 carga el ayudante antes de su `skip` de Linux), y B1 a B6 fallan por el contenido actual del e2e (`contracts/host-oracle.md`, sección 6). Después: 26 de 26 en los dos bash (O1 se salta en macOS con su motivo). La enmienda de P1 cae contra el cuerpo actual y pasa con el nuevo. El ROJO de comportamiento de O1 y de la rama de `/proc` de O2 lo dan M35 y M36 en la pata Linux.

## V2. El gate completo del host (SC-005)

Sobre el árbol final congelado, en una copia aislada y en secuencia:

```bash
bats --tap tests/                               # bash 5.x, unos 20 min
PATH=/bin:$PATH bats --tap tests/               # bash 3.2.57, unos 20 min
git diff origin/main --stat -- docker scripts modules setup.sh   # vacío
git diff origin/main -- VERSION                                  # vacío
```

Esperado: la línea base medida en la etapa 0 más 26 pruebas por bash (1868 + 26 = 1894 si `origin/main` sigue en `cd8b74f`), 0 fallidas y la salida de error vacía; el producto y `VERSION` sin diferencias (FR-012).

## V3. El catálogo de mutaciones (SC-004)

Las 39 mutaciones de `contracts/host-oracle.md` (sección 5: M1 a M34 y M37 a M41) se aplican, una a una, sobre una copia aislada de los archivos que lee el oráculo, como usuario no root, con un corredor del scratchpad (no versionado). Esperado: las 39 caen en bash 5.x y en 3.2 con las pruebas previstas, sin sobrevivientes y sin mutaciones rotas (el texto a mutar aparece exactamente una vez). M35 y M36, para O1 y O2, solo pueden caer en Linux y corren en la pata Linux (`ubuntu:24.04`, bash 5.2).

## V4. La inyección de falla local (SC-001, SC-002, SC-008)

Protocolo de `contracts/evidence-protocol.md`, sección 3. Resumen:

1. Copia del archivo de pruebas actual: `git show origin/main:tests/docker-e2e-qmd.bats` (con su `helper.bash`), en un directorio de ensayo del scratchpad.
2. Por sitio, el corredor local lanza el test con `DOCKER_E2E=1` (y `QMD_EMBED_E2E=1` más `QMD_E2E_MODELS_DIR` para la 041), espera a que el contenedor esté en marcha y lanza el retenedor con `docker exec -d -u agent`, que espera su archivo marcador, toma el lock con `flock` bloqueante y lo retiene H segundos.
3. ROJO: el cuerpo actual cae (la 041 con `already running` y sin `qmd-index.json`; la 13 por `engine-calls.log` ausente; la 12 por `qmd-index.json` ausente). VERDE: el cuerpo nuevo pasa, con R-BUSY nombrando al retenedor en el TAP.
4. Vencimiento: la prueba 13 con `QMD_E2E_REINDEX_LOCK_WAIT_S=6` y H de 60 s falla a los 6 s de espera con R-EXPIRED (lock, espera, intentos, última salida y dueño), sin error de `jq` ni de `grep`; y la fase `reindex` de la 041, con el mismo plazo y H de 600 s, falla igual y su estado al fallar nombra al retenedor (SC-008).

Se registran, por corrida, el identificador, el instante en que el retenedor tomó el lock, el resultado y las líneas de R-BUSY o R-EXPIRED.

## V5. El DOCKER_E2E local completo (SC-006; SC-003 como referencia)

```bash
DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041 \
  bats --tap tests/docker-e2e-qmd.bats
```

Esperado: `ok` en las cinco pruebas, la 16 con sus ocho marcas de fase en orden y la línea `# qmd embed resources:`. Se registran la duración, el costo de reconstruir las imágenes y, como referencia, la prueba 16 sin `setup` (SC-003 se decide en V6, porque el umbral sale de nocturnas amd64).

## V6. Una corrida manual en CI (COMPUERTA; SC-003 y SC-006)

```bash
git -c credential.helper='!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git 043-e2e-lock-race-hardening
gh workflow run docker-e2e.yml --ref 043-e2e-lock-race-hardening
gh run list --workflow docker-e2e.yml --branch 043-e2e-lock-race-hardening --limit 1
```

Esperado: el job en verde con `ok 16 qmd real (041)` ejecutado y no saltado y `e2e summary: total=49 executed=49 skipped=0 failed=0`, y la prueba 16 sin `setup` en 24 s o menos (SC-003). Se registran identificador, duración, margen frente a 45 minutos y las marcas de fase; un rojo ajeno se clasifica antes de seguir.

## V7. Las noches siguientes al merge (SC-007)

```bash
gh run list --workflow docker-e2e.yml --event schedule --limit 12
```

Por noche: identificador, duración del job (API de jobs), margen, línea TAP de la prueba 16, `e2e summary:`, si apareció R-BUSY y quién tenía el lock, y la clasificación de cualquier rojo. Se registran en un PR de documentos aparte.

## V8. Auditoría de bytes de los artefactos nuevos

```bash
python3 <scratchpad>/byte_audit_files.py specs/043-e2e-lock-race-hardening/*.md specs/043-e2e-lock-race-hardening/contracts/*.md specs/043-e2e-lock-race-hardening/checklists/*.md
python3 <scratchpad>/byte_audit.py origin/main     # las líneas agregadas a archivos ya rastreados
```

Esperado: 0 ofensores (marcas combinantes, caracteres de control, de formato, de uso privado o emoji).
