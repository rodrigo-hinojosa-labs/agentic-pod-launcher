# Revisión del operador para terminar 046

Estado al 16-11-2026: implementación local validada, T075 en tres commits y rama publicada; [PR #135](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/135) en borrador para adelantar la CI. El merge sigue condicionado al respaldo y restauración reales en linus (FR-022). El Registro de [tasks.md](tasks.md) conserva resultados y excepciones.

## 1. Restablecer el acceso a ferrari

La consulta de metadata por `ssh-ferrari` terminó con código 255 y `websocket: bad handshake`, antes de obtener la inspección del contenedor. Se intentó la renovación normal con `cloudflared access login --quiet --auto-close`: terminó con 0 y no imprimió el JWT, pero la siguiente consulta SSH volvió a fallar igual. La interfaz de navegador no estuvo disponible para inspeccionar más. No se cambió la configuración del host ni de linus. El error no demuestra que linus esté caído; la causa del fallo de transporte no está confirmada.

El operador debe restablecer el acceso habitual y confirmar que SSH funciona. Después se podrá levantar el inventario de nombres y tamaños, verificar el estado del contenedor y preparar el respaldo previo al gate. No se leerán archivos de secretos ni llaves privadas.

## 2. Confirmar la llave para restaurar

Estas son las huellas de las cinco llaves **públicas** que GitHub entregó el 16-11-2026 para `rodrigo-hinojosa`. No se ha seleccionado ninguna ni se ha leído una llave privada.

| ID público de GitHub | Tipo | Huella |
| --- | --- | --- |
| 126881112 | RSA, 4096 bits | `SHA256:S5jCwTAt8qiYjOpumWdmqZYpsEDKl3yZOfp6xPDjiEE` |
| 148280926 | ED25519 | `SHA256:UgjQgrCNyp7Q8/j69i5O2Vh+c6Yga3RwR6khwNmLkwM` |
| 149670388 | ED25519 | `SHA256:h+B1iJ7ROGi6MUqOUj1g62xahHfFEhEMHu/4JGuhn/E` |
| 150293570 | ED25519 | `SHA256:7bX6qKIYZWfxMLOvyLP7PbrX+j0oyoHVO8xDbFUcOAw` |
| 155689556 | ED25519 | `SHA256:+8ehfqNcitKkzhNAj4mZ8Pr8I/iCCITt9ig4Sz0b4gE` |

El operador confirma cuál corresponde a una parte privada disponible en el equipo donde hará la restauración. Solo se necesita la huella y esa confirmación, nunca el contenido ni la passphrase de la llave. La llave pública se fijará con `backup-identity --configure-key` después de preparar el agente.

Fuente: API pública `users/rodrigo-hinojosa/keys`; huellas calculadas con `ssh-keygen -lf` sobre temporales públicos. Se debe refrescar la lista antes de configurar si las llaves cambian.

## 3. Resolver el inventario antes de asociar linus

No se obtuvo un inventario vivo por la falla de acceso. La observación histórica de [research.md, M16](research.md#m16-estado-del-agente-que-ninguna-unidad-cubre-medido-solo-nombres-y-tamaños) menciona `repos/` y `linus-workspace-agent-admin/`, con un commit local sin publicar en el clon antiguo; todavía hay que verificar su estado actual.

Para cada entrada sin cobertura, el operador decidirá entre declararla en `backup.extra_paths` para respaldo cifrado o dejarla fuera con su razón. No se borrará, moverá ni reemplazará el clon antiguo por inferencia.

**El commit local requiere revisión propia**: declarar un clon como ruta adicional copia sus archivos, pero `_memory_find_files` excluye los directorios `.git`. Por tanto, esa declaración no conserva por sí sola la historia ni los commits sin publicar. No se debe sustituir el clon antiguo hasta resolver ese punto (T077).

La lista de archivos que podrían viajar en claro sale del código; todavía requiere comprobar los nombres presentes en linus y la revisión del operador:

| Unidad | Candidatos en un agente sin marca sensible |
| --- | --- |
| identity | `.state/.claude.json`, `.state/.claude/settings.json`, `.state/.claude/channels/telegram/access.json` y los archivos de `.state/.claude/plugins/config/` |
| config | `agent.yml`, `CLAUDE.md`, `personas/` sin copias `*.bak*`, `docker-compose.override.yml`, `.claude/settings.json` y archivos de `.claude/{skills,commands,agents,hooks,output-styles}/`, excluyendo `.git` |
| vault y auto-memoria | Viajan en claro en un agente sin marca sensible, según la decisión ya tomada en FR-009 |

El archivo de secretos de la raíz, claude-mem, las rutas adicionales y los transcripts siempre viajan cifrados. Marcar el agente como sensible cifra también vault, auto-memoria y configuración, salvo `agent.yml`; esa marca no cifra la lista de identidad. Si un candidato de identidad o `agent.yml` contiene un valor sensible, se debe resolver antes de asociar el repositorio.

Fuentes: `identity_whitelist` en `docker/scripts/lib/backup_identity.sh`, `config_build_maps` en `backup_config.sh`, FR-009 y T077. Esta tabla describe el código; no certifica contenidos del agente.

## 4. Continuación después de esas confirmaciones

1. Refrescar las cabezas remotas y la privacidad, guardar imagen y archivos de sistema, llevar el código y regenerar.
2. Asociar linus, instalar la llave pública confirmada y ejecutar los cinco respaldos; verificar ramas y segundo ciclo sin commits nuevos.
3. Restaurar en el equipo con la llave privada, sin arrancar el workspace restaurado, y comparar tamaños y hashes.
4. Pedir autorización separada para M5 (`claude -p --continue`): consume cuota y sigue pendiente. Si no retoma, enmendar SC-002 con el operador.
5. Completar T080/T081 y quitar el borrador solo con la evidencia requerida. El merge lo hace el operador.

Después del merge: despliegue secuencial linus, donna y cbum, con 24 horas de observación por agente. El alta del repositorio de cbum y el ajuste de su regla sobre datos de salud también corresponden al operador (T085).

## Comando para retomar

```text
$speckit-implement Retoma 046 desde handoff-codex.md, el Registro de tasks.md y operator-review.md. Continúa con T077 a T081 cuando el acceso y las decisiones humanas estén resueltos. Conserva la evidencia ya validada; no repitas suites completas sin un cambio que lo justifique. No hagas merge ni leas llaves privadas o archivos de secretos.
```
