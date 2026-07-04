# Contract: Reubicación de libs qmd/backup (FR-003, D1)

## Movimientos (git mv, historia preservada)

| Antes (canónico image-baked) | Después (canónico host-side) |
|---|---|
| `docker/scripts/lib/qmd_index.sh` | `scripts/lib/qmd_index.sh` |
| `docker/scripts/lib/backup_vault.sh` | `scripts/lib/backup_vault.sh` |
| `docker/scripts/qmd_watch.sh` | `scripts/qmd_watch.sh` |

Tras el mv, esos paths NO existen bajo `docker/` en el repo (igual que `vault.sh`).

## Espejo en setup.sh (scaffold + regenerate, SOLO modo docker)

Extender el bloque existente (`setup.sh:1501-1535`, junto a `vault.sh` y vault-skeleton):

```bash
cp "$src/scripts/lib/qmd_index.sh"    "$dest/docker/scripts/lib/qmd_index.sh"
cp "$src/scripts/lib/backup_vault.sh" "$dest/docker/scripts/lib/backup_vault.sh"
cp "$src/scripts/qmd_watch.sh"        "$dest/docker/scripts/qmd_watch.sh"
```

- Con validación de presencia + fail-loud, igual que el bloque actual.
- Modo local: NO espeja (no hay árbol docker/), las libs se usan in-place desde `scripts/`.
- Dockerfile: líneas `COPY` EXISTENTES sin cambios (leen el build context `./docker` del workspace, que el espejo puebla).

## Invariantes (tests que lo fijan)

1. `bash -n` y `shellcheck -S error` limpios en los nuevos paths.
2. Los sourcers del contenedor no cambian: `heartbeatctl` y `start_services.sh` siguen sourceando `/opt/agent-admin/scripts/lib/*.sh` (paths de imagen, poblados por COPY del espejo).
3. Tests existentes (`qmd-setup/qmd-index/qmd-watch/backup-vault-*`) SOLO cambian el path de carga (load_lib / source), no aserciones.
4. Scaffold docker produce `docker/scripts/lib/{qmd_index,backup_vault}.sh` y `docker/scripts/qmd_watch.sh` en el destino (test de scaffold), byte-idénticos al canónico (`cmp`).
5. Scaffold local NO produce árbol docker/ (invariante 011 intacta).
6. `DOCKER_E2E=1`: imagen construye y `docker-e2e-qmd.bats` (T035) + `docker-e2e-vault.bats` pasan sin cambio de contrato.

## Cambio aditivo en backup_vault.sh (FR-008, D2)

`vault_resolve_root()` gana un cortocircuito inicial:

```bash
if [ -n "${VAULT_ROOT_OVERRIDE:-}" ]; then printf '%s\n' "$VAULT_ROOT_OVERRIDE"; return 0; fi
```

- Sin la env: comportamiento byte-idéntico (contrato docker fijado por `backup-vault-lib.bats` intacto).
- Test nuevo: con override seteado, devuelve el override literal (sin rebase).
