# Implementation Plan: Log de stderr del canal de Telegram acotado y sin bucle de EPIPE

**Branch**: `049-telegram-stderr-log-bound` | **Date**: 2026-11-23 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/049-telegram-stderr-log-bound/spec.md`

## Summary

El grupo de parches que captura el stderr del plugin de Telegram pasa de v1 a v2.

- **Corte del bucle.** v2 escucha el evento `error` de `process.stderr`. Ante un destino cerrado (EPIPE y equivalentes), deja de reenviar a stderr y escribe una sola línea de aviso. Es la única vía que ve el error en bun: la escritura no lanza, el error llega asíncrono (research M1). Con ese listener, el error no se convierte en `uncaughtException`, así que el manejador del vendor no corre y el bucle no arranca (M2 lo reproduce con v1, M3 lo corta con el prototipo).
- **Tope de disco.** Antes de cada anexo, v2 rota el log al umbral de 10 MiB, ajustable con `TELEGRAM_STDERR_LOG_MAX_BYTES`. Guarda dos generaciones anteriores, y de un archivo heredado enorme conserva solo su tramo final. Costo medido: despreciable (M4, M5).
- **Upgrade.** El patcher sube v1 a v2 con una gemela congelada y un fixture dorado del estado actual de la flota.
- **Doctor.** `agentctl doctor` muestra el tamaño del log y avisa sobre 100 MiB.

Nada cambia en el formato de lo que se registra, en la ruta, en los hooks 028 y 031 ni en los otros seis grupos de parches.

## Technical Context

**Language/Version**: TypeScript ejecutado por bun 1.3.14 en la imagen (el texto lo inserta el patcher), Python 3 (patcher, horneado), bash 3.2 a 5.3 (`agentctl`, pruebas).

**Primary Dependencies**: ninguna nueva. Solo `node:fs` y `node:path`, que v1 ya usa.

**Storage**: archivos del workspace: el log y sus generaciones `.1`, `.2` y `.1.tmp`.

**Testing**: bats-core. Para las suites de comportamiento, bun en el host (si falta, se saltan con motivo). DOCKER_E2E con el bun de la imagen.

**Target Platform**: contenedor Alpine 3.20 musl (amd64 y arm64) para el parche; host macOS o Linux para `agentctl`.

**Project Type**: CLI y launcher en bash, con un parche de código del vendor.

**Performance Goals**: el costo por escritura no debe crecer de forma medible frente a v1. Medido: 2.810 ms contra 2.888 ms en 100.000 escrituras.

**Constraints**:

- fail-silent en toda falla de disco;
- un stderr sano se comporta byte por byte como v1;
- la ruta y el formato no cambian;
- a lo sumo una línea de aviso de corte por proceso.

**Scale/Scope**: tres agentes docker (linus, donna y cbum). Un archivo de producto horneado (el patcher), uno de producto en el host (`scripts/agentctl`), un fixture dorado, dos suites nuevas y una extendida.

## Constitution Check

*GATE: pasa antes de la Fase 0 y se revisa de nuevo después de la Fase 1.*

| Principio | Evaluación | Estado |
| --- | --- | --- |
| I. Single Source of Truth | No hay archivo derivado nuevo ni campo de `agent.yml`. La perilla `TELEGRAM_STDERR_LOG_MAX_BYTES` vive en el `.env`, que no es derivado y sobrevive a `--regenerate`, igual que `TELEGRAM_TYPING_MAX_MS` (research D3). | PASS |
| II. Least-Privilege Container | Sin capacidades, montajes ni sockets nuevos. El parche corre como `agent` dentro del proceso del canal; el doctor lee un tamaño desde el host, sin `docker exec`. | PASS |
| III. Test-First, Host-Runnable | ROJO antes del VERDE en H1, que reproduce el bucle con v1, y en S1 a S9 y A1 a A5. La suite por defecto no necesita Docker. Las pruebas que necesitan bun se saltan con motivo si falta. El DOCKER_E2E va detrás de `DOCKER_E2E=1`. `shellcheck -S error` sobre `agentctl`. | PASS |
| IV. Idempotent, Fail-Silent | Idempotencia por marcador (v1 y v2). Ante un ancla o una gemela que no coincide, WARN y el grupo intacto. La rotación y el anexo tragan todo error y la escritura original ocurre igual. | PASS |
| V. Workspace-Is-the-Agent | El log vive en `scripts/heartbeat/logs/` del workspace, no en `.state/`. Ninguna unidad de respaldo lo incluye, y esta feature no cambia eso. Acotarlo reduce lo que arrastran las copias del workspace. | PASS |
| VI. Pinned Dependencies | Sin dependencias nuevas. El bun de la imagen sigue fijo en `BUN_VERSION=1.3.14`. | PASS |

**Re-check post-diseño (Fase 1)**: sin cambios, 6 de 6 PASS. Complexity Tracking queda vacío.

## Project Structure

### Documentation (this feature)

```text
specs/049-telegram-stderr-log-bound/
├── spec.md
├── plan.md                       # este archivo
├── research.md                   # M1-M6 medidos, D1-D9
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── stderr-hook-v2.md         # C1-C8, oráculos H1-H10 y H2a
│   ├── patcher-stderr-upgrade.md # P1-P5, oráculos S1-S9
│   └── doctor-stderr-size.md     # D1-D3, oráculos A1-A5
├── checklists/requirements.md
└── tasks.md                      # /speckit-tasks
```

### Source Code (repository root)

```text
docker/scripts/apply_telegram_typing_patch.py   # MARKER_STDERR v2, MARKER_STDERR_V1, STDERR_HOOK_V1 (gemela),
                                                # STDERR_HOOK v2, upgrade_stderr_v1_to_v2, apply_stderr, main()
scripts/agentctl                                # _file_size, línea del log en cmd_doctor
tests/fixtures/telegram-server-patched-v034.ts  # dorado: patcher de 9a0b93e sobre pristine (generado UNA vez)
tests/apply-telegram-patches.bats               # S1-S9 (y churn de oráculos que miran el marcador v1)
tests/telegram-stderr-hook.bats                 # nuevo: H1-H10 y H2a bajo bun
tests/agentctl-doctor-telegram-patches.bats     # A1-A5
tests/docker-e2e-stderr-log.bats                # nuevo, auto-sembrado, detrás de DOCKER_E2E=1
CHANGELOG.md, VERSION (0.34.0 -> 0.35.0), README.md (sección Telegram), CLAUDE.md (sección del parche)
```

**Structure Decision**: el cambio vive en el patcher horneado (código de imagen) y en `agentctl` (host). No toca `modules/`, `setup.sh` ni `scripts/lib/`, así que no hay render ni espejo que mantener.

## Riesgos y mitigaciones

| Riesgo | Mitigación |
| --- | --- |
| Un error de sintaxis en el TS del hook pone el canal en flap al arrancar | H1 a H10 ejecutan el texto exacto del bloque bajo bun; S9 parsea el archivo parcheado completo; el DOCKER_E2E lo carga con el bun de la imagen; el despliegue empieza por cbum como canario |
| Que bun 1.3.14 en musl informe EPIPE distinto que 1.3.12 en macOS | el DOCKER_E2E corre el caso del pipe cerrado en la imagen antes del PR |
| Una gemela v1 copiada mal, que dejaría a la flota sin el upgrade | el oráculo S4 compara la gemela contra un dorado generado por el patcher real, no contra sí misma |
| Barras invertidas transformadas por Python (034 D14) | oráculo S8 sobre la salida, más el reemplazo con `lambda` en `re.subn` |
| Un oráculo existente que mira el literal `stderr-capture patch v1` | se identifica al empezar (`grep -n 'stderr-capture' tests/`) y se actualiza junto con el bump, conservando su intención |
| El margen del brazo macOS de la CI (unos 15 min) | las suites nuevas son cortas y la de bun se salta en la CI; medirlo en la CI del PR |

## Evidencia de cierre (para tasks)

1. Línea base del host en los dos bash antes de tocar nada.
2. ROJO de H1 contra v1 y de S1 a S7 y A1 a A3 antes de implementar.
3. Gate completo en serie en bash 5.3.15 y 3.2.57, con 0 `not ok`, stderr vacío y `shellcheck` limpio.
4. Mutaciones dirigidas: quitar el listener, dejar el reenvío activo después del corte, aviso sin la guarda de una vez, rotación sin el caso del heredado, `.2` no reemplazada, la gemela v1 con un byte cambiado, la cascada fuera de `main()`, el umbral sin validar. Cada una tiene que hacer caer al menos un oráculo.
5. Revisión independiente de solo lectura antes del gate final.
6. DOCKER_E2E de la feature y de voz en arm64 local.
7. Commits, push y PR, con la CI verde. El merge es del operador.
8. Despliegue: cbum, después linus y donna. Doctor y `grep -c` de marcadores en cada uno.

## Complexity Tracking

Vacío: ninguna violación de la constitución.
