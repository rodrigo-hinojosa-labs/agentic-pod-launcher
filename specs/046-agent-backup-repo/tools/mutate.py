#!/usr/bin/env python3
"""T068 de 046: el corredor de mutaciones (molde de 045).

Para cada fila: copia el arbol del worktree (sin .git, con los archivos sin rastrear)
a <scratchpad>/046/mut/<Id>/, le hace `git init` (TU31 lista docker/scripts con git
ls-files), aplica UNA variante (reemplazos exactos; error si un ancla no aparece el
numero de veces esperado), corre SOLO las pruebas nombradas en bash 5.x y con
PATH=/bin:$PATH (bash 3.2), anota que pruebas cayeron y borra la copia.

M0 es el codigo de origin/main (<scratchpad>/046/base) con las pruebas finales de la
rama: corren las seis suites nuevas enteras.

Uso:
  mutate.py --check              valida todas las anclas contra el worktree
  mutate.py [--only M1,M2] [--from M10] [--timeout 900]
Resultados: <scratchpad>/046/mutations/<Id>.json y results.md.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

S = os.environ.get("BR046_WORK", os.path.join(os.path.expanduser("~"), ".cache", "agentic-046"))
W = os.environ.get("BR046_REPO", os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")))
BASE = os.path.join(S, "base")
OUT = os.path.join(S, "mutations")
MUT = os.path.join(S, "mut")

FILES = {
    "TD": "tests/backup-dest.bats",
    "TS": "tests/backup-store.bats",
    "TU": "tests/backup-repo-units.bats",
    "TR": "tests/backup-repo-restore.bats",
    "TA": "tests/agent-repo-surface.bats",
    "TB": "tests/backup-status.bats",
}

BD = "docker/scripts/lib/backup_dest.sh"
HB = "docker/scripts/heartbeatctl"
BI = "docker/scripts/lib/backup_identity.sh"
BV = "scripts/lib/backup_vault.sh"
BC = "docker/scripts/lib/backup_config.sh"
BM = "docker/scripts/lib/backup_memory.sh"
BH = "docker/scripts/lib/backup_history.sh"
AR = "docker/scripts/lib/agent_repo.sh"
PY = "docker/scripts/backup_store.py"
SS = "docker/scripts/start_services.sh"
SU = "setup.sh"
AC = "scripts/agentctl"
SC = "scripts/lib/schema.sh"
WV = "scripts/lib/wizard-validators.sh"
ASK = "docker/scripts/git-askpass-agent.sh"
DF = "docker/Dockerfile"
TPL = "modules/claude-md.tpl"

RE_GH = r"""local re_gh='^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]*/([A-Za-z0-9._-]+)$'"""
RE_ANY = r"""local re_gh='^https://[^/]+/[A-Za-z0-9][A-Za-z0-9-]*/([A-Za-z0-9._-]+)$'"""


def nochange_guard(unit):
    return (r'  if [ -n "$last_hash" ] && [ "$current_hash" = "$last_hash" ]; then echo "backup-' + unit
            + r': no changes since last backup (hash $last_hash)"; _repo_end; return 0; fi' + "\n")


# Cada fila: (id, descripcion, [(archivo, ancla, reemplazo[, veces])], [pruebas])
M = [
    ("M1", "backup_dest_resolve nunca responde repo", [
        (BD, '  if [ -n "$repo" ]; then\n    printf \'repo', '  if false; then\n    printf \'repo'),
    ], ["TD01", "TU01"]),
    ("M2", "con fork y repositorio, la regla prefiere el fork", [
        (BD, r"""  if [ -n "$repo" ]; then
    printf 'repo\t%s\n' "$repo"
  elif [ -n "$fork" ]; then
    printf 'fork\t%s\n' "$fork"
""", r"""  if [ -n "$fork" ]; then
    printf 'fork\t%s\n' "$fork"
  elif [ -n "$repo" ]; then
    printf 'repo\t%s\n' "$repo"
"""),
    ], ["TD01"]),
    ("M3", "con solo fork, la regla responde none", [
        (BD, '  elif [ -n "$fork" ]; then\n    printf \'fork', '  elif false; then\n    printf \'fork'),
    ], ["TD02"]),
    ("M4", "un null (o una clave ausente) cuenta como URL: sin // y sin el filtro null", [
        (BD, """    repo=$(yq -r '.backup.repo.url // ""' "$f" 2>/dev/null) || repo=\"\"""",
         """    repo=$(yq -r '.backup.repo.url' "$f" 2>/dev/null) || repo=\"\""""),
        (BD, '  [ "$repo" = "null" ] && repo=""\n', ''),
    ], ["TD03"]),
    ("M5", "el askpass siempre es /bin/true", [
        (BD, """    printf '%s\\n' "${BACKUP_ASKPASS_OVERRIDE:-/opt/agent-admin/scripts/git-askpass-agent.sh}\"""",
         """    printf '/bin/true\\n'"""),
    ], ["TD04", "TD06", "TU01"]),
    ("M6", "el askpass responde la contrasena vacia", [
        (ASK, """  Password*) printf '%s\\n' "${GITHUB_PAT:-}" ;;""", """  Password*) printf '\\n' ;;"""),
    ], ["TD05", "TU01"]),
    ("M7", "la consulta autenticada pone la credencial en la URL y la guarda en el registro", [
        (BD, r"""  local heads="${heads_out:-$hb/.backup-dest.heads.$$}" arc=0""",
         r"""  local heads="${heads_out:-$hb/.backup-dest.heads.$$}" arc=0
  local curl="${url%%://*}://x-access-token:${GITHUB_PAT:-}@${url#*://}" """),
        (BD, r"""    git -c credential.helper= ls-remote --heads "$url" > "$heads" 2> /dev/null < /dev/null || arc=$?""",
         r"""    git -c credential.helper= ls-remote --heads "$curl" > "$heads" 2> /dev/null < /dev/null || arc=$?"""),
        (BD, '  _backup_dest_write_record "$url" "$verdict" "$now" "$anon_epoch"',
         '  _backup_dest_write_record "$curl" "$verdict" "$now" "$anon_epoch"'),
    ], ["TD14"]),
    ("M8", "se omite la sonda anonima", [
        (BD, r"""  if [ "$prev_url" = "$url" ] && [ "$prev_verdict" = "private" ] \
     && _backup_dest_is_uint "$prev_anon" && [ $((now - prev_anon)) -lt 86400 ] \
     && [ $((now - prev_anon)) -ge 0 ]; then""", "  if true; then"),
    ], ["TD07", "TU15"]),
    ("M9", "se empuja con el veredicto public", [
        (HB, "    private|unverified-allowed)\n      _REPO_REMOTE_HEAD", "    private|unverified-allowed|public)\n      _REPO_REMOTE_HEAD"),
    ], ["TU15"]),
    ("M10", "una sonda anonima que falla por otra razon cuenta como privada", [
        (BD, '      anon="unknown"', '      anon="auth-required"'),
    ], ["TD16"]),
    ("M11", "allow_unverified habilita un repositorio publico", [
        (BD, '    if [ "$rc" -eq 0 ]; then\n      rm -f "$err"', '    if [ "$rc" -eq 0 ] && ! _backup_dest_allow_unverified; then\n      rm -f "$err"'),
    ], ["TD17"]),
    ("M12", "allow_unverified salta la sonda anonima", [
        (BD, '  local anon="" anon_epoch=""\n  if [ "$prev_url" = "$url" ]',
         '  local anon="" anon_epoch=""\n  if _backup_dest_allow_unverified; then\n    anon="unknown"; anon_epoch=0\n  elif [ "$prev_url" = "$url" ]'),
    ], ["TD09"]),
    ("M13", "el veredicto guardado nunca vence", [
        (BD, '[ $((now - prev_anon)) -lt 86400 ]', 'true'),
    ], ["TD10"]),
    ("M14", "el plazo de la sonda se cuenta desde la ultima corrida", [
        (BD, '    anon_epoch="$prev_anon"', '    anon_epoch="$now"'),
    ], ["TD10"]),
    ("M15", "un veredicto que no es private se guarda y se reutiliza", [
        (BD, '[ "$prev_verdict" = "private" ]', '[ -n "$prev_verdict" ]'),
    ], ["TD16", "TU22"]),
    ("M16", "una consulta autenticada que falla cuenta como alcanzable", [
        (BD, '  if [ "$arc" -ne 0 ]; then\n    verdict="unreachable"', '  if false; then\n    verdict="unreachable"'),
    ], ["TD08", "TU14"]),
    ("M17", "la regla de la URL de la libreria acepta otro servidor", [(BD, RE_GH, RE_ANY)], ["TD11"]),
    ("M18", "la regla de la URL del esquema acepta otro servidor", [(SC, RE_GH, RE_ANY)], ["TA05"]),
    ("M19", "el validador del wizard acepta otro servidor", [(WV, RE_GH, RE_ANY)], ["TA03"]),
    ("M20", "una consulta no tiene tope", [
        (BD, '    timeout -k 10 "$secs" "$@" 9>&-', '    "$@" 9>&-'),
    ], ["TD18"]),
    ("M21", "backup_dest_branch_head no mira la rama pedida", [
        (BD, """awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }'""",
         """awk -v ref="refs/heads/$branch" '{ print $1; exit }'"""),
    ], ["TD15"]),
    ("M22", "no se comprueba la marca de pertenencia (toda rama existente es ok)", [
        (BD, "    printf 'new\\n'\n    return 0\n  fi\n", "    printf 'new\\n'\n    return 0\n  fi\n  printf 'ok\\n'; return 0\n"),
    ], ["TD12", "TU17"]),
    ("M23", "no se compara el agente que nombra la marca", [
        (BD, '  elif [ "$a" = "$agent" ] && [ "$u" = "$unit" ]; then', '  elif [ "$u" = "$unit" ]; then'),
    ], ["TD12", "TU18"]),
    ("M24", "ninguna unidad escribe la marca", [
        (BI, '  backup_dest_mark_json "$agent" identity > "$dir/.agentic-pod-backup.json" || return 3', '  :'),
        (BV, '  backup_dest_mark_json "$agent" vault > "$dir/.agentic-pod-backup.json" || return 3', '  :'),
        (BC, '  backup_dest_mark_json "$agent" config > "$dir/.agentic-pod-backup.json" || return 3', '  :'),
        (BM, '  backup_dest_mark_json "$agent" memory > "$dir/.agentic-pod-backup.json" || return 3', '  :'),
        (BH, '  backup_dest_mark_json "$agent" history > "$dir/.agentic-pod-backup.json" || return 3', '  :'),
    ], ["TU01", "TU23"]),
    ("M25", "el registro del intento reemplaza el estado en vez de fusionar", [
        (BD, "'. + {last_attempt:$iso,", "'{last_attempt:$iso,"),
    ], ["TD13"]),
    ("M26", "no se comprueba que exista la credencial", [
        (HB, '  if [ -z "${GITHUB_PAT:-}" ]; then\n    _repo_fail "$unit" no-credential', '  if false; then\n    _repo_fail "$unit" no-credential'),
    ], ["TU13"]),
    ("M27", "un ciclo sin cambios de contenido no consulta al destino (las cinco unidades)", [
        (HB, '  _repo_verify identity "$url" "$current_hash" "$base/identity-repo.heads" || return "$_REPO_RC"',
         nochange_guard("identity") + '  _repo_verify identity "$url" "$current_hash" "$base/identity-repo.heads" || return "$_REPO_RC"'),
        (HB, '  _repo_verify vault "$url" "$current_hash" "$base/vault-repo.heads" || return "$_REPO_RC"',
         nochange_guard("vault") + '  _repo_verify vault "$url" "$current_hash" "$base/vault-repo.heads" || return "$_REPO_RC"'),
        (HB, '  _repo_verify config "$url" "$current_hash" "$base/config-repo.heads" || return "$_REPO_RC"',
         nochange_guard("config") + '  _repo_verify config "$url" "$current_hash" "$base/config-repo.heads" || return "$_REPO_RC"'),
        (HB, '  _repo_verify "$unit" "$url" "$current_hash" "$base/$unit-repo.heads" || return "$_REPO_RC"',
         nochange_guard("$unit") + '  _repo_verify "$unit" "$url" "$current_hash" "$base/$unit-repo.heads" || return "$_REPO_RC"'),
    ], ["TU23", "TU26"]),
    ("M28", "el hash no se guarda despues de un empuje (identity)", [
        (HB, '  identity_repo_write_state "$IDENTITY_BACKUP_STATE_FILE" "$current_hash" "$mode" "$sha" "$(_repo_now_iso)"',
         '  identity_repo_write_state "$IDENTITY_BACKUP_STATE_FILE" "" "$mode" "$sha" "$(_repo_now_iso)"'),
    ], ["TU02"]),
    ("M29", "--gc con repositorio sigue leyendo solo el fork", [
        (HB, '  if _dest_url=$(_repo_dest_url); then\n    local _c="${IDENTITY_BACKUP_CACHE_DIR',
         '  if false; then\n    local _c="${IDENTITY_BACKUP_CACHE_DIR'),
    ], ["TU02"]),
    ("M30", "el estado no se completa cuando el arbol es identico", [
        (HB, '    identity_repo_write_state "$IDENTITY_BACKUP_STATE_FILE" "$current_hash" "$mode" "$_REPO_REMOTE_HEAD" "$push"', '    :'),
        (HB, '    vault_repo_write_state "$VAULT_BACKUP_STATE_FILE" "$current_hash" "$_REPO_REMOTE_HEAD" "$push" "$store_recip"', '    :'),
        (HB, '    config_repo_write_state "$CONFIG_BACKUP_STATE_FILE" "$current_hash" "$_REPO_REMOTE_HEAD" "$push" "$store_recip"', '    :'),
        (HB, '    "${unit}_repo_write_state" "$state" "$current_hash" "$_REPO_REMOTE_HEAD" "$push" "$store_recip"', '    :'),
    ], ["TU33"]),
    ("M31", "identity empuja con --mirror", [
        (BI, '  _identity_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/identity > /dev/null 2>&1 || return 2',
         '  _identity_repo_git -C "$dir" push -q --mirror origin > /dev/null 2>&1 || return 2'),
    ], ["TU03"]),
    ("M32", "se quita el candado", [
        (BD, '  command -v flock > /dev/null 2>&1 || return 0\n  hb=$(_backup_dest_hb_dir)', '  return 0\n  hb=$(_backup_dest_hb_dir)'),
    ], ["TU37"]),
    ("M33", "el git de identity (repo) no tiene tope", [
        (BI, '    timeout -k 10 "$secs" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\', '    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\'),
    ], ["TU36"]),
    ("M34", "el git de vault (repo) no tiene tope", [
        (BV, '    timeout -k 10 "$secs" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\', '    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\'),
    ], ["TU36"]),
    ("M35", "el git de identity (repo) honra la configuracion global", [
        (BI, 'GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git "$@" 9>&-', 'GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git "$@" 9>&-', 2),
    ], ["TU38"]),
    ("M36", "identity vuelve a leer el archivo de secretos del directorio de estado", [
        (BI, """    printf '%s/.env\\n' "$workspace\"""", """    printf '%s/.env\\n' "$state_dir\""""),
    ], ["TU24"]),
    ("M37", "el supervisor calcula el hash de identity con la ruta del fork", [
        (SS, '  if [ "$dtype" = "repo" ] && command -v identity_secrets_file >/dev/null 2>&1; then', '  if false; then'),
    ], ["TU25"]),
    ("M38", "el supervisor no espera tras un intento fallido", [
        (SS, '           && [ $((nowc - le)) -lt "$retry" ]; then', '           && false; then'),
    ], ["TU34"]),
    ("M39", "el disparador conserva el tope de 90 s con repositorio", [
        (SS, "      repo$'\\t'*) _cap=(-k 10 300) ;;", "      repo$'\\t'*) _cap=(90) ;;"),
    ], ["TU34"]),
    ("M40", "un registro sin hash conserva el attempt_hash anterior", [
        (BD, "attempt_hash:$attempted}'", "attempt_hash:(if $attempted == \"\" then (.attempt_hash // \"\") else $attempted end)}'"),
    ], ["TU34"]),
    ("M41", "un estado ilegible hace fallar a _check_identity_backup (sin || true)", [
        (SS, """    lr=$(jq -r '.last_result // ""' "$state_file" 2>/dev/null || true)""",
         """    lr=$(jq -r '.last_result // ""' "$state_file" 2>/dev/null)"""),
    ], ["TU34"]),
    ("M42", "--configure-key no muestra la huella", [
        (HB, '    echo "backup-identity: key fingerprint $_fp (${_comment:-no comment})"', '    :'),
    ], ["TU32"]),
    ("M43", "falta la linea diaria de identity con repositorio", [
        (HB, '    if [ "$bi_enabled" != "false" ]; then\n      backup_line=', '    if [ "$bi_enabled" = "true" ]; then\n      backup_line='),
    ], ["TU29"]),
    ("M44", "el crontab gana las lineas de memory y history sin repositorio", [
        (HB, '  if [ "$bi_dest" = "repo" ]; then\n    local _ru _ru_en _ru_sched', '  if true; then\n    local _ru _ru_en _ru_sched'),
    ], ["TU21"]),
    ("M45", "falta la linea COPY de backup_dest.sh", [
        (DF, 'COPY scripts/lib/backup_dest.sh      /opt/agent-admin/scripts/lib/backup_dest.sh\n', ''),
    ], ["TU31"]),
    ("M46", "config se amplia tambien con fork (CLAUDE.md y personas)", [
        (BC, '  cp -a "$agent_yml" "$stage/agent.yml"\n',
         '  cp -a "$agent_yml" "$stage/agent.yml"\n'
         '  [ -f "$(dirname "$agent_yml")/CLAUDE.md" ] && cp -a "$(dirname "$agent_yml")/CLAUDE.md" "$stage/CLAUDE.md"\n'
         '  [ -d "$(dirname "$agent_yml")/personas" ] && cp -a "$(dirname "$agent_yml")/personas" "$stage/"\n'),
    ], ["TU05"]),
    ("M47", "el fork recibe la marca", [
        (BI, '  git -C "$stage" add -A\n', '  backup_dest_mark_json agent identity > "$stage/.agentic-pod-backup.json"\n  git -C "$stage" add -A\n'),
    ], ["TU20"]),
    ("M48", "el fork recibe el askpass", [
        (BI, 'GIT_ASKPASS=/bin/true git "$@"', 'GIT_ASKPASS="$(backup_dest_askpass repo)" git "$@"', 2),
    ], ["TU20"]),
    ("M49", "el estado gana el registro del intento con fork o sin destino", [
        (HB, '  if [ -z "$fork_url" ]; then\n    echo "backup-identity: agent.yml has no scaffold.fork.url',
         '  if [ -z "$fork_url" ]; then\n    backup_dest_record identity none\n    echo "backup-identity: agent.yml has no scaffold.fork.url'),
        (HB, '''  printf 'backup-identity: %s pushed (%s)\\n' "${sha:0:8}" "$mode"
}

_bi_configure_key''', '''  backup_dest_record identity ok "$current_hash"
  printf 'backup-identity: %s pushed (%s)\\n' "${sha:0:8}" "$mode"
}

_bi_configure_key'''),
    ], ["TU19", "TU20"]),
    ("M50", "un agente sin destino escribe backup-dest.json", [
        (HB, '  if [ -z "$fork_url" ]; then\n    echo "backup-identity: agent.yml has no scaffold.fork.url',
         '  if [ -z "$fork_url" ]; then\n    backup_dest_verify "" > /dev/null\n    echo "backup-identity: agent.yml has no scaffold.fork.url'),
    ], ["TU19"]),
    ("M51", "unpack escribe los bloques sin descomprimirlos", [
        (PY, '                    chunk = gzip.decompress(plain)', '                    chunk = plain'),
    ], ["TS01", "TS02", "TS04"]),
    ("M52", "un archivo vacio queda fuera del manifiesto", [
        (PY, '        data, mode = files[path]\n', '        data, mode = files[path]\n        if not data:\n            continue\n'),
    ], ["TS03"]),
    ("M53", "no se restauran los permisos", [
        (PY, '                os.chmod(staged, int(str(entry.get("mode") or "600"), 8) & 0o777)', '                pass'),
    ], ["TS04"]),
    ("M54", "pack vuelve a cifrar bloques que ya existen", [
        (PY, '            if not name or not os.path.isfile(block_path(store, name)):', '            if True:'),
    ], ["TS05", "TS06", "TU12"]),
    ("M55", "pack deja bloques sin referencia", [
        (PY, '                if not name.endswith(".age") or name[:-4] not in referenced:', '                if False:'),
    ], ["TS07"]),
    ("M56", "pack deja un temporal en claro dentro del almacen", [
        (PY, '                atomic_write(block_path(store, name), enc)\n',
         '                atomic_write(block_path(store, name), enc)\n                atomic_write(os.path.join(store, ".tmp-" + psha[:8]), chunk)\n'),
    ], ["TS08"]),
    ("M57", "el manifiesto se escribe en claro", [
        (PY, '    enc = run_age(["-r", recipient], data=json.dumps(manifest, sort_keys=True).encode("utf-8"))',
         '    enc = json.dumps(manifest, sort_keys=True).encode("utf-8")'),
    ], ["TS09"]),
    ("M58", "unpack deja salida parcial cuando age falla (una marca de progreso en --dest)", [
        (PY, '    stage = tempfile.mkdtemp(prefix="stage-", dir=work)\n    try:\n',
         '    stage = tempfile.mkdtemp(prefix="stage-", dir=work)\n    os.makedirs(a.dest, exist_ok=True)\n'
         '    open(os.path.join(a.dest, ".unpack-in-progress"), "w").close()\n    try:\n'),
        (PY, '        print(json.dumps({"files": len(planned), "verified": len(planned)}, sort_keys=True))',
         '        os.unlink(os.path.join(a.dest, ".unpack-in-progress"))\n'
         '        print(json.dumps({"files": len(planned), "verified": len(planned)}, sort_keys=True))'),
    ], ["TS10"]),
    ("M59", "unpack no verifica el hash", [
        (PY, '                if hashlib.sha256(raw).hexdigest() != name:', '                if False:'),
        (PY, '                if hashlib.sha256(chunk).hexdigest() != psha:', '                if False:'),
        (PY, '            if len(data) != entry.get("size") or hashlib.sha256(bytes(data)).hexdigest() != entry.get("sha256"):',
         '            if False:'),
    ], ["TS11"]),
    ("M60", "unpack acepta una ruta con ..", [
        (PY, '        if seg in ("", ".", "..") or seg.lower() == ".git":',
         '        if seg in ("", ".") or seg.lower() == ".git":'),
        (PY, '    if os.path.commonpath([root, target]) != root:', '    if False:'),
    ], ["TS12", "TR12"]),
    ("M61", "se quita la regla de las lineas completas", [
        (PY, '    if logical.endswith(".jsonl"):', '    if False:'),
    ], ["TS13", "TU11"]),
    ("M62", "la base SQLite se copia en bruto", [
        (PY, '    if is_sqlite(source):', '    if False:'),
    ], ["TS14", "TU10"]),
    ("M63", "digest ignora --extra", [
        (PY, '    print(unit_digest(entries, a.extra))', '    print(unit_digest(entries, ""))'),
    ], ["TS15"]),
    ("M64", "fingerprint calcula sobre la linea entera", [
        (PY, '    digest = hashlib.sha256(blob).digest()', '    digest = hashlib.sha256(pubkey_line.strip().encode("utf-8")).digest()'),
    ], ["TS16"]),
    ("M65", "un error de sintaxis en la herramienta", [
        (PY, 'BLOCK_SIZE = 1048576\n', 'BLOCK_SIZE = 1048576 +\n'),
    ], ["TS17"]),
    ("M66", "una base SQLite con otro nombre se empaqueta en bruto", [
        (PY, '    if is_sqlite(source):', '    if logical.endswith(".db") and is_sqlite(source):'),
    ], ["TS18"]),
    ("M67", "no hay rotacion al cambiar la llave del operador", [
        (PY, '    elif read_text(os.path.join(store, "operator")) != operator_fp:', '    elif False:'),
    ], ["TS19"]),
    ("M68", "unpack usa la llave del operador en cada bloque", [
        (PY, '                plain = run_age_data(["-d", "-i", keyfile], raw, "a block (%s)" % path)',
         '                run_age(["-d", "-i", a.identity, key_age])\n                plain = run_age_data(["-d", "-i", keyfile], raw, "a block (%s)" % path)'),
    ], ["TS20"]),
    ("M69", "unpack deja la llave de datos en un archivo", [
        (PY, '        try:\n            os.unlink(keyfile)\n        except OSError:\n            pass\n', '        pass\n'),
    ], ["TS20"]),
    ("M70", "se ignora --expect-recipient", [
        (PY, '    elif a.expect_recipient is not None and a.expect_recipient != recipient:', '    elif False:'),
    ], ["TS21"]),
    ("M71", "el hash de una unidad con almacen no incluye la llave del operador", [
        (HB, '    --extra "sensitive=$3 $4"\n', '    --extra "sensitive=$3"\n'),
    ], ["TU40"]),
    ("M72", "una unidad no le pasa --expect-recipient a pack", [
        (HB, '  [ -n "$expect" ] && args+=(--expect-recipient "$expect")', '  :'),
    ], ["TU40"]),
    ("M73", "digest --list informa el tamano del archivo vivo", [
        (PY, '''    if a.list:
        for path, size, sha in entries:
            sys.stdout.write("%s\\t%d\\t%s\\n" % (path, size, sha))''', '''    if a.list:
        srcs = dict(read_map(a.map))
        for path, size, sha in entries:
            sys.stdout.write("%s\\t%d\\t%s\\n" % (path, os.path.getsize(srcs[path]), sha))'''),
    ], ["TS22"]),
    ("M74", "la persona queda fuera de config", [
        (BC, '      case "${f##*/}" in *.bak*) continue ;; esac\n      _cfg_add "$rel" "$f"', '      case "${f##*/}" in *.bak*) continue ;; esac\n      :'),
    ], ["TU04"]),
    ("M75", "config incluye todo el directorio .claude/", [
        (BC, '''  for item in skills commands agents hooks output-styles; do
    [ -d "$ws/.claude/$item" ] || continue
    while IFS= read -r -d '' f; do
      rel="${f#"$ws"/}"
      _cfg_add "$rel" "$f"
    done < <(find "$ws/.claude/$item" -name .git -prune -o -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  done''', '''  if [ -d "$ws/.claude" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$ws"/}"
      [ "$rel" = .claude/settings.json ] && continue
      _cfg_add "$rel" "$f"
    done < <(find "$ws/.claude" -name .git -prune -o -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  fi'''),
    ], ["TU27"]),
    ("M76", "con la marca de datos sensibles, la configuracion queda en claro", [
        (BC, '    if [ "${3:-}" = "plain" ] || [ "$sensitive" != "true" ]; then target="$plain"; fi', '    target="$plain"'),
    ], ["TU35"]),
    ("M77", "el vault va siempre al almacen", [
        (HB, '''  sensitive=$(_repo_sensitive)
  recipient=$(_yq '.backup.identity.recipient')
  if [ "$sensitive" = "true" ]; then
    # U4''', '''  sensitive=true
  recipient=$(_yq '.backup.identity.recipient')
  if [ "$sensitive" = "true" ]; then
    # U4'''),
    ], ["TU06"]),
    ("M78", "con la marca, el vault queda en claro", [
        (HB, '''  sensitive=$(_repo_sensitive)
  recipient=$(_yq '.backup.identity.recipient')
  if [ "$sensitive" = "true" ]; then
    # U4''', '''  sensitive=false
  recipient=$(_yq '.backup.identity.recipient')
  if [ "$sensitive" = "true" ]; then
    # U4'''),
    ], ["TU07"]),
    ("M79", "con la marca y un fork, el vault se empuja en claro", [
        (HB, '''  if [ "$(_yq '.backup.sensitive')" = "true" ] && [ -n "$(_yq '.scaffold.fork.url')" ]; then''', '  if false; then'),
    ], ["TU07"]),
    ("M80", "claude-mem va en claro", [
        (BM, '''      rel="claude-mem/${f#"$state"/.claude-mem/}"
      printf '%s\\0%s\\0' "$rel" "$f" >> "$store"''', '''      rel="claude-mem/${f#"$state"/.claude-mem/}"
      printf '%s\\0%s\\0' "$rel" "$f" >> "$plain"'''),
    ], ["TU08"]),
    ("M81", "el hash de memory ignora la auto-memoria", [
        (BM, '''        printf '%s\\0%s\\0' "$rel" "$f" >> "$target"
        printf '%s\\0%s\\0' "$rel" "$f" >> "$all"''', '''        printf '%s\\0%s\\0' "$rel" "$f" >> "$target"'''),
    ], ["TU08"]),
    ("M82", "con la marca, la auto-memoria queda en claro", [
        (BM, '        if [ "$sensitive" = "true" ]; then target="$store"; else target="$plain"; fi', '        target="$plain"'),
    ], ["TU09"]),
    ("M83", "el historial va en claro", [
        (HB, '''  _repo_store_unit history "$url" "$h" "$HISTORY_BACKUP_STATE_FILE" "$base" "" \\
    "$base/history-repo.map" "$recipient"''', ''': > "$base/history-repo.none"
  _repo_store_unit history "$url" "$h" "$HISTORY_BACKUP_STATE_FILE" "$base" "$base/history-repo.map" \\
    "$base/history-repo.none" "$recipient"'''),
    ], ["TU11"]),
    ("M84", "sin llave publica, memory sube lo cifrable en claro", [
        (HB, '''  if [ -s "$base/memory-repo.map" ] && [ -z "$recipient" ]; then
    _repo_fail memory no-recipient
    return "$_REPO_RC"
  fi''', '''  if [ -s "$base/memory-repo.map" ] && [ -z "$recipient" ]; then
    cat "$base/memory-repo.map" >> "$base/memory-repo.plain"
    : > "$base/memory-repo.map"
  fi'''),
    ], ["TU16"]),
    ("M85", "una ruta adicional con .. se acepta", [
        (BM, '''    if [ "$seg" = ".." ]; then printf 'not relative\\n'; return 1; fi''', '    :'),
    ], ["TU28"]),
    ("M86", "una ruta adicional viaja en claro", [
        (BM, '''        rel="extra/${f#"$ws"/}"
        printf '%s\\0%s\\0' "$rel" "$f" >> "$store"''', '''        rel="extra/${f#"$ws"/}"
        printf '%s\\0%s\\0' "$rel" "$f" >> "$plain"'''),
    ], ["TU28"]),
    ("M87", "una ruta adicional bajo .state/.cache se acepta", [
        (BM, "    ''|.|.state|.state/.cache|.state/.cache/*|agent-repo|agent-repo/*|.restore-tmp|.restore-tmp/*)",
         "    ''|.|.state|agent-repo|agent-repo/*|.restore-tmp|.restore-tmp/*)"),
    ], ["TU28"]),
    ("M88", "una entrada . de backup.extra_paths se acepta", [
        (BM, "    ''|.|.state|.state/.cache|.state/.cache/*|agent-repo|agent-repo/*|.restore-tmp|.restore-tmp/*)",
         "    ''|.state|.state/.cache|.state/.cache/*|agent-repo|agent-repo/*|.restore-tmp|.restore-tmp/*)"),
    ], ["TU28"]),
    ("M89", "se quitan las exclusiones de los archivos volatiles de claude-mem", [
        (BM, '  if [ "$kind" = "claude-mem" ]; then', '  if false; then'),
    ], ["TU30"]),
    ("M90", "memory e history no comprueban la marca", [
        (HB, '  _repo_owner_ok "$unit" "$dir" "$current_hash" || return "$_REPO_RC"', '  :'),
    ], ["TU39"]),
    ("M91", "el git de history no tiene tope", [
        (BH, '    timeout -k 10 "$secs" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\', '    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \\'),
    ], ["TU39"]),
    ("M92", "memory sin fuentes no registra nothing-to-back-up", [
        (HB, '''  if [ ! -s "$base/memory-repo.all" ]; then
    _repo_fail memory nothing-to-back-up
    return "$_REPO_RC"
  fi''', '''  if [ ! -s "$base/memory-repo.all" ]; then
    echo "backup-memory: nothing to back up yet"
    _repo_end
    return 0
  fi'''),
    ], ["TU39"]),
    ("M93", "claude-mem se restaura en otro directorio", [
        (SU, '  n=$((n + $(_restore_move_tree "$out/claude-mem" "$dest/.state/.claude-mem")))',
         '  n=$((n + $(_restore_move_tree "$out/claude-mem" "$dest/.state/claude-mem")))'),
    ], ["TR01"]),
    ("M94", "una rama que falta aborta la restauracion", [
        (SU, '''      _RESTORE_SKIPPED="${_RESTORE_SKIPPED}${_RESTORE_SKIPPED:+, }$unit (no branch)"
    fi
    return 0''', '''      _RESTORE_SKIPPED="${_RESTORE_SKIPPED}${_RESTORE_SKIPPED:+, }$unit (no branch)"
    fi
    exit 1'''),
    ], ["TR02"]),
    ("M95", "sin llave, la restauracion aborta", [
        (SU, '  rm -rf "$out"\n  return 11\n}', '  rm -rf "$out"\n  echo "  x restore: no usable key" >&2\n  exit 1\n}'),
    ], ["TR03"]),
    ("M96", "sin python3, la restauracion aborta", [
        (SU, '    return 10\n  fi\n  while IFS= read -r k; do', '    exit 1\n  fi\n  while IFS= read -r k; do'),
    ], ["TR04"]),
    ("M97", "la restauracion deja una unidad a medias (la parte en claro llega aunque el almacen falle)", [
        (SU, '''  if [ "$rc" = "12" ]; then
    _restore_store_line "$unit" "$rc"
    _RESTORE_SKIPPED="${_RESTORE_SKIPPED}${_RESTORE_SKIPPED:+, }$unit (integrity)"
    rm -rf "$btmp" "$tmp/$unit"
    return 0
  fi
''', ''),
    ], ["TR05"]),
    ("M98", "la restauracion imprime las lineas de memory y history para un fork", [
        (SU, '''    if [ "$_RESTORE_AGENT_REPO" = "1" ]; then
      echo "  ⚠ restore: no backup/$unit branch at $url — skipping"''', '''    if true; then
      echo "  ⚠ restore: no backup/$unit branch at $url — skipping"'''),
    ], ["TR06"]),
    ("M99", "el alias no se registra", [
        (SU, '      --restore-from-repo) RESTORE_FORK_URL="$2"; shift 2 ;;\n', ''),
    ], ["TR07"]),
    ("M100", "un vault cifrado se restaura como su store/", [
        (SU, '''    if [ -d "$vault_tmp/store" ]; then
      local _vrc=0''', '''    if [ -d "$vault_tmp/store" ]; then
      cp -a "$vault_tmp/store" "$dest/$vault_path/"
    fi
    if false; then
      local _vrc=0'''),
    ], ["TR08"]),
    ("M101", "la marca se copia al workspace", [
        (SU, '    CLAUDE.md|docker-compose.override.yml|.claude/settings.json) return 0 ;;',
         '    .agentic-pod-backup.json|CLAUDE.md|docker-compose.override.yml|.claude/settings.json) return 0 ;;'),
    ], ["TR09"]),
    ("M102", "el archivo de secretos restaurado queda con el modo por defecto", [
        (SU, '      chmod 600 "$env_out" 2>/dev/null || true\n', ''),
    ], ["TR10"]),
    ("M103", "el aviso del token sale siempre", [
        (SU, '      if [ -z "$(env_file_get CLAUDE_CODE_OAUTH_TOKEN "$dest/.env" 2>/dev/null || true)" ]; then', '      if true; then'),
    ], ["TR10"]),
    ("M104", ".claude/ se restaura bajo .state/", [
        (SU, '    if [ -n "$filter" ] && ! "$filter" "$rel"; then continue; fi\n',
         '    if [ -n "$filter" ] && ! "$filter" "$rel"; then continue; fi\n    case "$rel" in .claude/*) rel=".state/$rel" ;; esac\n'),
    ], ["TR11"]),
    ("M105", "las rutas adicionales se restauran bajo extra/", [
        (SU, '  n=$((n + $(_restore_move_tree "$out/extra" "$dest" _restore_extra_allowed)))',
         '  n=$((n + $(_restore_move_tree "$out/extra" "$dest/extra" _restore_extra_allowed)))'),
    ], ["TR12"]),
    ("M106", "sin llave, la configuracion cifrada no restaura agent.yml", [
        (SU, '        11) echo "  ⚠ restore: backup/config is partly encrypted',
         '        11) rm -f "$dest/agent.yml"; echo "  ⚠ restore: backup/config is partly encrypted'),
    ], ["TR13"]),
    ("M107", "el directorio temporal no se borra", [
        (SU, '  rm -rf "$_rtmp"\n  trap - INT TERM', '  trap - INT TERM'),
    ], ["TR14"]),
    ("M108", "GITHUB_PAT se escribe siempre en el archivo de secretos", [
        (SU, '  if [ "$github_enabled" = "true" ] || [ -n "$backup_repo_url" ]; then', '  if true; then'),
    ], ["TA01"]),
    ("M109", "el token no se pide sin el MCP", [
        (SU, '  elif [ -n "$backup_repo_url" ]; then\n    # 046 (A1)', '  elif false; then\n    # 046 (A1)'),
    ], ["TA02"]),
    ("M110", "el wizard vuelve a preguntar sin terminal", [
        (SU, '    [ -t 0 ] || return 1\n  done', '    :\n  done'),
    ], ["TA03"]),
    ("M111", "el backfill usa // y pisa un false", [
        (SU, '''    if [ "$(yq -r '(((.features // {}).memory_backup // {}) | has("enabled")) // false' "$agent_yml" 2>/dev/null)" != "true" ]; then
      yq -i '.features.memory_backup.enabled = true' "$agent_yml"
    fi''', '''    yq -i '.features.memory_backup.enabled = (.features.memory_backup.enabled // true)' "$agent_yml"'''),
    ], ["TA04"]),
    ("M112", "el esquema acepta un backup.sensitive que no es booleano", [
        (SC, "  '.backup.sensitive'\n", ''),
    ], ["TA05"]),
    ("M113", "los bloques unless e if de la plantilla se invierten", [
        (TPL, '{{#unless BACKUP_REPO_ENABLED}}## Backups', '{{#if BACKUP_REPO_ENABLED}}## Backups'),
        (TPL, '{{/unless}}{{#if BACKUP_REPO_ENABLED}}## Backups', '{{/if}}{{#unless BACKUP_REPO_ENABLED}}## Backups'),
        (TPL, '`backup.extra_paths` in `agent.yml`.{{/if}}', '`backup.extra_paths` in `agent.yml`.{{/unless}}'),
    ], ["TA06", "TA07"]),
    ("M114", "un marcador derivado no se exporta (BACKUP_REPO_WORKDIR)", [
        (SU, 'export BACKUP_REPO_ENABLED=false BACKUP_REPO_WORKDIR=/workspace/agent-repo BACKUP_REPO_NEXT_STEPS=""',
         'export BACKUP_REPO_ENABLED=false BACKUP_REPO_NEXT_STEPS=""'),
    ], ["TA08"]),
    ("M115", "el dueno de la llave sale solo del fork", [
        (SU, '  if [ -z "$owner" ] && [ -n "$repo_url" ]; then', '  if false; then'),
    ], ["TA09"]),
    ("M116", "el clon de trabajo trae las ramas de respaldo", [
        (AR, "  _agent_repo_git -C \"$dir\" config --add remote.origin.fetch '^refs/heads/backup/*' || return 1", '  :'),
    ], ["TA10"]),
    ("M117", "un clon que ya existe se vuelve a crear", [
        (AR, '      _agent_repo_settings "$dir" "$url" || _agent_repo_log "could not update the settings of $dir"',
         '      rm -rf "$dir"; _agent_repo_create "$dir" "$url" "$yml" || _agent_repo_log "could not update the settings of $dir"'),
    ], ["TA11"]),
    ("M118", "backup-config no vuelve a intentar el clon de trabajo", [
        (HB, '    if [ "$dry_run" != "1" ] && command -v agent_repo_ensure > /dev/null 2>&1; then', '    if false; then'),
    ], ["TA11"]),
    ("M119", "la credencial se escribe en la configuracion del clon (URL del remoto)", [
        (AR, '    _agent_repo_git -C "$dir" remote add origin "$url" || return 1',
         '    _agent_repo_git -C "$dir" remote add origin "${url%%://*}://x-access-token:${GITHUB_PAT}@${url#*://}" || return 1'),
    ], ["TA12"]),
    ("M120", ".gitignore pierde /agent-repo/", [
        (".gitignore", '/agent-repo/\n', ''),
    ], ["TA13"]),
    ("M121", "BACKUP_REPO_ENABLED vale true en modo local", [
        (SU, '  if [ -n "$url" ] && [ "$mode" != "local" ]; then\n    BACKUP_REPO_ENABLED=true',
         '  if [ -n "$url" ]; then\n    BACKUP_REPO_ENABLED=true'),
    ], ["TA14", "TA16"]),
    ("M122", "NEXT_STEPS muestra el bloque sin repositorio", [
        (SU, '  if [ -n "$url" ] && [ "$mode" != "local" ]; then\n    BACKUP_REPO_ENABLED=true',
         '  if [ "$mode" != "local" ]; then\n    [ -n "$url" ] && BACKUP_REPO_ENABLED=true'),
    ], ["TA15"]),
    ("M123", "la pregunta del wizard aparece en modo local", [
        (SU, '  if [ "$deploy_mode" = "docker" ]; then\n    echo "▸ Agent repository', '  if true; then\n    echo "▸ Agent repository'),
    ], ["TA16"]),
    ("M124", "el esquema acepta un backup.extra_paths que no es una lista", [
        (SC, '    *) errors+=(".backup.extra_paths must be a list of strings (got: ${extra_type#!!})") ;;', '    *) ;;'),
    ], ["TA17"]),
    ("M125", "--regenerate fija una llave por su cuenta", [
        (SU, '        echo "WARN: backup.repo is set but there is no encryption key - encrypted backups will not run. Set one with: docker exec -u agent $_br_agent heartbeatctl backup-identity --configure-key \\"<public key>\\"" >&2',
         """        yq -i '.backup.identity.recipient = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMutantMutantMutantMutantMutantMutantMut m"' "$agent_yml\""""),
    ], ["TA18"]),
    ("M126", "el aviso de --regenerate muestra el valor de GITHUB_PAT", [
        (SU, '      if [ -z "$(env_file_get GITHUB_PAT "$SCRIPT_DIR/.env" 2>/dev/null || true)" ]; then',
         '      echo "INFO: GITHUB_PAT=$(env_file_get GITHUB_PAT "$SCRIPT_DIR/.env" 2>/dev/null || true)" >&2\n'
         '      if [ -z "$(env_file_get GITHUB_PAT "$SCRIPT_DIR/.env" 2>/dev/null || true)" ]; then'),
    ], ["TA18"]),
    ("M127", "el clon deja extraida una rama backup/*", [
        (AR, "           | grep -v '^backup/' | LC_ALL=C sort)", "           | LC_ALL=C sort)"),
    ], ["TA19"]),
    ("M128", "--nuke no avisa", [
        (SU, '    if [ "${_ar_c:-0}" -gt 0 ] || [ "${_ar_d:-0}" -gt 0 ]; then', '    if false; then'),
    ], ["TA20"]),
    ("M129", "backup-status omite una unidad (history)", [
        (HB, '''      _bs_unit_json history "$(_bs_flag '.features.history_backup.enabled')" 49 "$HISTORY_BACKUP_STATE_FILE" "$hcache/history-repo"\n''', ''),
    ], ["TB01"]),
    ("M130", "con fork, el JSON trae work_clone", [
        (HB, '  if [ "$kind" = "repo" ]; then\n    local cred=missing', '  if true; then\n    local cred=missing'),
    ], ["TB02"]),
    ("M131", "el umbral de antiguedad nunca se supera", [
        (HB, '      if [ -n "$then" ] && [ $((now - then)) -gt $((max * 3600)) ]; then', '      if false; then'),
    ], ["TB03"]),
    ("M132", "un ultimo intento fallido se informa como correcto", [
        (HB, '''    case "$result" in ''|ok|no-change) ;; *) status="$status, last attempt $result" ;; esac''', '    :'),
    ], ["TB04"]),
    ("M133", "los commits sin publicar siempre son 0", [
        (HB, "      unpub=$(GIT_CONFIG_GLOBAL=/dev/null git -C \"$wdir\" rev-list --branches --not --remotes 2> /dev/null | wc -l | tr -d ' ') || unpub=0",
         '      unpub=0'),
    ], ["TB05"]),
    ("M134", "backup-status imprime el valor de la credencial", [
        (HB, '    [ -n "${GITHUB_PAT:-}" ] && cred=present', '    [ -n "${GITHUB_PAT:-}" ] && cred="$GITHUB_PAT"'),
    ], ["TB06"]),
    ("M135", "el diagnostico no advierte un intento fallido", [
        (AC, '''    case "$result" in
      ''|ok|no-change)
        if [ -z "$push" ]; then''', '''    case "ok" in
      ''|ok|no-change)
        if [ -z "$push" ]; then'''),
    ], ["TB07"]),
    ("M136", "el diagnostico muestra las lineas nuevas sin repositorio", [
        (AC, '    if [ -n "$_repo_url" ]; then\n      # 046 (A7)', '    if true; then\n      # 046 (A7)'),
    ], ["TB08"]),
    ("M137", "una ruta adicional que falta no se lista", [
        (HB, '''        missing_json=$(jq -c --arg e "$entry" '. + [$e]' <<< "$missing_json")''', '        :'),
    ], ["TB09"]),
    ("M138", "la advertencia de tamano nunca sale", [
        (AC, '  if [ "${total:-0}" -gt $((max_mb * 1048576)) ]; then', '  if false; then'),
    ], ["TB10"]),
    ("M139", "el clon pasa GITHUB_PAT en argv de env", [
        (AR, '  heads=$(_agent_repo_capped env GIT_CONFIG_GLOBAL=/dev/null',
         '  heads=$(_agent_repo_capped env GITHUB_PAT="$GITHUB_PAT" GIT_CONFIG_GLOBAL=/dev/null'),
    ], ["TA12"]),
    ("M140", "el git de identidad pasa GITHUB_PAT en argv de env", [
        (BI, 'env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass"',
         'env GITHUB_PAT="$GITHUB_PAT" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass"', 2),
    ], ["TU01"]),
    ("M141", "el clon no reinicia los helpers heredados", [
        (AR, '  _agent_repo_git -C "$dir" config --add "$key" "" || return 1\n', ''),
    ], ["TA12"]),
    ("M142", "--gc no toma el candado", [
        (HB, '  backup_dest_lock "$1" || return 0\n', ''),
    ], ["TU37"]),
    ("M143", "dry-run registra el intento", [
        (HB, '  [ "$_REPO_DRY" = "1" ] || backup_dest_record "$unit" "$result" "$attempted"',
         '  backup_dest_record "$unit" "$result" "$attempted"'),
    ], ["TU13"]),
    ("M144", "se descarta el stderr del almacen", [
        (HB, '    --extra "sensitive=$3 $4"\n', '    --extra "sensitive=$3 $4" 2> /dev/null\n'),
    ], ["TU10"]),
    ("M145", "el supervisor ignora identity_backup.enabled false", [
        (SS, '    [ "$bi_enabled" = "false" ] && return 0', '    :'),
    ], ["TU25"]),
    ("M146", "las rutas adicionales incluyen el archivo de login", [
        (BM, r'''    find "$root" -name .git -prune -o -type f ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' \
      ! -name '.credentials.json' -print0 2> /dev/null''',
         r'''    find "$root" -name .git -prune -o -type f ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' \
      -print0 2> /dev/null'''),
    ], ["TU28"]),
    ("M147", "memory_extra_path_check no consulta las reservadas", [
        (BM, '  if memory_extra_path_reserved "$p"; then', '  if false; then'),
    ], ["TU28"]),
    ("M148", "el bloque se nombra por el hash en claro", [
        (PY, '                name = hashlib.sha256(enc).hexdigest()', '                name = psha'),
    ], ["TS08"]),
    ("M149", "pack no usa el mapa de bloques", [
        (PY, '    bmap = load_block_map(a.block_map, recipient)', '    bmap = {}'),
    ], ["TS05", "TS06"]),
    ("M150", "la unidad no pasa block-map a pack", [
        (HB, '                 --snapshot-dir "$prefix.snap" --block-map "$prefix.blockmap")',
         '                 --snapshot-dir "$prefix.snap")'),
    ], ["TU12"]),
    ("M151", "unpack no verifica el nombre cifrado del bloque", [
        (PY, '                if hashlib.sha256(raw).hexdigest() != name:\n                    err(5, "a block does not match its name (%s)" % path)\n', ''),
    ], ["TS11"]),
    ("M152", "unpack acepta segmentos git", [
        (PY, '        if seg in ("", ".", "..") or seg.lower() == ".git":',
         '        if seg in ("", ".", ".."):'),
    ], ["TS12", "TR12"]),
    ("M153", "unpack conserva los bits especiales", [
        (PY, '                os.chmod(staged, int(str(entry.get("mode") or "600"), 8) & 0o777)',
         '                os.chmod(staged, int(str(entry.get("mode") or "600"), 8))'),
    ], ["TS04"]),
    ("M154", "una falla posterior a key.age sale con 4", [
        (PY, '        err(5, "%s does not decrypt" % what)', '        err(4, "%s does not decrypt" % what)'),
    ], ["TS11"]),
    ("M155", "SQLite usa una URI sin escapar", [
        (PY, '        s = sqlite3.connect(pathlib.Path(os.path.abspath(src)).as_uri() + "?mode=ro", uri=True)',
         '        s = sqlite3.connect("file:" + os.path.abspath(src) + "?mode=ro", uri=True)'),
    ], ["TS14"]),
    ("M156", "restore acepta vault.path bajo git", [
        (SU, "    case \"$seg\" in ''|.|..|[.][gG][iI][tT]) return 1 ;; esac",
         "    case \"$seg\" in ''|.|..) return 1 ;; esac"),
    ], ["TR08"]),
    ("M157", "restore escribe por un enlace del destino", [
        (SU, '    _restore_no_link "$root" "$dest/$rel" || continue\n', ''),
    ], ["TR11"]),
    ("M158", "la config en claro pierde su lista cerrada", [
        (SU, '    _restore_move_tree "$cfg_tmp" "$dest" _restore_config_allowed > /dev/null',
         '    _restore_move_tree "$cfg_tmp" "$dest" > /dev/null'),
    ], ["TR11"]),
    ("M159", "la config cifrada pierde su lista cerrada", [
        (SU, '          _restore_move_tree "$_rtmp/config" "$dest" _restore_config_allowed > /dev/null',
         '          _restore_move_tree "$_rtmp/config" "$dest" > /dev/null'),
    ], ["TR13"]),
    ("M160", "el vault cifrado pierde el filtro markdown", [
        (SU, '        _vn=$((_vn + $(_restore_move_tree "$_rtmp/vault" "$dest/$vault_path" _restore_vault_allowed)))',
         '        _vn=$((_vn + $(_restore_move_tree "$_rtmp/vault" "$dest/$vault_path")))'),
    ], ["TR08"]),
    ("M161", "restore sigue un vault.path con puntos", [
        (SU, "    case \"$seg\" in ''|.|..|[.][gG][iI][tT]) return 1 ;; esac",
         "    case \"$seg\" in ''|.|[.][gG][iI][tT]) return 1 ;; esac"),
    ], ["TR08"]),
    ("M162", "restore extra ignora las rutas reservadas", [
        (SU, '  memory_extra_path_reserved "$rel" && return 1\n', ''),
        (SU, '    memory_extra_path_reserved "$e" && continue\n', ''),
    ], ["TR12"]),
    ("M163", "restore extra ignora la lista declarada", [
        (SU, '  memory_extra_path_reserved "$rel" && return 1\n',
         '  memory_extra_path_reserved "$rel" && return 1\n  return 0\n'),
    ], ["TR12"]),
    ("M164", "restore extra permite el archivo de login", [
        (SU, '  case "${rel##*/}" in .credentials.json) return 1 ;; esac\n', ''),
    ], ["TR12"]),
    ("M165", "restore extra no excluye las rutas del git del workspace", [
        (SU, '  if [ -n "$exclude" ] && [ -d "$dest/.git" ] && [ ! -L "$dest/.git" ]; then',
         '  if false; then'),
    ], ["TR12"]),
    ("M166", "se anuncia un vault cuyo almacen se omitio", [
        (SU, '    if [ "$_vok" = "1" ] || [ "$_vn" -gt 0 ]; then', '    if true; then'),
    ], ["TR08"]),
    ("M167", "identidad en claro copia enlaces de su rama", [
        (SU, '    _restore_move_tree "$id_tmp/.claude" "$dest/.state/.claude" > /dev/null',
         '    cp -a "$id_tmp/.claude/." "$dest/.state/.claude/" > /dev/null'),
    ], ["TR11"]),
]

M0_EXPECT_PASS = ["TU05", "TU19", "TU20", "TU31", "TR06", "TA06", "TA14", "TB08"]


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, s):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(s)


def apply_subs(root, subs, dry=False):
    for sub in subs:
        f, old, new = sub[0], sub[1], sub[2]
        times = sub[3] if len(sub) > 3 else 1
        p = os.path.join(root, f)
        s = read(p)
        n = s.count(old)
        if n != times:
            raise SystemExit("ancla: %s aparece %d veces (se esperaban %d): %r" % (f, n, times, old[:90]))
        if not dry:
            write(p, s.replace(old, new))


def copy_inventory(src, dst, prefix=""):
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=src)
    for raw in paths.split(b"\0"):
        if not raw:
            continue
        rel = os.fsdecode(raw)
        if prefix and not rel.startswith(prefix):
            continue
        parts = rel.split("/")
        name = parts[-1]
        if (any(p in (".git", ".state", ".ssh") for p in parts)
                or name.startswith(".env") or name.endswith((".pem", ".key"))
                or name in ("credentials", "id_rsa", ".credentials.json")):
            continue
        source = os.path.join(src, rel)
        target = os.path.join(dst, rel)
        if not os.path.isfile(source) and not os.path.islink(source):
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)


def copy_tree(src, dst, tests_from=None):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    copy_inventory(src, dst)
    if tests_from:
        copy_inventory(tests_from, dst, prefix="tests/")
    subprocess.run(["git", "init", "-q", dst], check=True)


TAP_RE = re.compile(r"^(ok|not ok) \d+ ((T[A-Z]\d\d)\b[^#]*)")


def run_bats(root, files, regex, bash, timeout):
    env = dict(os.environ)
    path = "/opt/homebrew/bin:" + env.get("PATH", "")
    if bash == "3.2":
        path = "/bin:" + path
    env["PATH"] = path
    env.pop("CI", None)
    cmd = ["bats", "--tap"]
    if regex:
        cmd += ["-f", regex]
    cmd += files
    t0 = time.time()
    timed_out = False
    active = os.path.join(OUT, "active-bash%s.tap" % bash.replace(".", ""))
    with open(active, "wb") as live:
        proc = subprocess.Popen(cmd, cwd=root, env=env, stdout=live, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            out, _ = proc.communicate()
    if out is None:
        with open(active, "rb") as fh:
            out = fh.read()
    secs = int(time.time() - t0)
    text = out.decode("utf-8", "replace")
    results = {}
    reported = []
    skipped = []
    for line in text.splitlines():
        m = TAP_RE.match(line)
        if m:
            results[m.group(3)] = (m.group(1) == "ok")
            reported.append(m.group(3))
            if re.search(r"#\s*skip\b", line, re.I):
                skipped.append(m.group(3))
    meta = {"returncode": proc.returncode, "reported": reported, "skipped": skipped,
            "plans": [int(n) for n in re.findall(r"^1\.\.(\d+)\s*$", text, re.M)]}
    return results, timed_out, secs, text, meta


def test_ids(root, files):
    ids = []
    for rel in files:
        ids.extend(re.findall(r'^@test "(T[A-Z]\d{2}):', read(os.path.join(root, rel)), re.M))
    return ids


def integrity_errors(results, timed_out, text, meta, expected):
    errors = []
    if timed_out:
        errors.append("timeout: not evidence of an assertion failure")
    if set(results) != set(expected) or len(meta["reported"]) != len(expected):
        errors.append("missing, extra or duplicate test results")
    if meta["plans"] != [len(expected)]:
        errors.append("TAP plan does not match the expected test count")
    if meta["skipped"]:
        errors.append("skipped tests: " + ", ".join(meta["skipped"]))
    expected_rc = 1 if any(not ok for ok in results.values()) else 0
    if meta["returncode"] != expected_rc:
        errors.append("unexpected bats exit status: %s" % meta["returncode"])
    if "Bail out!" in text:
        errors.append("TAP bailout")
    return errors


def files_for(tests):
    return sorted({FILES[t[:2]] for t in tests})


def run_row(mid, desc, subs, tests, timeout):
    dst = os.path.join(MUT, mid)
    if mid == "M0":
        copy_tree(BASE, dst, tests_from=W)
        files = [FILES[k] for k in ("TD", "TS", "TU", "TR", "TA", "TB")]
        regex = None
    else:
        copy_tree(W, dst)
        apply_subs(dst, subs)
        files = files_for(tests)
        regex = "^(" + "|".join(tests) + "):"
    row = {"id": mid, "desc": desc, "tests": tests, "bash": {}}
    expected = test_ids(dst, files) if mid == "M0" else tests
    for bash in ("5", "3.2"):
        results, timed_out, secs, text, meta = run_bats(dst, files, regex, bash, timeout)
        with open(os.path.join(OUT, "%s.bash%s.tap" % (mid, bash.replace(".", ""))), "w") as fh:
            fh.write(text)
        fell = sorted(t for t, ok in results.items() if not ok)
        passed = sorted(t for t, ok in results.items() if ok)
        errors = integrity_errors(results, timed_out, text, meta, expected)
        row["bash"][bash] = {"fell": fell, "passed": passed, "timed_out": timed_out,
                              "secs": secs, "errors": errors, "returncode": meta["returncode"]}
    shutil.rmtree(dst, ignore_errors=True)
    if mid == "M0":
        ok = not any(b["errors"] for b in row["bash"].values())
        for bash in ("5", "3.2"):
            b = row["bash"][bash]
            for t in M0_EXPECT_PASS:
                if t not in b["passed"]:
                    ok = False
            for t in b["passed"]:
                if t not in M0_EXPECT_PASS:
                    ok = False
        row["verdict"] = "ok" if ok else "REVISAR"
    else:
        caught = not any(b["errors"] for b in row["bash"].values())
        for bash in ("5", "3.2"):
            fell = [t.split("(")[0] for t in row["bash"][bash]["fell"]]
            for t in tests:
                if t not in fell:
                    caught = False
        row["verdict"] = ("INCOMPLETA" if any(b["errors"] for b in row["bash"].values())
                          else "cazada" if caught else "SOBREVIVE")
    with open(os.path.join(OUT, mid + ".json"), "w") as fh:
        json.dump(row, fh, indent=1)
    return row


def write_results():
    rows = []
    for mid, desc, subs, tests in [("M0", "codigo de origin/main con las pruebas finales", [], [])] + M:
        p = os.path.join(OUT, mid + ".json")
        if os.path.exists(p):
            rows.append(json.load(open(p)))
    lines = ["# Mutaciones de 046 (T069)", "",
             "| Id | Variante | Debe caer | Cayeron (bash 5) | Cayeron (bash 3.2) | s | Veredicto |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        b5 = r["bash"]["5"]
        b3 = r["bash"]["3.2"]
        if r["id"] == "M0":
            f5 = "%d caen; pasan %s" % (len(b5["fell"]), ", ".join(b5["passed"]))
            f3 = "%d caen; pasan %s" % (len(b3["fell"]), ", ".join(b3["passed"]))
            must = "todas salvo " + ", ".join(M0_EXPECT_PASS)
        else:
            f5 = ", ".join(b5["fell"]) or "-"
            f3 = ", ".join(b3["fell"]) or "-"
            must = ", ".join(r["tests"])
        lines.append("| %s | %s | %s | %s | %s | %d+%d | %s |" % (
            r["id"], r["desc"], must, f5, f3, b5["secs"], b3["secs"], r["verdict"]))
    write(os.path.join(OUT, "results.md"), "\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--control", action="store_true")
    ap.add_argument("--only")
    ap.add_argument("--from", dest="start")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--no-m0", action="store_true")
    a = ap.parse_args()
    if a.control:
        # The copy without any mutation: every one of the six suites must pass in it,
        # or a row could count as caught for a reason of the copy, not of the mutant.
        os.makedirs(OUT, exist_ok=True)
        dst = os.path.join(MUT, "CTRL")
        copy_tree(W, dst)
        files = [FILES[k] for k in ("TD", "TS", "TU", "TR", "TA", "TB")]
        expected = test_ids(dst, files)
        control = {"tests": expected, "bash": {}}
        valid = True
        for bash in ("5", "3.2"):
            results, timed_out, secs, text, meta = run_bats(dst, files, None, bash, 1800)
            with open(os.path.join(OUT, "CTRL.bash%s.tap" % bash.replace(".", "")), "w") as fh:
                fh.write(text)
            bad = sorted(t for t, ok in results.items() if not ok)
            errors = integrity_errors(results, timed_out, text, meta, expected)
            control["bash"][bash] = {"bad": bad, "errors": errors, "secs": secs,
                                       "returncode": meta["returncode"]}
            valid = valid and not bad and not errors
            print("control bash %s: %d ok, %d not ok %s, timeout=%s, %ds" % (
                bash, sum(1 for v in results.values() if v), len(bad), bad, timed_out, secs))
            for error in errors:
                print("control bash %s: %s" % (bash, error))
        control["valid"] = valid
        write(os.path.join(OUT, "CTRL.json"), json.dumps(control, indent=2) + "\n")
        shutil.rmtree(dst, ignore_errors=True)
        return 0 if valid else 1
    if a.check:
        ids = set()
        for mid, desc, subs, tests in M:
            assert mid not in ids, mid
            ids.add(mid)
            for t in tests:
                assert t[:2] in FILES, t
            apply_subs(W, subs, dry=True)
        print("anclas ok: %d filas" % len(M))
        return 0
    rows = [("M0", "codigo de origin/main con las pruebas finales", [], [])] + M
    if a.no_m0:
        rows = M
    if a.only is not None:
        want = a.only.split(",")
        unknown = sorted(set(want) - {r[0] for r in rows})
        if unknown:
            print("unknown mutation identifiers: %s" % ", ".join(repr(t) for t in unknown), file=sys.stderr)
            return 2
        rows = [r for r in rows if r[0] in want]
    if a.start is not None:
        if a.start not in {r[0] for r in rows}:
            print("unknown start identifier in this selection: %r" % a.start, file=sys.stderr)
            return 2
        idx = [r[0] for r in rows].index(a.start)
        rows = rows[idx:]
    if not rows:
        print("empty mutation selection", file=sys.stderr)
        return 2
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(MUT, exist_ok=True)
    log = open(os.path.join(OUT, "progress.log"), "a")
    t0 = time.time()
    status = 0
    for mid, desc, subs, tests in rows:
        r = run_row(mid, desc, subs, tests, a.timeout)
        log.write("%s %s %s 5:%s 3.2:%s (%ds)\n" % (time.strftime("%H:%M:%S"), mid, r["verdict"],
                  ",".join(r["bash"]["5"]["fell"]) if mid != "M0" else len(r["bash"]["5"]["fell"]),
                  ",".join(r["bash"]["3.2"]["fell"]) if mid != "M0" else len(r["bash"]["3.2"]["fell"]),
                  r["bash"]["5"]["secs"] + r["bash"]["3.2"]["secs"]))
        log.flush()
        write_results()
        if r["verdict"] not in ("ok", "cazada"):
            print("%s: %s; inspect its TAP before continuing" % (mid, r["verdict"]), flush=True)
            status = 1
            break
    log.write("total %ds\n" % int(time.time() - t0))
    log.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
