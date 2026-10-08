# Data Model: El nightly de docker-e2e ejecuta la suite de verdad

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

La feature no persiste datos de producto. Las dos entidades del spec son registros de evidencia: una describe lo que ocurrió en una corrida del nightly y la otra lo que se decidió sobre cada e2e en rojo. Sus formatos están fijados para que SC-004 y SC-006 sean verificables sin reproducir nada en local.

## Entidad 1: Corrida nocturna

Una ejecución del workflow `docker-e2e (nightly)`, programada o manual.

| Campo | Tipo | Notas |
|-------|------|-------|
| `run_id` | entero | Identificador de GitHub Actions (por ejemplo `37307700006`) |
| `evento` | `schedule` \| `workflow_dispatch` | Las corridas de evidencia (FR-014) son `workflow_dispatch` sobre la rama |
| `commit` | sha | Sobre qué commit corrió |
| `paso_verificacion` | `ok` \| `fallo` | Resultado del paso `Verify deps + docker` |
| `resumen_suite` | `{total, ejecutados, saltados, fallidos}` \| ausente | Ausente si la suite nunca arrancó; sale de la línea `e2e summary:` del log, cuyas claves `total`, `executed`, `skipped` y `failed` corresponden a `total`, `ejecutados`, `saltados` y `fallidos` |
| `conclusion` | `success` \| `failure` \| `cancelled` \| `timed_out` | Dada por GitHub |
| `duracion` | segundos | Para medir contra el tope del job |

**Reglas de validación**:
- `ejecutados = total - saltados`, siempre (es la definición, ver [contracts/suite-step.md](contracts/suite-step.md)).
- Una corrida `success` exige `paso_verificacion = ok`, `ejecutados > 0` y `fallidos = 0` (FR-005, FR-006).
- Una corrida con `resumen_suite` ausente y `conclusion = failure` murió antes de la suite: es el estado de las cinco corridas de octubre.
- El verde vacío (`ejecutados = 0` con código de salida 0 de `bats`) **no puede** terminar en `success` (FR-006, SC-007).

**Transiciones**:

```text
en cola -> verificando -> [paso_verificacion = fallo] -> failure (murio antes de la suite)
                       -> ejecutando la suite -> [bats con codigo != 0]            -> failure
                                              -> [bats con codigo 0, ejecutados=0] -> failure (verde vacio detectado)
                                              -> [bats con codigo 0, ejecutados>0] -> success
                                              -> [tope del job agotado]            -> timed_out
```

## Entidad 2: Rojo clasificado

Un e2e que falló en una corrida real, con lo que se decidió sobre él. Se registra en las Notes de `tasks.md` tras la primera corrida real, con el formato de [contracts/e2e-classification.md](contracts/e2e-classification.md).

| Campo | Tipo | Notas |
|-------|------|-------|
| `test` | archivo + nombre | Por ejemplo `docker-e2e-askq-guard.bats` / `E2E 031: pre_install_askq_hook registers …` |
| `estado` | `not ok` \| `timeout` | Cómo falló en la corrida |
| `causa` | texto | Qué falló y por qué, con el mecanismo nombrado |
| `tipo` | `arnés` \| `producto` \| `entorno` | Defecto de arnés, defecto de producto o diferencia de entorno (por ejemplo arquitectura del runner) |
| `evidencia` | `run_id` + fragmento del log | El fragmento que prueba la causa (FR-011) |
| `disposicion` | `corregido` \| `aislado` \| `escalado` | Ver reglas |
| `motivo_salto` | texto | Solo si `aislado`: el texto del salto, visible en el TAP |
| `seguimiento` | referencia | Tarea, issue o feature donde sigue el asunto |

**Reglas de validación**:
- **R1**: ningún rojo existe sin `tipo`, `evidencia` y `disposicion` (SC-004).
- **R2**: `tipo = producto` implica `disposicion = escalado`; nunca se aísla en silencio ni se corrige dentro de esta feature (FR-013).
- **R3**: `disposicion = aislado` exige un salto con `motivo_salto` visible en el TAP y un `seguimiento` registrado (FR-012). Un salto sin motivo o sin seguimiento es inválido.
- **R4**: `disposicion = corregido` solo se admite si la causa ya estaba diagnosticada (E1 y E3 de 031) o si el arreglo queda acotado al propio test o a su arnés sin tocar producción, y se verificó con una corrida real (FR-012).
- **R5**: un salto por `tipo = entorno` se condiciona al entorno (por ejemplo a la arquitectura) y no es incondicional.

**Transiciones**:

```text
rojo nuevo -> clasificado (tipo + evidencia) -> con disposicion:
                 corregido -> verificado en una corrida real (verde)
                 aislado   -> salto visible con motivo y seguimiento
                 escalado  -> registrado como defecto de producto, fuera de esta feature
```

## Estados iniciales conocidos (05-10-2026)

| Test | Tipo | Disposición prevista | Estado de la evidencia |
|------|------|----------------------|------------------------|
| `docker-e2e-askq-guard.bats` E1 | arnés | corregido | Causa fundada en código; demostración pendiente de Docker |
| `docker-e2e-askq-guard.bats` E3 | arnés | corregido | Causa fundada en código; demostración pendiente de Docker |
| los demás (46) | sin medir | se clasifican tras la primera corrida real | Sin datos: la suite nunca se ejecutó en CI |
