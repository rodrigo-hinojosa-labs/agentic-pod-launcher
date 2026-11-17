# Revisión del operador para terminar 046

Estado al 17-11-2026: implementación y gates automáticos validados; [PR #135](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/135) sigue en borrador. La CI publicada de `d340eef` dio 2104/2104 por sistema y shellcheck correcto; el e2e amd64 dio 62/62 con runtime y archivo e2e idénticos.

**Piloto M4 verificado**: cinco respaldos correctos, segundo ciclo sin commits, R7 11/11 exactos y M5_RETOMA_OK. El lector recuperó la misma sesión y marcador; el perfil vacío respondió UNKNOWN. Los lectores y temporales se retiraron. El intento original detenido y el cierre complementario se conservaron. Resultados y límites en [pilot-m4-results.md](pilot-m4-results.md); historial en el Registro de [tasks.md](tasks.md). No repetir run.command ni m5.command.

El operador confirmó 0 prompts de passphrase en ambos auxiliares y autorizó por separado publicar el commit documental, su push y quitar el borrador tras CI en verde. T079/T080 cerradas; T081 espera la publicación y su CI. Esa autorización excluye merge y despliegue. La validación operacional de la flota sigue pendiente; no se midió recuperar el login ni un emparejamiento vivo de Telegram.

## 1. Acceso a ferrari, pendiente para el despliegue

La consulta de metadata por `ssh-ferrari` terminó con código 255 y `websocket: bad handshake`, antes de obtener la inspección del contenedor. Se intentó la renovación normal con `cloudflared access login --quiet --auto-close`: terminó con 0 y no imprimió el JWT, pero la siguiente consulta SSH volvió a fallar igual. La interfaz de navegador no estuvo disponible para inspeccionar más. No se cambió la configuración del host ni de linus. El error no demuestra que linus esté caído; la causa del fallo de transporte no está confirmada.

**Respuesta del operador (16-11-2026)**: está sin acceso remoto y necesita llegar a casa para reiniciar ferrari. El gate queda pendiente de que confirme la recuperación del acceso; no se siguen repitiendo consultas SSH mientras esa condición no cambie. Esto registra su próximo paso, sin atribuir una causa técnica confirmada al fallo.

**Decisión posterior (16-11-2026)**: el acceso a ferrari ya no bloquea el piloto de integración previo al merge, aprobado en el M4. Sigue siendo necesario para validar y desplegar los agentes reales. No repetir consultas SSH sin confirmación del operador.

Después se podrá levantar el inventario de nombres y tamaños, verificar el estado del contenedor y preparar el respaldo previo al gate. No se leerán archivos de secretos ni llaves privadas.

## 2. Confirmar la llave para restaurar

**Comprobación resuelta por el operador (16-11-2026)**: la privada del MacBook Pro M4 abrió la prueba sintética cifrada para la pública `150293570`, huella `SHA256:7bX6qKIYZWfxMLOvyLP7PbrX+j0oyoHVO8xDbFUcOAw`. El operador ejecutó age en su Terminal y reportó `LLAVE_M4_OK`. Queda confirmada su disponibilidad para esa comprobación de recuperación. El asistente no leyó la privada y todavía no se configuró ninguna llave en ferrari.

Estas son las cinco huellas **públicas** que GitHub entregó el 16-11-2026 para `rodrigo-hinojosa`; la verificada es la del M4:

| ID público de GitHub | Equipo según su título | Tipo | Huella |
| --- | --- | --- | --- |
| 126881112 | MacBook Pro M1 | RSA, 4096 bits | `SHA256:S5jCwTAt8qiYjOpumWdmqZYpsEDKl3yZOfp6xPDjiEE` |
| 148280926 | Ubuntu 25 | ED25519 | `SHA256:UgjQgrCNyp7Q8/j69i5O2Vh+c6Yga3RwR6khwNmLkwM` |
| 149670388 | Ferrari RPi5 | ED25519 | `SHA256:h+B1iJ7ROGi6MUqOUj1g62xahHfFEhEMHu/4JGuhn/E` |
| 150293570 | MacBook Pro M4 | ED25519 | `SHA256:7bX6qKIYZWfxMLOvyLP7PbrX+j0oyoHVO8xDbFUcOAw` |
| 155689556 | McLaren RPi5 | ED25519 | `SHA256:+8ehfqNcitKkzhNAj4mZ8Pr8I/iCCITt9ig4Sz0b4gE` |

Los equipos se identificaron por los títulos de las llaves públicas que devuelve `GET /user/keys`, consultado el 16-11-2026. Son etiquetas de GitHub, no prueba de que la parte privada siga en esos equipos. Las cinco huellas coinciden con la consulta pública anterior.

La pública permite preparar el cifrado para el operador; la privada correspondiente permite recuperar la parte cifrada desde otro equipo. La huella identifica el par. Conviene conservar una copia segura de la privada independiente de ferrari. La pública se fijará con `backup-identity --configure-key` al preparar el agente, después de resolver las demás condiciones de T077.

La prueba está en `/Users/rodrigo-hinojosa/.cache/agentic-046/key-check-m4-20261116/`: `challenge.age` (246 bytes), `manifest.json`, `instructions.md` y `operator-verification.json`. Contiene solo datos sintéticos. El primer intento con la ruta predeterminada de SSH falló; las huellas públicas aportadas por el operador localizaron después el archivo personalizado del M4 y su prueba de descifrado pasó. La secuencia completa se conserva en el Registro de `tasks.md`. `age` no usa el agente SSH (M19 de `research.md`).

El resultado confirmó la llave y después se completaron los respaldos, R7 y M5 del piloto M4. El respaldo/restauración vivos de linus y su revisión de inventario y archivos en claro se conservan en T083. No se pidió ni se registró el contenido de una privada o su passphrase.

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

## 4. Cierre documental y publicación

El piloto M4 aprobado y M5 ya se ejecutaron. La secuencia de preparación, sus incidentes y las verificaciones están en [pilot-m4-results.md](pilot-m4-results.md) y en el Registro. Los documentos adecuados siguen locales; el runtime y las pruebas conservan las fuentes de la cabeza validada.

1. T079/T080 cerradas: el operador confirmó 0 solicitudes de passphrase en ambos auxiliares, sin repetir age ni leer su privada.
2. Publicar el commit/push documental de D38 y del piloto, autorizado por separado el 17-11-2026.
3. Comprobar la CI automática de esa nueva cabeza y, con autorización, quitar el borrador del PR. T081 no se cierra por los checks de la cabeza anterior.
4. El merge lo hace el operador. Después se verifica main; el acceso a ferrari, el gate operacional de linus y la ampliación de flota conservan sus compuertas.

Para retomar:

```text
$speckit-implement Retoma 046 desde handoff-codex.md, el Registro de tasks.md, operator-review.md y pilot-m4-results.md. Respaldo, R7 y M5 del M4 ya están verificados: no los repitas. Continúa el cierre documental/T081 respetando la autorización de publicación que conste en el Registro. El merge y la flota tienen compuertas separadas. No leas privadas o archivos reales de secretos ni repitas gates completos sin cambios de fuente que lo justifiquen.
```
