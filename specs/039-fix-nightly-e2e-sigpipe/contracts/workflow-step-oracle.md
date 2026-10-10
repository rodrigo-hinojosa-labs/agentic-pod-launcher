# Contract: Oráculo de pasos de workflow

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Cubre**: FR-001, FR-002, FR-003, FR-007, FR-008, FR-009, FR-010 | **Archivo**: `tests/ci-workflows.bats`

Define cómo la suite del host (sin Docker ni red) ejecuta el texto **real** de un paso de un workflow y qué debe afirmar. Es un contrato de comportamiento: fija el arnés, el `docker` falso y los casos, no el texto del arreglo.

## 1. Extracción del paso

**Entrada**: ruta del workflow, id del job y nombre del paso. Para el paso de verificación: `docker-e2e.yml`, job `e2e`, paso `Verify deps + docker`.

**Regla**: el paso se selecciona **por nombre** y debe coincidir **exactamente una vez**; su `run:` no puede estar vacío. Si el paso se renombra, se borra o se duplica, el test falla con un mensaje que lo dice: nunca pasa en vacío. Para el paso de la suite se extrae además el mapa `env:`.

**Mecanismo**: `yq` v4 (mikefarah) sobre el YAML. El texto extraído es el mismo que el runner entrega al shell, sin copia ni reescritura.

## 2. Ejecución

1. El texto extraído se escribe en un archivo temporal y se le **agrega una última línea centinela** (`echo __ORACLE_REACHED_END__`). Un script que muere antes no la imprime.
2. Se ejecuta con `bash -e <archivo>`, que es el shell por defecto del runner (`bash -e {0}`), en un directorio temporal, con `PATH` = el directorio de stubs delante del `PATH` normal. El paso trae su propio `set -euo pipefail`, igual que en el runner.
3. El intérprete es el `bash` que ejecuta bats: 3.2.57 en el brazo de macOS y 5.x en el de ubuntu del CI, y ambos en local con `PATH=/bin:$PATH`. Es el gate dual de 025 aplicado al oráculo.
4. Se capturan el estado y la salida combinada (stdout y stderr).

## 3. Contrato del `docker` falso

Un script bash en el directorio de stubs. Las herramientas `bats`, `yq`, `jq`, `git` y `tmux` son stubs triviales que imprimen una línea `<herramienta> stub 1.0` y salen con 0, para que el oráculo no dependa de lo que el host tenga instalado.

| Invocación | Comportamiento |
|------------|----------------|
| `docker --version` | `Docker version 28.0.4, build b8034c0` |
| `docker compose version` | `Docker Compose version v2.38.2` |
| `docker info` (sin argumentos) | **Sección de cliente de 14 líneas, pausa de `${STUB_INFO_DELAY:-0.3}` s, sección de servidor de 40 líneas**, cada línea con su propio `echo` (una escritura por línea). Es la forma que produce el SIGPIPE medido en el run 37197340169 |
| `docker info --format <plantilla>` | **Renderiza** los campos conocidos: `{{.ServerVersion}}` por `27.5.1`, `{{.OperatingSystem}}` por `Ubuntu 24.04.2 LTS`, `{{.Architecture}}` por `x86_64`, `{{.CgroupVersion}}` por `2`, `{{.Driver}}` por `overlayfs`. Si tras renderizar queda un `{{`, imprime `template parsing error` en stderr y sale con 1 (lo que hace Docker real con un campo inexistente) |
| cualquier `info` con `STUB_DOCKER_DOWN=1` | Imprime `Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?` en stderr y sale con 1 |

**Por qué renderiza**: si el stub ignorara la plantilla, el oráculo no detectaría que el paso dejó de pedir la arquitectura o la versión del servidor, y FR-002 sería indemostrable. Renderizar convierte la aserción sobre el log en una aserción sobre lo que el paso **pidió**. **El servidor vale `27.5.1` y el cliente `28.0.4` a propósito**: si ambos valieran lo mismo, `docker --version` ya imprimiría ese valor y la aserción sobre el servidor sería vacua (el paso podría dejar de pedir `ServerVersion` sin que O3 lo notara).

**Por qué escrituras por línea y una pausa**: medido (M1 y M2 de [research.md](../research.md)): con escrituras por línea el paso con defecto da 141 en 30 de 30 corridas aun sin pausa, con bash 3.2.57 y 5.3.15. La pausa de 0,3 s es margen para un runner cargado: asegura que `head` ya salió cuando llega la segunda tanda.

## 4. Casos

| ID | Sujeto | Debe afirmar |
|----|--------|--------------|
| **O1** | Extracción del paso real | Coincide exactamente una vez; `run:` no vacío; el texto menciona `docker` |
| **O2** | **Autotest del arnés**: el mismo arnés sobre `tests/fixtures/ci/step-verify-with-defect.sh`, el paso de `da22a06` copiado verbatim | Estado **141** y centinela **ausente**. Si el arnés deja de poder detectar el defecto, este test se pone rojo (FR-008) |
| **O3** | Paso real, Docker sano | Estado 0; centinela presente; la salida contiene `Docker version`, `Docker Compose version` y los tokens `server=27.5.1` y `arch=x86_64` (FR-001, FR-002) |
| **O4** | Paso real, `STUB_DOCKER_DOWN=1` | Estado distinto de 0; centinela ausente; el mensaje del daemon aparece en la salida (FR-003) |
| **O5** | Autochequeo del stub | `docker info` ejecutado solo escribe más de 10 líneas en la primera tanda, hay una pausa y hay una segunda tanda. Evita que un stub debilitado deje el oráculo en vacío |

**Mutaciones que cada caso caza** (se corren a mano al implementar y quedan en las Notes de `tasks.md`): reintroducir `docker info | head -10` pone rojos O3 (141) y el ratchet; reemplazar la línea de `docker info --format` por una que silencie el fallo (`|| true`) pone rojo O4; quitar de la plantilla `server=` o `arch=` (una a la vez) pone rojo O3.

## 5. Ratchet estático

**Entrada**: todos los `run:` de `.github/workflows/*.yml`, vía `yq` a JSON y `jq`.

**Regla**: falla si alguna línea de un `run:` contiene un pipe (no `||`) cuyo consumidor es:
- `head`;
- `grep` con una agrupación de opciones que incluya `q`, o con `-m`;
- `sed` con `-n` y una orden `q`, o con un script de la forma `Nq`;
- `awk` cuyo programa contiene `exit`.

No hay lista de excepciones (decisión D6). Se ignoran las líneas de comentario. Límite conocido: las continuaciones con `\` se evalúan por línea física.

**Casos**:

| ID | Sujeto | Debe afirmar |
|----|--------|--------------|
| **R1** | `tests/fixtures/ci/ratchet-bad.yml`, con cada consumidor prohibido en un paso | El detector marca **todos**, con archivo, paso y línea (el detector puede fallar) |
| **R2** | `tests/fixtures/ci/ratchet-good.yml`, con `xargs`, `tee`, `sort`, `wc`, `grep` sin `-q` y `||` | No marca ninguno (no bloquea de más) |
| **R3** | Los tres workflows reales | **Cero** infractores, y que el barrido no fue vacío: `$WF` contiene al menos 3 archivos `.yml` y cada uno tiene al menos un paso con `run:` (contado aparte con `yq`) |

## 6. Fuera del contrato

- No se ejecuta Docker real ni se prueba la plantilla de `--format` contra un daemon: eso lo prueba la corrida de evidencia de FR-014.
- El oráculo no sustituye la lectura del log de una corrida real; la complementa.
- No se lintean los scripts embebidos con `shellcheck` (el job de CI solo revisa archivos `.sh`). Posible mejora, no parte de esta feature.
