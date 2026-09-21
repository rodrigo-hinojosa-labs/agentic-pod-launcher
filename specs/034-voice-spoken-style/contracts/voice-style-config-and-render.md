# Contract — voice style configuration and render (`agent.yml` → compose environment)

Mold: 032 `contracts/voice-config-and-render.md` + the `VOICE_STT_LANG` derived placeholder
(`setup.sh:2182-2191`). Host-side only (`setup.sh`, `modules/*.tpl`, fixtures, host bats,
one helper in `tests/helper.bash`).

## C1. `agent.yml` fields

```yaml
features:
  voice:
    enabled: false
    reply_mode: auto
    voice_id: ""
    provider: elevenlabs
    signoff: "Eso es toda la información. Cambio y fuera, {nickname}."   # NEW (034)
    currency: "pesos chilenos"                                          # NEW (034)
```

Defaults by `user.language` (wizard heredoc, `$user_lang`; `regenerate()` backfill reads
`.user.language // ""`):

| `user.language` | `signoff` | `currency` |
| --- | --- | --- |
| `es`, `mixed`, anything else | `Eso es toda la información. Cambio y fuera, {nickname}.` | `pesos chilenos` |
| `en` | `That is all the information. Over and out, {nickname}.` | `Chilean pesos` |

Helpers in `setup.sh`: `voice_signoff_default LANG`, `voice_currency_default LANG` (single
source for heredoc, backfill and sanitizer fallback).

No wizard prompt. `wizard_answers()` in `tests/helper.bash` **gains two optional kv `lang=`
and `nick=`** (defaults `en` / `Alice`; the `User (5 prompts)` line becomes
`printf 'Alice\n%s\nUTC\na@b.com\n%s\n' "$nick" "$lang"`; every inline block marker that
`tests/quickstart-doc.bats:73-93` checks is preserved; existing call sites unchanged). This is
the only way the wizard heredoc gets an oracle (031 lesson: heredoc and backfill are different
call sites). `tests/e2e-smoke.bats` unchanged.

## C2. Backfill in `regenerate()` (after the 032 whole-block backfill, inside `[ -f "$agent_yml" ]`)

```bash
# 034: backfill the two style fields for a 032/033 workspace. has()-guarded so an
# operator's own phrase survives every --regenerate. Language read ONCE here —
# regenerate() has no `lang` local and runs under set -u.
local _vlang
_vlang=$(yq -r '.user.language // ""' "$agent_yml" 2>/dev/null)
if [ "$(yq -r '(.features.voice | has("signoff")) // false' "$agent_yml" 2>/dev/null)" != "true" ]; then
  yq -i ".features.voice.signoff = \"$(voice_signoff_default "$_vlang")\"" "$agent_yml"
fi
if [ "$(yq -r '(.features.voice | has("currency")) // false' "$agent_yml" 2>/dev/null)" != "true" ]; then
  yq -i ".features.voice.currency = \"$(voice_currency_default "$_vlang")\"" "$agent_yml"
fi
```

Order matters: the 032 whole-block backfill runs first (measured: `null | has("signoff")` is
`false`; inverting the order would create `.features.voice` with only `signoff` and skip the
four 032 defaults). Two consecutive `--regenerate` runs are byte-identical. The oracle for
US2 scenario 4 asserts the EXACT localized value in `agent.yml` (not field presence — an empty
value would be protected by `has()` forever) and that stderr carries no `unbound variable` /
`command not found`.

## C3. Render-time sanitizer (after `render_load_context`, next to `VOICE_STT_LANG`)

```bash
# voice_phrase_effective FIELD RAW NICK MAX_BYTES DEFAULT_TEMPLATE → stdout (one line)
# FIELD ∈ {signoff, currency}: used ONLY in the warning message, never on stdout (analyze U3).
voice_phrase_effective() {
  local field raw nick max tpl v bytes
  v="$(_voice_phrase_clean "$raw" "$nick")"          # steps 1-4 of data-model §6
  bytes=$(printf '%s' "$v" | wc -c | tr -d ' ')      # BYTES in bash 3.2 and 5.x alike (CI matrix)
  …                                                   # step 5: empty / over MAX → default + WARN
}
```

`LC_ALL=C` goes on each external command inside `_voice_phrase_clean` (`LC_ALL=C tr …`,
`LC_ALL=C sed …`), never as `local LC_ALL=C` in the function body: implementation measured
(2026-09-18, bash 5.3.15 — the bash `bats` and `setup.sh` resolve to on the dev host and in
the ubuntu CI arm) an intermittent SIGSEGV (status 139, 3 of 15 `--regenerate` runs) when
bash restores the locale on return from a function that declared `local LC_ALL`; 0 of 15 with
the per-command form, and 0/15 either way under bash 3.2.57. The observable contract (bytes,
limits, WARN, outputs) is unchanged.

Inputs are the RAW `agent.yml` values, never the flattened `FEATURES_VOICE_*` variables (an
explicit YAML `null`/`~`/`Null` flattens to the string `null`; `yq -r '… // ""'` collapses
it to empty, the same mold as `VOICE_STT_LANG`):

```bash
local _vnick _vraw
_vnick=$(yq -r '.user.nickname // ""' "$agent_yml" 2>/dev/null)
_vraw=$(yq -r '.features.voice.signoff // ""' "$agent_yml" 2>/dev/null)
VOICE_SIGNOFF="$(voice_phrase_effective signoff "$_vraw" "$_vnick" 120 "$(voice_signoff_default "$_vlang")")"
_vraw=$(yq -r '.features.voice.currency // ""' "$agent_yml" 2>/dev/null)
VOICE_CURRENCY="$(voice_phrase_effective currency "$_vraw" "" 40 "$(voice_currency_default "$_vlang")")"
export VOICE_SIGNOFF VOICE_CURRENCY
```

Neither `FEATURES_VOICE_SIGNOFF` nor `USER_NICKNAME` is re-exported or altered (033 F1
lesson: `claude-md.tpl` consumes `USER_NICKNAME` verbatim). The WARN idiom is `setup.sh`'s
own: `echo "WARN: features.voice.${FIELD} is empty, null or over ${MAX} bytes — using the localized default" >&2`
(there is no `warn` helper in `setup.sh`; the message names the field — from the FIELD
parameter — and the reason, never the value).

Cases (host bats, `voice-config.bats`; near-limit cases in ASCII so both bash arms agree):

| Input `signoff` (nickname `Rodri`) | Rendered `TELEGRAM_VOICE_SIGNOFF` |
| --- | --- |
| default | `Eso es toda la información. Cambio y fuera, Rodri.` |
| default, nickname `` | `Eso es toda la información. Cambio y fuera.` |
| `Listo, {nickname}` | `Listo, Rodri` |
| `Con "comillas" y $dolar y {llaves} y \ barra` | `Con comillas y dolar y llaves y barra` |
| `Con<TAB>tab y<CR>retorno` (written with `yq -i`) | `Con tab y retorno` |
| 121+ ASCII characters | default (+ WARN mentioning `signoff`) |
| `""` | default (+ WARN) |
| `null` (explicit YAML null, `yq -i '… = null'`) | default (+ WARN) |
| `user.language: en`, default | `That is all the information. Over and out, Rodri.` |
| `currency: ~` | default currency (+ WARN mentioning `currency`) |

Documented negative (pre-existing behaviour, not a 034 feature): a multi-line scalar written
with `yq -i '.features.voice.signoff = "Línea uno\nlínea dos"'` makes `./setup.sh --regenerate`
exit non-zero (`run …; [ "$status" -ne 0 ]`) — `render_load_context` aborts on every
multi-line string field. The test comments why (second line multi-word, deterministic).

## C4. Compose template

```yaml
      TELEGRAM_VOICE_STT_LANG: "{{VOICE_STT_LANG}}"
      # 034: spoken style — closing phrase (nickname already substituted, sanitized:
      # no quotes/backslashes/dollar signs/braces, ≤ 120 bytes) and the word spoken
      # for a bare "$" amount. Unconditional, like the five lines above.
      TELEGRAM_VOICE_SIGNOFF: "{{VOICE_SIGNOFF}}"
      TELEGRAM_VOICE_CURRENCY: "{{VOICE_CURRENCY}}"
```

Oracles: `docker-render.bats` (title "the five…" → "the seven TELEGRAM_VOICE_* env lines",
+2 assertions); `voice-config.bats` unconditional test +2; `schema.bats` `known_external`
gains `VOICE_SIGNOFF VOICE_CURRENCY`; fixtures `tests/fixtures/sample-agent{,-with-vault}.yml`
gain both fields; e2e E2 asserts the English rendered values (`TELEGRAM_VOICE_SIGNOFF=That is
all the information. Over and out, Alice.`, `TELEGRAM_VOICE_CURRENCY=Chilean pesos`).

## C5. Wizard heredoc oracle (host bats, `voice-config.bats`)

Three tests drive the real wizard: `wizard_answers lang=es nick=Rodri | ./setup.sh
--destination …`, same with `lang=mixed`, same with `lang=en`; each asserts on `agent.yml`
that `.features.voice.signoff` is the TEMPLATE with `{nickname}` LITERAL (not substituted)
and `.features.voice.currency` the default by language, and on `docker-compose.yml` the
rendered `TELEGRAM_VOICE_SIGNOFF` with the nickname substituted. Asserting `agent.yml` is
what catches a heredoc mutation — the sanitizer's fallback would mask an omitted field in the
compose output.

## C6. `.env.example` and docs

`modules/env-example.tpl`: only the comment/default `TELEGRAM_VOICE_SPOKEN_CHAR_CAP=1200` →
`=900` ("spoken-reply cut budget: 900 chars ≈ 60 s"); oracle in `voice-config.bats` (T012 g):
`grep -q 'TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900' .env.example` and no `TELEGRAM_VOICE_SIGNOFF`
line (bats-live negative). The two style fields are NOT listed
(they are `agent.yml`-sourced; compose `environment:` takes precedence over `env_file`, so a
`.env` line would be silently ignored). README documents the two fields in the "Round-trip
voice" bullet.

## C7. Local mode

Nothing rendered (the 032 invariant `local-render.bats` FR-011 stays green by construction:
the two new lines live only in `docker-compose.yml.tpl`). `agent.yml` still carries the two
fields (harmless, documented).
