# Quickstart: validar 039

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Cómo comprobar cada criterio de éxito. Los comandos se ejecutan desde la raíz del repositorio.

## 0. Requisitos

`bats` 1.x, `yq` v4 (mikefarah), `jq`, `shellcheck`, y `gh` autenticado con el scope `workflow` (el token de `rodrigo-hinojosa` ya lo tiene). Para forzar bash 3.2 en macOS se antepone `/bin` al `PATH`. Docker solo hace falta para la sección 6 y la línea base local opcional de la sección 8.

## 1. Oráculo del host (SC-003)

```bash
bats tests/ci-workflows.bats                      # bash 5.x (el que resuelva el PATH)
PATH=/bin:$PATH bats tests/ci-workflows.bats      # bash 3.2.57 en macOS
```

Esperado: **14 de 14** (O1 a O5, S1 a S6 y R1 a R3 de los contratos [workflow-step-oracle.md](contracts/workflow-step-oracle.md) y [suite-step.md](contracts/suite-step.md)), en ambas versiones de bash. El autotest O2 debe pasar **porque** el paso congelado con el defecto da 141; si el arnés dejara de poder fallar, ese test se pone rojo. R3 sostiene SC-005 (todos los `run:` auditados, sin consumidores que cierren antes) junto con la tabla de la auditoría en [research.md](research.md), D5.

## 2. Mutaciones (SC-003, SC-007)

Cada una se aplica sobre una copia del workflow, se corre el oráculo y se restaura. El procedimiento seguro:

```bash
F=.github/workflows/docker-e2e.yml
cp "$F" /tmp/docker-e2e.yml.bak
# ... aplicar UNA mutación de la tabla (con python3 o un editor) ...
bats tests/ci-workflows.bats; echo "rc=$?"
cp /tmp/docker-e2e.yml.bak "$F"                   # restaurar siempre
```

| Mutación | Debe ponerse rojo |
|----------|-------------------|
| Reintroducir `docker info \| head -10` en el paso de verificación | O3 (141) y R3 |
| Reemplazar la línea de `docker info --format` por una que silencie el fallo (`\|\| true`) | O4 |
| Quitar `server=` o `arch=` de la plantilla de `--format` (una a la vez) | O3 |
| Quitar la guarda `executed -eq 0` del paso de la suite | S1 y S2 |
| Quitar `DOCKER_E2E` del `env:` del paso de la suite | S6 |
| Cambiar `exit "$rc"` por `exit 0` | S4 y S5 |
| Estrechar el glob del paso de la suite a `tests/docker-e2e-smoke.bats`, ensancharlo a `tests/*.bats` o quitar `--tap` | S3 |
| Agregar un `\| head -1` en cualquier paso de `test.yml` | R3 |

Cada mutación y el test que la cazó se registran en las Notes de `tasks.md`. Si alguna sobrevive, se endurece el oráculo antes de seguir (la lección de 033 y 034).

## 3. Gates del repositorio

```bash
bats tests/                                       # suite completa, bash 5.x
PATH=/bin:$PATH bats tests/                       # suite completa, bash 3.2.57 (secuencial, nunca a la vez)
{
  find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' -not -path './scripts/vendor/*' -not -path './tests/*'
  printf './scripts/agentctl\n./docker/scripts/heartbeatctl\n'
} | xargs shellcheck -S error -e SC1090,SC1091    # comando exacto del job de CI
```

Esperado: línea base de `main` más los tests nuevos, 0 `not ok` en ambas versiones, y `shellcheck` con rc 0 y sin salida.

## 4. Alcance acotado (SC-008)

```bash
git diff --stat origin/main..HEAD -- docker scripts modules setup.sh      # vacío
yq '.permissions' .github/workflows/docker-e2e.yml                        # contents: read, sin cambios
git show origin/main:VERSION; cat VERSION                                 # iguales: sin bump
git diff origin/main..HEAD -- .github/workflows > /tmp/wf.diff; grep -c 'secrets\.' /tmp/wf.diff    # 0: sin secretos nuevos
```

## 5. Corrida real (SC-001, SC-004, SC-006, SC-009)

Requiere empujar la rama (confirmación del operador; por HTTPS con el helper de `gh`, porque SSH falla por cuenta equivocada) y que el workflow modificado esté en esa rama.

```bash
gh workflow run docker-e2e.yml --ref 039-fix-nightly-e2e-sigpipe
sleep 5; RID=$(gh run list --workflow docker-e2e.yml --branch 039-fix-nightly-e2e-sigpipe --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RID" --exit-status --interval 30
gh run view "$RID" --log | grep -E 'e2e summary|^not ok|# skip|::error::'
gh run view "$RID" --json jobs --jq '.jobs[0] | "\(.conclusion) en \(((.completedAt|fromdateiso8601)-(.startedAt|fromdateiso8601))/60|floor) min"'
```

Comprobar:
- **SC-001**: el paso de verificación termina en verde y el paso de la suite arranca (el job ya no muere a los pocos segundos).
- **SC-004 y SC-006**: la línea `e2e summary:` cuadra con los 48 tests; cada rojo se registra en las Notes de `tasks.md` con el formato de [e2e-classification.md](contracts/e2e-classification.md).
- **SC-009**: la corrida termina dentro del tope vigente. Si `conclusion` es `timed_out`, se sube `timeout-minutes`, se vuelve a despachar y se registra la duración medida (FR-016).

## 6. E1 y E3 de 031 (requiere Docker)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-askq-guard.bats      # esperado: 3 de 3
```

Sin Docker local, la demostración sale de CI: el rojo es la corrida de la sección 5 con E1 y E3 todavía sin corregir y el verde es la re-despachada tras corregirlos. Antes de corregir, la misma orden da **1 de 3** (E1 y E3 en rojo): ese es el rojo previo que hace falta registrar. Tras la corrección debe dar 3 de 3 en local y en la corrida real de la sección 5.

## 7. Después del merge (SC-002)

```bash
gh run list --workflow docker-e2e.yml --limit 3 --json databaseId,conclusion,createdAt
for id in <los 3 ids>; do gh run view "$id" --log | grep -c 'exit code 141'; done      # 0 en cada una
```

Esperado: las tres noches siguientes al merge no abortan en el paso de verificación. Un rojo por otra causa (un e2e real) es válido y debe estar en el registro de la sección 5.

## 8. Línea base local, opcional (compuerta)

Solo con el visto bueno del operador (Docker Desktop está apagado y el Mac cargado). Sirve para comparar arm64 contra amd64 y atribuir rojos a la arquitectura:

```bash
DOCKER_E2E=1 bats --tap --timing tests/docker-e2e-*.bats > /tmp/e2e-local.tap 2>&1
grep -c -E '^ok .* # skip' /tmp/e2e-local.tap; grep -E '^not ok' /tmp/e2e-local.tap
```

## 9. Documentación

`CHANGELOG.md` con una entrada (CI y tests, sin cambio de runtime) y sin bump de `VERSION`. `CLAUDE.md` con la entrada de 039 actualizada a mano y una línea de gotcha sobre el consumidor que cierra el pipe en un `run:` de workflow.
