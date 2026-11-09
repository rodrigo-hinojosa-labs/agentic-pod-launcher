# Contrato: el oráculo del host, `tests/qmd-embed-nightly.bats`

Corre en `bats tests/` sin Docker ni red (Principio III; FR-016, FR-017; research D13). Cada test se ve en rojo antes de su arreglo y tiene al menos una mutación que lo pone en rojo ([quickstart.md](../quickstart.md) §3). `tests/ci-workflows.bats` de 039 no se edita.

## 1. Reglas del archivo

- bash 3.2 a 5.x; sin `mapfile`, sin arreglos asociativos.
- Las aserciones sobre `$output` usan `_has` y `_lacks` (`case`, sin tubería), como 039. Un negativo es `_lacks` o `run …; [ "$status" -ne 0 ]`, nunca un `!` intermedio. Ningún `[[ ]]` intermedio.
- Las cargas grandes pasan por archivo, nunca por `argv` ni por el entorno (límite de 128 KiB de Linux).
- Todo proceso en segundo plano (el servidor HTTP local) se lanza con los descriptores 3 y 4 cerrados (lección de 040) y se detiene en `teardown`.
- Ningún test usa la red: el `curl` real solo habla con `127.0.0.1`.

## 2. Arnés

- **Extracción del workflow**: `yq` con `strenv(NAME)` y la condición de que el paso aparezca exactamente una vez, como `_extract_run` de 039. Una extracción vacía o duplicada hace fallar el test, nunca lo deja pasar.
- **`curl` falso**: `tests/fixtures/qmd-e2e/fake-curl` (modo 100755). Lee `--output`, `--max-time`, la URL y un plan en `FAKE_CURL_PLAN`, con líneas `<subcadena de la URL>|<número de llamada>|<acción>`. Acciones:
  - `ok:<archivo>`: copia el archivo e imprime `200`;
  - `fail:<rc>`: sale con ese código e imprime, como `--write-out`, `404` para el 22 (error HTTP) y `000` para cualquier otro;
  - `pfail:<rc>`: como `fail`, pero antes deja unos bytes en `--output`: una transferencia que se corta a medias deja un parcial, y el script debe borrarlo;
  - `grow:<archivo>`: copia y agrega un byte, para el cuerpo más largo;
  - `shrink:<archivo>`: copia y quita el último byte, para el cuerpo más corto (una descarga truncada);
  - `flip:<archivo>`: copia y cambia un byte, para el mismo tamaño con otro sha256;
  - `hang:<s>`: deja un parcial en `--output`, duerme `min(s, --max-time)` con el `sleep` real (`/bin/sleep`, no el falso de abajo) y sale con 28.

  Sin acción que coincida, sale con 7. Registra cada llamada (argv completo, una línea por argumento) en `FAKE_CURL_LOG`.
- **`sleep` falso**: `_run_fetch` pone al frente del `PATH` un `sleep` que agrega su argumento a `FAKE_SLEEP_LOG` y vuelve en el acto. Así las esperas por defecto (`10 30`) se afirman sin esperar, y ningún test fija `QMD_FETCH_BACKOFF_S` salvo F10.
- **ASCII**: `_run_fetch` ejecuta el script con `run --separate-stderr` y afirma, en cada ejecución, que stdout y stderr son ASCII. Así lo prueban todas las piernas F.
- **Modelos falsos**: dos archivos pequeños creados en el test, con su sha256 calculado ahí, y una tabla alternativa (`QMD_MODELS_TABLE`) que los describe. Solo se acepta con una base local (contracts/fetch-models-script.md §3).
- **Servidor local**: `python3 -u -m http.server 0 --bind 127.0.0.1 --directory <dir>` sobre un directorio temporal; el puerto lo elige el núcleo y el servidor lo informa en su primera línea.
- **Stubs de Docker**: para los tests K, `docker` y `curl` en un directorio al frente del `PATH`, que agregan una línea a un log y salen con 99.

## 3. Tests

### W: estructura del workflow (estática, con `yq`)

| Id | Afirma | Requisito |
| --- | --- | --- |
| W1 | `Fetch the qmd models` existe exactamente una vez en el job `e2e`, con `id: fetch_models`, `run: .github/scripts/fetch-qmd-models.sh`, sin `continue-on-error` ni `if:` (en la forma combinada con 040, el `if:` es `${{ !inputs.alert_trial }}`), después de `verify_deps` y antes de `Run docker-e2e suite` | FR-007, FR-008 |
| W2 | `Verify deps + docker` tiene `id: verify_deps`, no tiene `continue-on-error` (con él, un Docker caído dejaría el paso en `failure` con conclusión `success`, la suite se saltaría por su `if:` y la noche saldría verde sin tests) y el sha256 de su `run:` es el de research M13 | FR-019, FR-008 |
| W3 | el sha256 del `run:` de `Run docker-e2e suite` es el de research M13 | FR-019 |
| W4 | el `env` de la suite tiene `DOCKER_E2E: '1'` y `QMD_EMBED_E2E: '1'` | FR-001, FR-016(a) |
| W5 | el `if:` de la suite es exactamente `${{ !cancelled() && steps.verify_deps.outcome == 'success' }}` y el paso no tiene `continue-on-error` | FR-008 (D7) |
| W6 | el `env` de `fetch_models` define `QMD_EMBED_DEFECT`, vacío o con el formato registrado de data-model §3 (la expresión se calibra con una muestra buena y dos malas: una sin motivo y una cuyo motivo son solo espacios, que el script rechaza) | FR-014, FR-016(a) |
| W7 | ningún workflow define las costuras del script; los permisos de nivel superior siguen siendo `contents: read` y el job `e2e` no tiene un bloque `permissions` propio; el job `e2e` no tiene `secrets.` | FR-018 |
| W8 | `.github/scripts/fetch-qmd-models.sh` tiene el bit ejecutable en disco y, si el archivo ya está versionado (siempre lo está en la CI), `git ls-files -s` muestra el modo `100755` | lección de 040 |

### F: el script de obtención

| Id | Escenario | Afirma |
| --- | --- | --- |
| F1 | base local y dos modelos falsos que se sirven bien | rc 0; `$GITHUB_ENV` tiene exactamente `QMD_E2E_MODELS_DIR=<dir>`; los archivos existen con su `local_name` y su sha256; por modelo, la línea completa `qmd model <name>: ok file=<local_name> bytes=<n> attempts=1 elapsed_s=<entero>` (el entero se comprueba con una expresión), y la línea `qmd models: ok total_bytes=<suma> elapsed_s=<entero> free_kb=<entero>` (FR-011); las dos líneas `free_kb=`; ningún `.part`. Segunda pierna: con `QMD_MODELS_DIR=<otro>` los archivos y la clave de `$GITHUB_ENV` van a ese directorio y no al de por defecto (es la perilla de la receta local de la checklist) |
| F2 | la primera llamada del modelo 2 falla con 28 | rc 0; `attempts=2` para ese modelo; exactamente una línea `attempt 1/3 failed`; sin `QMD_EMBED_SKIP_REASON` |
| F3 | el modelo 1 falla siempre con 22 dejando un parcial (`pfail:`) | rc 1; tres llamadas para el modelo 1 y ninguna para el 2; las esperas `10` y `30`, en ese orden, en `FAKE_SLEEP_LOG`; `::error::` que nombra el modelo; el motivo dice `curl exit 22 (http 404)`; `$GITHUB_ENV` con `QMD_EMBED_SKIP_REASON` que contiene `fetch_models` y sin `QMD_E2E_MODELS_DIR`; ningún `.part` al salir (el parcial que dejó cada intento se borra) |
| F4 | `grow:` y después `shrink:` en todos los intentos | en cada una: rc 1; tres llamadas; el motivo dice `size <n> != <m>` con el tamaño observado (uno más, uno menos); ningún `.part` |
| F5 | `flip:` (mismo tamaño, un byte distinto) | rc 1; exactamente una llamada para ese modelo y ninguna para el siguiente; el motivo dice `cambio en origen` y `sha256 <x> != <y>` con `<x>` una suma real de 64 caracteres distinta de `<y>` (la esperada, no repetida); ningún `.part` |
| F6 | `QMD_EMBED_DEFECT='#123 vec0 x64'` | rc 0; cero llamadas a curl; el motivo contiene `#123`; `::warning::` |
| F7 | valores de `QMD_EMBED_DEFECT` que no son un defecto registrado: sin issue (`sin issue`, `#123`, `#123 `, `#abc motivo`, `issue 123 vec0`), con el motivo solo de espacios (`#12   `), con una URL de otro sitio o sin número de issue, con un carácter no ASCII (generado con `printf '\303\251'`), y con un salto de línea o un retorno de carro (`#123 x` seguido de `INJECTED=1`, de `::warning::y` o de `\r`) | en todos: rc 1; cero llamadas a curl; `configuracion invalida`; `$GITHUB_ENV` con exactamente una línea (el motivo): un valor con salto de línea nunca se convierte en una segunda variable |
| F8 | `QMD_MODELS_BASE_URL` que no es Hugging Face ni `http://127.0.0.1:<1 a 5 dígitos>`: otro sitio, `http` a Hugging Face, un sufijo de dominio, sin puerto, seis dígitos, `http://127.0.0.1:@a.io` (aquí `127.0.0.1:` sería un usuario y el host `a.io`), `localhost`, `https` a 127.0.0.1; **sin tabla alternativa**, para que solo la validación de la base pueda rechazarlas | en todos: rc 1; cero llamadas a curl; el motivo nombra `QMD_MODELS_BASE_URL` |
| F9 | `QMD_MODELS_TABLE` con la base real; una tabla mal formada contra una base local (suma corta, suma no hexadecimal, tamaño no numérico, tamaño con un cero a la izquierda, que la aritmética de shell leería en octal); un `QMD_MODELS_DIR` bajo un archivo regular, y el directorio por defecto (sin `QMD_MODELS_DIR`, con `RUNNER_TEMP` bajo un archivo regular) | en todos: rc 1; cero llamadas a curl; `configuracion invalida` (el caso de `QMD_MODELS_DIR` lo nombra; el del directorio por defecto no nombra una variable que nadie fijó) |
| F10 | `hang:30` con `QMD_FETCH_BUDGET_S=3` y esperas en 0; después `pfail:22` con `QMD_FETCH_BUDGET_S=5` y las esperas por defecto | primera pierna: rc 1; el motivo conserva los dos hechos, `budget (3s)` y `curl exit 28`; termina en menos de 8 s; cada `--max-time` pasado es menor o igual al presupuesto restante; ningún `.part` al salir. Segunda pierna: rc 1 y cada espera registrada en `FAKE_SLEEP_LOG` es menor o igual al presupuesto (el reloj corre en segundos enteros, así que no se afirma un valor exacto) |
| F11 | el `curl` real contra el servidor local; después, el servidor detenido | rc 0 con los dos modelos verificados; con el servidor detenido, rc 1 tras los intentos, motivo con el código 7 y el mensaje propio de curl (`curl: (7)`) en stderr |
| F12 | F1 sin `GITHUB_ENV`; después, con un `GITHUB_ENV` que es un directorio (no se puede escribir, tampoco como root) y el idioma del sistema en español; por último, lo mismo con un defecto abierto registrado | sin `GITHUB_ENV`: el mismo rc y las mismas líneas, el directorio de trabajo queda vacío (el ASCII de todas las piernas F lo afirma `_run_fetch`, §2). Con uno que no se puede escribir: rc 1, `::error::` que nombra `GITHUB_ENV` y salida en ASCII aunque bash traduzca sus propios mensajes; además, el script trae `LC_ALL=C` y `export LC_ALL` en sus propias líneas (la pierna de comportamiento solo muerde donde bash tiene el catálogo del idioma de la máquina). La rama del defecto abierto (`QMD_EMBED_DEFECT='#12 vec0 x64'`) con ese mismo `GITHUB_ENV` también termina en rojo: rc 1, `::error::` que nombra `GITHUB_ENV`, ningún `::warning::` y cero llamadas a curl (una razón que no llega al paso siguiente dejaría la puerta del test abierta y sin modelos) |
| F13 | base y tabla reales, `curl` falso que sirve un archivo chico | el argv incluye `--fail`, `--location`, `--proto =https`, `--proto-redir =https`, `--speed-limit 1048576`, `--speed-time 30` y `--max-time`, con el primer `--max-time` entre 470 y 480 (el presupuesto por defecto), y la URL exacta `https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf?download=true`; rc 1 por tamaño, sin red |

### V: `vec0-libc.sh`

Se ejecuta con `sh` (dash en Ubuntu, bash en modo sh en macOS), como el test lo ejecuta dentro del contenedor (busybox).

| Id | Prefijo | Afirma |
| --- | --- | --- |
| V1 | `sqlite-vec-linux-arm64/vec0.so` sin `GLIBC_` (la biblioteca puede mencionar la palabra `GLIBC` sin guion bajo) | rc 0, `MUSL …` |
| V2 | `sqlite-vec-linux-x64/vec0.so` sin `GLIBC_` | rc 0, `MUSL …` (no depende de la arquitectura) |
| V3 | `sqlite-vec-linux-x64/vec0.so` con `GLIBC_2.17` | rc 1, `GLIBC …` |
| V4 | sin `vec0.so` | rc 2, `ABSENT` |
| V5 | las dos carpetas | rc 3, `AMBIGUOUS 2` |
| V6 | sin argumento | rc 64, `usage:` |

### K: la semántica de salto del test real (bats anidado)

Se ejecuta `bats --tap tests/docker-e2e-qmd.bats -f 'qmd real \(041\)'` con `DOCKER_E2E=1` y los stubs de §2.

| Id | Entorno | Afirma |
| --- | --- | --- |
| K1 | `QMD_EMBED_E2E` sin definir, con valor `0` y vacía | una línea `ok 1 … # skip` con el motivo por defecto (menciona `QMD_EMBED_E2E=1` y el script de obtención); el log de los stubs está vacío: la puerta se abre con el valor 1 y con nada más |
| K2 | `QMD_EMBED_E2E=1`, y también `QMD_EMBED_E2E=0`, con `QMD_EMBED_SKIP_REASON='fase apagada #123'` | `# skip fase apagada #123` en los dos casos; el log de los stubs está vacío |
| K3 | `QMD_EMBED_E2E=1`, sin motivo, sin `QMD_E2E_MODELS_DIR` | `not ok 1 …` con un mensaje que nombra `QMD_E2E_MODELS_DIR`; el log de los stubs está vacío |
| K4 | estático | `qmd real (016): native deps compile with toolchain; RED without it (SC-003)` existe con ese nombre, su cuerpo no contiene `QMD_EMBED_E2E`, y el test `qmd real (041)` es el siguiente del archivo |

### G: guards de identidad (FR-012)

| Id | Afirma |
| --- | --- |
| G1 | `QMD_MODELS_QMD_VERSION` del script es igual a la versión por defecto de `qmd_pkg` (se carga `qmd_index.sh` como en `tests/qmd-version-guard.bats`), y `_qmd_real_ws` de `tests/docker-e2e-qmd.bats` no escribe la versión de qmd como literal: la toma de `qmd_pkg` (research D5) |
| G2 | cada `local_name` de la tabla cumple la regla de data-model §1 para su `repo` y su `file`; una fila cuyo `file` no empieza con el repo sin `-GGUF` hace fallar el test con un mensaje que lo dice (regla no modelada); los `bytes` son enteros positivos y los `sha256` tienen 64 caracteres hexadecimales |
| G3 | `docs/qmd-upgrade-checklist.md` menciona `.github/scripts/fetch-qmd-models.sh`, `QMD_E2E_MODELS_DIR` y `QMD_MODELS_QMD_VERSION`, y trae los dos comandos de la receta del DOCKER_E2E del embed (`QMD_MODELS_DIR=` y `QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=`); además, el encabezado que manda buscar en un log rojo (el texto entre comillas inversas que sigue a «starts with») es una línea que `tests/docker-e2e-qmd.bats` imprime: una checklist que manda buscar algo que el test no escribe no le sirve a quien lee un rojo |

### P: marcas de fase y evidencia al fallar (FR-004)

| Id | Afirma |
| --- | --- |
| P1 | dentro del test `qmd real (041)`: las llamadas a `_embed_phase` nombran las ocho fases de data-model §4, una vez cada una y en ese orden; la ayuda `_embed_phase` imprime por el descriptor 3; entre cada marca y la siguiente (o el final del test) aparecen el ancla de su fase **y las aserciones de su resultado**, según la tabla de abajo; las fases que informan una falla la terminan con `false` justo después del informe; y el cuerpo no contiene `sqlite-vec-linux-arm64` |
| P2 | fuera del cuerpo del test 041 (FR-004; research D18): el `teardown` llama una sola vez a `_embed_failure_state` bajo la guarda de fallo y antes de bajar el proyecto; esa función lee el disco (`df -Pk`), el veredicto del contenedor (`docker inspect`, `OOMKilled`, `RestartCount`) y, con `exec -T -u agent`, `uname -m`, `vec0-libc.sh`, `memory.events` y los tres archivos donde queda la causa de una falla que no es un plazo (`qmd-index.json`, `qmd-reindex.out` y `vsearch.out`); cada sonda tolera el fallo (`\|\| true` en la línea de cada una); y el `_qmd_real_ws` programa el cron de respaldo de qmd el 31 de febrero (`0 0 31 2 *`) y no cada 5 minutos |

Este test es la única red de las aserciones del cuerpo, que no se puede ejecutar sin Docker: una línea borrada de ahí no la notaría ningún otro test. Por eso exige, además del comando que define cada fase (una marca puesta después de su ancla atribuiría la falla a la fase anterior), el texto de lo que esa fase afirma:

| Fase | Ancla (el comando) | Aserciones que debe contener |
| --- | --- | --- |
| `models-seed` | `seed-marker` | `[ "$seeded" -lt 1 ]` |
| `boot` | `docker compose up -d` | `.state/.vault/wiki/` (el vault sembrado bajo `wiki/`) y `[ "$status" -ne 0 ]` |
| `setup` | `.qmd-setup-ok` | `[ "$setup_done" -ne 1 ]`, `grep -q HAVE_MODEL` y `10#` (el plazo del operador se lee en decimal) |
| `vector-extension` | `vec0-libc.sh` | `[ "${output%% *}" = "MUSL" ]` |
| `reindex` | `heartbeatctl qmd-reindex` | `/.vault/wiki/concepts/gatos.md` (la página va bajo `wiki/`), `grep -qE 'ok\|indexed'`, `[ "$output" = "0" ]`, `timeout -k 10 600`, `qmd-reindex did not finish` (un reindex colgado falla esta fase) y `SECONDS - t0` (el informe dice cuántos segundos corrió: un 137 mucho antes del plazo es un kill desde fuera, no un cuelgue) |
| `semantic-search` | `vsearch` | `grep -qi 'gato'`, `timeout -k 10 300`, `vsearch did not finish` y `SECONDS - t0` |
| `mcp` | `qmd-mcp` | `BUG-4 signature` |
| `models-untouched` | `-newer` | `qmd downloaded or rewrote a model` y tres usos de `_embed_note` (las listas `seeded`, `now` y `newer` llevan su `#` en cada línea) |

Total: 36 tests (W 8, F 13, V 6, K 4, G 3, P 2).
