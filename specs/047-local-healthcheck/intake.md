# Entrada y evidencia inicial de 047

Propósito: dejar trazable la elección del issue, las fuentes leídas y la línea base antes de implementar. Este documento registra la fase specify; no es un plan de implementación ni declara el defecto corregido.

## Estado al 17-11-2026

| Dato | Verificado |
| --- | --- |
| Issue seleccionado | [#111](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/issues/111), abierto, sin comentarios al consultar |
| Rama | `047-local-healthcheck` |
| Worktree | `/Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher/.claude/worktrees/047-local-healthcheck` |
| Base | `origin/main` y `HEAD` inicial `3afae74bd6335f7ebd8f6b4ff613b4e876f2db08` |
| VERSION / constitución de partida | 0.32.0 / 1.1.0, sin cambios en esta fase |
| Alcance de la invocación | Especificación de #111, sin encadenar plan, tasks o implement |

El usuario pidió revisar los issues del repositorio y corregirlos uno a la vez con Spec Kit. Se encontraron cuatro abiertos: #111, #117, #120 y #131. La recomendación inicial fue #120; el operador eligió explícitamente #111 para iniciar 047. No se abren features para los demás ni se publican los borradores de hallazgos de 046.

La copia principal queda en main y conserva su AGENTS.md sin rastrear. El worktree 046 y su Registro posterior al merge se preservan. La nueva carpeta de trabajo está bajo `.claude/worktrees`, que Git confirma ignorada; no se modificó .gitignore ni se hizo commit para crearla.

## Fuentes y hallazgos

| Fuente actual en la base | Lectura verificada | Límite de la evidencia |
| --- | --- | --- |
| [Healthcheck](../../modules/local-healthcheck.sh.tpl), líneas 25 y 102-118 | La ventana es de 24 h y se consulta el primer expiresAt encontrado recursivamente. El valor vencido produce login expired. | Esto confirma el criterio actual; no prueba cuánto duran los tokens de todas las versiones del proveedor. |
| Mismo archivo, líneas 59-62 | Solo se buscan los patrones API Error: 401 y Please run /login en una ventana de diez minutos. | Hay que distinguir mensajes terminales de mensajes sobre acceso renovable; no asumir que toda falla de refresh es irrecuperable. |
| Mismo archivo, líneas 70-81 | La conexión se busca por el MainPID, no por todos los procesos de la unidad. | El issue documenta conexiones en un hijo. No se consultó un host vivo en esta fase. |
| Mismo archivo, líneas 121-134 | Cada ejecución DEGRADED con configuración de avisos intenta enviar, sin registro de episodios. | La cantidad de mensajes realmente recibidos por el agente histórico no está medida en #111. |
| [Timer](../../modules/local-healthcheck.timer.tpl), líneas 5-6 | Arranca tras 2 min y se vuelve a ejecutar aproximadamente cada 5 min. | No se cambió su frecuencia. |
| [Tests actuales](../../tests/local-healthcheck.bats) | 21 casos; los fixtures de salud usan principalmente un expiresAt muy lejano y una conexión del MainPID. | El verde actual no demuestra el comportamiento nuevo sobre renovación, familia de procesos o deduplicación. |
| [Contrato 021](../021-local-secret-delivery/contracts/secret-delivery.md) | Se preservan configuración de avisos y precedencia legacy, parseo sin source, secreto fuera de argv y ausencia de EnvironmentFile en la unidad del healthcheck. | No se lee configuración secreta real del operador. |
| [Spec 011](../011-local-standalone-mode/spec.md), US3 y FR-015 a FR-017 | Contrato previo de niveles de salud y degradación ante información faltante. | Es historia del contrato; 047 cambia el criterio de expiración y la política de avisos, sin reescribir 011. |

El issue #111 recoge 1.672 veredictos de un solo agente en octubre, de ellos 309 DEGRADED por login expired y 0 OK. Son mediciones históricas proporcionadas en el issue, no mediciones nuevas ni estado confirmado de la flota actual. El issue distingue lecturas, inferencias y propuestas. Ninguna propuesta allí listada se cuenta como implementación existente.

## Decisiones del operador

- **17-11-2026**: abordar #111 antes de los otros issues, una feature a la vez.
- **17-11-2026**: ventana de aviso de siete días, basada en la fecha de vencimiento de la renovación.
- **17-11-2026**: avisar al entrar en WARN por vencimiento, DEGRADED y recuperación, sin repetir cada tick.
- **17-11-2026**: reintentar el aviso pendiente cada 30 minutos hasta éxito; nunca repetir un envío confirmado. El intervalo se evalúa en el healthcheck periódico, sin añadir otro temporizador.

Las distinciones entre dato desconocido y login perdido, advertencia general y aviso de vencimiento, recuperación completa y parcial, y entrega pendiente y confirmada son precisiones propuestas para cumplir esos objetivos. No implican reparación automática del agente ni lectura de secretos desde el asistente.

## Línea base focal, sin mutar

Se ejecutó `tests/local-healthcheck.bats` en el worktree nuevo, antes de escribir el comportamiento o sus pruebas. BATS y su PATH se fijaron a cada bash; ambas ejecuciones fueron secuenciales.

| Bash efectivo | Plan / resultados | Fallas | Saltadas | stderr | Duración |
| --- | --- | --- | --- | --- | --- |
| 5.3.15 | 21 / 21 ok | 0 | 0 | 0 bytes | 31,307 s |
| 3.2.57 | 21 / 21 ok | 0 | 0 | 0 bytes | 33,827 s |

Evidencia local en `/Users/rodrigo-hinojosa/.cache/agentic-047/specify-5qrn9h3j/`: `baseline.json`, `bash5.tap`, `bash5.err`, `bash32.tap`, `bash32.err` e `issue-111.json`. El snapshot del issue conserva el texto consultado; no incluye credenciales reales. No se corrió la suite completa de 2104 durante specify: esta fase no modifica comportamiento. El plan debe definir los gates y la reproducción test-first antes del arreglo.

## Estado de Spec Kit

- Numeración secuencial: se comprobaron las carpetas existentes, cuyo máximo era 046; se creó solo 047.
- `specify preset resolve spec-template` resolvió la plantilla core del propio worktree, copiada como punto de partida.
- `.specify/feature.json` apunta a `specs/047-local-healthcheck` solo en este worktree. La copia principal y el worktree 046 conservan sus selectores.
- `.specify/extensions.yml` declara `installed: []` y `hooks: {}`; no hay hooks before_specify ni after_specify que ejecutar.
- El spec y su checklist son los entregables de esta fase. No se crean plan.md ni tasks.md anticipadamente.
- Sin cambios de runtime, tests, VERSION, constitución o agentes; sin SSH, Docker, llamadas al modelo, commit, push o cambios en GitHub.

## Cierre de specify (17-11-2026)

Las tres decisiones sobre vencimiento, tipos de aviso y reintentos están respondidas e incorporadas en el spec. FR-018 y los escenarios 7 y 8 de US4 explicitan el límite de 30 minutos, su persistencia y la sustitución de avisos obsoletos; SC-006 fija una secuencia temporal verificable. Se validaron cuatro historias, 22 requisitos, ocho criterios de éxito y la checklist 16/16, sin marcadores pendientes. Esta revisión de requisitos no acredita todavía la corrección del código.

Siguiente fase propuesta: `speckit-clarify`, sobre esta misma feature. No se ejecutó ni se encadenó a plan o implementación. Los resultados focales de la línea base se conservan sin repetir BATS, porque solo cambiaron documentos de especificación.

**Registro posterior, clarify concluido (17-11-2026):** tres preguntas nuevas respondidas e integradas en [el spec](spec.md#clarifications): suspender envíos si no puede persistirse su registro; no avisar recuperación si ningún aviso del episodio se confirmó; y exigir integración con un servicio de prueba real en Linux y datos ficticios antes del merge. El spec queda con cuatro historias, 23 requisitos y nueve criterios de éxito. La checklist vuelve a 16/16 tras resolver el ítem de ambigüedad reabierto durante la revisión. Se aclaró además que cancelar un aviso obsoleto no obliga a generar recuperación y que la invariancia funcional de Docker admite su identificación de versión. El método de persistencia y sincronización, el presupuesto de las llamadas externas y el entorno concreto de integración quedan para plan. Siguiente comando: `speckit-plan` en este worktree; no ejecutado. Sin implementación, nuevas pruebas, commit, push ni operaciones sobre agentes.

## Registro posterior: plan (17-11-2026)

Invocación explícita del operador: `speckit-plan`, limitada a investigación y diseño de 047. Base/HEAD `3afae74bd6335f7ebd8f6b4ff613b4e876f2db08`, rama `047-local-healthcheck`; VERSION 0.32.0 y constitución 1.1.0 sin modificar. El setup del skill se ejecutó una vez. Se consultaron spec, constitución, plantillas, código, contratos anteriores y fuentes primarias; tres agentes de investigación de solo lectura cubrieron autenticación, avisos y Linux.

Entregables: [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [health-verdict.md](contracts/health-verdict.md), [notice-state.md](contracts/notice-state.md), [validation.md](contracts/validation.md) y [quickstart.md](quickstart.md). Diseño conforme a los seis principios, sin nueva excepción constitucional. CLI y biblioteca renderizados solo para local; estado JSON privado con lock y sincronización; gate CI real de Linux separado de BATS, con diez escenarios sintéticos antes del merge. El bump propuesto es 0.33.0, sujeto a verificar origin/main al implementar.

La revisión independiente del diseño encontró siete hallazgos: uno alto (retroceso y corrección del reloj podían dar doble crédito), cuatro medios (frontera rename/flush final, invariantes cruzadas del estado, nueva descendencia durante observación y falta de escenario de persistencia Linux real) y dos bajos (precedencia legacy por legibilidad y barreras de carrera no obligatorias). Se corrigieron en documentos y ambas revisiones posteriores no encontraron contradicciones bloqueantes en los ajustes. No son resultados de ejecución. El contrato ahora exige conservar el máximo de reloj contabilizado, sincronizar el checkpoint visible antes de adoptarlo, rechazar combinaciones incoherentes, volver a enumerar antes de concluir absent y ejercer flock/sync/timeout/curl reales en L10.

Se precisó una suposición del spec: una confirmación remota recibida pero no persistida también puede dejar entrega incierta y duplicarse al reintentar. No se cambian las decisiones del operador ni se inventan respuestas nuevas. El spec conserva cuatro historias, 23 FR, nueve SC y siete Q/A; checklist 16/16. Referencias relativas verificadas, sin enlaces locales rotos ni marcadores pendientes de diseño.

`.specify/extensions.yml` fue comprobado antes y después: YAML válido, `hooks: {}`, sin before_plan/after_plan que ejecutar. Esta fase no creó tasks.md ni modificó runtime, tests, VERSION o constitución; no ejecutó BATS, integración, Docker, SSH, sudo, servicios, modelo, commit, push o escrituras GitHub. Los gates reales siguen pendientes; la línea base focal de specify se conserva sin repetirla. Siguiente invocación manual: `speckit-tasks` desde el worktree 047.

## Registro posterior: tasks (17-11-2026)

Invocación explícita del operador: `speckit-tasks`, usando el skill y el setup de la rama 047. Se generó [tasks.md](tasks.md) con 64 tareas: tres Setup, cinco Foundational, seis US1, diez US2, cuatro US3, dieciséis US4 y veinte de integración transversal/cierre. Se conservaron el plan y las decisiones; las 64 tareas quedan pendientes de ejecución.

El inventario planifica 92 tests nuevos del host (30 auth/journal, 20 procesos, 36 avisos y seis ampliaciones de render/regenerate/CI), conservando los 21 existentes del healthcheck y el número previo de pruebas SIGPIPE. El esperado será la línea base completa de T002 más 92, con revisión explícita si cambia el inventario; 2196 solo aplica si la medición reconfirma 2104. L01–L10 siguen fuera del plan BATS del host. El catálogo inicial incluye M00 de control y 31 mutaciones, no ejecutadas.

Se comprobaron formato, numeración secuencial, etiquetas por historia, rutas, citas literales de restricciones del estado y cobertura de los escenarios/requisitos. El paralelismo se limita a preparar el fixture Linux en otro archivo y a dos grupos de documentación; BATS siempre secuencial. Los hooks before_tasks/after_tasks no están registrados (`hooks: {}`), con YAML comprobado.

Sin implementación, BATS, mutaciones, integración, cambios de VERSION/constitución o Git/publicación. La validación de esta fase es documental. Próximo comando manual recomendado: `speckit-analyze`; no ejecutado ni encadenado.

## Registro posterior: análisis y remediación U1/A1 (17-11-2026)

El análisis de spec/plan/tasks detectó dos hallazgos medios y cobertura formal 32/32, sin altos/críticos: preparación explícita de timeout/sync para el arnés macOS y origen/prueba del presupuesto global de 60 s. El análisis inicial fue solo lectura. El operador aprobó posteriormente aplicar solo esa remediación documental y volver a analizar.

Se ajustaron plan, investigación, contratos, quickstart y las tareas existentes, conservando 64 tareas y 92 pruebas previstas. Los dobles estrictos y sus autopruebas quedan asignados; H5 es el contrato canónico de los deadlines absolutos y N31 cubre el CLI completo. Las dos revisiones focales confirmaron cierre documental, con validación estática satisfactoria y alcance limitado a estos documentos. Detalle y autorización en el [Registro de tasks](tasks.md#registro). No hay implementación, pruebas de ejecución, commit, push ni cambios de agentes.
