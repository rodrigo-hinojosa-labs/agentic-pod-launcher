# Contrato: cambio en `.github/workflows/docker-e2e.yml`

Qué agrega 041 al job `e2e` y qué no puede tocar (FR-001, FR-007, FR-008, FR-014, FR-018, FR-019; research D1, D6, D7 y D15).

## 1. Lo que no cambia

- El texto `run:` de `Verify deps + docker` y de `Run docker-e2e suite`. Su sha256, tal como lo extrae `yq`, debe seguir siendo el de research M13; lo vigilan el oráculo W2 y W3 y, por comportamiento, los O1 a O5 y S1 a S5 de 039.
- `permissions: contents: read`, los disparadores (`schedule` y `workflow_dispatch`), `concurrency`, el nombre del job, `runs-on` y `timeout-minutes: 30`. El tope solo cambia si una corrida real deja menos de 5 minutos de margen (FR-013), y ese cambio va en un commit aparte.
- Ningún `secrets.`. Ningún paso define las costuras del script (contracts/fetch-models-script.md §3).
- Ni `Fetch the qmd models` ni `Run docker-e2e suite` llevan `continue-on-error`: con él, una obtención que falla siempre, o una suite roja, dejarían la noche en verde (FR-008, research D7). Lo vigilan W1 y W5.

## 2. Forma sobre `main` (sin 040)

```yaml
      - name: Verify deps + docker
        id: verify_deps                      # NUEVO: lo lee el `if:` de la suite
        run: |
          ...                                  # sin cambios (sha256 de research M13)

      # 041: the qmd models the embed phase uses (embeddings + query expansion,
      # ~1.6 GB) are fetched and verified HERE, in a step of their own: a
      # HuggingFace or network failure must read as infrastructure (this step),
      # never as a regression of the embed. Bounded retries; a persistent
      # failure turns the night red here and the suite still runs, with the
      # embed phase skipped (see the `if:` of the suite step).
      - name: Fetch the qmd models
        id: fetch_models
        env:
          # A recorded open defect switches the embed phase off (FR-014):
          # '#<issue> <short reason>'. Empty means the phase runs.
          QMD_EMBED_DEFECT: ''
        run: .github/scripts/fetch-qmd-models.sh

      # (comentario existente de 039, sin cambios)
      # 041: !cancelled() lets the suite run when only the model fetch failed.
      - name: Run docker-e2e suite
        if: ${{ !cancelled() && steps.verify_deps.outcome == 'success' }}
        env:
          DOCKER_E2E: '1'
          QMD_EMBED_E2E: '1'                 # NUEVO: la puerta de la fase del embed
        run: |
          ...                                  # sin cambios (sha256 de research M13)
```

Semántica:

| Situación | `fetch_models` | Suite | Fase del embed | Conclusión del job |
| --- | --- | --- | --- | --- |
| todo sano | `success` | corre | se ejecuta | según los tests |
| HuggingFace caído | `failure` | corre (`!cancelled()`) | `skip`, motivo «no se pudieron obtener…» | `failure`, y el aviso de 040 nombra `fetch_models` |
| defecto abierto | `success` | corre | `skip`, motivo «apagada por defecto abierto: #N…» | según el resto de los tests |
| Docker caído | se salta (`success()` implícito) | se salta (`verify_deps` no fue `success`) | no corre | `failure` en `verify_deps` |
| tiempo agotado o cancelación | se cancela | se salta | no corre | según la plataforma (medición E7 de 040) |

## 3. Forma combinada si 041 rebasa sobre 040

- `Fetch the qmd models` gana `if: ${{ !inputs.alert_trial }}`: los ensayos del aviso no bajan 1,6 GB.
- El `if:` de la suite pasa a `${{ !inputs.alert_trial && !cancelled() && steps.verify_deps.outcome == 'success' }}`, y conserva `id: run_suite`.
- Enmiendas explícitas en `tests/nightly-alert.bats` de 040, declaradas en las Notes de `tasks.md`:
  - `:1419`: la lista de ids pasa a `checkout,install_yq,install_bats,verify_deps,fetch_models,run_suite,collect`;
  - `:1952`: el `if:` esperado pasa a ser el combinado.
- W1 (el `if:` de `fetch_models`) y W5 (el de la suite) de 041 se ajustan a la forma combinada en el mismo commit.
- Si FR-013 obliga a subir el tope, el literal `30` de la expresión `timeout-minutes` de 040 (`:1956`) cambia en el mismo commit que su test.
- Conflictos previsibles del rebase: `.specify/feature.json`, las dos entradas de `CHANGELOG.md` en `[Unreleased]`, el bloque SPECKIT de `CLAUDE.md` y el `id: verify_deps` que agregan las dos ramas. Se resuelven sin perder ninguna entrada, y `VERSION` se compara a mano con `origin/main`.

Si 040 rebasa sobre 041, las mismas enmiendas van en la dirección inversa. Como ese rebase ocurre en la rama de 040, se dejan anotadas en la memoria del proyecto y se le avisan al operador para las Notes de 040 cuando 041 mergee primero (tasks T039).
