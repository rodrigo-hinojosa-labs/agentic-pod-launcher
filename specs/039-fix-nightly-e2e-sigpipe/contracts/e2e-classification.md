# Contract: Registro de rojos clasificados

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Cubre**: FR-011, FR-012, FR-013, SC-004 | **Entidad**: Rojo clasificado de [data-model.md](../data-model.md)

Define el formato en que se registra qué pasó con cada e2e que falle en la primera corrida real del nightly, para que "cero casos de no se sabe qué pasó" (SC-004) sea comprobable leyendo un solo lugar.

## 1. Dónde se registra

En las **Notes de `tasks.md`**, en un bullet fechado **"Primera corrida real del nightly"**, con la tabla de abajo. Es el precedente del repo: las mediciones y su evidencia viven junto a la tarea que las exigió. Los seguimientos que excedan esta feature se abren como entradas propias y se referencian desde la columna `seguimiento`.

## 2. Formato

Una fila por cada test que **no** terminó verde. Los verdes no se listan, pero el resumen de la corrida (`e2e summary: total=… executed=… skipped=… failed=…`) y el `run_id` van al principio, para que el total cuadre.

```markdown
Corrida: run <ID> (workflow_dispatch, <rama>, <commit>) — e2e summary: total=<N> executed=<N> skipped=<N> failed=<N>

| Test | Archivo | Estado | Causa | Tipo | Evidencia | Disposición | Seguimiento |
|------|---------|--------|-------|------|-----------|-------------|-------------|
| <nombre del @test> | <archivo.bats> | not ok / timeout | <qué falló y por qué> | arnés / producto / entorno | run <ID>: "<fragmento del log>" | corregido / aislado / escalado | <tarea, issue o feature> |
```

## 3. Reglas

- **R1 (completitud)**: la suma de las filas con `Estado = not ok` o `timeout` coincide con `failed` más los tests que no llegaron a correr por tiempo agotado. Una fila sin `Tipo`, `Evidencia` o `Disposición` es inválida.
- **R2 (producto)**: `Tipo = producto` exige `Disposición = escalado`. No se aísla ni se corrige dentro de esta feature (FR-013).
- **R3 (aislado)**: `Disposición = aislado` exige que el salto exista en el código con su motivo, que ese motivo aparezca en el TAP como `# skip <motivo>`, y que `Seguimiento` apunte a algo concreto (FR-012). El texto del salto debe nombrar el entorno o la causa, no decir solo "temporalmente".
- **R4 (corregido)**: `Disposición = corregido` solo con causa ya diagnosticada (E1 y E3 de 031) o con un arreglo acotado al test o a su arnés sin tocar producción, y verificado con una corrida real: la `Evidencia` de una fila corregida incluye el `run_id` en verde.
- **R5 (entorno)**: un salto por diferencia de entorno se condiciona a ese entorno (por ejemplo `[ "$(uname -m)" = "x86_64" ] && skip "…"`), nunca incondicional.
- **R6 (intermitentes)**: un test que falla a ratos no se etiqueta "flake" sin medirlo: se registra la tasa observada sobre repeticiones y, si no se midió, se escribe "intermitencia sin medir" en `Causa`.

## 4. Filas ya conocidas (05-10-2026)

Preasignadas por lectura del código; se confirman o corrigen con la primera corrida real.

| Test | Archivo | Causa fundada | Tipo | Disposición prevista |
|------|---------|---------------|------|----------------------|
| `E2E 031: pre_install_askq_hook registers PreToolUse+AskUserQuestion in settings.json at boot` | `docker-e2e-askq-guard.bats` | El arnés usa `--entrypoint sh` y `$HOME/.claude` no existe; el instalador fail-silent no crea `settings.json` y el `jq` siguiente aborta | arnés | corregido (crear el directorio, como el arranque real) |
| `E2E 031: the patched plugin server.ts carries typing v6 + the askq give-up hunk` | `docker-e2e-askq-guard.bats` | La imagen no trae el plugin de Telegram (se instala tras el login) y el test lo busca con `find` | arnés | corregido (auto-sembrar el fixture como `docker-e2e-voice.bats`) |

## 5. Fuera del contrato

- Alertas o notificaciones de un nightly rojo.
- Arreglar defectos de producto (escalado, no corregido aquí).
- Un panel o histórico de corridas: el registro es el de la primera corrida real; las siguientes se leen en el propio log gracias al resumen.
