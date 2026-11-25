# Investigación: carrera de arranque del e2e de migración QMD

**Fecha**: 24-11-2026. **Base examinada**: `a45beaefaa68da17ce16d956351337bd5ce3b9d5`. **Alcance**: diseño de la feature 050; no implementación ni corrida Docker.

Las referencias de línea corresponden a esa base. Los dos agentes de investigación trabajaron en solo lectura: uno revisó fixture, setup y competidores; el otro revisó el oráculo, los ayudantes y las guardias existentes. No ejecutaron pruebas ni hicieron cambios.

## Evidencia obtenida

### E1. Contratos distintos de setup y migración

Verificado por lectura:

- `scripts/lib/qmd_index.sh:315`: índice presente sin `.qmd-collection-wiki` significa `pending`.
- `scripts/lib/qmd_index.sh:463`: el fast path de setup exige `.qmd-setup-ok` **e** `index.sqlite`.
- `scripts/lib/qmd_index.sh:519`: un índice heredado se refresca sin escribir el marcador de migración; al terminar se escribe el de setup.
- `tests/docker-e2e-qmd.bats:458`: el fixture actual omite ambos marcadores; `:504` inspecciona el de setup y exige que siga ausente.

Las dos pruebas existentes de refresh y setup reentrante pasaron en los dos bash durante `/speckit-specify`. Esa comprobación respalda el contrato, no acredita una reproducción de la carrera completa.

### E2. Sonda de las dos aserciones originales

Medición local del 24-11-2026, Bats 1.13.0, bash 5.3.15 y 3.2.57. Se extrajeron del bloque real de la prueba las dos líneas `[[ ... ]]` (`SKIPPED` y `HAVE_SENTINEL`). Cada una se ejecutó como sentencia directa de un test Bats temporal, precedida de un resultado falso y seguida de `true`.

| Sonda | bash 5.3.15 | bash 3.2.57 |
| --- | --- | --- |
| Aserción original de setup con resultado `RAN` | rc 1 | rc 0 |
| Aserción original de migración con resultado `MISSING` | rc 1 | rc 0 |
| Aserción intermedia `[ ]` de setup con resultado `RAN` | rc 1 | rc 1 |
| Aserción de status con texto válido y retorno 7 | rc 1 | rc 1 |

Las ocho celdas dieron el resultado previsto. Los archivos temporales fueron retirados. **Límite:** es una medición de las aserciones aisladas; la reproducción del e2e anterior en Docker sigue pendiente.

### E3. Otras fuentes de indeterminismo del mismo fixture

- El calendario actual es `*/5 * * * *` (`tests/docker-e2e-qmd.bats:441`). El cron podría migrar antes del tick manual.
- El calendario imposible `0 0 31 2 *` ya se usa en la 041 del mismo archivo (`:698`). No requiere cambiar el producto.
- El seed del vault precede al setup (`docker/scripts/start_services.sh:205-216`); el watcher arranca después de la sesión inicial (`:1474`) y reindexa ante eventos (`scripts/qmd_watch.sh:47-77`). Sembrar el contenido antes del boot evita que una escritura de la prueba dispare al watcher.
- Las primeras ocurrencias de remove/add/cleanup solo prueban orden (`tests/docker-e2e-qmd.bats:537-544`); no prueban que haya exactamente una migración.
- El bucle de 45 s lanza tick 1 otra vez en cada vuelta. Eso podría ocultar que la primera ejecución no migró. El bucle puede conservarse solo para leer el registro.

### E4. Superficies reutilizables y límites de las guardias

- `tests/helper-qmd-e2e.bash:118-174`: retorno del ayudante y `REINDEX_STATUS` son señales distintas. Los dos deben aceptarse antes de seguir.
- `tests/qmd-e2e-lock.bats:632-667`: B2 comprueba texto, retornos, tolerancia del registro y diagnóstico; no ejecuta las aserciones ni protege el fixture. El archivo contiene 26 pruebas (`bats --count`, medido en esta fase).
- `tests/qmd-embed-nightly.bats:208-230`: precedente de localizar el launcher exterior de Bats y ejecutar un Bats hijo en entorno limpio.
- `tests/ci-workflows.bats:97-113`: precedente de extracción que falla cuando el sujeto está ausente o no es único.
- `.github/workflows/docker-e2e.yml`: el e2e corre por cron o dispatch; un PR no lo dispara. El dispatch normal ejecuta la suite y reporta arquitectura y resumen. No se necesitan cambios al workflow.

## Decisiones

### D1. Representar setup completado y migración pendiente

**Decisión:** presembrar `index.sqlite` y `.qmd-setup-ok`; mantener ausente `.qmd-collection-wiki`. Presembrar una página fija bajo `wiki/`, cambiar solo el calendario del fixture al imposible y no escribir en el vault durante los ticks. Comprobar la precondición dentro del contenedor y que no haya replace previo.

**Razón:** representa una instalación heredada válida y hace que el setup real sea un no-op, cualquiera sea su orden de ejecución. El índice vacío sigue siendo un stand-in del motor falso, como en la prueba actual; no se afirmará que es una base SQLite real.

**Alternativas descartadas:** quitar la aserción inicial (pierde atribución al primer tick); escribir el marcador de migración (elimina lo que se quiere probar); aumentar una espera (mantiene la carrera); cambiar setup o locks de producto (fuera de FR-010).

### D2. Un solo tick efectivo antes de observar el registro

**Decisión:** mover la llamada y las guardias de tick 1 antes del bucle de 45 s. Dentro quedan únicamente lectura tolerante y espera. Conservar los dos ticks a través del ayudante de 043, sus retornos, los topes, el diagnóstico y el tratamiento del archivo aún inexistente.

**Razón:** un log tardío no justifica repetir trabajo ya aceptado. Se conserva la cobertura de #109 y se impide ocultar un primer tick sin migración.

**Alternativas descartadas:** eliminar toda tolerancia del registro; conservar el reindex dentro del bucle; modificar el ayudante compartido de 043.

### D3. Comprobar efecto y capacidad de fallar

**Decisión:** usar aserciones `[ ]`, validar status de cada inspección y exigir un remove y un add, en orden, antes de cleanup. Exigir marcador final, estado `done` y ningún replace adicional tras tick 2. El oráculo host ejecutará segmentos reales de la prueba como sentencias directas de un Bats hijo, con fakes limitados a las fronteras de ejecución, reloj y espera.

**Razón:** una guardia textual por sí sola no acredita que la aserción falle. Copiar una versión ideal del cuerpo al oráculo sería tautológico.

**Alternativas descartadas:** solo regex; ejecutar la sección como una función dentro de `run`, `if` o una lista `||` (puede alterar errexit); reutilizar un Bats interno que resuelva otro intérprete.

### D4. Mantener el cambio pequeño y separado del ayudante de locks

**Decisión:** nuevo `tests/qmd-e2e-boot-race.bats`, con un ayudante propio de pruebas para extracción y Bats hijo; B2 se adapta al orden nuevo. `tests/helper-qmd-e2e.bash` no cambia. No hay nuevas pruebas Docker: cambia el escenario existente.

**Razón:** la guardia de boot y sus controles negativos tienen un propósito distinto de la espera del lock. Se evita ampliar la superficie de un ayudante compartido.

**Alternativa descartada:** mezclar todos los escenarios en `qmd-e2e-lock.bats` o crear un nuevo e2e que deje intacto el defectuoso.

### D5. Reproducción Docker inducida sobre copias aisladas

**Decisión:** implementar en la fase de implementación una herramienta y un wrapper de prueba bajo `specs/050-e2e-qmd-boot-race/tools/`. El wrapper sustituye el supervisor solo en el contenedor de la reproducción, sourcea una copia verificada del supervisor original, envuelve `qmd_setup_if_needed` con gates y llama al `main` original.

**Factibilidad por lectura:** `docker/entrypoint.sh:118` ignora un `command:` alternativo y ejecuta el supervisor como `agent`. Su guard al final (`docker/scripts/start_services.sh:1485-1490`) permite sourcearlo sin iniciar `main`; las bibliotecas ya se cargaron antes de envolver setup. Las llamadas siguen usando el código real y el entrypoint conserva su preparación.

**Razón:** early necesita acreditar el retorno real de setup; un marcador de setup presembrado no lo demuestra. Late debe acreditar que setup entró al gate antes de inspeccionar.

**Alternativas descartadas:** cambiar `command:` de Compose (no intercepta el entrypoint); bloquear solo el motor QMD (no hay llamada al motor en el fast path nuevo); dormir una cantidad fija; tocar un agente desplegado.

**Límite:** el wrapper aún no se ejecutó en Docker. La implementación deberá hacer primero un smoke de su cableado; si no conserva el entrypoint, la identidad `agent`, los hashes o el `main` original, la evidencia no será válida y habrá que corregir el arnés sin cambiar producto ni ampliar alcance.

### D6. Evidencia local y CI antes del PR

**Decisión del operador, registrada en clarify:** reproducción y validación local, más corrida manual verde del e2e de CI en Linux amd64 antes del PR. La evidencia debe identificar el commit y mostrar la prueba ejecutada, sin salto.

**Razón:** el verde de los checks ordinarios del PR no incluye ese e2e. La matriz inducida prueba la intercalación; la corrida normal y la CI prueban integración.

**Alternativa descartada por la respuesta del operador:** esperar la primera nocturna posterior al merge para tener evidencia e2e de CI.

## Resultado de investigación

No quedan decisiones técnicas sin resolver para escribir el diseño. Los pasos pendientes son mediciones de implementación y aceptación: ROJO/VERDE del nuevo oráculo, reproducción completa en Docker, regresión del host y CI. Ninguno se declara realizado en este documento. No se crean `tasks.md`, scripts de implementación ni cambios de producto en esta fase.
