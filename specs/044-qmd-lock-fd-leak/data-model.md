# Data model: las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Feature**: `044-qmd-lock-fd-leak` | **Fecha**: 2026-11-06

La feature no agrega datos persistentes: no cambian `agent.yml`, `qmd-index.json` ni los sentinels de qmd. Lo que modela este documento son los objetos del sistema operativo que deciden si el lock está tomado, y sus transiciones.

## Entidades

### Archivo del lock

- **Ruta**: `$(qmd_cache_root)/.reindex.lock`, en docker `/home/agent/.cache/qmd/.reindex.lock`.
- **Contenido**: ninguno que importe. Cada sección lo abre con `9>"$lock"`, que lo trunca.
- **Lo comparten** el setup del primer arranque y el reindex, sea del cron, del vigilante de archivos o manual.

### Descripción de archivo abierta (la del lock)

- **Se crea** cuando el subshell de una sección abre el archivo en el descriptor 9.
- **La heredan** todos los procesos que el subshell lanza: cada llamada a qmd, `bun install`, sus descendientes y el vigilante del `timeout` de BusyBox. Conservan el descriptor 9 que apunta a ella.
- **El lock de `flock(2)` pertenece a esta descripción**, no a un proceso.
  - Se suelta con `flock -u` sobre cualquier descriptor que apunte a ella.
  - También se suelta cuando ya no queda ningún descriptor abierto que apunte a ella.

### Sección con lock

- **Hay dos**: la del setup (`qmd_setup_if_needed`) y la del reindex (`qmd_reindex`), que incluye la migración de 037 cuando está pendiente.
- **Campos observables**:
  - el resultado del `flock -n 9`: gana o pierde;
  - el código de salida del subshell: 91 si perdió, otro valor si corrió;
  - la línea de log del perdedor: `already running — skip`.

### Vigilante del `timeout`

- **Qué es**: el hijo que deja el `timeout` de BusyBox (1.36.1 y 1.37.0) para vigilar el comando.
- **Descriptores**: deja 0, 1 y 2 en `/dev/null` y conserva los demás, entre ellos el 9 (`research.md` M2).
- **Cuánto vive**: hasta cerca de 1 s después de que el comando termina.
- **En GNU coreutils no existe** (M3).

### Sondeo del lock

- **Qué es**: un `flock -n "$lock" true` desde una descripción nueva, repetido cada 100 ms.
- **Qué mide**: cuántos intentos hacen falta para obtener el lock después de que la sección terminó. Es la métrica de SC-001.

## Transiciones del lock

```text
  libre --- flock -n 9 (gana) ---> tomado por la sección
                                        |
                                        | la función de la sección vuelve (fin normal o return temprano)
                                        v
  HOY:     el subshell termina; los vigilantes del timeout siguen vivos con el
           descriptor 9 -> el lock sigue tomado de 0,9 a 1 s, hasta que muere el último
           -> libre
  CON 044: el último paso del subshell, después de la función de la sección, es
           `flock -u 9` -> libre de inmediato, aunque los vigilantes sigan vivos (ya sin lock)

  tomado por la sección
        |
        | una señal al subshell (SIGTERM o SIGKILL) antes del último paso
        v
  HOY y CON 044: el `flock -u 9` no corre; el lock sigue tomado mientras viva un
           proceso con el descriptor 9 (un qmd hijo que trabaja, o un vigilante)
           -> libre cuando muere el último (research.md M8)
```

- **Un perdedor** (`flock -n 9` falla) no pasa a «tomado»: sale con 91 y su descripción se cierra. El lock del ganador no cambia (FR-002; prueba L5).
- **Sin `flock` en el host**, no hay transiciones: la sección corre sin lock (FR-005).

## Reglas de validación (de los requisitos)

| Regla | Requisito | Prueba |
| --- | --- | --- |
| Tras la salida de una sección ganadora, el primer sondeo obtiene el lock | FR-001, SC-001 | L1, L2, L3, L4, L7 |
| Mientras la sección corre, un sondeo desde otra descripción falla | FR-002 | L6 |
| Un perdedor se salta con rc 0, no llama al motor y no suelta el lock del ganador | FR-002 | L5 |
| El estado que deja el reindex no cambia con un vigilante vivo | FR-004 | L8 |
| El `flock -u 9` va una sola vez por sección, después de la llamada a la función de la sección y como último paso del subshell, y no hay ningún `trap` | FR-002, FR-005, caso borde de la sección que muere a mitad de camino | G1 |
| El arnés puede producir el ROJO | FR-007 | G2 |
