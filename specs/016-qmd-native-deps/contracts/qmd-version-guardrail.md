# Contrato: guardrail de versión de qmd (US4)

Impide subir `vault.qmd.version` sin re-verificar las suposiciones del fix. En 2.6.x los `tree-sitter-*` pasaron de `optionalDependencies` a dependencias **duras**, lo que invalidaría la estrategia por `trustedDependencies` (tree-sitter volvería a intentar compilar).

## Comportamiento esperado

1. **Pin single-source**: la versión vive solo en `agent.yml` (`vault.qmd.version`, hoy `2.5.3`). Sin duplicados.
2. **Test bats que fija la versión esperada**: un `tests/qmd-version-guard.bats` (host) asevera que la cadena por defecto/rendereada es `2.5.3` (patrón `wizard-prompt-test-touchpoints`). Cambiarla sin actualizar el test rompe el test conscientemente.
3. **Checklist pre-bump** (documento en el repo, p.ej. `docs/qmd-upgrade-checklist.md` o dentro de este contrato): antes de subir la versión, verificar contra el `package.json` de la versión destino:
   - los `tree-sitter-*` siguen siendo `optionalDependencies` (si pasaron a duros, la estrategia de trustedDependencies debe re-diseñarse);
   - `web-tree-sitter` sigue presente y el `.wasm` viaja en el tarball;
   - `node-llama-cpp` sigue siendo la ruta de embed y su receta de build (cmake/GGML/bigstack) sigue aplicando;
   - existe prebuilt musl-arm64 O el mecanismo A vigente sigue cubriendo el build.

## Invariantes verificables (bats host)

- El test de versión falla si `vault.qmd.version` != la cadena fijada (sin actualizar el test).
- El checklist existe y está referenciado desde CHANGELOG/quickstart.

## Nota

`2.6.x` ya viró a deps duras; hoy no existe `2.6.x` estable que además tenga prebuilt musl, así que el guardrail es prevención, no un fix presente. El pin se mantiene en `2.5.3`.
