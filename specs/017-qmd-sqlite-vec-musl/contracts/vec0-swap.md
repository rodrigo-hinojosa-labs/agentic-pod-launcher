# Contrato: swap del `vec0.so` en `_qmd_ensure_prefix` (runtime)

**Dónde**: `scripts/lib/qmd_index.sh` (fuente) → espejo `docker/scripts/lib/qmd_index.sh` (COPY). Función `_qmd_ensure_prefix`, tras confirmar que el binario de qmd existe, antes de retornar éxito.

## Precondiciones
- El prefijo gestionado ya provisto (`bun install` RC=0), con `node_modules/sqlite-vec-linux-arm64/vec0.so` (prebuilt glibc) presente.

## Comportamiento (MUST)
1. Definir la ruta del artefacto horneado: `QMD_VEC0_MUSL_SO=/opt/agent-admin/sqlite-vec/vec0.so` (constante; overridable por env para tests).
2. **Gate**: proceder al swap solo si:
   - el artefacto horneado existe (`[ -f "$QMD_VEC0_MUSL_SO" ]`), **y**
   - la libc objetivo es musl (salvaguarda: `_libc_variant` == `musl`, o probe `/lib/ld-musl-*` si `_libc_variant` no es sourceable en este contexto).
3. Si el gate pasa: `cp -f "$QMD_VEC0_MUSL_SO" "<prefix>/node_modules/sqlite-vec-linux-arm64/vec0.so"` y loguear vía `_qmd_log` ("sqlite-vec: swapped glibc prebuilt for musl build").
4. Si el gate no pasa por artefacto ausente **en un entorno musl** (p.ej. `QMD_NATIVE_TOOLCHAIN=0`): loguear un warning redactado ("sqlite-vec musl build absent; embed unavailable, lexical intact") y **continuar** (no fallar el aprovisionamiento; no crashear reindex/supervisor — Principle IV).
5. En glibc (artefacto ausente por diseño): **no-op silencioso** (el prebuilt glibc ya carga).

## Idempotencia
- `cp -f` del mismo artefacto determinista es idempotente; re-ejecutable sin efectos. (Opcional: saltar si el destino ya es el artefacto — `cmp -s`.)

## Postcondiciones
- En musl con toolchain: `vec0.so` del prefijo es musl → `qmd embed`/`vsearch` cargan `vec0`.
- En glibc: sin cambios respecto de 016.

## Invariantes
- Sobrevive `--regenerate` (la lib se re-espeja a docker).
- No toca `.state` fuera del prefijo; sin secretos en argv/journal.
