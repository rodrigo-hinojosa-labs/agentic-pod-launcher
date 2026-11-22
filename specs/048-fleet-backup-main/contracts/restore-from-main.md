# Contract R: restaurar desde `main`, con las ramas como compatibilidad

Cambia `setup.sh` (`restore_from_fork`, `_restore_store_unit`, `_restore_clone_branch`). Todo lo demás del contrato `restore.md` de 046 (R1 a R9: orden, llaves, almacén, reglas de escritura, informe de 046) se conserva.

## R1'. Fuente de cada unidad

1. Un clon por restauración, `git clone --filter=blob:none --depth 1 --no-checkout --branch main`, con checkout parcial de `.agent-backup/<u>` según se necesite. Si `main` no existe o el clon falla, todas las unidades caen al paso 3.
2. Si `.agent-backup/<u>/.agentic-pod-backup.json` existe y su `unit` es `<u>` (y, desde que `config` restauró `agent.yml`, su `agent` es el `agent.name` restaurado): la raíz de la unidad es `.agent-backup/<u>/`.
3. Si no: `_restore_clone_branch <url> backup/<u>` como en 046.
4. Si ninguna existe: la línea de 046 (`no backup/<u> branch ... skipping`), con el texto ampliado a `no backup of <u> in main or in backup/<u> — skipping`.

## R2'. Informe

Cada línea de unidad restaurada termina en `(from main)` o `(from backup/<u>)`. Una marca inválida en `main` produce `⚠ restore: .agent-backup/<u> in main has no valid mark — trying backup/<u>`.

## R3'. Invariantes que prueban los tests

- R-I1: con el mismo contenido, restaurar desde `main` y desde las ramas deja el mismo conjunto de archivos, con los mismos hashes (SC-003).
- R-I2: un repo solo con ramas restaura igual que 046 (los dorados de `restore-unified.bats` y `restore-from-fork.bats` siguen pasando sin editarse).
- R-I3: un repo mixto restaura cada unidad de donde está, y el informe lo dice.
- R-I4: R9 de 046 sigue valiendo sobre la nueva raíz: nada bajo `.git`, nada por un enlace simbólico, lista cerrada para `config`, solo markdown para el vault.
