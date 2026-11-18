# Propuesta de publicación de 047

**Estado:** publicación autorizada el 18-11-2026, en ejecución. T058/T059 de
[tasks.md](tasks.md) registrarán commit, push y PR al observar sus resultados. El merge
sigue reservado al operador.

## Commit propuesto

```text
fix: corrige los falsos avisos del healthcheck local
```

Alcance: 45 archivos de 047; artefactos Spec Kit y su selector; VERSION 0.33.0/CHANGELOG; par de plantillas
del healthcheck local y su render; oráculos/fixtures sintéticos; job de integración Linux;
documentación y patrones de exclusión. Excluir caches, evidencia temporal, estado de agentes,
archivos de credenciales y AGENTS.md. El script Linux debe conservar 100755 en el índice y
commit, comprobación que se hará solo después de autorizar la escritura Git.

La fuente validada, los resultados exactos y las revisiones están en el Registro de tasks;
no se publican trazas privadas de cache. Antes del commit se revalida que el diff no haya
cambiado y que la base/versionado sigan siendo compatibles.

## PR propuesto

**Título:** Corrige los falsos avisos y la entrega del healthcheck local (#111)

**Destino:** main. Crear como borrador; quitar el borrador solo con autoridad vigente y
todos los checks de la misma cabeza en verde. No lanzar workflow_dispatch ni hacer merge.

El cuerpo canónico está en [pr-body.md](pr-body.md), preparado para pasarlo como argumento
estructurado o archivo. Incluye el gate host final y distingue la integración Linux pendiente;
no publicar el borrador antes de la autorización T058/T059.

Después de la CI, incorporar al PR los conteos/URLs de esa cabeza. Después del merge que
haga el operador, verificar árbol/VERSION/checks por lectura y registrar el cierre. El
despliegue a un agente real y la limpieza de ramas/worktrees requieren su autorización.
