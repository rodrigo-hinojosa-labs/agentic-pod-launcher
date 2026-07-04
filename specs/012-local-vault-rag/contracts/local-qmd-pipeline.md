# Contract: Pipeline QMD local (FR-004/005/006/012, D3/D4/D5)

## Entrypoint `scripts/local/agent-qmd-reindex.sh` (rendered de `modules/local-qmd-reindex.sh.tpl`)

```text
Uso: agent-qmd-reindex.sh [--setup-only]
Env fija (horneada por render): QMD_CACHE_HOME, QMD_VAULT_DIR, QMD_INDEX_STATE_FILE,
                                 VAULT_ROOT_OVERRIDE, workspace/agent.yml paths.
Flujo:  source scripts/lib/qmd_index.sh
        qmd_setup_if_needed "$AGENT_YML"        # SIEMPRE (guard auto-sanador; sentinel = no-op)
        [ --setup-only ] && exit 0              # camino del --login (background)
        qmd_reindex "$AGENT_YML"                # camino del timer (flock + hash-debounce intactos)
Exit:   siempre 0 (fail-silent, Principio IV); detalle en journal + qmd-index.json.
Gate:   si vault.qmd.enabled != true → exit 0 inmediato sin efectos.
```

## Wrapper watcher `scripts/local/agent-qmd-watch.sh` (rendered)

```text
Env:    QMD_WATCH_AGENT_YML=<ws>/agent.yml, QMD_REINDEX_CMD=<ws>/scripts/local/agent-qmd-reindex.sh
Flujo:  exec bash <ws>/scripts/qmd_watch.sh   # lib reubicada, lógica intacta (debounce 15s, EOF→exit)
Degradación sin inotify-tools: la maneja la UNIT, no el wrapper (ver ExecCondition
abajo). Con Restart=always, un wrapper que "sale limpio" restart-loopea igual
(systemd reinicia también en salida exitosa) y golpea el start-limit default
(5/10 s) → unit failed — exactamente lo que el invariante prohíbe. ExecCondition
fallida en cambio deja la unit skipped/inactive SIN disparar Restart (mismo
patrón validado en producción por 011 con .credentials.json). La lib conserva su
guard interno (sale limpia sin inotifywait) como cinturón redundante inofensivo.
Invariante: host sin inotify-tools → unit inactive (condición no cumplida), sin
failed-loop; el timer de reindex queda de backstop.
```

## Units

```ini
# agent-<name>-qmd-reindex.timer
[Timer]
OnCalendar={{QMD_TIMER_ONCALENDAR}}
Persistent=true

# agent-<name>-qmd-watch.service
[Service]
Type=simple
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
ExecCondition=/bin/sh -c 'command -v inotifywait'
ExecStart=<ws>/scripts/local/agent-qmd-watch.sh
Restart=always
RestartSec=2
```

## Conversión cron→systemd (`scripts/lib/local_schedule.sh`)

`cron_to_systemd_calendar CRON_EXPR DEFAULT_ONCALENDAR` — pura, stdout = OnCalendar, rc 0 siempre; forma no soportada → imprime DEFAULT + warning a stderr.

| Entrada (cron) | Salida (OnCalendar) |
|---|---|
| `*/5 * * * *` | `*-*-* *:0/5:00` |
| `*/30 * * * *` | `*-*-* *:0/30:00` |
| `0 * * * *` | `*-*-* *:00:00` |
| `15 * * * *` | `*-*-* *:15:00` |
| `30 3 * * *` | `*-*-* 03:30:00` |
| `0 12 * * *` | `*-*-* 12:00:00` |
| `0 * * * 1-5` (no soportada) | DEFAULT + warning stderr |
| `` / valor ausente | DEFAULT (sin warning — es el caso "usa default") |

Defaults de llamada: qmd → `*-*-* *:0/5:00`; backup → `*-*-* *:00:00`.

## Enganches de ciclo de vida

- `--login` (local-login.sh.tpl): bloque `{{#if VAULT_QMD_ENABLED}}` — `nohup <entrypoint> --setup-only >/dev/null 2>&1 &` tras el bootstrap de runtimes; y las units qmd entran a la lista del loop de instalación staged (generalización del paso 6 actual).
- `install_service` (setup.sh, rama local): renderiza+instala/stagea las units qmd solo si `vault.qmd.enabled`.
- Kill-switch: `systemctl stop` de reindex.timer + watch.service (además de las actuales).
- `--uninstall`: `disable --now` + rm de las units qmd (instaladas o staged).
- `agentctl status`: línea por unit (active/staged/absent) cuando qmd on; `doctor`: `index.sqlite` presente + edad de `last_run` en `qmd-index.json`.
