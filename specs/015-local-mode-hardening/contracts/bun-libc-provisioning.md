# Contract: Provisioning de `bun` sensible a la libc (US2)

**Interfaz**: `provision_bun` en `modules/local-bootstrap.sh.tpl` (workspace-templated;
corre en el host destino durante bootstrap local).

## Precondiciones

- Modo local; qmd habilitado (el bootstrap provisiona runtimes de MCP).
- Host arm64/x86_64 con glibc (Debian/Ubuntu) o musl (Alpine).

## Comportamiento observable

| # | Dado | Cuando | Entonces |
|---|------|--------|----------|
| C1 | host glibc (aarch64/x86_64) | `provision_bun` | instala `bun-linux-<arch>.zip` (glibc); `bun --version` ejecuta rc 0 |
| C2 | host musl (Alpine) | `provision_bun` | instala `bun-linux-<arch>-musl.zip` (comportamiento docker sin cambios) |
| C3 | `bun` ya presente y **ejecuta** | `provision_bun` (re-run) | no-op idempotente (no re-baja) |
| C4 | `bun` presente pero **NO ejecuta** (build incompatible) | `provision_bun` | re-provisiona con la build correcta; no deja la rota |
| C5 | `unzip` ausente | `provision_bun` | mensaje accionable (ya existente) + rc≠0; qmd marcado no-disponible con honestidad en `doctor` |

## Detección de libc (R1)

Probe del loader `/lib/ld-musl-*` → `ldd --version` (`*musl*`/`*GLIBC*`) →
`getconf GNU_LIBC_VERSION` → default `glibc`.

## Selección de asset

- `bun_arch`: `x86_64→x64`, `aarch64|arm64→aarch64` (sin cambios).
- glibc: URL `…/bun-linux-${bun_arch}.zip`, dir interno `bun-linux-${bun_arch}`.
- musl:  URL `…/bun-linux-${bun_arch}-musl.zip`, dir interno `bun-linux-${bun_arch}-musl`.
- Pin `BUN_VERSION` intacto (1.3.14).

## Cobertura de test (host, test-first)

- Extender `tests/local_bootstrap.bats` (o nuevo):
  - Test unitario de `_libc_variant` con loaders simulados (crea `/lib/ld-musl-*`
    falso vía `$TMPDIR` override, o inyecta un `ldd` stub en PATH) → asserta musl/glibc.
  - Test de selección de URL: dado variant=glibc, la URL construida NO trae `-musl`;
    dado musl, sí. (Sin bajar de red: interceptar `curl` con un stub que registra la URL.)
  - Test del guard C3/C4: stub `bun` que retorna rc≠0 en `--version` fuerza re-provision.

## Invariantes de constitución

- Principle IV (idempotencia por ejecución real, no presencia).
- Principle VI (sin pin nuevo; sólo cambia el sufijo de build). Consolidación del pin
  hacia `versions.sh` = tarea opcional de Polish.
