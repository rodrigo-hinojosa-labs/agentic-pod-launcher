# Research: El nightly de docker-e2e ejecuta la suite de verdad

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Fecha**: 2026-10-05 | **Spec**: [spec.md](spec.md)

Fase 0 del plan. Cada pregunta abierta se cerró **midiendo**, no suponiendo. Los comandos están en [quickstart.md](quickstart.md) y las mediciones se hicieron el 05-10-2026 sobre `main` en `da22a06`, con bash 3.2.57 (`/bin/bash` de macOS) y bash 5.3.15 (Homebrew), `yq` v4.52.5, `jq` 1.7.1 y `bats` 1.13.0. Una medición (la línea base local de los e2e) queda **diferida a una compuerta**, con la razón escrita en D8.

## Resumen de mediciones

| ID | Medición | Resultado |
|----|----------|-----------|
| M1 | El paso `Verify deps + docker` real, extraído del workflow y ejecutado con `bash -e` contra un `docker` falso realista | **141 en 30 de 30 corridas** con bash 3.2.57 y **30 de 30** con bash 5.3.15 |
| M2 | Sensibilidad a la espera entre las dos escrituras de `docker info` (0, 0,01, 0,05, 0,1 y 0,3 s), paso con defecto, bash 5.3.15 | **141 en 30 de 30** en todas: las escrituras línea a línea bastan; la espera de 0,3 s queda solo como margen para un runner cargado |
| M3 | Arreglo candidato (sin pipe), mismas 30 corridas por bash | **rc 0 en 30 de 30** con ambos bash |
| M4 | Docker caído (`docker info` falla), arreglo candidato | **rc 1** con el mensaje del daemon como última línea, en ambos bash: el fallo ambiental sigue siendo ruidoso (FR-003) |
| M5 | `bats --tap tests/docker-e2e-*.bats` con `DOCKER_E2E` sin definir | **rc 0, plan `1..48`, 48 `ok`, 48 `# skip`**: el verde vacío existe y es trivial de producir |
| M6 | Auditoría de los `run:` de los tres workflows | 14 pasos, 5 pipes reales, 4 con un consumidor que cierra antes de tiempo (todos `| head`); 1 fallando |
| M7 | Los 48 e2e | 13 archivos; el `setup()` de cada test hace `docker compose build`; el test `qmd real (016)` corre **reducido** sin `QMD_EMBED_E2E=1` (su Tier 2, el embed real con descarga de modelo, solo corre con esa variable, y el test pasa sin ejercerlo) |
| M8 | Entorno local | Docker Desktop instalado pero **apagado**; carga del Mac ~9 por apps del usuario; el token de `gh` ya tiene el scope `workflow` |

## D1. Método del oráculo de regresión (pregunta a)

**Decisión**: dos piezas con roles distintos. (1) Un oráculo **de ejecución**, primario: extrae el `run:` real del paso desde `docker-e2e.yml` con `yq`, lo ejecuta con `bash -e` (el shell por defecto del runner) contra un `docker` falso realista, y exige estado 0, un centinela de fin de script y la presencia de las versiones en la salida. (2) Un **ratchet estático**, secundario, sobre todos los `run:` de los workflows, que prohíbe los consumidores que cierran antes de tiempo. Ambos viven en `tests/ci-workflows.bats`.

**Fundamento**: la ejecución es la única forma de *demostrar* el SIGPIPE y de verificar FR-002 y FR-003 (M1 a M4); el ratchet cubre la *clase* en los otros workflows, que la ejecución de un solo paso no ve.

**Alternativas descartadas**:
- Solo auditoría estática: no puede probar la señal, ni que las versiones sigan visibles, ni que Docker caído siga fallando. Pasa igual con un `| head` que no falla en la práctica y se rompe con uno nuevo que sí.
- Correr el paso contra un Docker real: viola el principio III (la suite del host no usa Docker) y no sería hermético.
- `nektos/act` para ejecutar el workflow completo: dependencia pesada que exige Docker, para probar un paso de once líneas.

**Prueba de que no puede pasar en vacío**, en cuatro capas: (a) la extracción debe encontrar el paso exactamente una vez y no vacío; (b) el centinela de fin de script se agrega al texto extraído, así que un script que muere antes no lo imprime; (c) un **autotest del arnés** corre el mismo mecanismo sobre un fixture congelado con el defecto original, copiado verbatim de `da22a06`, y exige que dé 141: si el arnés dejara de poder fallar, ese test se pone rojo; (d) un chequeo de que el stub, ejecutado solo, escribe más de 10 líneas en la primera tanda y otra tanda después de una pausa, de modo que un stub debilitado no pueda dejar el oráculo en vacío. Con (c) la mutación que exige SC-003 queda **permanente en la suite**, no solo corrida a mano una vez.

## D2. Diseño del `docker` falso

**Decisión**: un script bash con tres comportamientos. `--version` y `compose version` imprimen una línea. `info` sin argumentos imprime una sección de cliente de 14 líneas, una pausa de 0,3 s y una sección de servidor de 40 líneas, todas con `echo` (una escritura por línea): la forma exacta que produce el SIGPIPE del run 37197340169. `info --format <plantilla>` **renderiza** los campos que Docker real conoce (`ServerVersion`, `OperatingSystem`, `Architecture`, `CgroupVersion`, `Driver`) y termina en error si queda un `{{` sin resolver, como hace Docker real con un campo inexistente.

**Fundamento**: si el stub ignorara la plantilla, el oráculo no detectaría que el paso dejó de pedir la arquitectura, y FR-002 sería indemostrable. Renderizar convierte "el log muestra servidor y arquitectura" en una aserción real sobre lo que el paso pidió. El valor del servidor es distinto del de `docker --version` a propósito, para que la aserción sobre él no sea vacua. Un modo "Docker caído" (variable de entorno) hace que `info` falle con el mensaje del daemon, para FR-003.

**Alternativa descartada**: un stub que imprime siempre la misma línea fija para `--format`. Pasaría aunque el paso pidiera cualquier cosa.

## D3. Arreglo del paso de verificación (FR-001 a FR-003)

**Decisión**: quitar el pipe del diagnóstico de Docker y pedir a Docker solo lo que se quiere ver: `docker info --format 'server=… os=… arch=… cgroup=… storage=…'`. Una línea, sin consumidor, y si el daemon no responde el comando falla con su mensaje y `set -e` detiene el job. Para las líneas `bash --version | head -1` se usa una función local que **captura** la salida completa (`v=$("$@")`) y imprime la primera línea con `${v%%$'\n'*}`, sin pipe.

**Fundamento**: M3 y M4. Conserva exactamente la información que se pretendía mostrar, agrega la que faltaba (la versión del servidor y la arquitectura, que el `head -10` nunca llegaba a imprimir y que importan por el cambio de arm64 a amd64), y mantiene el fallo ambiental ruidoso.

**Alternativas descartadas**:
- `docker info | head -10 || true`: silencia el fallo de Docker caído (viola FR-003) y enmascara cualquier otro error del paso.
- Quitar `pipefail` del paso: el defecto es el consumidor, y `pipefail` es lo que protege de errores reales en los otros pipes.
- `head -10 < <(docker info)`: la sustitución de procesos esconde el estado de `docker info`; con el daemon caído el paso pasaría en silencio.
- `docker info > archivo && head -10 archivo`: funciona, pero deja un archivo y imprime 10 líneas de cliente que no sirven.
- `sed -n 1,10p`, `awk 'NR<=10'` con `exit`: son la misma clase de consumidor.

**Riesgo declarado**: los nombres de campo de la plantilla se verifican contra el stub, no contra un Docker real; la validación real ocurre en la corrida de evidencia (FR-014). Los cinco campos existen en la estructura de información del motor (`ServerVersion`, `OperatingSystem`, `Architecture`, `CgroupVersion`, `Driver`). Si el daemon rechazara uno, el paso falla fuerte en el primer despacho y se corrige ahí.

## D4. Detección del verde vacío (pregunta b; FR-006, SC-006, SC-007)

**Decisión**: dentro del propio paso de la suite. La salida de `bats --tap` pasa por `tee e2e.tap` (el log se ve en vivo y el archivo queda para contar); después se cuentan con `grep -c` las líneas `ok`/`not ok`, las saltadas (`ok … # skip`) y las fallidas, se imprime una línea `e2e summary: total=N executed=N skipped=N failed=N` y se decide: si bats devolvió un código distinto de cero, ese código gana; si devolvió cero pero no se ejecutó ningún test, el paso termina en 1 con una anotación `::error::`.

**Fundamento**: M5 muestra que sin esta guarda un runner sin Docker, o con la variable sin propagar, da verde con 48 saltos. `tee` consume toda la entrada, así que no introduce el patrón que esta feature elimina. Un solo paso evita acoplar dos pasos por un archivo y es ejecutable por el mismo arnés que el oráculo, con un `bats` falso que imprime TAP enlatado.

**Alternativas descartadas**:
- Un paso aparte con `if: always()`: agrega orden y condiciones, y tendría que manejar que el archivo no exista si el paso de la suite murió antes.
- Exigir un mínimo de N tests ejecutados: frágil, cambia cada vez que se agrega un e2e.
- Exigir cero saltos: el test de `QMD_EMBED_E2E` se salta por diseño, así que el nightly quedaría rojo para siempre.
- Un formateador JUnit: requiere herramientas extra para algo que `grep -c` resuelve.

**Prueba no vacía**: cinco casos TAP enlatados (todo saltado, lista vacía `1..0`, mezcla con saltos, un test fallando, y bats que no arranca) y una aserción de que el `env:` del paso trae `DOCKER_E2E: '1'`.

## D5. Resultado de la auditoría de `run:` (pregunta d; FR-010, SC-005)

Ningún paso fija `shell:`, así que en el runner rige `bash -e {0}` **sin** `pipefail`; este solo existe donde el script lo declara: 10 de los 14 pasos lo hacen.

| Workflow | Pasos `run:` | Con `pipefail` explícito | Pipes reales |
|----------|:-----------:|:------------------------:|--------------|
| `docker-e2e.yml` | 4 | 3 | `bash --version \| head -1`, `docker info \| head -10` |
| `shellcheck.yml` | 2 | 1 | `{ find…; printf…; } \| xargs shellcheck…` |
| `test.yml` | 8 | 6 | `bash --version \| head -1`, `/bin/bash --version \| head -1` |

**Disposición de los cinco pipes**:
- `docker info | head -10`: **defecto, falla siempre** (M1). Se corrige (D3).
- `bash --version | head -1` (×2) y `/bin/bash --version | head -1`: seguros hoy porque `bash --version` escribe su salida de una vez al terminar, así que `head` nunca cierra con algo pendiente. Es seguro por construcción del productor, no por el pipe: la propia regla de `CLAUDE.md` los llama "safe only by accident". **Se eliminan igual**, con la función de captura, para que el ratchet no necesite lista de excepciones. Es un cambio de dos líneas en `test.yml` que no toca la matriz de 025.
- `... | xargs shellcheck`: el consumidor lee hasta EOF, no cierra antes. Seguro; el ratchet no lo marca.

**Falsos positivos**: una búsqueda ingenua de `|` cuenta también las cuatro líneas `brew list … || brew install …` de macOS; la expresión correcta excluye `||`.

**Scripts de los e2e**: las únicas apariciones de `pipefail` en `tests/docker-e2e-*.bats` son un comentario de `postlogin.bats:131` (que documenta el patrón evitado: `docker compose logs | grep -q`) y dos bloques de `warm-cache.bats` sin consumidor que cierre antes. Sin hallazgos.

## D6. Ratchet estático

**Decisión**: un test que lee todos los `run:` de `.github/workflows/*.yml` (con `yq` a JSON y `jq`) y falla si alguna línea de pipeline tiene como consumidor `head`, `grep -q` o `grep -m`, `sed -n '…q'` o `sed Nq`, o `awk` con `exit`. Sin lista de excepciones. El detector tiene su propia prueba: fixtures con cada patrón prohibido deben detectarse, y un fixture con pipes benignos (`xargs`, `tee`, `sort`, `wc`) no debe marcarse.

**Fundamento**: convierte la auditoría de una sola vez en una guarda permanente, y el "no hay excepciones" es posible porque D3 y D5 eliminan los cuatro casos. El autotest del detector aplica la misma lección que D1: un chequeo que no puede fallar no es evidencia.

**Alternativa descartada**: una lista blanca con razones. Funciona, pero cada excepción es una deuda que alguien debe volver a mirar cuando cambie el productor; eliminar es más barato.

## D7. Causa y arreglo de E1 y E3 de `docker-e2e-askq-guard.bats` (pregunta e; FR-012)

Causas, **por lectura del código** (la verificación necesita Docker, ver D8):

**E1**: el test invoca el instalador con `--entrypoint sh`, que se salta el arranque. El instalador es fail-silent (`set +e`, `exit 0` en toda ruta) y, si `$HOME/.claude` no existe, su `printf '{}' > settings.json` falla y sale sin crear nada; el `jq` siguiente del test aborta. En el arranque real el directorio ya existe. Las aserciones de E1 son coherentes con el código: `pre_install_askq_hook` existe en `start_services.sh:801` y el instalador registra el `matcher` `AskUserQuestion`.

**E3**: el test busca el `server.ts` del plugin de Telegram con `find`, pero la imagen no trae el plugin (se instala después del login). Las tres cadenas que afirma (`typing refresh patch v6`, `askq-guard give-up delivery patch v1`, `bloqueada en un men…`) **siguen vigentes en el parcheador** (verificado con grep), así que el único fallo es la ausencia del plugin.

**Arreglo**, ambos acotados al test (política clarificada el 05-10-2026): E1 crea `$HOME/.claude` antes de invocar el instalador, que es lo que el arranque real ya garantiza; E3 se **auto-siembra** con el patrón que ya usa `docker-e2e-voice.bats` (copiar `tests/fixtures/telegram-server-pristine.ts` a `/workspace/.e2e/`, copiarlo al caché del plugin dentro del contenedor y ejecutar el parcheador de la imagen), y luego afirma los mismos marcadores. No se toca producción ni se cambia lo que cada test prueba.

**Alternativa descartada para E1**: invocar la función real `pre_install_askq_hook` cargando `start_services.sh` con `START_SERVICES_NO_RUN=1`. Es más fiel al título del test, pero cambia lo que prueba y exige verificar la carga del script en la imagen; la política pide cambios mínimos. Queda anotada como mejora posible, no como parte de esta feature.

**Estado**: hipótesis fundadas en código, no demostradas. La demostración (rojo antes, verde después) exige Docker y está en las tareas de implementación.

## D8. Línea base de los e2e (pregunta c)

**Decisión**: medir por **CI**, y la medición local queda opcional y con compuerta.

**Por qué por CI primero**: el nightly corre en `ubuntu-latest` amd64 y los e2e solo constan corridos en arm64; la medición que importa es la de su entorno real, que además no cuesta nada (el repo es público, minutos gratis) ni ocupa el Mac. Requiere empujar la rama con el arreglo y un `workflow_dispatch`: el push necesita confirmación del operador; el token de `gh` ya tiene el scope `workflow` (M8), así que no hace falta device-flow.

**Por qué no local ahora**: Docker Desktop está apagado y el Mac tiene una carga cercana a 9 por aplicaciones del propio usuario (Chrome, Fireflies, WindowServer). Arrancar Docker y construir 48 veces competiría con lo que esté usando, y una línea base medida bajo esa carga sería poco representativa para tests con tiempos. Se hará solo con el visto bueno del operador, y su valor es comparar arm64 contra amd64 para atribuir rojos a la arquitectura.

**Estimación de tiempo (no medida)**: 48 `docker compose build` con caché más los cuerpos de los tests pueden superar el tope de 30 minutos en un runner frío. El candidato más lento es `qmd real (016)`, cuyo Tier A compila `node-llama-cpp` desde fuente (cmake) dentro de la imagen musl. La decisión ya está tomada (FR-016): si la primera corrida agota el tiempo, se sube el tope y se vuelve a medir; no se parte la suite en jobs. Una corrida que agota el tiempo igual deja en el log el TAP de los tests que alcanzó a ejecutar, que sirve para clasificar parte de la suite.

**Cobertura reducida por diseño (no es un salto)**: `qmd real (016)` ejecuta su Tier A y pasa sin ejercer el Tier 2 si falta `QMD_EMBED_E2E=1`. No aparece como `# skip` en el TAP, así que la guarda de verde vacío no la ve ni debe verla; se declara aquí para que un nightly verde no se lea como cobertura total. Cambiarlo queda fuera de alcance (no cambia la semántica de los e2e).

## D9. VERSION y CHANGELOG

**Decisión**: entrada en `CHANGELOG.md` y **sin bump de `VERSION`**. Es CI y tests, sin cambio de runtime (precedente 019 y 025). Al implementar se verifica a mano `VERSION` contra `origin/main` (hoy 0.28.0), la lección de 023.

## D10. Lo que NO se hace

- No se ejecuta el hook `speckit.agent-context.update` (borra el bloque SPECKIT de `CLAUDE.md`); la referencia al plan se agrega a mano.
- No se toca `docker/`, `scripts/` ni `modules/`, ni se agregan permisos o secretos al workflow (FR-015).
- No se rediseña la matriz de `test.yml`: solo cambian las dos líneas `| head -1`.
- No se agregan alertas de nightly rojo (fuera de alcance).

## Estado de las incógnitas

| Pregunta | Estado |
|----------|--------|
| (a) Método del oráculo | Resuelta: D1, D2, medida en M1 a M4 |
| (b) Detección de verde vacío | Resuelta: D4, problema medido en M5 |
| (c) Cuántos e2e fallan realmente | **Diferida a compuerta**: D8 (CI primero; local con visto bueno) |
| (d) Auditoría de `run:` | Resuelta: D5, M6 |
| (e) Causa y arreglo de E1 y E3 | Causa fundada en código, arreglo diseñado; demostración pendiente de Docker (D7) |
