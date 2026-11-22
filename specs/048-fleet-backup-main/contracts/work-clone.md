# Contract W: el clon de trabajo esquiva `.agent-backup/`

Cambia `docker/scripts/lib/agent_repo.sh` (`_agent_repo_settings` y `_agent_repo_create`) y `modules/claude-md.tpl` (sección *Your repository*).

## W1. Ajustes, aplicados al crear y en cada reparación

1. Checkout parcial no cono: `core.sparseCheckout=true`, `core.sparseCheckoutCone=false`, patrón `/*` y `!/.agent-backup/` en `.git/info/sparse-checkout`; `git sparse-checkout reapply` si el clon ya tenía archivos de `.agent-backup/` en el árbol (no borra nada fuera de ese directorio).
2. Filtro: `remote.origin.promisor=true`, `remote.origin.partialclonefilter=blob:none`. La creación usa `--filter=blob:none`.
3. Hook `pre-commit`: escrito por el launcher con la línea `# agentic-pod-launcher: agent-backup guard`. Rechaza (rc 1) si `git diff --cached --name-only` contiene una ruta bajo `.agent-backup/`, con el mensaje `.agent-backup/ belongs to the launcher's backups - unstage it (git restore --staged .agent-backup)`. Si existe un `pre-commit` sin esa línea, no se toca y se registra en `agent-repo.log`.

Los dos ajustes de 046 (refspec negativo de `backup/*`, helper de credencial por servidor) se conservan.

## W2. Texto para el agente (FR-011)

La sección *Your repository* de `modules/claude-md.tpl` cambia el párrafo de respaldo por: los respaldos del launcher viven en `main` bajo `.agent-backup/`; el clon de trabajo no lo muestra; no se edita ni se borra; trabajar en ramas de features y en `main` como siempre. Debe quedar en ASCII, como el resto de la plantilla.

## W3. Invariantes que prueban los tests

- W-I1: tras `agent_repo_ensure` sobre un remoto con `.agent-backup/`, `ls /workspace/agent-repo/.agent-backup` no existe y los archivos de trabajo sí.
- W-I2: un `git add -A && git commit` del agente con cambios de trabajo no toca `.agent-backup/` en el commit.
- W-I3: un `git add -f .agent-backup/x` seguido de `git commit` es rechazado por el hook.
- W-I4: un hook `pre-commit` ajeno no se reemplaza.
- W-I5: con fork o sin destino, `agent_repo_ensure` no hace nada (046).
