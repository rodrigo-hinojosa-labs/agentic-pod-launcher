# Contrato: DOCKER_E2E des-stubeado, en tiers

`tests/docker-e2e-qmd.bats` deja de stubear `bunx` y ejerce qmd real. La imagen ya trae `bunx→bun` (Dockerfile:126); des-stubear = **no** inyectar el bind-mount `- ./bin/bunx:/usr/local/bin/bunx:ro` (borrar también el bloque que escribe `DEST/bin/bunx`). El stub de `claude` (sleep) se conserva.

## Tiers

| Tier | Fase | Gate | Assert |
|------|------|------|--------|
| 1 | **A** build-detector | `DOCKER_E2E=1` | `bunx/qmd --help` RC=0 (paga install+compile nativo; sin modelo) |
| 1 | **B** update léxico | `DOCKER_E2E=1` | seed vault mínimo (3–5 `.md`, frontmatter válido) → `heartbeatctl qmd-reindex` → `jq .last_status == ok` + índice ≥1 doc |
| 2 | **C** embed real | `QMD_EMBED_E2E=1` | modelo cacheado → `qmd embed` rc0 + `*.gguf` presente + consulta semántica ≥1 hit; `skip` si el gate no está |
| — | **RED** detección | `DOCKER_E2E=1` | 2ª imagen `--build-arg QMD_NATIVE_TOOLCHAIN=0` → Fase A RC≠0 **y** stderr con causa real (`exited with 1`/`node-gyp`/`cmake`) |

## Reglas

- **Poder de detección (SC-003)**: la Fase A debe FALLAR con `QMD_NATIVE_TOOLCHAIN=0` y PASAR con `=1`. El grep de causa real evita que un RED por red-caída se confunda con detección.
- **Model cache**: `QMD_E2E_MODEL_CACHE` (default `$HOME/.cache/agentic-qmd-e2e/models`, fuera de `TMP_TEST_DIR`) bind-mounteado al `models/` de qmd; persistir solo `models/`.
- **Gotchas heredados** (memory): `compose run` necesita `--entrypoint` (ignora CMD), sin `--network`, pre-crear `.state`, declarar `plugins[]`. Mantener la aserción barata `bunx→bun` (symlink).
- **Subcomando de conteo**: confirmar desde `qmd --help` en el contenedor; NO asumir el flag.
- Verificar en el log que compiló con el `cmake` de apk (ausencia del fallback xpack/glibc) y que no hubo SIGSEGV/`regex_error` (veredicto adversarial).

## Cabecera del archivo

Reemplazar la nota "bunx is stubbed ... NOT exercised" (L21-24) por la descripción del flujo real + los dos tiers. Documentar `QMD_EMBED_E2E`/`QMD_E2E_MODEL_CACHE` en CLAUDE.md (Commands) y quickstart.md.
