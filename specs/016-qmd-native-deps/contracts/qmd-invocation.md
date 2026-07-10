# Contrato: invocación de qmd por prefijo gestionado

Reemplaza el modelo `bunx @tobilu/qmd@<ver>` por un prefijo `bun install` controlado, en `scripts/lib/qmd_index.sh::_qmd_run` (y su espejo `docker/scripts/lib/qmd_index.sh`).

## Comportamiento esperado

1. **Prefijo**: `PREFIX="$(qmd_cache_root)/pkg"`. Se genera `PREFIX/package.json`:
   ```json
   { "dependencies": { "@tobilu/qmd": "<vault.qmd.version>" },
     "trustedDependencies": ["better-sqlite3", "node-llama-cpp"] }
   ```
2. **Instalación idempotente**: si el sha256 de `package.json` cambió respecto a un sentinel (`PREFIX/.installed-hash`), correr `bun install` en `cd PREFIX`; si no, saltar. (Principle IV: guard por hash, no mtime.) El sentinel se escribe **solo** en éxito, así que un build muerto se reintenta al siguiente boot/tick.
3. **Ejecución**: `"$PREFIX/node_modules/.bin/qmd" "$@"` con el env de la tabla (data-model §3). NUNCA `bunx`.
4. **Env de build/embed**: `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF`, `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH=armv8-a`; `LD_PRELOAD=/opt/agent-admin/bigstack.so` **solo** en el sub-comando `embed`; `PATH` incluye `/usr/bin`; `TMPDIR` host-backed (015).
5. **Presupuestos de timeout separados** (cuando `timeout(1)` está presente): el build nativo de una-sola-vez usa `QMD_INSTALL_TIMEOUT` (default 3600s; `0` = sin cota), mayor que el runtime recurrente `QMD_CMD_TIMEOUT` (default 900s), para que un compile largo de llama.cpp en aarch64/musl no sea SIGTERM'd hacia un loop que nunca escribe el sentinel. El setup corre backgrounded, así que un build largo no cuelga el boot.
6. **Observabilidad del fallo (016/US4, NO guard fail-loud de cmake)**: el build corre **dentro** de `bun install` con su salida capturada a un scratch (host-backed, no `/dev/null`). Si el build falla y el binario del prefijo queda ausente, se emite el error real (redactado vía `redact_secrets`) por `_qmd_log` y se retorna no-cero — sin crashear (Principle IV) y sin que el `exec` posterior lo sobrescriba con un engañoso "No such file or directory". Si un binario **viejo** sobrevive a un re-install fallido, se degrada a esa versión. **No** hay guard runtime `command -v cmake`: en modo local glibc con prebuilt, cmake no se necesita, así que el guard falsaría-positivo; la presencia real del toolchain se verifica en DOCKER_E2E, no en runtime.

## MCP server (T036) — el READER que Claude usa para buscar

El servidor MCP (`qmd mcp`) NO se lanza con `bunx` (repetía BUG 4 en musl y resolvía un prefix distinto al reindex). Se lanza vía `qmd_mcp_exec` desde el MISMO prefix gestionado:

- `qmd_mcp_exec [PKG]`: `_qmd_ensure_prefix` (idempotente) → `exec qmd mcp` **sin timeout** (proceso de larga duración) con `LD_PRELOAD=bigstack` (el server embebe queries → mismo hazard musl que `embed`).
- Entry points: docker image-baked `docker/scripts/qmd-mcp`; local rendered `<ws>/scripts/local/agent-qmd-mcp.sh` (plantilla que fija `PATH` + `QMD_CACHE_HOME` para que el prefix coincida con el reindex writer — el `.mcp.json` env solo trae `XDG_CACHE_HOME`).
- `modules/mcp-json.tpl`: `"command": "{{QMD_MCP_COMMAND}}"` (pre-computado por modo en `setup.sh`, como `QMD_MCP_ENV`), `"args": []`. El pin de versión ya no se duplica en el `.mcp.json`; lo resuelve el wrapper de `agent.yml` (single source).

## Invariantes verificables (bats host)

- `package.json` generado lista `trustedDependencies` == `["better-sqlite3","node-llama-cpp"]` exactamente; sin ningún `tree-sitter-*`.
- El wrapper exporta las 3 env vars de node-llama-cpp/LD_PRELOAD en el path de embed y NO `LD_PRELOAD` global.
- No queda ninguna llamada `bunx "$@"` en `_qmd_run`.
- El sentinel de hash existe y se respeta (segunda corrida no re-instala).
- Un `bun install` que falla sin producir el binario hace que `_qmd_run` retorne no-cero y el log contenga la señal del build (no un "No such file or directory").

## No-objetivos

- No `--omit=optional` (dropearía `sqlite-vec-linux-arm64`).
- No `--ignore-scripts` (irrelevante bajo bun para deps).
- No tocar el pin de versión (vive en `agent.yml`).
