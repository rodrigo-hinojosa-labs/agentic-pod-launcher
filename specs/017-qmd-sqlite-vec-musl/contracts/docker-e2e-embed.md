# Contrato: DOCKER_E2E des-stubeado (embed+vsearch reales)

**Dónde**: `tests/docker-e2e-qmd.bats`.

## Fase A (corrección del defecto heredado)
- **Antes (016, defectuoso)**: `bunx @tobilu/qmd@2.5.3 --help` directo → nunca ejerce node-llama-cpp/sqlite-vec; por eso 016 pasó el merge sin detectar el muro.
- **Ahora (MUST)**: usar el path de producción (`_qmd_run` / prefijo gestionado). La aserción de sanidad debe discriminar por **carga real del binding**, no por `--help`.

## Tier de embed (`QMD_EMBED_E2E=1`, MUST)
1. Construir la imagen con `QMD_NATIVE_TOOLCHAIN=1` (default).
2. Correr, dentro del container (`-u agent`, entrypoint bypasseado para el test), el pipeline real contra el prefijo gestionado:
   `collection add <vault> → update → embed → vsearch <consulta semántica>`.
3. Aseverar (con `grep -q`, nunca `[[ ]]`/`!`-negado intermedio — ver quirk bats del proyecto):
   - `embed` reporta éxito (p.ej. "Embedded N chunks"); **no** "sqlite-vec extension is unavailable".
   - `vsearch` devuelve el documento esperado por similitud semántica (consulta sin solapamiento léxico).
   - el `vec0.so` en uso es musl (opcional: assert `ldd`/`strings` sin GLIBC).

## Detección RED (MUST)
- Construir con `--build-arg QMD_NATIVE_TOOLCHAIN=0` → sin artefacto horneado → el embed debe fallar / quedar no disponible. El test asevera el RED (si pasa igual, el gate no discrimina → fallar el test).
- Patrón de aserción RED: capturar salida y `if echo "$out" | grep -q 'Embedded'; then false; fi` (no `!`-negado intermedio).

## Gating
- Todo gateado por `DOCKER_E2E=1` (+ `QMD_EMBED_E2E=1` para el tier de embed real). La suite host por defecto no lo corre (Principle III).

## Notas de invocación (gotchas conocidos)
- `docker run` para el path de producción necesita `--entrypoint bash` (no `sh`: `qmd_index.sh` fuentea libs con sintaxis bash) y `-u agent`; sin `--entrypoint`, `entrypoint.sh` corre y falla creando `/etc/crontabs/agent`.
- El modelo gguf (~333MB) se descarga en el primer embed; cachear entre corridas si es posible para no re-bajar.
