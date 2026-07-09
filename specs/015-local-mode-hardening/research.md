# Phase 0 Research: Local-mode & docker RAG hardening

Resuelve los tres unknowns que `/speckit-clarify` dejó deferidos a plan. Las tres
decisiones de mecanismo (US1 persistir+guard, US3 TMPDIR host-backed, US4
observabilidad) ya están fijadas en el spec; aquí se cierra el **cómo**.

---

## R1 — Detección de libc del host para elegir la build de `bun` (US2)

**Decision**: En `provision_bun` (modules/local-bootstrap.sh.tpl), detectar musl vs
glibc **probando el loader dinámico**, y elegir el asset:
- musl → `bun-linux-${bun_arch}-musl.zip` (dir interno `bun-linux-${bun_arch}-musl`).
- glibc → `bun-linux-${bun_arch}.zip` (dir interno `bun-linux-${bun_arch}`).

Detección (orden, primer match gana), robusta en Alpine/busybox y Debian:

```sh
_libc_variant() {
  # 1) loader musl presente → musl (Alpine)
  for f in /lib/ld-musl-*.so.1 /lib/ld-musl-*; do [ -e "$f" ] && { echo musl; return; }; done
  # 2) ldd delata la implementación (glibc imprime "GNU libc"/"GLIBC"; musl imprime "musl")
  if command -v ldd >/dev/null 2>&1; then
    case "$(ldd --version 2>&1 | head -n1)" in
      *musl*) echo musl; return ;;
      *GLIBC*|*GNU\ libc*|*glibc*) echo glibc; return ;;
    esac
  fi
  # 3) getconf (glibc-only símbolo)
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 && { echo glibc; return; }
  # 4) default seguro: glibc (el 99% de los hosts bare-metal locales)
  echo glibc
}
```

**Rationale**: El chequeo del loader `/lib/ld-musl-*` es el discriminante más
directo y sin dependencias (Alpine SIEMPRE lo trae; glibc nunca). `ldd --version`
es el fallback estándar. El default glibc es correcto para el caso de uso local
(Debian/Ubuntu en las Pi); docker (Alpine) matchea en el paso 1 y conserva su
build musl (Acceptance US2-2, sin cambios en docker).

**Alternatives considered**:
- `uname`/`/etc/os-release`: frágil (una distro glibc podría no traer os-release; no
  distingue musl-en-Void, etc.). Descartado.
- `file $(command -v sh)` parseando el intérprete: correcto pero requiere `file`, no
  garantizado. Descartado como primario; el probe del loader lo cubre sin deps.

---

## R2 — Asset glibc de `bun` y single-source del pin (US2, Principle VI)

**Decision**: El pin de `bun` permanece **1.3.14** (sin cambio de versión). Sólo
cambia el **sufijo de build** según R1. Los assets de oven-sh siguen la convención:
`bun-linux-<arch>.zip` (glibc) y `bun-linux-<arch>-musl.zip` (musl), donde
`<arch> ∈ {x64, aarch64}`. El parche de host aplicado en mclaren usó exactamente
`bun-linux-aarch64.zip` (glibc) y ejecutó — **evidencia empírica del naming**
(ver [[local-mode-deploy-gotchas]] BUG 2).

El guard de idempotencia (FR-005) cambia de "presencia" a "**ejecución real**":

```sh
# ANTES (local-bootstrap.sh.tpl:147): if have bun && have bunx; then return 0; fi
# DESPUÉS: sólo saltar si bun EJECUTA (una build musl-en-glibc pasa `have` pero no ejecuta)
if have bun && have bunx && bun --version >/dev/null 2>&1; then log "bun present"; return 0; fi
```

**Rationale**: `have` = `command -v` sólo verifica que el archivo existe en PATH;
una build musl en host glibc existe pero da `cannot execute: required file not
found`. Verificar `bun --version` rc 0 hace el guard honesto y auto-sanador
(re-provisiona con la build correcta sin intervención).

**Consolidación del pin (Principle VI, SHOULD, no bloqueante)**: hoy `1.3.14`
aparece en `docker/Dockerfile:107` (ARG), `modules/local-bootstrap.sh.tpl:29`
(`BUN_VERSION`) y `scripts/lib/versions.sh:35` (`AGENTIC_FLOOR_BUN`). `versions.sh`
NO es sourceable por el template de bootstrap renderizado en el host destino sin
plumbing extra. Se deja como oportunidad **opcional** (una tarea de bajo riesgo en
Polish); no se introduce pin nuevo, así que no hay violación.

**Alternatives considered**:
- Bajar siempre glibc y sólo musl en docker vía flag explícito de modo: equivalente
  funcional pero acopla la lib al modo en vez de al host real; R1 (probe del host)
  es más robusto (un local sobre Alpine seguiría funcionando). Descartado.

---

## R3 — `TMPDIR` host-backed + observabilidad de errores de infra (US3/US4)

**Decision**: Los wrappers de mantenimiento exportan un `TMPDIR` **host-backed bajo
`.state`** antes de invocar `bunx`/qmd y antes del `mktemp` del runner wiki-graph.
El directorio se ancla al cache root ya resuelto (013): en docker `$HOME` = bind
`.state`; en local `.state/.cache/qmd`. Scratch propuesto: `${cache_root}/tmp`
(o `${XDG_CACHE_HOME:-$HOME/.cache}/tmp`), creado con `mkdir -p` (fail-silent).

Puntos de aplicación:
- **qmd** (`_qmd_run`, qmd_index.sh:84-89): exportar `TMPDIR` (y, defensivo, un temp
  dir para bun) en el entorno de la llamada a `bunx`. `bunx` extrae el paquete en
  `$TMPDIR/bunx-<uid>-<pkg>` — la ruta observada en ferrari era `/tmp/bunx-1000-@tobilu`,
  confirmando que honra `TMPDIR`. Con `TMPDIR` host-backed el cache de ~98 MB deja
  de vivir en el tmpfs RAM y **persiste entre reinicios** (menos cold-starts).
- **wiki-graph** (`wiki_graph.sh:290`): el runner ya hace
  `mktemp -d "${TMPDIR:-/tmp}/wg.XXXXXX"`. Basta con que el runner **fije su propio
  `TMPDIR`** host-backed al inicio (defensivo ante `/tmp` lleno por otros
  consumidores), de modo que records/combined caigan en disco host-backed.

Observabilidad (FR-007/FR-008) — quitar el swallow, registrar el error real:
- **wiki-graph** (`wiki_graph.sh:325`): reemplazar `2>/dev/null` por captura del
  stderr a un archivo bajo el `TMPDIR` host-backed; en fallo, incluir la cola del
  stderr real en el campo `error` del state (`aggregation failed: <stderr>`), no el
  genérico `jq aggregation failed`.
- **qmd reindex** (`qmd_index.sh:252,257`): reemplazar `>/dev/null 2>&1` por captura
  del stderr a un log/archivo; el `error` del state y el log del reindex traen la
  salida real de qmd. **Redacción obligatoria** (Principle V): cualquier volcado de
  env efectivo o stderr MUST filtrar secretos (`sk-ant-*`, tokens OAuth, API keys,
  `*_TOKEN`, `*_KEY`) antes de escribir a log/journal/state.

**Rationale**: Mecanismo A (routing) desacopla el tamaño del vault del tamaño de la
RAM, hace el runner robusto a `/tmp` lleno por diseño, y **no toca**
`docker-compose.yml.tpl` (Principle II intacto). La captura de stderr convierte el
falso "aggregation failed" en un diagnóstico accionable (habría dicho "No space
left on device" en el gate real de ferrari).

**Riesgo residual / a validar en DOCKER_E2E**: que `bun`/`bunx` honre `TMPDIR` para
la extracción del paquete en la versión 1.3.14. Evidencia: la ruta observada estaba
bajo `/tmp` (= `$TMPDIR` por defecto). Mitigación defensiva: además de `TMPDIR`,
exportar los alias que bun reconoce (`TMP`, `TEMP`) al mismo dir. El gate docker lo
confirma empíricamente (SC-003).

**Alternatives considered**:
- **Subir el tmpfs `/tmp`** (parche de ferrari, 512m, condicional a `qmd.enabled`):
  descartado como primario en clarify — consume RAM y sigue siendo un límite fijo
  que un vault suficientemente grande vuelve a topar; además tocaría el compose.
  Se mantiene como fallback documentado si el routing resultara insuficiente.
- **Defensa en profundidad (routing + piso de tmpfs)**: descartado por disciplina de
  alcance (Principle II/scope): dos mecanismos que mantener y testear cuando uno
  bien elegido basta.

---

## Resumen de decisiones

| # | Área | Decisión |
|---|------|----------|
| R1 | US2 detección libc | Probe del loader `/lib/ld-musl-*` → `ldd --version` → `getconf` → default glibc |
| R2 | US2 asset + guard | Pin 1.3.14 intacto; sufijo `-musl`/glibc por R1; guard por `bun --version` rc 0 |
| R3 | US3/US4 temp+obs | `TMPDIR` host-backed bajo `.state` en los wrappers; capturar stderr real (redactado) en state/log |

Sin `NEEDS CLARIFICATION` pendientes. Listo para Phase 1.
