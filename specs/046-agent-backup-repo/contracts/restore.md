# Contrato: restauración desde el repositorio del agente

**Feature**: `046-agent-backup-repo` | Cubre FR-014 y las historias 3 y 6 del spec.

La restauración corre en el host, desde un clon del launcher, con las credenciales de git del operador. No corre dentro de ningún contenedor.

## R1. Invocación

```text
./setup.sh --restore-from-fork <url> [--identity-key <ruta>] --destination <dir>
./setup.sh --restore-from-repo <url> [--identity-key <ruta>] --destination <dir>
```

- `--restore-from-repo` es un alias nuevo de `--restore-from-fork`. Los dos aceptan la URL de un fork o la de un repositorio asociado, y hacen lo mismo.
- `--identity-key` es la ruta de la llave privada del operador. El launcher no la lee: se la pasa a `age`.
- **Qué llave se usa**: la regla de hoy, y vale para toda pieza cifrada. Primero la de `--identity-key`; si no se pasó, o no abre, las dos llaves ssh por defecto del directorio personal del operador (`setup.sh:1772-1776`). Se usa la primera que abre.
- Si ninguna llave abre, lo cifrado se omite y lo demás se restaura.
- Como hoy, la restauración corre al final del scaffold: el operador pasa primero por el wizard, y el `agent.yml` restaurado reemplaza al que el wizard escribió (`setup.sh:1345` y `:2008-2011`).
- Las pruebas y el ensayo de R7 llaman a la función `restore_from_fork` directamente, sobre un directorio vacío, con `GIT_TERMINAL_PROMPT=0`. Las pruebas usan además un `HOME` propio y vacío, para que ninguna toque las llaves del operador.

## R2. Orden y comportamiento por rama

Cada rama se trae con un clon de una sola rama y profundidad 1. Si una rama no existe, se sigue con la siguiente.

| Orden | Rama | Qué restaura | Requiere llave |
| --- | --- | --- | --- |
| 1 | `backup/config` | `agent.yml` y, si están, `CLAUDE.md`, `personas/`, `docker-compose.override.yml` y el directorio `.claude/` de proyecto | Solo si trae `store/`: para todo salvo `agent.yml` |
| 2 | `backup/identity` | Los archivos de identidad en `.state/` y, si hay llave, los secretos en la raíz del workspace, con modo 0600 | Solo para los secretos |
| 3 | `backup/vault` | El markdown del vault. Si la rama trae `store/`, lo descifra | Solo si trae `store/` |
| 4 | `backup/memory` | La auto-memoria en claro, si la hay, y lo de `store/`: claude-mem, las rutas adicionales y, en un agente sensible, la auto-memoria | Para `store/` |
| 5 | `backup/history` | Lo de `store/` | Sí |

- El orden de los tres primeros pasos es el de hoy. `config` va primero porque de ahí sale `vault.path`.
- La marca `.agentic-pod-backup.json` y los tres archivos de la llave de datos (`key.age`, `recipient` y `operator`) no se copian al workspace.
- El destino de cada ruta lógica está en la sección 8 de [data-model.md](../data-model.md).

### Repositorio de agente o fork

El origen es un **repositorio de agente** cuando alguna de sus ramas de respaldo trae la marca de pertenencia.

- Los pasos 4 y 5 se intentan siempre, en silencio.
- Las líneas de esos dos pasos y el resumen final de R3 solo se imprimen cuando el origen es un repositorio de agente.
- Con un fork de tres ramas, que no tiene marcas, la salida es la de hoy, palabra por palabra.

### Unidad mixta

Una unidad puede traer una parte en claro y otra en `store/`: `memory` en un agente sin marcar, y `config` en uno sensible. Sin llave, sin `python3` o sin `age`, la parte en claro se restaura y la cifrada se omite, con su línea.

## R3. Salida

Una línea por rama. `[ok]`, `[aviso]` y `[falla]` representan aquí los tres prefijos que `setup.sh` ya usa en sus líneas de restauración; el texto que sigue es el literal:

```text
[ok]    restore: memory restored into <dest>/.state/ (N files)
[aviso] restore: no backup/history branch at <url> — skipping
[aviso] restore: backup/history is encrypted and no usable key was found (pass --identity-key <path>) — skipped
[aviso] restore: backup/config is partly encrypted and no usable key was found — only agent.yml was restored
[aviso] restore: backup/memory needs python3 and age on this host — skipped
[falla] restore: backup/history failed its integrity check — nothing was written for this unit
[aviso] restore: no Claude token in the restored secrets file — run /login after the first boot
[aviso] restore: docker-compose.override.yml was restored — review it before the first boot
```

Al final, un resumen con las unidades restauradas, las omitidas y el motivo de cada omisión.

- **El aviso del token** sale cuando el archivo de secretos restaurado no trae un `CLAUDE_CODE_OAUTH_TOKEN` con valor. La comprobación mira solo si el valor existe, con `env_file_get` de `scripts/lib/env_file.sh`, y nunca lo imprime.
- **El aviso del override** sale cuando la restauración deja un `docker-compose.override.yml`: ese archivo puede cambiar los mounts y los privilegios del contenedor, y llega desde el repositorio.
- **Los dos avisos y el resumen** salen solo cuando el origen es un repositorio de agente. Con un fork, la salida es la de hoy.

## R4. Requisitos del host

| Herramienta | Para qué | Si falta |
| --- | --- | --- |
| `git` y `yq` | Todo, como hoy | Error, como hoy |
| `age` | Los secretos (como hoy) y todo `store/` | Lo cifrado se omite, con aviso |
| `python3` 3.9 o superior | Todo `store/` | Lo que viene en `store/` se omite, con aviso |

**Una llave con passphrase**: `age` la pide una vez por cada pieza cifrada que abre con la llave del operador (M19 de [research.md](../research.md)), y una vez más por cada llave que prueba antes y no abre. Son los secretos de `identity` y una vez por cada unidad con almacén: tres veces en un agente sin marcar y hasta cinco en uno sensible. Hace falta una terminal; sin ella, esas piezas se omiten con su línea.

## R5. Temporales

- Lo que se descifra se arma en `<destino>/.restore-tmp/`, con modo 0700, y se mueve a su lugar cuando la unidad pasó su verificación.
- Ese directorio se borra al terminar, también ante un error o una interrupción.
- Ahí vive también, mientras dura cada `unpack`, el archivo con la llave de datos.

## R6. Invariantes

- **I1**: lo que viene en el `store/` de una unidad se restaura completo o no se restaura. Si su verificación de integridad falla, no queda ningún archivo parcial de esa unidad en el destino.
- **I2**: la falla o la ausencia de una unidad no impide restaurar las demás.
- **I3**: la restauración desde un fork con las tres ramas de hoy produce el mismo resultado y la misma salida que en `main`, con una diferencia buscada: el archivo de secretos descifrado queda con modo 0600.
- **I4**: la restauración no arranca el agente ni contacta a Telegram.
- **I5**: el valor de ningún secreto aparece en la salida.
- **I6**: una ruta adicional se restaura solo dentro del directorio de destino. Una ruta lógica absoluta o con `..` se rechaza.
- **I7**: al terminar, con éxito o sin él, no queda `<destino>/.restore-tmp/` ni ninguna copia en claro de una llave de datos.

## R7. Ensayo de restauración

Es la comprobación que usan el gate previo al merge y el despliegue (D30 de [research.md](../research.md)):

1. Dentro del agente, justo después de un ciclo de respaldo, se arman dos listas, sin mostrar contenido:
   - de lo que viaja tal cual (los archivos en claro y el archivo de secretos), el tamaño y el SHA-256 de cada archivo de origen;
   - de lo que se captura (las bases SQLite y los `.jsonl`), la salida de `backup_store.py digest --list` de cada unidad.
2. En un directorio limpio del host donde está la llave privada, se corre la restauración.
3. Se comparan las dos listas con los archivos restaurados. Se acepta una diferencia solo en los archivos que cambiaron después del último respaldo, y esa diferencia se anota.
4. El workspace restaurado no se arranca: dos procesos con el mismo token de Claude y el mismo bot de Telegram se pisan.
5. Al terminar, el directorio restaurado se borra, porque contiene secretos descifrados, y se confirma.

Qué se espera de un agente restaurado y arrancado en otro host: si el original se autentica con el token del archivo de secretos, no pide iniciar sesión; si solo usa `/login`, hay que iniciar sesión de nuevo (D24 de [research.md](../research.md)). Eso se sigue de que el archivo de secretos restaurado es el del original, y no se mide por separado.

## R8. Modelo de confianza

La restauración confía en el contenido del repositorio. El cifrado protege la confidencialidad de lo respaldado, no su autenticidad (S5 de [block-store.md](block-store.md)): quien pueda escribir en el repositorio puede hacer que una restauración traiga otro contenido. Es el mismo modelo del respaldo en claro de hoy.
