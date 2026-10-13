# Quickstart: validar el aviso del nightly

Guía de validación de la feature: qué correr, en qué orden y qué se espera. No contiene el código del script ni de los tests (están en `tasks.md` y en la implementación); los contratos están en `contracts/` y las entidades en `data-model.md`. Lo marcado **[COMPUERTA]** necesita una autorización explícita del operador antes de ejecutarse (push de la rama, `workflow_dispatch`, PR).

## 1. Prerrequisitos

- Rama `040-nightly-red-alert` desde `main`@`13cafc3`; `VERSION` 0.28.0 (se confirma contra `origin/main` a mano, sin bump).
- Herramientas del host: `bats-core`, `yq` v4, `jq`, `perl`, `shellcheck`, `gh` (para las corridas reales).
- Línea base del gate: 1817 ok y 0 not ok en bash 5.x y en 3.2.57 (la CI de `main` sobre `13cafc3` está en verde).
- Para las corridas reales: token de `gh` con el scope `workflow` (lo tiene), push por HTTPS con el helper de `gh`, y los logs bajados con `--allow-escape-sequences`.

## 2. Validación local (sin Docker, sin red)

```bash
# 2.1 El oráculo nuevo, en ROJO antes de existir el script y el workflow editado
bats tests/nightly-alert.bats                      # esperado al empezar: todos not ok

# 2.2 Tras implementar: el oráculo nuevo en verde, en los dos bash, secuencial
bats tests/nightly-alert.bats                      # bash 5.x
PATH=/bin:$PATH bats tests/nightly-alert.bats      # bash 3.2.57
perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/nightly-alert.bats   # el proceso de bats con SIGPIPE ignorada, como en el runner (los casos de comportamiento fijan su propia disposición con SIGPIPE_MODE; esta pasada cubre el resto del archivo)

# 2.3 El gate completo, un bash tras otro (nunca a la vez)
bats tests/                                        # esperado: 1849 ok, 0 not ok (1817 + 32)
PATH=/bin:$PATH bats tests/                        # esperado: lo mismo

# 2.4 shellcheck con el comando exacto del job de CI (incluye .github/scripts)
{ find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' -not -path './scripts/vendor/*' -not -path './tests/*'
  printf './scripts/agentctl\n./docker/scripts/heartbeatctl\n'; } | xargs shellcheck -S error -e SC1090,SC1091

# 2.5 Alcance (FR-017, SC-007)
git diff origin/main -- docker scripts modules setup.sh | wc -l      # esperado: 0
grep -c 'secrets\.' .github/workflows/docker-e2e.yml                 # esperado: 0
```

Los tests de 039 (`tests/ci-workflows.bats`, 14) deben seguir verdes sin editarse: el paso `Run docker-e2e suite` no cambia de texto.

## 3. Mutaciones (SC-005)

Son 20 mutaciones (M2, M12 y M19 con dos variantes cada una). Cada fila se aplica sobre una copia del script o del workflow, apuntando `ALERT_SCRIPT` o `ALERT_WORKFLOW` a ella (los tests no leen otra ruta), el test cazador debe caer y la copia se descarta. Una mutación que sobrevive obliga a endurecer el oráculo antes de seguir.

| Id | Mutación | Cae |
|---|---|---|
| M1 | quitar `always()` del `if` del job `alert` | N23 |
| M2 | (a) agregar `issues: write` al nivel del workflow; (b) agregar una referencia a `secrets.TOKEN` | N25; N27 |
| M3 | quitar `continue-on-error: true` del paso `notify` | N26 |
| M4 | `notify` sale con el código del último `gh` fallido | N12 |
| M5 | crear el aviso sin `--assignee` | N01 |
| M6 | tratar `cancelled` como rojo | N07 |
| M7 | dejar que una corrida manual normal abra el aviso | N08 |
| M8 | en un rojo repetido crear un segundo issue | N03, N04 |
| M9 | en verde no cerrar el aviso | N05 |
| M10 | en verde sin aviso previo crear o comentar | N06 |
| M11 | cierre manual: crear uno nuevo en vez de reabrir | N09 |
| M12 | (a) cierre por verde sin escribir `state=resolved`; (b) un verde sobre un issue cerrado a mano que no reescribe el marcador | N10 |
| M13 | quitar la cota de 20 nombres | N14 |
| M14 | no sanear comillas invertidas ni `~~~` | N15 |
| M15 | `collect` cuenta `executed` igual que `total` | N19 |
| M16 | quitar la guarda de idempotencia (`run=<id>`) | N13 |
| M17 | el ensayo usa la etiqueta del aviso real | N11 |
| M18 | `run_suite` pierde su `if` de ensayo | N29 |
| M19 | (a) introducir `\| head -1` en el script; (b) introducir un pipe que lee una línea y cierra, con una carga de más de 64 KiB (solo se nota si cambia la disposición de SIGPIPE) | N22; N17 |
| M20 | cambiar el literal de `timeout-minutes` | N29 |

## 4. Evidencia real **[COMPUERTA]**

Se necesita: la rama empujada y las corridas lanzadas con `gh workflow run docker-e2e.yml --ref 040-nightly-red-alert -f alert_trial=true -f trial_outcome=<red|green|timeout>`. Cada corrida de ensayo dura cerca de un minuto. Tras cada una se anota: id de la corrida, número del issue de ensayo, conclusión de cada job, y la anotación `::notice::nightly-alert:` del log (con `RUN_RESULT`).

| Paso | Lanzamiento | Esperado | Cubre |
|---|---|---|---|
| E1 | ensayo `red` | issue `[ensayo] docker-e2e nightly en rojo` creado, asignado al mantenedor, con la etiqueta de ensayo y `total=1`; el job `e2e` en rojo, el job `alert` en verde; **el mantenedor confirma que le llegó la notificación sin abrir Issues ni Actions** | FR-001, FR-002, FR-019, SC-001, SC-009; mediciones M8 y M9 de research |
| E2 | ensayo `red` otra vez | el mismo issue, `total=2`, un comentario nuevo y ningún issue nuevo | FR-005, SC-002 |
| E3 | el mantenedor cierra a mano el issue de ensayo y se lanza ensayo `red` | el mismo issue se reabre con comentario, `total=3` | FR-008 |
| E4 | ensayo `green` | marcador `resolved`, comentario de cierre y issue cerrado; corrida completa en verde | FR-006, SC-003 |
| E5 | ensayo `red` | un issue **nuevo** (otra racha); el anterior sigue cerrado | FR-008 |
| E6 | ensayo `green` | el issue nuevo se cierra | FR-006 |
| E7 | ensayo `timeout` | se registra con qué valor entrega la plataforma `needs.e2e.result` y qué hace el script; decide la regla de research R7 | FR-001, FR-007; medición M7 de research |
| E8 | corrida manual **normal** (sin ensayo; corre los 15 minutos de la suite) | 48 de 48 en verde, el job `alert` omitido, ningún cambio en los issues y las salidas de `collect` presentes; duración dentro del +1 minuto | FR-011, SC-008, regresión de 039 |

**Regla de la evidencia**: la evidencia vale para el texto que se mergea. Se anota el commit con el que se lanzó E1; si el script o el workflow cambian después, se repiten E1 a E6 o se justifica por escrito que el cambio no toca esos caminos, y antes del PR `git diff <commit de E1>..HEAD -- .github/workflows/docker-e2e.yml .github/scripts/nightly-alert.sh` debe salir vacío o justificado.

**Limpieza al terminar**: cerrar cualquier issue de ensayo abierto. Los issues de ensayo quedan cerrados como historial y la etiqueta `nightly-red-trial` se conserva.

Si E1 muestra que la política de la organización impide crear issues o etiquetas con el token del workflow (M9 de research), o que la notificación no llega (M8), se detiene la secuencia y se consulta al operador: cualquiera de las dos cambia el diseño (permiso de la organización, o volver a `/speckit-clarify`).

## 5. Criterios de éxito: cómo se verifica cada uno

| SC | Cómo |
|---|---|
| SC-001 | E1: el aviso existe al terminar la corrida y contiene los cuatro elementos |
| SC-002 | N04 en el host y E2 en real |
| SC-003 | N05 en el host y E4 en real |
| SC-004 | N12 (cada llamada a `gh` fallando por turnos) |
| SC-005 | la tabla de la sección 3, 0 mutaciones sobrevivientes en ambos bash |
| SC-006 | los ids de E1 a E4 registrados en las Notes de `tasks.md` |
| SC-007 | los dos comandos de la sección 2.5 y los tests N23 a N31 |
| SC-008 | E8: duración de la suite menos de 1 minuto sobre los ~15 medidos |
| SC-009 | la confirmación humana de E1 |

## 6. Documentación y cierre

- `CHANGELOG.md`: entrada (sin cambio de `VERSION`) que diga qué cubre el aviso y qué no cubre (FR-018): no detecta un nightly que no llega a arrancar, y la rama `schedule` de la condición solo la ejercen el oráculo y la primera noche roja real.
- `CLAUDE.md`: entrada de 040 en el bloque SPECKIT y, si algo nuevo se aprendió, una viñeta en "Common gotchas".
- Commit y push de la rama, las corridas de ensayo, el PR y el merge piden la confirmación del operador, cada uno.
