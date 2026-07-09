# Contract: Observabilidad del reindex qmd en docker (US4 — sólo observabilidad en 015)

**Interfaz**: `_qmd_reindex_locked` en `scripts/lib/qmd_index.sh` (líneas 252, 257:
`>/dev/null 2>&1`), espejado a docker.

## Alcance en 015

**En alcance ahora** (verificable sin ferrari, por host + DOCKER_E2E):
- Hacer **observable** el error real del reindex.

**Deferido al gate confirmatorio** (requiere ferrari alcanzable):
- El fix de causa raíz para que el wrapper construya/actualice el índice de forma
  equivalente a la invocación directa del binario (FR-008, SC-005).

## Comportamiento observable (en alcance)

| # | Dado | Cuando | Entonces |
|---|------|--------|----------|
| C1 | el reindex del wrapper falla (`update`/`embed`) | se inspecciona log/estado | el **stderr real de qmd** es visible (no oculto por `>/dev/null 2>&1`) |
| C2 | el reindex corre | se escribe el log | el **env efectivo** relevante (cache root, config dir, TMPDIR, colección) queda registrado para comparar contra la invocación manual que sí funciona |
| C3 | el stderr/env contiene un secreto | se escribe log/state | redactado (`sk-ant-*`, `*_TOKEN`, `*_KEY`, OAuth) — nunca en claro |

## Comportamiento observable (gate confirmatorio, deferido)

| # | Dado | Cuando | Entonces |
|---|------|--------|----------|
| G1 | contenedor docker con qmd on y espacio suficiente | corre el reindex programado | construye/actualiza el índice (`index.sqlite` presente) y reporta `ok`, equivalente al binario directo |

## Mecanismo (en alcance)

- `qmd_index.sh:252,257`: `>/dev/null 2>&1` → capturar stderr a un archivo bajo el
  `TMPDIR` host-backed (US3) y teejarlo al log del reindex; incluir `tail` del
  stderr real en el estado de error.
- Loguear (una vez por corrida) el env efectivo del wrapper: `pkg`, `coll`,
  `cache_root`, `QMD_CONFIG_DIR`/`XDG_CACHE_HOME`, `TMPDIR` — la comparación contra
  el env que funciona a mano (memoria: `XDG_CACHE_HOME=/home/agent/.cache
  QMD_CONFIG_DIR=/home/agent/.config/qmd`) es la pista de la causa raíz.

## Cobertura de test

- **Host (bats, test-first)**: stub `bunx` que escribe a stderr y falla → asserta que
  el log/estado del reindex captura ese stderr (C1) y que el env efectivo se registra
  (C2); asserta redacción (C3).
- **DOCKER_E2E**: el reindex con un `bunx` que falla deja el error visible en el log
  (no `/dev/null`). G1 (índice construido) NO se asserta aquí — es el gate de hardware.

## Invariantes de constitución

- Principle IV (refinado): el reindex sigue retornando 0 (fail-silent) pero el error
  queda **observable**, no tragado.
- Principle V: redacción obligatoria del env/stderr.
