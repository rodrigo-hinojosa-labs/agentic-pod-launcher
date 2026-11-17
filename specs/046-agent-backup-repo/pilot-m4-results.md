# Resultado del gate M4 de 046

El piloto aprobado en D38 verificó respaldo y restauración contra GitHub privado real y la continuación de una conversación recuperada. Terminó el **17-11-2026 a las 00:25:01, Santiago**. El contenido fue sintético; los agentes de ferrari no se modificaron.

## Procedencia y alcance

- Runtime y pruebas: cabeza publicada `d340eef2c6f3da2ed367ecd2f44263198c362564`; las 47 fuentes del mapa validado conservan su SHA-256. `VERSION` 0.32.0 y constitución 1.1.0.
- Imagen arm64 propia: `sha256:7f3f42efcd6c170818bcde8402f2b5297e480d860a251a9c5c99a723852d6f84`; 77 archivos horneados comparados con el contexto. La etiqueta `latest` anterior se conservó.
- Herramientas comprobadas: Claude Code 2.1.170, age 1.3.1, Git 2.54.0, Python 3.14.5 y SQLite 3.53.4.
- Repositorio privado real: `rodrigo-hinojosa/agentic-046-recovery-gate`. `main` permaneció en `7f5f761fadf0a5213b3dddc8254189a32fdc3859`; el clon de trabajo quedó en `main`, sin refs de respaldo.
- Consola como `agent`, sin cron, supervisor, bots o perfiles del Mac. Workspace y estado montados como `/workspace` y `/home/agent`. Los lectores de M5 usaron el mismo SHA de imagen y perfiles propios, sin acceso al productor ni al oráculo del marcador.

## Respaldo y comparación de archivos

| Unidad | Primer ciclo | Duración del primer empuje | Segundo ciclo |
| --- | --- | --- | --- |
| identity | ok | 4,056 s | no-change |
| vault | ok | 2,987 s | no-change |
| config | ok | 5,019 s | no-change |
| memory | ok | 3,137 s | no-change |
| history | ok | 2,890 s | no-change |

Las cinco ramas tuvieron su marca de agente/unidad y el contenido cifrado requerido. Las cinco cabezas del segundo ciclo fueron idénticas a las del primero, con intentos nuevos registrados. El cambio controlado posterior del JSONL reutilizó 3 bloques, creó 1 y retiró 1.

R7 comparó **11/11 archivos, 4.191.978 bytes**, por tamaño/SHA-256: identidad sintética, archivo de secretos sintético, configuración, persona, vault, auto-memoria, SQLite, ruta adicional y JSONL. Las capturas se calcularon con Python/SQLite de la imagen. El JSONL tenía 4.168.997 bytes crudos: el prefijo completo de 4.168.986 coincidió con el digest y se excluyó la cola incompleta de 11 bytes. No se mostraron contenidos.

El inventario incluía `.env`, `.state/.claude.json`, `.state/.claude/settings.json`, `agent.yml`, `CLAUDE.md`, `personas/recovery-gate046.md`, una página del vault, `memory/MEMORY.md`, `claude-mem.db`, `.custom/data.txt` y el JSONL sintético. No incluía `access.json` de Telegram: no había canal en este piloto. No se acredita aquí recuperación de un emparejamiento vivo.

## Incidencia del auxiliar y cierre complementario

Después de la comparación original, la guarda de procesos falló con `Unexpected process in console` y el auxiliar confirmó la detención. Ese resultado `stopped` se conservó.

La lista de procesos del momento original no se capturó. Una reproducción separada, con la misma imagen y sin datos o credenciales, mostró cuatro zombies de `timeout` cuando `sleep` era PID 1 y cero con `tini`. Se corrigió el arranque de prueba para conservar `tini`; la guarda sigue rechazando procesos ajenos y zombies y ahora guarda sus metadatos antes de validar. No cambió el producto.

El cierre complementario volvió a comprobar las ramas, el clon de trabajo y la consola corregida; recapturó los mismos orígenes y repitió la comparación local: 11/11 exactos. No ejecutó nuevos respaldos, age o llamadas al modelo. Eliminó el destino restaurado y su HOME temporal. Sus informes están separados del intento original.

## M5: conversación real recuperada

El operador autorizó por separado un máximo de tres invocaciones Sonnet de un turno. Se ejecutaron exactamente tres, con `claude-sonnet-4-6`, sin herramientas ni MCPs:

| Fase | Resultado | Sesión | Duración |
| --- | --- | --- | --- |
| Conversación nueva con marcador aleatorio | Marcador esperado | `6771552b-af08-49b7-8f58-2f0995c1b876` | 2,981 s |
| Perfil vacío, después de crear la conversación | `UNKNOWN` | Distinta de la original | 1,541 s |
| Lector con solo el JSONL recuperado, `--continue` desde `/workspace` | Mismo marcador | Misma sesión original | 1,935 s |

El JSONL recuperado tenía **2.329 bytes**, SHA-256 `065637bb56c99e755944340683202c92c30baeaa295075cabd53c7d574e7b68a`, igual al capturado en el productor. El lector no recibió el perfil original ni el oráculo del marcador, y su nuevo prompt no contenía el marcador completo. El hash de la respuesta coincidió con el del marcador esperado.

Solo cambió `backup/history`, de `47c886e788cdf6d9b8009749b834d7699fec85e3` a `0fb8dafb464b915b1d9a6ce4029cc363256e943b`. Entre esos dos ciclos, con una conversación real de por medio, reutilizó **4 bloques** y agregó **1**, sin retirar bloques. Las otras cuatro ramas y `main` conservaron sus cabezas. La restauración tardó 6,703 s y el empuje 4,724 s.

El token OAuth se suministró aparte al lector: M5 acredita continuación del historial, no recuperación del login. Los dos lectores y todos sus perfiles y destinos temporales fueron retirados; se confirmó su ausencia. El auxiliar no capturó el conteo de solicitudes de passphrase; el operador confirmó después **0 en run.command y 0 en m5.command**. Es un reporte humano y no una inferencia de los tiempos.

## Evidencia y pendientes

Fuentes locales bajo `$HOME/.cache/agentic-046/pilot-m4-20261116/evidence/`:

- `cycle1-*.json`, `cycle2-*.json`, `cycle3-*.json`, `capture/expected.json`, `restore-verification.out` y `history-incremental.json`;
- `gate-result.json`, `process-diagnosis.json`, `tini-guard-{red,green}.json`, `reentry-{red,green}.json` y `post-diagnosis/completion.json`;
- `m5/{result,comparison,invocations,seed,negative,resumed,after-backup-refs,after-resume-refs}.json`;
- `m5-verification/{semantic,incremental,remote-refs,producer}.json`, que separan la verificación posterior de la ejecución del operador.

T077/T078 y las comprobaciones de R7/M5 están verificadas en el alcance M4 aprobado. Los inventarios, archivos en claro, autenticación y emparejamiento vivos, cron, supervisor y canales de la flota siguen pendientes del despliegue, empezando por linus antes de ampliar a donna/cbum. No hubo commit/push de la actualización documental ni merge al emitir este informe. T081 continúa pendiente de publicar el cierre y comprobar la CI de esa cabeza.
