# Contract G: despliegue, ensayo de restauración y limpieza (US7)

Compuertas del operador. Ninguna se ejecuta sin su autorización explícita en el momento.

## G1. Antes del merge

- Suite del host completa en bash 5.x y 3.2, `shellcheck`, y `DOCKER_E2E=1` de los archivos e2e de 046 y 048 en verde.
- CI del PR en verde en los tres checks.
- El merge lo hace el operador.

## G2. cbum (canario)

1. Respaldos previos: `agentic-pod:cbum-pre034`, `~/cbum-pre034-<TS>` (sin `.state`).
2. Swap de archivos del README, `--regenerate`, `printf 'y\n' | ./setup.sh --regenerate --force-claude-md` (el CLAUDE.md de los agentes se preserva si no, y el texto de FR-011 no llegaría), `docker compose build`, stop, 150 s, `agentctl up`.
3. Ciclo de las cinco unidades; luego `backup-status`.
4. Esperado: cinco `location: main`, cinco `legacy: deleted`, `main` del repo con `.agent-backup/` y el README; un segundo ciclo con cinco `no-change`; el doctor sin los tres avisos falsos (SC-009).

## G3. Ensayo de restauración (operador, en la Mac)

```bash
git clone https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git /tmp/apl-restore-test
cd /tmp/apl-restore-test
./setup.sh --restore-from-repo https://github.com/rodrigo-hinojosa/cbum-workspace-agent-admin \
    --identity-key <ruta de la privada del M4> \
    --destination /tmp/cbum-restore-test
```

- Sin `docker compose up` del destino restaurado (cbum sigue vivo en ferrari).
- Verificación (la corre el asistente): el informe dice `(from main)` en las cinco unidades; comparación de nombres y sha256 entre `/tmp/cbum-restore-test` y el workspace vivo de cbum en lo que las cinco unidades cubren, imprimiendo solo conteos y diferencias de nombres, nunca contenidos (SC-011).
- Cierre: borrar `/tmp/cbum-restore-test` y `/tmp/apl-restore-test`.

## G4. linus y donna

Solo con G3 aprobado. Mismo procedimiento que G2, uno por vez; linus y donna requieren `custom-apply --no-regenerate` después del `--force-claude-md` (bloque de reglas de trabajo en CLAUDE.md, y en donna además el overlay de MCP), y se comprueba que el bloque `BEGIN overlay` y los MCP del overlay siguen presentes. Verificar además que todos los commits previos de su `main` siguen siendo ancestros de la punta (SC-005).

## G5. Limpieza (SC-012)

Con los tres en G2/G4 verificados y la autorización del operador:

- ferrari: `~/<agente>-pre033-*`, `~/<agente>-pre034-*`, imágenes `agentic-pod:<agente>-pre033` y `-pre034`, `~/old-clones-20261121/`, `~/ferrari-preUpgrade-v033-*`.
- mclaren: `~/mclaren-preUpgrade-v033-*`.
- Cada borrado se registra en `tasks.md` con fecha, ruta y tamaño.

## G6. Reversión

Si G2 o G4 fallan: `docker tag agentic-pod:<agente>-pre034 agentic-pod:<agente>`, restaurar archivos desde `~/<agente>-pre034-*`, stop, 150 s, up. Las ramas `backup/*` que el launcher ya borró no se recuperan desde el launcher; por eso G2 corre en cbum y G3 antes de los demás.
