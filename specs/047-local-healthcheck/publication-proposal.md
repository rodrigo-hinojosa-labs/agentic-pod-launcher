# Publicación y aceptación de 047

**Estado:** publicación autorizada y ejecutada el 18-11-2026: commits `8bc7baa` y `17fcd6b`,
con cuatro checks verdes sobre la segunda cabeza. [PR #136](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/136)
fue habilitado tras verificar esa CI y devuelto a borrador para publicar el cierre documental.
Evidencia y recibo en [tasks.md](tasks.md). El merge sigue reservado al operador.

El seguimiento de T060 encontró un corte real del job macOS a45min, después de1872/2196
resultados sin aserciones fallidas entre los terminados. El ajuste acotado amplía el
presupuesto exterior compartido a60min y su guarda, conservando runners/Bash/permisos,
inventario y topes del producto. La CI de17fcd6b completó los2196 casos por bash; macOS
necesitó54min03s y dejó5min57s de margen. La decisión del agente, RED/GREEN y resultados
exactos se identifican en el Registro. El estado de la cabeza documental posterior se
verifica en PR#136/checks antes de su habilitación definitiva.

## Commits publicados

```text
fix: corrige los falsos avisos del healthcheck local
```

Commit `8bc7baa951a480bd9293857a3c3148e878d90216`. El ajuste de CI y su registro se publicaron
en `17fcd6b3ff51b4746ed618138f6539d6f841b25d`, `fix: amplía el presupuesto de BATS tras medir la CI de 047`.

Alcance: 45 archivos de 047; artefactos Spec Kit y su selector; VERSION 0.33.0/CHANGELOG; par de plantillas
del healthcheck local y su render; oráculos/fixtures sintéticos; job de integración Linux;
documentación y patrones de exclusión. Excluir caches, evidencia temporal, estado de agentes,
archivos de credenciales y AGENTS.md. El script Linux conserva 100755, comprobado en índice
y árbol del commit; los cuatro documentos de este cierre conservan la fuente d81d962d.

La fuente validada, los resultados exactos y las revisiones están en el Registro de tasks;
no se publican trazas privadas de cache. Antes del commit se revalida que el diff no haya
cambiado y que la base/versionado sigan siendo compatibles. La escritura del cierre sigue
la misma autoridad de publicación de047; no autoriza merge, despliegue ni limpieza remota.

## PR para revisión del operador

**Título:** Corrige los falsos avisos y la entrega del healthcheck local (#111)

**Destino:** main. Crear como borrador; quitar el borrador solo con autoridad vigente y
todos los checks de la misma cabeza en verde. No lanzar workflow_dispatch ni hacer merge.

El cuerpo base está en [pr-body.md](pr-body.md), preparado para pasarlo como argumento
estructurado o archivo. Incluye el gate host y la CI completa de17fcd6b. Los resultados de
los checks de la cabeza documental posterior se completan en el propio PR; no se inventa
un resultado futuro ni se sustituye por la igualdad de producto. Se exige CI verde actual.

Después de la CI, incorporar al PR los conteos/URLs de esa cabeza. Después del merge que
haga el operador, verificar árbol/VERSION/checks por lectura y registrar el cierre. El
despliegue a un agente real y la limpieza de ramas/worktrees requieren su autorización.
