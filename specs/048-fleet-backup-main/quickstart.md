# Quickstart: validar 048

Guía de validación, no de implementación. Los contratos están en `contracts/`; el detalle de datos, en `data-model.md`.

## 1. Host, sin Docker (gate de cada historia)

```bash
# Archivos nuevos o extendidos de 048 (nombres previstos; tasks.md los fija)
bats tests/backup-main-units.bats        # contrato M: layout, commit, carreras, idempotencia, invariantes I1-I7
bats tests/backup-main-legacy.bats       # contrato L: orden del borrado, marcas, L-I1 a L-I4
bats tests/backup-main-pr.bats           # contrato P: servidor de prueba protegido
bats tests/backup-main-restore.bats      # contrato R: main, ramas y mixto
bats tests/agent-repo-sparse.bats        # contrato W
bats tests/token-health-lib.bats tests/token-health-claude-oauth.bats tests/agentctl-doctor-token-health.bats
bats tests/agentctl-doctor-heartbeat.bats  # contrato D3

# No regresión de 046 (deben pasar sin editarse, salvo lo que el contrato D declara)
bats tests/backup-repo-units.bats tests/backup-repo-restore.bats tests/restore-unified.bats tests/restore-from-fork.bats

# Suite completa, en los dos bash, en serie
bats tests/
PATH=/bin:$PATH bats tests/
```

Esperado: 0 `not ok` en los dos; el conteo total es la línea base medida al empezar más las pruebas nuevas.

## 2. Carrera contra `main` (SC-001, SC-002)

La prueba de carrera de `backup-main-units.bats` corre 100 ciclos con un commit ajeno inyectado entre el `fetch` y el `push` (un `git` envoltorio en el `PATH` que empuja un commit al servidor de prueba la primera vez que ve un `push`). Al final:

- todos los commits ajenos son ancestros de `main`;
- `git log --format=%H main` del servidor no muestra ningún commit de respaldo que cambie rutas fuera de `.agent-backup/<u>/`;
- el registro del servidor no muestra ningún empuje forzado.

## 3. Contenedor (`DOCKER_E2E=1`)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-backup-repo.bats   # 046, adaptado a main
DOCKER_E2E=1 bats tests/docker-e2e-backup-main.bats   # 048: cinco unidades a main, migración, clon de trabajo con checkout parcial
```

Esperado: verde en arm64 local; la nocturna amd64 los corre tras el merge.

## 4. Flota (US7)

Ver `contracts/fleet-gate.md`: cbum, ensayo de restauración en la Mac, linus y donna, limpieza. Comprobaciones rápidas por agente:

```bash
docker exec -u agent <agente> heartbeatctl backup-status          # cinco location=main, legacy=deleted
gh api repos/rodrigo-hinojosa/<agente>-workspace-agent-admin/branches --jq '.[].name'   # solo ramas de trabajo
gh api repos/rodrigo-hinojosa/<agente>-workspace-agent-admin/contents/.agent-backup --jq '.[].name'
./scripts/agentctl doctor                                        # sin avisos de Atlassian, heartbeat ni Claude
```
