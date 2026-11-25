# Modelo de estados del escenario de migración

**Fecha**: 24-11-2026. Este diseño no agrega formatos ni estado al producto. Describe los archivos temporales del fixture y la evidencia de pruebas.

## Instalación heredada

Ruta del caché en el host: `<fixture>/.state/.cache/qmd/`; dentro del contenedor: `$HOME/.cache/qmd/`.

| Campo observable | Antes del boot corregido | Antes de tick 1 | Después de tick 1 |
| --- | --- | --- | --- |
| `index.sqlite` | Presente, stand-in vacío del motor falso | Presente | Presente |
| `.qmd-setup-ok` | Presente | Presente | Presente |
| `.qmd-collection-wiki` | Ausente | Ausente | Presente |
| Estado de migración | `pending` | `pending` | `done` |
| Llamadas `collection remove` | 0 | 0 | Exactamente 1 |
| Llamadas `collection add` | 0 | 0 | Exactamente 1, con máscara `wiki/**/*.md` |

El estado de setup y el de migración son independientes. Sembrar el marcador de colección invalidaría la prueba. El índice vacío no es una base de QMD real; la prueba conserva el motor falso existente y valida orquestación.

El vault se prepara con una página fija bajo `wiki/` antes de levantar el contenedor. El calendario del fixture es `0 0 31 2 *`; no se escriben páginas durante los ticks. Los logs y los gates están fuera del vault.

## Ejecución de reindex

Se conserva el contrato de `tests/helper-qmd-e2e.bash`. Cada invocación lógica al ayudante puede reintentar **solo** la contención del lock. La prueba acepta un tick cuando el retorno del ayudante es 0 y `REINDEX_STATUS` es 0. Una salida de contención sin trabajo no satisface esas dos comprobaciones del protocolo completo.

```text
fixture preparado -> boot -> precondición LEGACY_PENDING
    -> ayudante tick 1 + guardias
    -> observación del log (sin otro reindex)
    -> conteos exactos + orden + HAVE_SENTINEL + migration=done
    -> ayudante tick 2 + guardias
    -> conteos de colección idénticos
```

La lectura inicial del log admite archivo todavía inexistente. Se conserva el bucle de 45 s para observarlo, pero nunca se relanza tick 1 desde ese bucle. Si no aparecen las operaciones esperadas, falla al vencer el plazo.

## Confirmaciones de inspección

| Señal | Condición para aceptarla |
| --- | --- |
| `LEGACY_PENDING` | Inspección rc 0; índice y setup presentes; marcador de colección ausente; sin replace previo |
| Registro de tick 1 | Un remove y un add con la máscara correcta; remove precede a add y add a cleanup |
| `HAVE_SENTINEL` | Inspección rc 0 y texto exacto esperado |
| `.migration` | Inspección rc 0 y valor `done` |
| Conteo de tick 2 | Inspección rc 0 y mismo conteo que tras tick 1 |

Las aserciones son sentencias directas de Bats y validan status antes de contenido. No se aceptan `[[ ... ]]` ni negaciones intermedias que puedan quedar inactivas.

## Gates exclusivos de la reproducción

Por caso se genera un directorio nuevo `<fixture>/.e2e/050/`, fuera del vault:

| Señal | Escritor | Significado |
| --- | --- | --- |
| `entered` | Wrapper, antes de la función real | El setup de boot llegó al punto controlado |
| `release` | Coordinador, solo en late | Autoriza ejecutar el setup real después de la inspección inicial |
| `returned` | Wrapper, después de la función real | Esa llamada real terminó; no se infiere del marcador presembrado |
| Registro de control | Wrapper y coordinador | Variante, orden, tiempos y retorno, sin contenido de estado del agente |

Early exige `returned` con retorno 0 antes de la inspección. Late exige `entered` y ausencia de `returned`, inspecciona, escribe `release` y exige después `returned` con retorno 0 antes de tick 1. En ambos se comprueba también el desenlace de setup correspondiente a base/candidato. Las señales no se reutilizan entre casos; liberar el gate sin observar el retorno invalida el caso. Los plazos y el tratamiento de una señal ausente se definen en [el protocolo de evidencia](contracts/evidence-protocol.md).

## Identidad de recursos de reproducción

Cada caso tiene un `COMPOSE_PROJECT_NAME` único. El nombre fijo de contenedor del fixture es `qmd-migrate-e2e`: si ya existe, el preflight rechaza el caso sin tocarlo. El registro conserva proyecto, nombre/ID de contenedor y label `com.docker.compose.project` observada, para acreditar que la limpieza actúa solo sobre recursos propios. La identidad se propaga al Bats, a su teardown y al coordinador, conforme al protocolo.

## Registro de evidencia

Cada fila de la matriz guarda: base/candidato, hashes de los archivos probados, bash/Bats, sistema y arquitectura, orden solicitado y observado, resultado de gates, TAP y código de salida. La corrida normal agrega resumen de tests y recursos si ya se emiten. La CI agrega commit, run ID y URL. Los resultados se incorporarán al Registro de `tasks.md` durante implementación; este comando no lo crea.
