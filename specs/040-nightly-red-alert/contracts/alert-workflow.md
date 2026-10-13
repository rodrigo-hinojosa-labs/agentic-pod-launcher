# Contrato AW: cableado del workflow `docker-e2e.yml`

Qué cambia en `.github/workflows/docker-e2e.yml` y qué no. Es el contrato que fijan los tests estructurales de `tests/nightly-alert.bats` (AW-1 a AW-9) y que `contracts/alert-script.md` (AS) completa por el lado del script.

## 1. Disparadores y entradas

El `schedule` (`0 5 * * *`) no cambia. `workflow_dispatch` gana dos entradas que solo sirven para el ensayo (research R6):

| Entrada | Tipo | Por defecto | Efecto |
|---|---|---|---|
| `alert_trial` | boolean | `false` | Salta la suite, simula el resultado y publica en el aviso de ensayo |
| `trial_outcome` | choice (`red`, `green`, `timeout`) | `red` | Resultado simulado; `timeout` además baja el tope del job a 1 minuto |

Una corrida manual con los valores por defecto se comporta como hoy: corre la suite y no abre, actualiza ni cierra ningún aviso (FR-011).

## 2. Job `e2e` (la suite)

- **Se conserva**: el nombre del job, `runs-on`, el texto de los pasos `Checkout`, `Install yq v4 (mikefarah)`, `Install bats-core`, `Verify deps + docker` y `Run docker-e2e suite` (incluido `env: DOCKER_E2E: '1'`), y `permissions: contents: read` heredado del workflow. Los tests O1 a O5 y S1 a S6 de 039 siguen valiendo sin cambios.
- **Cambia**:
  1. Cada paso gana un `id` legible, que es lo que `collect` reporta como "paso que falló": `checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`, `simulate`, `collect`.
  2. `run_suite` gana `if: ${{ !inputs.alert_trial }}`.
  3. Paso nuevo `simulate` (`if: ${{ inputs.alert_trial }}`, entorno `TRIAL_OUTCOME: ${{ inputs.trial_outcome }}`): `run: .github/scripts/nightly-alert.sh simulate "$TRIAL_OUTCOME"`.
  4. Paso nuevo `collect`, el último (`if: ${{ always() }}`, `continue-on-error: true`, entorno `STEPS_JSON: ${{ toJSON(steps) }}`): `run: .github/scripts/nightly-alert.sh collect`. El script sale siempre con 0; el `continue-on-error` cubre lo único que el script no puede: que ni siquiera arranque (un bit ejecutable perdido en el commit, un `checkout` que falló). Sin él, esa falla volvería roja una noche verde, que es justo lo que FR-009 prohíbe (hallazgo de la implementación, 13-10-2026; no estaba en el contrato original).
  5. `outputs` del job: `failed_step`, `summary` y `failed_tests`, cada uno `${{ steps.collect.outputs.<nombre> }}`.
  6. `timeout-minutes: ${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}`: vale 30 en las corridas programadas y en las manuales normales (`inputs` no define esas claves) y 1 solo en el ensayo de tiempo agotado.

## 3. Job `alert` (el aviso)

```yaml
alert:
  name: nightly alert
  needs: e2e
  if: ${{ always() && (github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.alert_trial)) }}
  runs-on: ubuntu-latest
  timeout-minutes: 5
  permissions:
    contents: read
    issues: write
  steps:
    - name: Checkout
      continue-on-error: true
      uses: actions/checkout@v6
    - name: Publish the nightly notice
      continue-on-error: true
      timeout-minutes: 3
      env:
        GH_TOKEN: ${{ github.token }}
        GH_REPO: ${{ github.repository }}
        EVENT: ${{ github.event_name }}
        TRIAL: ${{ inputs.alert_trial }}
        RUN_RESULT: ${{ needs.e2e.result }}
        FAILED_STEP: ${{ needs.e2e.outputs.failed_step }}
        SUMMARY: ${{ needs.e2e.outputs.summary }}
        FAILED_TESTS: ${{ needs.e2e.outputs.failed_tests }}
        RUN_ID: ${{ github.run_id }}
        RUN_ATTEMPT: ${{ github.run_attempt }}
        RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        ASSIGNEE: rodrigo-hinojosa
      run: .github/scripts/nightly-alert.sh notify
```

- **Ningún paso de este job puede volver roja una noche verde** (FR-009; hallazgo de la revisión independiente del 13-10-2026): el `Checkout` lleva `continue-on-error: true` (un fallo transitorio de GitHub), y el paso que publica lleva `continue-on-error: true` y un tope propio de 3 minutos, menor que los 5 del job, para que un `gh` colgado termine como un **paso** fallido (que se absorbe) y no como un **job** que agotó su tiempo (que pondría roja la corrida). Si el `Checkout` falla, el paso siguiente no encuentra el script, también falla y también se absorbe: la noche conserva su color y el aviso se pierde con un icono rojo dentro de un job verde.
- El job no arranca en una corrida manual normal (la expresión `if` lo excluye) y, además, el script rechaza ese caso por su cuenta (defensa en profundidad).
- `contents: read` está solo para el `checkout` que trae el script; el único permiso nuevo es `issues: write` (FR-013, research R1).
- Los valores externos llegan por **entorno**, nunca interpolados dentro de `run:` (evita la inyección de comandos por nombres de test o entradas).

## 4. Lo que no cambia

`permissions: contents: read` del workflow, el `concurrency` (`group: docker-e2e`, `cancel-in-progress: false`), el cron, `yq` v4.44.3 y `bats-core` v1.11.0, y cero referencias a `secrets.` (SC-007).

## 5. Pruebas estructurales (AW)

| Id | Afirma |
|---|---|
| AW-1 | El job `alert` existe, tiene `needs: e2e`, su `if` es exactamente la expresión de la sección 3 y `timeout-minutes` vale 5 |
| AW-2 | `permissions` del job `alert` es exactamente `{contents: read, issues: write}` |
| AW-3 | El nivel del workflow y el job `e2e` no tienen `issues` en `permissions` (solo `contents: read`) |
| AW-4 | El paso `notify` lleva `continue-on-error: true` y `timeout-minutes: 3`; el `Checkout` del job `alert` lleva `continue-on-error: true`; su `run` llama al script con `notify` sin `${{ }}` dentro; y cada una de las 12 variables de su entorno (y ninguna más) vale exactamente la expresión de la sección 3 |
| AW-5 | No hay `secrets.` en el workflow |
| AW-6 | Las entradas `alert_trial` y `trial_outcome` existen con tipo, valores y por defecto de la sección 1 |
| AW-7 | `run_suite` y `simulate` tienen las condiciones de la sección 2; `timeout-minutes` del job `e2e` es el literal de la sección 2, punto 6 |
| AW-8 | `collect` es el último paso, con `if: ${{ always() }}` y `continue-on-error: true`; las tres salidas del job apuntan a `steps.collect.outputs.*`; todos los pasos tienen `id` |
| AW-9 | El script referenciado existe, es ejecutable y empieza con `#!/usr/bin/env bash` |

## 6. Limitaciones declaradas

- La rama `schedule` de la condición del job `alert` solo la ejercen el oráculo del host y la primera noche roja real; las corridas programadas solo ocurren sobre la rama por defecto.
- Un nightly que no llega a arrancar (cola atascada, workflow deshabilitado por inactividad) no puede avisarse desde dentro del propio job (FR-018).
- Si la plataforma reportara un tiempo agotado como `cancelled`, la regla por defecto lo ignoraría; se mide con `trial_outcome=timeout` antes del merge (research R7).
