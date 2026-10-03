# Contract: superficie declarativa de 037 en `agent.yml`

Seis claves nuevas, sin prompt de wizard, con el trío completo de Principio I (heredoc con default +
backfill `has()` + validación) y sus touchpoints de tests. Líneas sobre `main` @ `70214d9` (informe K §6).

## 1. Claves, defaults y consumidores

| Clave | Default | Flatten | Consumidor | Saneo |
|---|---|---|---|---|
| `vault.review.project_days` | `7` | `VAULT_REVIEW_PROJECT_DAYS` | runner del grafo (yq) → `policy.json`; el agente lo lee de ahí | entero `1..3650`, inválido → default + WARN (render y runner) |
| `vault.review.area_days` | `30` | `VAULT_REVIEW_AREA_DAYS` | idem | idem |
| `vault.archive.candidate_days` | `90` | `VAULT_ARCHIVE_CANDIDATE_DAYS` | runner (`archive_candidate`) → `policy.json` | idem |
| `features.heartbeat.review.enabled` | `false` | `FEATURES_HEARTBEAT_REVIEW_ENABLED` | `heartbeatctl cmd_reload` (docker) | booleano (`schema.sh`) |
| `features.heartbeat.review.schedule` | `"7 9 * * 1"` | `FEATURES_HEARTBEAT_REVIEW_SCHEDULE` | `heartbeatctl cmd_reload` | no vacío (`schema.sh`); forma cron de 5 campos validada en `heartbeatctl` (`_v_cron5`) |
| `features.heartbeat.review.prompt` | `""` (= default por idioma, `heartbeat_review_prompt_default`) | `FEATURES_HEARTBEAT_REVIEW_PROMPT` | `heartbeatctl cmd_reload` | 0..4000 chars (molde `_v_prompt` `:526-529`); vacío legal |

Ningún `{{VAR}}` nuevo entra a plantillas de `modules/` (la línea de crontab la escribe `heartbeatctl` en
runtime; las cadencias viajan por `policy.json`). Por eso `known_external` de `schema.bats:62-83` **no**
cambia. Si la implementación decidiera renderear alguno (p. ej. en `claude-md.tpl`), ese `{{VAR}}` entra a
`known_external` (precedente 029/034).

## 2. `setup.sh`

| Toque | Dónde | Molde |
|---|---|---|
| Heredoc `features.heartbeat` | tras `default_prompt` (`:1254-1260`): bloque `review:` con `enabled: false`, `schedule: "7 9 * * 1"`, `prompt: ""` | `reply_guard` `:1261-1263` |
| Heredoc `vault:` | tras `schema:` (`:1282-1297`): `review: {project_days: 7, area_days: 30}`, `archive: {candidate_days: 90}` | — |
| Backfill en `regenerate()` | tres guardas `has()` (nunca `//`, gotcha 028): `((.vault // {}) \| has("review"))`, `((.vault // {}) \| has("archive"))`, `((.features.heartbeat // {}) \| has("review"))`; cada una agrega el bloque completo con defaults sin tocar valores existentes | 029 `:2335-2337`, 036 `:2358-2362`, sub-clave 034 `:2324-2329` |
| Saneo de enteros | helpers `vault_review_project_days_effective`, `vault_review_area_days_effective`, `vault_archive_candidate_days_effective` (regex `^[0-9]{1,4}$` y rango 1..3650; inválido/ausente → default) — usados solo para WARN en render (`echo "WARN: …" >&2` nombrando la clave, nunca el valor) porque el consumidor real es el runner, que re-sanea | `mcp_timeout_effective` `:2373`, `channel_health_timeout_effective` `:2380` |
| Default del prompt | `heartbeat_review_prompt_default <lang>` (`es`/`en`; `mixed` → `es`) escrito por `heartbeatctl` cuando `prompt` está vacío; `setup.sh` solo documenta el default en `NEXT_STEPS` | `voice_signoff_default` (034) |
| Sin prompt de wizard | `wizard_answers` (`tests/helper.bash:141-210`) y `e2e-smoke.bats:52-65` intactos | FR-029 |

Regla vigente (034): **nunca `local LC_ALL=C` dentro de una función de `setup.sh`** (segfault intermitente
en bash 5.3); `LC_ALL=C` va por comando externo.

## 3. `scripts/lib/schema.sh`

- `_SCHEMA_BOOLEANS` (`:65-74`): `+ .features.heartbeat.review.enabled`.
- `_SCHEMA_OPTIONAL_NONEMPTY` (`:81-89`): `+ .features.heartbeat.review.schedule`.
- No hay validador de enteros en `schema.sh` (solo required/enum/bool/nonempty): los `*_days` se sanean en
  render y en el runner; no se agrega un validador nuevo al schema (fuera de alcance; consistente con
  `channel_health_timeout_s` de 036).

## 4. Fixtures y tests

| Archivo | Cambio |
|---|---|
| `tests/fixtures/sample-agent-with-vault.yml:75-90` | bloque `vault:` gana `review` y `archive`; bloque `features.heartbeat` (`:39-44`) gana `review` |
| `tests/fixtures/sample-agent.yml:62-67` | `vault:` mínimo: **sin** `review`/`archive` (verifica el backfill), `features.heartbeat` gana `review` |
| `tests/schema.bats:42-43` | la lista exacta de sub-claves de `vault:` gana `archive review` (orden alfabético del `keys` de yq) — **obligatorio**, o el test rompe (riesgo K-10) |
| `tests/schema-validate.bats` | + booleano inválido en `review.enabled` → error; `schedule` vacío → error |
| `tests/regenerate.bats` | + backfill de los tres bloques sobre un `agent.yml` pre-037 (valores existentes intactos; dos regenerates byte-idénticos) |
| nuevo `tests/vault-review-config.bats` (molde `mcp-handshake-timeout.bats`) | `_write_agent_yml value/OMIT/NULL` para cada `*_days`: valor válido pasa a `policy.json`; inválido → default + WARN que nombra la clave |
| `docs/vault.md:100-126`, `docs/heartbeatctl.md`, `README.md:206-225`, `NEXT_STEPS` (en/es) | tabla de claves con defaults; las cuatro claves muertas (`initial_sources`, `mcp.server`, `schema.frontmatter_required`, `schema.log_format`) marcadas **reserved (no reader today)** |

## 5. Invariantes

1. Un `agent.yml` anterior a 037 pasa `--regenerate` y queda con los tres bloques y defaults; ningún valor
   preexistente cambia; el segundo `--regenerate` deja `agent.yml` byte-idéntico (oráculo nuevo de T011(c);
   el test existente `regenerate.bats:85` solo diffea `.mcp.json` y no sirve para esto, refutación N C18).
2. `agent.yml` sigue siendo la única fuente: `policy.json` es derivado del runner, `review-prompt.txt` es
   derivado de `cmd_reload`; ninguno se edita a mano.
3. Sin `{{VAR}}` nuevo en `modules/` salvo decisión explícita registrada en el plan; `known_external` refleja
   exactamente los que existan.
4. VERSION 0.26.0 → 0.27.0 (verificar `git show origin/main:VERSION` antes del bump); entrada `### Added`
   en `CHANGELOG.md` bajo `## [Unreleased]`.
