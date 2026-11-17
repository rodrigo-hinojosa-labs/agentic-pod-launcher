# Quickstart: cómo validar la feature 046

**Feature**: `046-agent-backup-repo` | **Fecha**: 2026-11-13, corregido el 14-11-2026 tras el análisis de consistencia

Esta guía dice cómo comprobar que la feature funciona, de lo más barato a lo más caro. Los comandos valen una vez implementada. Los contratos están en [contracts/](contracts/) y las formas de los datos en [data-model.md](data-model.md).

## 0. Requisitos

| Dónde | Qué hace falta |
| --- | --- |
| Mac del operador | `bats`, `yq`, `jq`, `git` (con `git http-backend`), `age`, `python3` y `ssh-keygen`. En este equipo, `bats`, `yq` y `age` están en `/opt/homebrew/bin`, que hay que poner en el PATH |
| Prueba de extremo a extremo | Docker Desktop encendido |
| Gate y despliegue | Acceso a ferrari, y la llave privada que corresponde a la llave pública que se fije en cada agente |

## 1. Suite del host (sin Docker)

Las seis suites nuevas, en los dos bash:

```bash
export PATH=/opt/homebrew/bin:$PATH
bats tests/backup-dest.bats tests/backup-store.bats tests/backup-repo-units.bats \
     tests/backup-repo-restore.bats tests/agent-repo-surface.bats tests/backup-status.bats
PATH=/bin:$PATH bats tests/backup-dest.bats tests/backup-store.bats tests/backup-repo-units.bats \
     tests/backup-repo-restore.bats tests/agent-repo-surface.bats tests/backup-status.bats
```

**Esperado**: 124 pruebas y 0 `not ok` en las dos corridas. En un equipo de desarrollo, una prueba que no encuentra una dependencia se salta con su motivo; en la CI, falla.

El control de que el camino del fork no cambió son las suites que ya existían:

```bash
bats tests/backup-identity-lib.bats tests/backup-identity-git.bats tests/backup-identity-cmd.bats \
     tests/backup-vault-lib.bats tests/backup-vault-git.bats tests/backup-vault-cmd.bats \
     tests/backup-config.bats tests/restore-from-fork.bats tests/restore-unified.bats \
     tests/local-vault-backup.bats
```

**Esperado**: los mismos resultados que en `origin/main`, sin editar ninguna de esas pruebas.

El gate completo es `bats tests/` en los dos bash: la línea base medida más 132 (las 124 del host y las 8 de extremo a extremo, que en el host salen saltadas), con 0 `not ok` (SC-009).

## 2. Prueba manual con el servidor de prueba

Sirve para ver el flujo completo sin GitHub. Todo corre en un directorio temporal.

1. Crear un repositorio bare con una rama de trabajo y levantar `tests/fixtures/backup-repo/git-auth-server.py` con una credencial de prueba.
2. Crear un workspace de prueba con `backup.repo.url` apuntando al servidor, la misma credencial en `GITHUB_PAT`, `BACKUP_DEST_ALLOW_HTTP=1` y una llave pública de prueba en `backup.identity.recipient`.
3. Correr cada unidad con `heartbeatctl backup-<unidad>`, usando las variables de entorno de prueba de `heartbeatctl`.
4. Comprobar en el repositorio bare:
   - las cinco ramas `backup/*`, cada una con su `.agentic-pod-backup.json`;
   - la rama de trabajo, con la misma cabeza que al comienzo;
   - ninguna cadena de los archivos de origen dentro de `store/`, y sus tres archivos de llave (`key.age`, `recipient` y `operator`).
5. Correr las unidades otra vez: 0 commits nuevos.
6. Restaurar en otro directorio con `./setup.sh --restore-from-repo` y comparar como dice R7 de [contracts/restore.md](contracts/restore.md).

## 3. Prueba de extremo a extremo (con compuerta)

```bash
export PATH=/opt/homebrew/bin:$PATH
DOCKER_E2E=1 bats tests/docker-e2e-backup-repo.bats
DOCKER_E2E=1 bats tests/docker-e2e-*.bats
```

**Esperado**: TE1 a TE8 en verde, y el total del e2e en 62 casos. En este Mac, el caso de humo `tests/docker-e2e-smoke.bats:79` falla también en `origin/main` por su espera de 20 segundos; no es de esta feature.

## 4. Gate de integración en el M4, antes del merge (con compuerta)

**Ejecución completada**: R7 y M5 se verificaron el 17-11-2026. Resultados, alcance y límites en [pilot-m4-results.md](pilot-m4-results.md); no repetir los comandos de esa ejecución. La secuencia siguiente conserva el procedimiento del ensayo.

El operador aprobó el piloto local el 16-11-2026 para continuar sin ferrari. El alcance está en [contracts/local-pilot.md](contracts/local-pilot.md) y lo que se registra en V5 de [contracts/evidence.md](contracts/evidence.md). Se conserva el respaldo/restauración real contra GitHub privado antes del merge; los datos de la flota no se simulan como recuperados.

1. **Aislamiento**: preparar workspace, estado y evidencia propios bajo el caché de 046, con imagen etiquetada aparte y hashes comparados con la rama. No tocar las imágenes ni workspaces existentes.
2. **Cabezas de trabajo**: anotar las cabezas de las ramas de trabajo en GitHub. Va antes de asociar el repositorio: desde que se asocia, el cron puede empujar.
3. **Código de la rama**: regenerar el workspace sintético con sus archivos de sistema y registrar la imagen construida. Mantener las librerías y herramientas horneadas sin overrides de pruebas.
4. **Inventario**: sembrar identidad, vault, persona/configuración, auto-memoria, SQLite, extra path y JSONL de prueba. Declarar el extra path y `backup.sensitive: true`.
5. **Revisión de lo que viaja en claro**: comprobar que toda identidad y configuración del piloto son sintéticas. El operador proporciona las credenciales por su Terminal o gestor, sin valores en chat, argumentos ni logs.
6. **Asociación**: fijar `backup.repo.url` con `https://github.com/rodrigo-hinojosa/agentic-046-recovery-gate`, privado y creado con `main`, y regenerar. `--regenerate` avisa si falta la llave o la credencial.
7. **Contexto del agente**: comprobar que el `CLAUDE.md` vivo ganó la sección `## Your repository`. Si no la tiene, es porque estaba editado y `--regenerate` lo preservó: se fuerza con `--force-claude-md`.
8. **Consola aislada**: arrancar el contenedor como `agent`, con el estado montado igual que en producción y un proceso inerte; sin cron, supervisor ni canales conectados. No copiar perfiles del Mac o de ferrari.
9. **Llave**: fijar la pública M4 comprobada por el operador con la CLI real. Registrar que configurar la llave dispara identidad; hacerlo antes de congelar las entradas o contarlo en el primer ciclo. No repetirlo entre ciclos:

   ```bash
   docker exec -u agent <contenedor-del-piloto> heartbeatctl backup-identity --configure-key "<llave pública>"
   ```

10. **Primer ciclo**: correr las cinco unidades y `heartbeatctl backup-status`.
11. **Verificación en GitHub**: las cinco ramas `backup/*` existen, y las ramas de trabajo tienen las cabezas del paso 2.
12. **Segundo ciclo**: 0 commits nuevos.
13. **Ensayo de restauración**: en el equipo que tiene la llave privada, restaurar en un directorio limpio y comparar como dice R7 de [contracts/restore.md](contracts/restore.md). El workspace restaurado no se arranca, y se borra al terminar.
14. **Medición de M5**: preparar una conversación real de prueba y, con autorización separada para consumir cuota, respaldarla y probar su historial recuperado en un perfil separado con `claude -p --continue` desde `/workspace`. Sin el resultado, SC-002 sigue pendiente.
15. **Estado final**: contenedor de consola activo, 0 reinicios y límites del ensayo registrados. No se certifican cron, supervisor, canales ni datos vivos de la flota.

**Si algo falla**: detener el piloto, conservar diagnósticos y presentar el hallazgo antes de tocar código. No proponer merge con el gate incompleto ni borrar automáticamente el repositorio. El workspace y la evidencia quedan para revisión; registrar la retirada del destino de restauración y temporales descifrados al terminar su uso.

## 5. Despliegue, después del merge (con compuerta)

Un agente a la vez: linus, después donna y al final cbum. La tabla con lo propio de cada uno está en la sección V6 de [contracts/evidence.md](contracts/evidence.md).

Linus completa primero la validación operacional con sus datos reales, que el piloto M4 no acredita: inventario y revisión de archivos en claro, ciclos de respaldo, restauración comparada y salud del canal/doctor. Guardar la imagen `agentic-pod:linus-pre046` y archivos de sistema para reversión; si falla, volver a ellos y detener la ampliación.

Para cada agente:

1. respaldo de la imagen y de los archivos de sistema, y las cabezas de las ramas de trabajo anotadas;
2. archivos de sistema de `main` y `--regenerate`;
3. inventario del estado sin cubrir, revisión de lo que viaja en claro y asociación del repositorio en `agent.yml`; en donna, además, sus rutas adicionales; en cbum, `backup.sensitive: true`;
4. comprobación de la sección `## Your repository` en el `CLAUDE.md` vivo, con `--force-claude-md` si hace falta; en donna, después, `custom-apply --no-regenerate`, porque el render le borra sus MCP de overlay;
5. build, stop, 150 segundos y up;
6. la llave, con `--configure-key`, y su huella confirmada;
7. primer ciclo de las cinco unidades y `backup-status`;
8. verificación de las ramas de respaldo y de las ramas de trabajo;
9. aviso al agente de que su clon de trabajo es ahora `/workspace/agent-repo`;
10. observación de 24 horas.

Lo que hace el operador y no el launcher:

- crear el repositorio privado de cbum, con un commit inicial en `main`;
- ajustar la regla de la persona de cbum sobre los datos de salud;
- decidir qué pasa con los clones actuales de donna y de linus, que quedan fuera de `/workspace/agent-repo`.

## 6. Mantención

| Tarea | Cómo |
| --- | --- |
| Ver cuánto ocupa el respaldo | `heartbeatctl backup-status`. El diagnóstico advierte sobre los 800 MB |
| Recortar la historia de una rama de respaldo | Borrar esa rama `backup/<unidad>` en GitHub. El ciclo siguiente la recrea con un solo commit. Las ramas de trabajo no se tocan |
| Cambiar la llave del operador | `heartbeatctl backup-identity --configure-key`. Cada unidad cifrada vuelve a subir todo en su ciclo siguiente |
| Sacar del repositorio lo que un agente subió en claro antes de marcarse como sensible | Recortar sus ramas, como arriba |

## 7. Qué mirar si algo no funciona

| Síntoma | Dónde mirar |
| --- | --- |
| Una unidad no empuja | `heartbeatctl backup-status` y `scripts/heartbeat/logs/backup-<unidad>.log` |
| `no-credential` | Falta `GITHUB_PAT` en el archivo de secretos; hay que recrear el contenedor después de agregarla |
| `not-private` | El repositorio responde sin credencial: es público |
| `unverified` | No se pudo comprobar que el repositorio sea privado: la sonda sin credencial falló por otra razón que la falta de credencial. Se repite en el ciclo siguiente |
| `unreachable` | La credencial no sirve para ese repositorio, no hay red, o la URL no es de GitHub |
| `no-recipient` | Falta `backup.identity.recipient`; se fija con `heartbeatctl backup-identity --configure-key` |
| `foreign-branch` u `other-agent` | Ya existe una rama `backup/*` que no es de este agente, o a una propia le quitaron la marca: se borra la rama y el ciclo siguiente la recrea |
| `another run holds the lock` | Otra corrida de la misma unidad está en curso. Es normal durante un empuje largo |
| La restauración omite una unidad | La línea de salida dice si faltó la rama, la llave, `python3` o `age` |
| La restauración pide la passphrase varias veces | Es una vez por pieza cifrada: tres en un agente sin marcar y hasta cinco en uno sensible. Conviene pasar la llave con `--identity-key` |
| El vault de un agente sensible no se respalda | Tiene fork y no tiene repositorio asociado: el vault de un agente sensible solo viaja cifrado, y un fork no lleva contenido cifrado |
| Una ruta adicional no llega al respaldo | `heartbeatctl backup-status` la lista como inexistente, o no cumple la regla de rutas |
| No existe `/workspace/agent-repo` | Faltaba `GITHUB_PAT` o el repositorio en el arranque. La unidad `config` lo vuelve a intentar cada día |
| El agente restaurado pide iniciar sesión | El original usaba `/login` y no el token del archivo de secretos: ese login no viaja en el respaldo |
