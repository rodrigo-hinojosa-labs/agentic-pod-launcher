# Contrato: toolchain de la imagen (gateado por build-arg)

`docker/Dockerfile` gana un toolchain C/C++ que persiste en la imagen final, gateado por un build-arg para permitir el test de detección RED.

## Comportamiento esperado

1. **Build-arg**: `ARG QMD_NATIVE_TOOLCHAIN=1` (default 1).
2. **Instalación condicional** (en la etapa final, single-stage):
   ```dockerfile
   RUN if [ "$QMD_NATIVE_TOOLCHAIN" = "1" ]; then \
         apk add --no-cache build-base cmake git linux-headers libgomp; \
       fi
   ```
3. **bigstack.so**: `COPY docker/bigstack.c ...` + `RUN gcc -shared -fPIC -o /opt/agent-admin/bigstack.so bigstack.c -ldl` (requiere el toolchain; si `QMD_NATIVE_TOOLCHAIN=0` este build también se saltea o falla-controlado — decidir en tasks: idealmente el bigstack se compila solo cuando el toolchain está).
4. **Plumbing** (Principle VI): `modules/docker-compose.yml.tpl` pasa `build.args.QMD_NATIVE_TOOLCHAIN` (default 1) para que el build documentado pueda overridearlo; no hardcode-only.

## Invariantes verificables

- Con `QMD_NATIVE_TOOLCHAIN=1`: `command -v cmake gcc g++ make` dentro del contenedor devuelve rutas; `/opt/agent-admin/bigstack.so` existe.
- Con `QMD_NATIVE_TOOLCHAIN=0`: no hay compilador → el reindex/embed falla (base del test de detección RED).
- La imagen sigue Alpine single-stage (sin `FROM ... AS builder`). Principle II sin cambios.
- No se agrega pin duplicado: la versión del toolchain la fija `alpine:3.24.1`.

## Notas

- `openssl-dev` NO se agrega (node-llama-cpp fuerza LLAMA_CURL/HTTPLIB/OPENSSL=OFF).
- Documentar el costo de tamaño en el Complexity Tracking del plan (ya registrado).
