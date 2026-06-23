# Data Model: Headless bootstrap

**Feature**: 006-headless-bootstrap · **Date**: 2026-06-22

Este feature no introduce entidades de `agent.yml` (el token es secreto y no es un campo de schema). Las "entidades" son artefactos de configuración/estado del runtime y su contrato de ubicación, sensibilidad y ciclo de vida.

## E1 — `CLAUDE_CODE_OAUTH_TOKEN` (credential headless)

| Atributo | Valor |
|----------|-------|
| Naturaleza | Secreto (token OAuth de larga duración, `sk-ant-oat01-…`, ~108 chars) |
| Origen | `claude setup-token` en el **host** (OAuth una vez; requiere suscripción Claude) |
| Ubicación | `<workspace>/.env`, línea `CLAUDE_CODE_OAUTH_TOKEN=…`, permisos `0600`, gitignored |
| Transporte al contenedor | `docker-compose.yml` `env_file: ./.env` → env del proceso `claude` |
| Backup | Incluido en backup/identity como `.env.age` (cifrado); en **modo partial** (sin recipient SSH) el `.env` va en texto plano — advertir en docs |
| Prohibiciones | NUNCA en `agent.yml`, en `.env.example` con valor, ni en logs |
| Ciclo de vida | Persiste hasta revocación/expiración del token; opcional re-`setup-token` |

**Reglas de validación**: presencia ⇒ auth headless activa (D4). Ausencia/vacío ⇒ path `/login` interactivo (fallback). Valor inválido ⇒ `401 Invalid bearer token` (debe ser visible, no enmascarado).

## E2 — Marketplace oficial (`claude-plugins-official`)

| Atributo | Valor |
|----------|-------|
| Nombre registrado | `claude-plugins-official` (cache key esperada por `plugin_cache_dir_for`) |
| Fuente | `anthropics/claude-plugins-official` (GitHub, HTTPS clone) |
| Registro | `claude plugin marketplace add anthropics/claude-plugins-official --scope user` |
| Scope | `user` → declarado en `~/.claude/settings.json` |
| Idempotencia | Guard previo con `claude plugin marketplace list` (skip si ya presente) |
| Single source | Constante shell junto a `REQUIRED_CHANNEL_PLUGIN` (no duplicar el literal) |
| Dependientes | 7+ plugins `@claude-plugins-official` (incl. `telegram`, el canal) |

**Reglas de validación**: el registro debe correr **antes** de `ensure_all_plugins_installed`; fallo de clone (red/VirtioFS) ⇒ tolerado (WARN, reintento idempotente en el próximo tick), nunca bloquea/crashea el supervisor.

## E3 — Estado de onboarding (`~/.claude/.claude.json` + `settings.json`)

| Atributo | Valor |
|----------|-------|
| Theme picker / trust dialog | Keys en `~/.claude/.claude.json` (p. ej. `theme`, `hasCompletedOnboarding`, trust de `/workspace`) — nombres exactos a confirmar por diff contra 2.1.170 |
| Settings headless | `~/.claude/settings.json`: `permissions.defaultMode=auto`, `skipDangerousModePermissionPrompt=true` |
| Creación | `pre_seed_onboarding` (nuevo) CREA `.claude.json` si falta; `pre_accept_bypass_permissions` se relaja para CREAR `settings.json` si falta |
| Idempotencia | jq-merge: re-aplicar es no-op si las keys ya están |
| Version-guard | Si las keys no matchean la versión pineada ⇒ WARN, no romper (FR-014) |
| Bloqueo afectado | Solo el **TUI** (bare claude / `--channels`); `-p` no requiere onboarding |

## Relaciones y orden de boot

```
env(CLAUDE_CODE_OAUTH_TOKEN) ──► has_oauth_token() ──► next_tmux_cmd: NO bare /login
                                                  └──► _check_auth_flip: baseline=auth'd (no kick)
start_session
  ├─ pre_accept_bypass_permissions (crea settings.json si falta)  ── E3
  ├─ pre_seed_onboarding (crea .claude.json si falta)             ── E3
  └─ next_tmux_cmd
       ├─ pre_accept_extra_marketplaces
       │     └─ ensure_official_marketplace (idempotente)          ── E2
       └─ ensure_all_plugins_installed (ahora encuentra el marketplace) ── E2
```
