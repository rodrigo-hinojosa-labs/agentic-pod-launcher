# Specification Quality Checklist: Un repositorio privado por agente para su trabajo y su respaldo completo

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-11-13
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`
- **Histórico: los tres marcadores del primer borrador se resolvieron el 13-11-2026**, con las respuestas del operador que quedaron en la sección Clarifications del spec:
  - FR-006: el agente empuja con la credencial amplia que ya tiene (`GITHUB_PAT`);
  - FR-008: el respaldo incluye todo, también el historial de conversaciones;
  - FR-009: cifrado por agente, con una marca de datos sensibles.
- **Default declarado, no decidido por el operador**: el historial de conversaciones se cifra en todos los agentes, también en los que no están marcados como sensibles, porque puede guardar secretos que pasaron por la conversación. Está en Assumptions y el operador lo puede cambiar.
- **Correcciones del plan (13-11-2026)**: las mediciones de `/speckit-plan` cambiaron tres cosas del spec, anotadas en su sección Clarifications como sesión del plan:
  - un agente sin fork sí corre los cron de vault y de configuración y deja una línea por corrida en su log (medido en cbum y donna), así que "sin ruido" pasó a "como hoy" en el contexto, la historia 1, FR-002, FR-018 y SC-004;
  - "memorias en claro" quedó acotado a la auto-memoria; la base de claude-mem viaja siempre cifrada (historia 2, FR-009, entidades y Assumptions);
  - sin repositorio asociado, el contexto del agente queda idéntico al de hoy, y SC-004 ya no tiene excepción (FR-015).

  Además, cuatro filas de la tabla de estado pasaron de inferidas o sin verificar a medidas o leídas, y se agregaron dos. Revalidado después: 16 de 16 ítems.
- **Revalidado tras integrar las respuestas (13-11-2026)**: 16 de 16 ítems. Cambiaron las historias 1 a 4, los casos borde, FR-003, FR-006, FR-008, FR-009, FR-010, FR-012 y FR-023, las entidades, SC-002, SC-005, SC-006, SC-007 y SC-010, y las Assumptions.
- **Sobre "sin detalles de implementación"**: las rutas y líneas de código del Contexto y de la tabla de estado son evidencia de lo medido y lo leído, como en 043, 044 y 045. Los requisitos y los criterios de éxito no fijan mecanismos: no nombran ramas nuevas, formatos de credencial ni herramientas de cifrado.
- **Hechos verificados el 13-11-2026** (leídos o medidos, no recordados):
  - por la API de GitHub, en solo lectura: metadatos, ramas, árbol y commits de `donna-workspace-agent-admin` y `linus-workspace-agent-admin`;
  - en ferrari, con sondas de solo lectura en donna, linus y cbum: `scaffold.fork.owner`, remotos de git, archivos de estado de respaldo, estado de la persona en el git local, dónde se nombra el repositorio, clones dentro del contenedor, medios de autenticación de git (solo presencia) y tamaños;
  - en el código de `main` = `10f22a7`: `docker/scripts/heartbeatctl`, `docker/scripts/start_services.sh`, `docker/scripts/lib/backup_identity.sh`, `docker/scripts/lib/backup_config.sh`, `scripts/lib/backup_vault.sh`, `modules/local-vault-backup.sh.tpl`, `modules/claude-md.tpl`, `setup.sh`, `scripts/agentctl`, `tests/docker-e2e-backup-identity.bats` y la constitución.
- **Inferencias que NO son hechos**: que un respaldo en modo docker contra un repositorio privado de GitHub falla hoy por autenticación (lo mide el plan) y que el trabajo diario del repositorio de donna se hace fuera del contenedor.
- **Sin verificar en esta sesión**: los límites de tamaño del servicio (por archivo y por repositorio) y la regla de que un fork de un repositorio público no puede ser privado. Los confirma el plan.
- **Sin hooks ni rama nueva por spec-kit**: `.specify/extensions.yml` tiene `hooks: {}`. La rama `046-agent-backup-repo` se creó a mano en su worktree propio (`.claude/worktrees/046-agent-backup-repo`) desde `origin/main` = `10f22a7`. El número 046 sale de `feature_numbering: sequential`: `specs/` llegaba hasta 045.
- **Correcciones de las tareas (13-11-2026)**: las mediciones hechas al generar `tasks.md` cambiaron el spec, y quedaron en su sección Clarifications como sesión de las tareas:
  - la unidad de identidad nunca cifró el archivo de secretos de un agente docker (medido en los tres): con un repositorio asociado pasa a cifrar el de la raíz del workspace (contexto, FR-008 e historia 3);
  - cada ciclo consulta al destino aunque no haya cambios, para ver una credencial vencida o una rama borrada (FR-013);
  - el alcance suma la configuración de proyecto de Claude y las rutas adicionales, FR-025 y FR-026, con la aprobación del operador;
  - "no pide iniciar sesión" queda acotado a los agentes que se autentican con el token de su archivo de secretos (historia 3, SC-002 y Assumptions);
  - la asociación es solo del modo docker (FR-003 y FR-019).

  Revalidado después: 16 de 16 ítems. El spec pasa de 24 a 26 requisitos funcionales.
- **Decisiones del operador en las tareas (13-11-2026)**: tres, por preguntas interactivas, y en las tres eligió la opción recomendada: incluir el estado propio del agente, dejar fuera el login de `/login` y entregar la feature en un solo PR.
- **Remediación del análisis (14-11-2026)**: `/speckit-analyze` dio 44 hallazgos (2 críticos, 15 altos, 21 medios y 6 bajos), y se remediaron todos en los artefactos. El operador tomó cuatro decisiones, las cuatro la opción recomendada: una llave de datos por almacén; la configuración cifrada en un agente de datos sensibles, salvo `agent.yml`; la llave del operador fijada con un paso explícito en un agente que ya existe; y SC-002 acotado a lo que el ensayo mide. El spec ganó la sesión "2026-11-14 (análisis)" en Clarifications, tres filas en "Estado de cada afirmación", seis escenarios y ocho casos borde, y ajustó FR-003, FR-005, FR-009, FR-010, FR-012, FR-013, FR-014, FR-017 y FR-020, y SC-002, SC-005, SC-006 y SC-010. Siguen siendo 26 requisitos funcionales y 10 criterios de éxito. Los 16 ítems de esta lista siguen en verde.
- **Verificación de la remediación (14-11-2026)**: dos revisiones independientes, de solo lectura. La primera recorrió los 44 hallazgos: 36 remediados, 8 parciales y ninguno sin remediar. La segunda buscó defectos nuevos contra los artefactos y contra el código: 2 altos, 8 medios y 7 bajos, casi todos en las pruebas y en su doble. Se corrigieron todos. En el spec cambiaron FR-009, FR-014 y FR-018 (un agente marcado como sensible con fork no empuja su vault; las llaves por defecto al restaurar). Los 16 ítems siguen en verde.
