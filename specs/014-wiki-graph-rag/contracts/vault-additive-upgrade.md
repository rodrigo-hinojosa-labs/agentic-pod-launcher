# Contract: Upgrade aditivo del vault

Norma para `vault_seed_missing` (nueva función en `scripts/lib/vault.sh`, ya espejada vía
COPY existente) y la entrega del delta de schema. Decisión base (clarify Q2): delta aparte
+ entrada en `log.md`; el `CLAUDE.md` del vault JAMÁS se toca.

## Firma y semántica

```bash
# vault_seed_missing TARGET_DIR SKELETON_DIR DELTAS_DIR [TODAY]
```

Precondiciones: TARGET existe y NO está vacío (si está vacío/ausente, el camino correcto
es `vault_seed_if_empty` — seed_missing retorna 0 sin actuar; el orquestador llama ambas
en orden). SKELETON y DELTAS existen.

Acciones, en orden, cada una individualmente idempotente:

1. **Directorios faltantes**: crea `wiki/normalization/` (con `.gitkeep`) si no existe.
   No crea ningún otro directorio del skeleton que el operador haya podido eliminar a
   propósito EXCEPTO los introducidos por esta versión del launcher (lista explícita en
   la función, no un walk genérico del skeleton — un walk resucitaría carpetas borradas
   deliberadamente).
2. **Templates faltantes**: copia `_templates/normalization.md` desde SKELETON si no
   existe en TARGET. Nunca sobreescribe.
3. **Delta de schema**: si el sentinel `TARGET/_templates/.schema-updates-0.8.0.applied`
   NO existe, copia `schema-updates-0.8.0.md` desde DELTAS_DIR, hace `touch` del sentinel
   oculto, y agrega a `log.md`:
   `## [YYYY-MM-DD] upgrade | schema updates 0.8.0 — read _templates/schema-updates-0.8.0.md and integrate into CLAUDE.md`.
   **El sentinel es el marcador oculto `.applied`, NO la existencia del delta `.md`** (C1):
   el delta es un artefacto que el agente puede borrar tras integrarlo, y como el trigger
   docker corre en CADA boot, usar el `.md` como sentinel lo re-depositaría y duplicaría la
   entrada de `log.md`. Con el marcador oculto desacoplado, la segunda corrida (y todo boot
   posterior al borrado del delta) es no-op total: sin re-depósito, sin segunda entrada.

Reglas duras:

- JAMÁS sobreescribe un path existente (ni contenido ni permisos).
- JAMÁS escribe `TARGET/CLAUDE.md` (capa 3 co-evolucionada).
- Fail-silent: cualquier error (vault read-only, disco) → warning a stderr, return 0
  (Principle IV) — nunca rompe boot/--login/--regenerate.
- Sin side effects al source (guard `BASH_SOURCE`, patrón de la lib).

## Contenido del delta (`modules/vault-deltas/schema-updates-0.8.0.md`)

Documento autocontenido con las secciones nuevas del schema listas para que el agente las
integre: capa de normalización (qué es, frontmatter, cuándo crear reglas), paso 2.5 del
ingest, paso de query con `.graph/backlinks.json`, y nota del lint estructural
determinista. Redactado en el mismo tono del `CLAUDE.md` del skeleton (en inglés, como el
skeleton). Incluye al inicio la instrucción de integración y auto-eliminación opcional:
integrar y luego borrar el archivo — decisión del agente. Borrar el delta es SEGURO: el
sentinel de idempotencia es el marcador oculto `.schema-updates-0.8.0.applied`, no el
delta, así que el upgrade no lo re-deposita en el siguiente boot.

## Triggers

| Contexto | Punto de invocación | Nota |
|---|---|---|
| Docker boot | `docker/scripts/start_services.sh::seed_vault_if_needed`, tras la rama `vault_seed_if_empty` (H5) | contexto usuario `agent`, `vault.sh` ya source-ado; fail-silent, corre en cada boot (idempotente vía sentinel `.applied`) |
| Local `--login` | `modules/local-login.sh.tpl`, tras asegurar el vault | mismo orden |
| Host `--regenerate` | `setup.sh`, si `vault.enabled` y el vault existe | usa el vault path de `agent.yml` mode-resuelto |

**Nota H5**: `docker/entrypoint.sh` NO es el punto de invocación — solo corre como root y
no toca el vault; el sembrado real vive en `start_services.sh::seed_vault_if_needed`
(llama `vault_seed_if_empty`), invocado bajo el usuario `agent` con `vault.sh` ya cargado.

Fresh scaffold: `vault_seed_if_empty` siembra el skeleton COMPLETO ya actualizado (incluye
`normalization/` y el `CLAUDE.md` nuevo); `vault_seed_missing` que corre después es no-op
puro — en fresh scaffold no falta ninguna estructura y `wiki/` está vacío, así que la regla
de fresh-scaffold (abajo) no deposita el delta ni toca el marcador `.applied`.

**Regla de fresh-scaffold**: para no depositar el delta como ruido en vaults nuevos,
`vault_seed_missing` deposita el delta SOLO si detectó al menos una estructura faltante en
los pasos 1-2 O si `wiki/` contiene páginas preexistentes. Un vault recién sembrado del
skeleton 0.8.0 no cumple ninguna de las dos → sin delta, sin entrada de log.

## Verificación (SC-005)

Test bats sobre fixture poblado: hash de TODOS los archivos antes/después → idénticos;
estructuras nuevas presentes; `CLAUDE.md` byte-idéntico; segunda corrida no cambia nada
(incluido `log.md`). Test de fresh scaffold: sin delta, sin log entry.
