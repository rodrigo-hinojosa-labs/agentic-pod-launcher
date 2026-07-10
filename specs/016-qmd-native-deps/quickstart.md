# Quickstart: validar el fix de qmd en Alpine (016)

Cómo construir, testear y correr los gates. La decisión de mecanismo (Opción A — Alpine + toolchain) está fijada; el gate DOCKER_E2E + ferrari es la prueba que decide.

## 1. Suite host (rápida, sin Docker)

```bash
bats tests/                              # suite completa (drift-guards nuevos incluidos)
bats tests/qmd-invocation.bats           # prefijo bun install + trustedDependencies + env
bats tests/qmd-version-guard.bats        # guardrail de versión (US4)
shellcheck -S error setup.sh scripts/lib/*.sh scripts/*.sh
```

Espera: verde. Los drift-guards fallan si `trustedDependencies` incluye algún `tree-sitter-*`, si falta una env var de node-llama-cpp, o si el pin de versión cambió sin actualizar el test.

## 2. DOCKER_E2E — Tier 1 (build + update léxico)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
```

- **Fase A**: construye la imagen (con toolchain) y corre `bunx/qmd --help` → RC0 (compila node-llama-cpp/better-sqlite3 real; sin modelo).
- **Fase B**: siembra un vault mínimo y corre `heartbeatctl qmd-reindex` → `last_status=ok` + índice poblado.
- **RED**: reconstruye con `--build-arg QMD_NATIVE_TOOLCHAIN=0` y confirma que la Fase A **falla** con causa real → prueba el poder de detección (SC-003).

Requiere: host con Docker + red (el primer build clona/compila llama.cpp).

## 3. DOCKER_E2E — Tier 2 (embed real, lento)

```bash
export QMD_E2E_MODEL_CACHE="$HOME/.cache/agentic-qmd-e2e/models"   # cachea el modelo ~300MB
QMD_EMBED_E2E=1 DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
```

- **Fase C**: `qmd embed` real → rc0 + `*.gguf` en cache + consulta semántica devuelve ≥1 hit. Ejercer dispose/salida del proceso y verificar en el log: compiló con el `cmake` de apk (sin fallback xpack/glibc) y sin SIGSEGV/`regex_error`.

## 4. Gate confirmatorio en hardware (ferrari, Alpine musl aarch64 real)

```bash
ssh ssh-ferrari   # túnel Cloudflare; requiere estar arriba
# en el workspace del agente docker:
docker compose build && docker compose up -d
docker exec -u agent rodri-cenco-admin heartbeatctl qmd-reindex     # update: last_status=ok
docker exec -u agent rodri-cenco-admin sh -lc 'qmd embed ...'        # embed: rc0, vectores
# verificar: /tmp no se llena (US3), wiki-graph sigue ok sobre 2696 páginas
```

## 5. Criterio de disparo del fallback B/C

Si en el Tier 2 o en ferrari el `embed` crashea reproduciblemente bajo bun (N-API dispose/exit) pese al `bigstack.so`, o el shim no cubre el hilo del tokenizer, o llama.cpp no enlaza en musl: **parar**, documentar el modo de falla, y re-abrir la decisión de mecanismo (`/speckit-clarify` acotado) hacia B (base glibc) o C (embeddings remotos). `update` (léxico) queda operativo igual.

## Modo local: prerequisito de toolchain (US5)

En modo `local` (systemd, host glibc) qmd instala `node-llama-cpp`/`better-sqlite3` desde
fuente igual que en docker. El host DEBE tener un toolchain C/C++ (`gcc`, `g++`, `make`) y
`cmake`. Hosts como mclaren (Debian) suelen traerlos vía `build-essential`; en un host
limpio, instalarlos antes de habilitar qmd:

```bash
# Debian/Ubuntu
sudo apt-get install -y build-essential cmake
```

Si faltan, el reindex falla en el build nativo; la observabilidad de 015 registra la causa
real en `qmd-index.json`/log (no un fallo opaco). En glibc el `bigstack.so` no se usa (no
existe en el host) — no es necesario (stack por defecto de glibc es amplio).

## Versionado

VERSION 0.9.0 → 0.10.0; entrada en CHANGELOG; documentar en CLAUDE.md (Commands) los gates `QMD_EMBED_E2E`/`QMD_E2E_MODEL_CACHE` y el requisito de red build-time.
