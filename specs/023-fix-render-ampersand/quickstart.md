# Quickstart — 023-fix-render-ampersand

Cómo reproducir el bug, cómo verificar el arreglo y cómo correr el gate. Todo es
host-runnable: no hace falta Docker ni systemd.

## 1. Reproducir el bug en 30 segundos

Sin tocar el repo, con el propio bash del equipo:

```bash
for B in /bin/bash "$(command -v bash)"; do
  printf '%-24s -> ' "$($B --version | head -1 | awk '{print $4}')"
  $B -c 's="ref={{u}}!"; v="A&B"; echo "${s//\{\{u\}\}/$v}"'
done
```

Esperado **antes** del arreglo:

```
3.2.57(1)-release        -> ref=A&B!        correcto
5.3.15(1)-release        -> ref=A{{u}}B!    corrupto
```

Si tu equipo solo tiene una versión, la de 5.2+ es la que importa. `brew install bash` la
deja en `/opt/homebrew/bin/bash` sin tocar `/bin/bash`.

## 2. Ver el rojo en la suite

```bash
bats tests/render.bats
```

Antes del arreglo, bajo bash ≥5.2, falla el test *"preserves literal `$1` and `\1`"* — un
nombre que **no** menciona el `&` y que apunta al diagnóstico equivocado. Arreglar eso es
la US2.

Bajo bash 3.2 la misma suite da 11/11:

```bash
PATH="/bin:$PATH" bats tests/render.bats
```

**Ese contraste ES el bug de fondo**: el mismo commit, verde o rojo según el intérprete.

## 3. Gate de la feature

Los cuatro deben pasar antes de abrir el PR.

### G1 — la suite, en las dos versiones

```bash
bats tests/                      # con el bash del PATH (5.x)
PATH="/bin:$PATH" bats tests/    # con el bash de stock (3.2)
```

Ambas en **cero fallas** (SC-004). Anotar en el PR con qué versión exacta corrió cada una:

```bash
bats --version; bash --version | head -1; /bin/bash --version | head -1
```

### G2 — la tabla de casos

Los 10 valores del contrato (`contracts/field-substitution.md` §3), cada uno saliendo
idéntico a como entró, en ambas versiones. Prestar atención a **A4 (`\&`)**: hoy en 5.2+
el motor se come el backslash del operador.

### G3 — no-regresión byte a byte

Un `agent.yml` sin ningún `&` debe producir artefactos byte-idénticos a los de antes del
cambio (SC-005, FR-005):

```bash
git stash                      # volver al estado previo
./setup.sh --regenerate        # sobre un workspace de prueba
cp .mcp.json /tmp/antes.mcp.json ; cp .env.example /tmp/antes.env.example
git stash pop
./setup.sh --regenerate
diff /tmp/antes.mcp.json .mcp.json && diff /tmp/antes.env.example .env.example
```

Sin diferencias. Esto es lo que protege a los workspaces ya desplegados.

### G4 — mutación: el test caza el defecto

Reintroducir el defecto a propósito y confirmar que se pone rojo el test **que lo nombra**
(SC-003):

```bash
# revertir un call site a la forma vieja y correr la suite
```

Debe fallar al menos un test cuyo nombre mencione el `&`. Si el único rojo es el test
heredado de `$1`/`\1`, la US2 no está cumplida.

## 4. Lo que NO hace falta

- **DOCKER_E2E**: `render.sh` no está espejado a `docker/` (`find docker -name render.sh`
  vacío, el `Dockerfile` no lo copia). Verificado, no supuesto.
- **Gate de hardware**: nada de esto necesita systemd ni un host de agente. La única
  consulta remota pendiente es informativa (punto 5).

## 5. Pendiente informativo: ferrari

mclaren ya se midió: bash 5.2.37 (reproduce el bug) y `agent.yml` sin valores afectados
(conteo 0). **ferrari sigue sin medir** — el túnel SSH está caído. Cuando vuelva:

```bash
ssh ssh-ferrari 'bash --version | head -1'
# y, sobre su agent.yml, SOLO el conteo — nunca imprimir valores:
ssh ssh-ferrari 'yq -r ".mcps.atlassian[]? | .name, .url, .email" <agent.yml> | grep -c "&"'
```

Si el conteo es 0, no hay datos que remediar y la feature cierra con el arreglo de código.
Si es >0, ese workspace necesita un `--regenerate` **después** de desplegar el arreglo, y
conviene revisar el `.env` generado antes de confiar en él.

## 6. Al desplegar

El arreglo es del renderizador, así que un workspace existente **no se corrige solo**:
hay que correr `./setup.sh --regenerate` en él para que sus artefactos se rehagan. En un
workspace sin `&` eso es un no-op byte-idéntico (G3), así que es seguro correrlo en todos.
