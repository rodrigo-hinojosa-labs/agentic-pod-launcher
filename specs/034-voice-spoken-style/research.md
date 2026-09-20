# Research — 034 voice spoken style (Phase 0)

**Branch**: `034-voice-spoken-style` | **Date**: 2026-09-16, remediated 2026-09-18 | **Spec**: [spec.md](spec.md)

Everything below is either **measured** (command run, file read, doc fetched — the source is
named) or a **decision** with its rationale and the alternatives rejected. Nothing is assumed.
The adversarial review of 2026-09-18 (plan.md "Adversarial review") changed D3, D4, D7, D8,
D11, D12, D14 and added D15; the "Review remediation" table at the end maps every finding.

## R — Measured baseline

### R1. Where the voice group lives today (v2, v0.24.0 = `main` @ `3534c6b`)

`docker/scripts/apply_telegram_typing_patch.py` (read 2026-09-16):

| Symbol | Line | Role |
| --- | --- | --- |
| `MARKER_VOICE_V1` / `MARKER_VOICE` (v2) | `:110-111` | gate + upgrade discriminator |
| `VOICE_HELPERS_V1` / `VOICE_HELPERS` | `:443` / `:550-693` | module-level config, STT/TTS, `_voiceTruncate`, matcher, cooldown; ends with the sentinel `// agentic-pod-launcher: voice helpers end (033)` |
| `VOICE_TEXT_WRAP_V1` / `VOICE_TEXT_WRAP` | `:786` / `:801` | `message:text` wrap (explicit-request matcher) |
| `VOICE_REPLY_BLOCK_V1` / `VOICE_REPLY_BLOCK` | `:824` / `:866` | outbound block in `case 'reply'` |
| `_REPLY_RETURN_V1` / `_REPLY_RETURN_V2` | `:849-850` | return line (`result` vs `result + _voiceOutcome`) |
| `VOICE_SCHEMA_PROPERTY_V1` / `VOICE_SCHEMA_PROPERTY` | `:912` / `:925` | `voice_text` + `voice_force` properties |
| `VOICE_INSTRUCTIONS_LINE_V1` / `VOICE_INSTRUCTIONS_LINE` | `:939` / `:948` | the contract line |
| `upgrade_voice_v1_to_v2` | `:1484` (pairs `:1507-1520`) | five exact pairs, all-or-nothing; its "new" side reads the LIVE constants |
| `apply_voice` | `:1523` | six hunks; gate `MARKER_VOICE in src or MARKER_VOICE_V1 in src` |
| `main` wiring | `:1632`, part `voice-upgrade-v1→v2` `:1709` | upgrader then `apply_voice` |

Facts that shape v3:

- The helpers hunk is anchored on `let botUsername = ''` — line **25** of the pristine
  plugin; the `instructions: [` array is at line **97** (`tests/fixtures/telegram-server-
  pristine.ts`). **Module-level constants defined by the helpers are in scope when the
  instructions array is built** → the v3 contract line can be a template literal that
  interpolates the configured language name and the spoken limit at runtime (D6).
- The synthesis request body is `{ text, model_id: VOICE_TTS_MODEL }` (`:512`); the STT
  request already appends `language_code` from `VOICE_STT_LANG` (`:496`). Model
  `eleven_flash_v2_5` (`:461`).
- `VOICE_SPOKEN_CHAR_CAP` default **1200** (`:456-458`); `_voiceTruncate` cuts at the last
  space above `cap/2`, else at `cap`, and appends `…` (`:90-95` of the helpers).
- The spoken text is assembled in the reply block as `spoken = _voiceFromText ?
  _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP) : voiceTextArg.trim()` (`:878-879`); the
  omission nag threshold is `VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)`
  (`:645`), compared against `spoken.length` (`:894`) — in v2 `spoken` carries NO closing
  phrase, so "spoken length" there means "narrated reply text" (D3 keeps that meaning).
- `_voiceNormalize` is **taken** (the 033 explicit-request matcher's NFD/lowercase helper) —
  the new narration normalizer is `_voiceSpokenNormalize`.
- The reply block is a separate constant injected into `case 'reply'` (it references `args`,
  `text`, `chat_id`, `bot.api.sendVoice`, `InputFile`); the e2e awk extraction (marker →
  sentinel) captures only the module-level helpers. Anything E10 must execute for real has to
  live in the helpers (D3).

### R2. Config surface today (032/033) and the oracles that churn

- `agent.yml` `features.voice.{enabled,reply_mode,voice_id,provider}`; wizard heredoc at
  `setup.sh:1262`; backfill in `regenerate()` gated on `has("voice")` (`setup.sh:2132-2143`,
  `yq -i`, never `//`). `regenerate()` declares `local agent_yml modules_dir os` only
  (`:2023-2027`); the only `local lang` in the file belong to other functions (`:1425`,
  `:1462`); `set -euo pipefail` at `:4`. **No `warn()` helper exists** in `setup.sh` or the
  libs it sources — warnings are `echo "WARN: …" >&2` (`:252`, `:259`, `:271`, …).
- Render-time sanitizers after `render_load_context` (`setup.sh:2160-2191`): `reply_mode`
  whitelist, `provider` forced, `voice_id` trimmed; **`VOICE_STT_LANG` is a DEDICATED derived
  placeholder read straight from `agent.yml` with `yq -r '.user.language // ""'`** (es|en
  pass, everything else empty) — the mold for the two new derived placeholders (D8). Reading
  the raw value with `// ""` is what collapses an explicit YAML `null`/`~` to empty; the
  flattened `FEATURES_*` variables carry the 4-character string `null` instead
  (`render.sh:61` uses `tostring`; measured by the review with yq 4.52.5).
- `render_load_context` (`render.sh:50-61`) splits a multi-line scalar into two `read` lines
  and exports the second as an invalid identifier → `setup.sh` aborts under `set -e` for ANY
  multi-line string field (pre-existing, measured in bash 3.2.57 and 5.3.15). A multi-line
  phrase is therefore out of scope, not sanitized (D8).
- `${#v}` counts bytes in `/bin/bash` 3.2.57 and characters in bash 5.3.15 when no locale is
  set (measured under `env -i`: the default Spanish phrase is 51 vs 50) — the CI matrix runs
  both. `local LC_ALL=C` inside the function pins bytes in both (D8).
- Compose: five `TELEGRAM_VOICE_*` lines rendered UNCONDITIONALLY (`modules/docker-compose.
  yml.tpl:80-84`), values double-quoted. `.env.example` documents `TELEGRAM_VOICE_MAX_NOTE_
  SECONDS=300` / `TELEGRAM_VOICE_SPOKEN_CHAR_CAP=1200` name-only (`modules/env-example.tpl:33-34`).
- Wizard variables: `user_nick` (`setup.sh:545`), `user_lang` (`:554`, choices `es en mixed`);
  heredoc `user:` block at `:1215-1219`.
- `tests/helper.bash:141-170` `wizard_answers` accepts no `lang=`/`nick=` kv and hard-codes
  `Alice / en`; `tests/quickstart-doc.bats:73-93` asserts its inline block markers
  (`Identity (4 prompts)`, `User (5 prompts)`, …) stay. Every wizard-driven test — including
  the DOCKER_E2E agent — is therefore `en`/`Alice` unless the helper gains the two kv (D12).
- `tests/schema.bats:80` registers derived placeholders in `known_external` (`VOICE_STT_LANG`
  is there) — the two new ones go in the same line.
- **Oracles that churn to v3** (re-verified by the review, 2026-09-18): `tests/apply-telegram-
  patches.bats` `:812` `:815` (`_voiceTruncate` → pipeline oracles), `:830` `:1052` `:1053`
  `:1060` (033 contract phrases replaced by the v3 wording — `:1053` "your full text is read
  aloud up to the cap" and `:1060` "Strongly recommended: when omitted" were missing from the
  first list), `:1075` `:1076` (omission line/condition move from `spoken.length` to the
  narrated length — D3), `:1140` (last-helper list gains the five new helpers), and every
  `patch v2` count taken on a file that WENT THROUGH the patcher (`:637 :651 :782 :867 :880
  :930 :967` become `patch v3`); `tests/docker-e2e-voice.bats:96 :156 :169 :228 :246`
  (`patch v2` greps and the awk range). **Stays**: `:945` — it is G4's out-of-band perl mutant
  on the golden v1 (it targets the frozen `VOICE_INSTRUCTIONS_LINE_V1`, which 034 does not
  touch; changing it would destroy the mutant and make `:948` fail for the wrong reason); the
  `patch v2` count on a golden left at v1 by a failed upgrade (`:950`) also stays. `tests/
  docker-render.bats:75` ("the five TELEGRAM_VOICE_* env lines") and `tests/voice-config.
  bats:149` become seven; e2e E2 (`:116-128`) title likewise.

### R3. Provider facts (ElevenLabs, fetched 2026-09-15/16)

- API reference `text-to-speech/convert` (fetched twice): body accepts `language_code` —
  "Language code (ISO 639-1) used to enforce a language for the model **and text
  normalization**. If the model does not support the provided language code, it will be
  ignored. This parameter is not supported for multilingual_v2 models." Fail-open by the
  provider's own contract; and it steers the provider's number normalization language, which
  is exactly the thousands-separator concern (R5).
- Same reference: `apply_text_normalization` enum `auto|on|off`, default `auto`; the current
  page carries **no model restriction sentence**. `pronunciation_dictionary_locators` (≤ 3)
  exists as a fallback lever for stubborn tokens (`UF`), not used in v3.
- Best-practices "normalization" page: "normalization is enabled by default for all TTS
  models"; its own examples read `$42.50` as "forty-two dollars and fifty cents" — i.e. the
  provider WILL say "dollars" for a bare `$` unless the symbol is named first. This is the
  measured justification for D4/D6 (symbol naming in the channel).

### R4. Prototype under bun (host bun 1.3.12; 2026-09-16, re-run 2026-09-18 after the review)

Scratch file `proto-spoken-v2.ts` (kept out of the repo) implements the contract of
[contracts/spoken-text-pipeline.md](contracts/spoken-text-pipeline.md) verbatim (normalizer,
sentence cut, key, strip, append, assemble) and runs:

- **Normalization table: 38/38 in Spanish + the English case** — the 21 original cases, the
  8 no-separator amounts the review added (`$1500`, `multa de $25000`, `US$ 1500`, `USD 2500`,
  `UF 1000`, `CLP 4500`, `vale $2024`, `1500 USD`), and the 9 layout cases (`---`, `***`,
  `* * *`, a lone `-` line, a table with its `|---|---|` row, an alignment row `|:---:|:---|`,
  a setext underline `=====`, `👍🏽` + flag, keycap `1️⃣`, plus `10:30` / `3.5%`).
- **Assembly invariants (cap 900, default sign-off "…, Rodri." = 50 chars)**: a narration of
  exactly `budget` chars ending in `;` → 899, no `;. `; ending in `:` → 899; a 2,000-char blob
  without spaces → 900 (hard cut) and trimmed; a 1,500-char list-heavy reply → 899, trimmed,
  ends with the sign-off; a single 1,500-char sentence → word boundary, 899; **a 811-char body
  + the sign-off written by the model → exactly one occurrence and `trimmed=false`** (the
  case the review measured as "heard twice" under the first design); an accent-less copy of
  the phrase at the end → one occurrence; a code-only reply → fixed sentence + sign-off; a
  rendition that IS the sign-off → fixed sentence + sign-off; an empty runtime phrase →
  nothing appended. With `VOICE_CAP=300` the same invariants hold (the 811-char body is then
  legitimately trimmed).
- **Cost of the sign-off strip**: 3.8 ms on a 1,200-char text in the naive form (scan every
  start index); the contract bounds the scan to the last `3 × signoff.length` characters,
  which is where a suffix can only start.
- **Re-measured after the analyze review (2026-09-18)**: with the figure group as `/…/.source`
  and the seven symbol rules as `String.raw` template literals, outputs are identical (38/38 +
  en); the new case (q) — 40 known sentences, 1,710 chars — cuts to exactly the longest
  sentence prefix that fits the budget (807 chars), which is the executable oracle for "last
  terminator within the budget".
- **Committed cases fixture**: `tests/fixtures/voice-spoken-cases.ts` — the prototype's table
  (38 Spanish + 1 English) as plain TS data (`const VOICE_SPOKEN_CASES`, no `export`), sha256
  `0b46410ea6c2559fa28ca45ba3feb7bf1d3a381cf0b3d4142dde9a28c418399a`, transpiles under host bun; E9 concatenates it after
  the extracted helpers (033 precedent: fixtures are executed, not transcribed).

Facts learned that bind the implementation:

- `/\p{Extended_Pictographic}/u` works under bun (JavaScriptCore); the class must also cover
  regional indicators (`\u{1F1E6}-\u{1F1FF}`), skin-tone modifiers (`\u{1F3FB}-\u{1F3FF}`,
  `Emoji_Modifier`, NOT pictographic), the keycap combining mark `\u{20E3}`, `\u{FE0F}` and
  `\u{200D}` — otherwise `👍🏽` leaves `🏽` and `1️⃣` leaves `1⃣`.
- Symbol order matters: `US$`/`USD` before the bare `$`, `CLP $` before `$`; a `$` not
  adjacent to a figure is dropped last.
- The figure group MUST be closed with `(?!\d)`: without it the first alternative
  (`\d{1,3}…`) wins in prefix rules and `$1500` becomes `150 pesos chilenos0` (measured);
  reordering the alternation instead breaks `1.234.567` and `12 500` (measured by the review).
- Horizontal rules must be removed BEFORE the emphasis pass (`***` → `*` otherwise) and table
  separator rows AFTER the pipe pass (they only become `--- ---` once pipes are gone).
- Line ends without a terminator get a period before joining, so list items and headings
  become sentences (`1. Uno\n2. Dos` → `Uno. Dos.`).
- The sign-off must be stripped from the end of the rendition BEFORE the cut (else the cut can
  land between the two sentences of the default phrase, and a rendition whose only overflow is
  the phrase is reported as trimmed) and re-appended AFTER it; the append normalizes a
  trailing `;`/`:` to `.` first (no `;. `), and the cut budget reserves `signoff.length + 2`
  (the separator can be two characters).
- The dedupe key used real combining characters in the scratch file; the patcher constant MUST
  spell them as `\\u0300-\\u036f` (D14).

### R5. What cannot be measured here and is deferred to the live gate

- How `eleven_flash_v2_5` reads a dotted Chilean figure (`1.234.567`) in Spanish with
  `language_code: es`, and a decimal comma (`1.234,50`). No synthesis key is available on the
  development host and the ferrari tunnel is behind an expired Cloudflare Access session; the
  key must never leave the agent's `.env` anyway. D9 picks the rule that needs no measurement
  to be SAFE (keep the figure as written, pass the language) and names the knob to turn if the
  live gate says the dots are misread.

## D — Decisions

### D1. Voice group v2 → v3: four rewritten constants, one new upgrader, frozen `_V2` twins

**Decision.** `MARKER_VOICE` becomes `…patch v3`; `MARKER_VOICE_V2` freezes the v2 string.
Four constants change and get a frozen `_V2` twin: `VOICE_HELPERS`, `VOICE_REPLY_BLOCK`,
`VOICE_SCHEMA_PROPERTY`, `VOICE_INSTRUCTIONS_LINE`. `VOICE_TEXT_WRAP` and `_REPLY_RETURN_V2`
are unchanged in v3 and get no new twin. New `upgrade_voice_v2_to_v3(src)`: four exact
`str.count(old) == 1` checks then four `str.replace`, all-or-nothing, WARN and return
unchanged on any miss — the 033 shape. `upgrade_voice_v1_to_v2` is **re-pointed at the `_V2`
twins** (today it reads the live constants as its "new" side; leaving that would make it
produce a v3-flavoured "v2" and break the golden-v2 oracle). `apply_voice` gates on
`MARKER_VOICE`, `_V1` and `_V2`. `main()` chains `v1→v2`, then `v2→v3`, then `apply_voice`,
and reports parts `voice-upgrade-v1→v2` / `voice-upgrade-v2→v3`. The no-change branch of `main()`
(silent today — the analyze review found four artifacts asserting a log line that no code
emits) gains a truthful line: `no changes to {path}: all patch groups already present`
(CANON-L1) when the seven markers are in, else `no changes to {path}: N/7 patch groups
present, remaining anchors not found`.

**Rationale.** Same mechanism the fleet already went through once (033); two agents are at v2
today and take the single-step path; an agent that skipped 033 takes both steps in one boot.

**Alternatives rejected.** (a) A direct `v1→v3` upgrader — a third set of pairs and no v2
golden oracle; (b) strip + fresh apply — no reliable strip once hunks interleave with upstream
code; (c) leaving the v1→v2 upgrader on the live constants — rejected above.

### D2. The v3 contract (instructions line + `voice_text` description)

**Decision.** The instructions line is rewritten as a **template literal** interpolating
`${VOICE_SPOKEN_CHAR_CAP}`, `${VOICE_SPOKEN_LANG_NAME}` and `${VOICE_CURRENCY}` (module-level
constants defined by the helpers, in scope per R1). Exact wording in
[contracts/spoken-style-contract.md](contracts/spoken-style-contract.md). The `voice_text`
description is rewritten (plain string). 033 substrings that other oracles rely on are kept;
the 033 sentence `include voice_text with a concise speakable version` and the description's
`your full text is read aloud up to the cap` / `Strongly recommended: when omitted` are
**replaced** — their four oracles (`:830 :1052 :1053 :1060`) move to the v3 wording.

### D3. Spoken-text pipeline: one module-level `_voiceSpokenAssemble`, called from the reply block

**Decision.** The whole assembly is a helper in `VOICE_HELPERS` v3 (before the sentinel), so
the e2e extraction executes the REAL composition and the reply block shrinks to a call:

```text
_voiceSpokenAssemble(raw) → { spoken, narrated, trimmed }
  t = _voiceSpokenNormalize(raw); if (!t) t = VOICE_EMPTY_SENTENCE
  t = _voiceSignoffStrip(t, VOICE_SIGNOFF); if (!t) t = VOICE_EMPTY_SENTENCE     // D7
  budget = max(cap − (signoff ? signoff.length + 2 : 0), floor(cap / 2))
  cut = _voiceSentenceCut(t, budget)                                             // D5
  spoken = _voiceSignoffAppend(cut.out, VOICE_SIGNOFF)                           // D7
  return { spoken, narrated: cut.out, trimmed: cut.trimmed }
```

Reply block v3: `const _voiceAsm = _voiceSpokenAssemble(_voiceFromText ? text :
voiceTextArg.trim())`, `const spoken = _voiceAsm.spoken`; synth as before;
`voice: sent (fmt, chars=spoken.length, ms)`; the 033 omission record and nag now use
`_voiceAsm.narrated.length` (the narrated text without the phrase — the SAME meaning `spoken`
had in v2, where no phrase existed; the ¼-cap rule is untouched); `else if
(_voiceAsm.trimmed)` adds `; voice_text trimmed to ${_voiceAsm.narrated.length} chars`.
`_voiceTruncate` is removed.

**Rationale.** FR-003/005/008/009 on both paths; E10 executes the real function (mutating
the helper turns E10 red); the +2 reserve keeps `spoken.length ≤ cap` (measured, R4); the
narrated basis keeps the 033 threshold meaning and puts nag and trim on the same number.

**Alternatives rejected.** Assembly inside the reply block (first design) — E10 could only
re-type the formula (tautological, review tests/F1); comparing the nag against the final
`spoken` — silently lowers the threshold by the phrase length and inflates the reported count
(review runtime/F4); a +1 reserve — overflows the cap by one on a hard cut or a `;` ending
(review patcher/F2, runtime/F3).

### D4. `_voiceSpokenNormalize(text)` — deterministic, regex-only, bun-verified

**Decision.** Fifteen ordered passes (contract C2): CRLF→LF; fenced code removed; inline code
unwrapped; `[text](url)`→text; bare URLs removed; heading hashes removed; **horizontal rules
and setext underlines removed** (`-`, `*`, `_`, `=` ×3+, alone on a line); `**`/`__`/`*`/`_`/
`~~` unwrapped; list bullets/numbering removed; block-quote `>` removed; pipes → spaces;
**table separator/alignment rows removed** (lines made only of `-`, `:`, spaces); pictographs
removed (Extended_Pictographic + regional indicators + skin tones + keycap + VS16 + ZWJ);
symbol naming in fixed order with the figure group closed by `(?!\d)`; each non-empty line
gets a terminator if it has none, lines joined by spaces; whitespace and space-before-
punctuation collapsed. Localized word table es (also the `mixed` default) / en; currency word
from `VOICE_CURRENCY`.

**Form of the regex sources (analyze I2).** The figure group is a regex literal's `.source`
(`const _VOICE_FIG = /…(?!\d)/.source`) and the seven symbol rules are `new RegExp(String.raw`…`,
'g')` — ONE backslash in the TS text, two in the Python literal, never a plain JS string with
doubled backslashes: that keeps D14 the only escape rule, matches the 033 precedent
(`_VOICE_REQUEST_NEGATION` is a literal) and lets every one-backslash oracle (`(?!\d)`,
`US\$|USD`) match the live line. Re-measured in this form: 38/38 + en, identical outputs.

**Rationale.** Everything a formatted reply carries that a listener should never hear, in a
form testable under bun without network (E9, 38 cases); no library.

### D5. Sentence-boundary cut and the empty-narration sentence

**Decision.** `_voiceSentenceCut(text, budget)`: if `text.length <= budget` return as is;
else last `[.!?;]` followed by whitespace/end within the budget; under `budget/4` → last
space; none → hard cut at the budget; trim; report `trimmed`. Empty narration speaks
`VOICE_EMPTY_SENTENCE` (es "El detalle va en el mensaje de texto." / en "The details are in
the text message.").

### D6. Language: one placeholder feeds model, synthesizer and word table

**Decision.** `VOICE_STT_LANG` (unchanged 032 derivation) is the single language signal:
synthesis body gains `...(VOICE_STT_LANG ? { language_code: VOICE_STT_LANG } : {})`;
`VOICE_SPOKEN_LANG_NAME` (`Spanish` / `English` / `the language the user wrote in`) feeds the
contract; the word table and localized defaults key on `VOICE_STT_LANG === 'en'` (`mixed` →
Spanish). No new field.

### D7. Sign-off: strip before the cut, append once after it

**Decision.** `_voiceKey` (NFD, strip `\\u0300-\\u036f`, lowercase, strip terminal
`.!?,;:\\u2026`, collapse spaces). `_voiceSignoffStrip(spoken, signoff)`: if the key of the
text ends with the key of the phrase, remove the longest suffix whose key equals the phrase
key (scan bounded to the last `3 × signoff.length` chars). `_voiceSignoffAppend(spoken,
signoff)`: empty phrase → unchanged; key-ending match → unchanged (defensive, after strip it
is normally false); else normalize a trailing `;`/`:` to `.`, then append with `. ` (or ` `
after `.!?`). Both run inside `_voiceSpokenAssemble` (D3).

**Rationale.** FR-003 "exactly once" now holds when the model writes the phrase at the end
of an over-budget rendition (review runtime/F5, measured R4) and the trim note stays honest.
A phrase written mid-text is accepted as not detected (spec edge case).

### D8. Configuration: two `agent.yml` fields, two derived placeholders, two compose lines

**Decision.**

- `features.voice.signoff` (may contain `{nickname}`) and `features.voice.currency`. Wizard
  heredoc writes localized defaults from `$user_lang` (`es`/`mixed` → Spanish; `en` →
  English) via `voice_signoff_default LANG` / `voice_currency_default LANG` — **no prompt**.
  `regenerate()` backfills each field under `has("signoff")` / `has("currency")` AFTER the 032
  whole-block backfill, reading the language ONCE inside the `[ -f "$agent_yml" ]` block
  (`_vlang=$(yq -r '.user.language // ""' "$agent_yml")`) — `regenerate()` has no `lang`
  local and runs under `set -u`; an undefined `$lang` would not abort but would persist an
  empty phrase that `has()` then protects forever (review config/F4). The 032 whole-block
  backfill writes both fields too.
- After `render_load_context`, two DEDICATED derived placeholders (mold `VOICE_STT_LANG`),
  fed from the RAW `agent.yml` values (`yq -r '.features.voice.signoff // ""'`, same for
  `currency`) — never from the flattened `FEATURES_VOICE_*` variables, which turn an explicit
  YAML `null`/`~` into the string `null` (review config/F3):
  `VOICE_SIGNOFF=$(voice_phrase_effective signoff "$_raw" "$_vnick" 120 "$(voice_signoff_default "$_vlang")")`,
  `VOICE_CURRENCY=$(voice_phrase_effective currency "$_raw" "" 40 "$(voice_currency_default "$_vlang")")`.
- `voice_phrase_effective FIELD RAW NICK MAX DEFAULT_TEMPLATE` (FIELD names the field in the
  warning only — analyze U3): `local LC_ALL=C` first (pins
  `${#v}` to bytes in bash 3.2 and 5.x — review config/F5); `{nickname}` → NICK via
  `_render_replace_all` (never `${var//}` — 023), dropping `, ` before it when NICK is empty;
  every byte < 0x20 and 0x7f → space; strip `"`, `\`, `$`, `{`, `}`; collapse spaces; trim; if
  empty or `${#v} > MAX` → output DEFAULT_TEMPLATE (same nickname rule) and
  `echo "WARN: features.voice.${FIELD} is empty, null or over ${MAX} bytes — using the localized default" >&2` once (setup.sh has no `warn`
  helper; that is its idiom). Limits are BYTES (≥ characters, conservative). A multi-line
  scalar is out of scope (R2).
- `modules/docker-compose.yml.tpl` gains `TELEGRAM_VOICE_SIGNOFF: "{{VOICE_SIGNOFF}}"` and
  `TELEGRAM_VOICE_CURRENCY: "{{VOICE_CURRENCY}}"`, unconditional. `tests/schema.bats`
  `known_external` gains both names. Fixtures `sample-agent{,-with-vault}.yml` gain both
  fields.
- `.env.example` only updates the cap comment `1200 → 900` (the fields are `agent.yml`-
  sourced; compose `environment:` beats `env_file`). README documents the two fields.

**Rationale.** Principle I; the 029/032 unconditional-render precedent; compose interpolates
`$` in `environment:` values (`$$` is the only escape) and YAML double quotes break on
`"`/`\` — stripping is simpler and safer in bash 3.2; default-instead-of-cut avoids splitting
a multibyte character; `LC_ALL=C` makes the branch deterministic across the CI matrix.

**Alternatives rejected.** `.env`-delivered knobs; a wizard prompt; empty = opt-out (review
config/F1: contradicts D3 "every audio" and the render already designed — an empty or null
value renders the default with one WARN; the runtime keeps `if (!signoff) return s` as a
defensive branch only).

### D9. Figures: keep as written, pass the language, name the knob

**Decision.** v3 does NOT rewrite digits or separators. It names symbols (D4), passes
`language_code` (D6), and the contract asks the model to write amounts in words. The live
gate (quickstart §3.4) measures a dotted figure on the FALLBACK path; if misread, the
follow-up is a one-line pass (strip thousands dots in es) — named here, not rediscovered.

### D10. Cap = maximum tier, default 900; nag derivation untouched

**Decision.** `VOICE_SPOKEN_CHAR_CAP` default `1200 → 900`; it is the cut budget's base (D3)
and is interpolated into the contract as the hard limit. `VOICE_OMISSION_NAG_CHARS =
Math.floor(cap / 4)` stays (225), compared against the narrated length (D3).

### D11. Fixtures and the anti-tautology oracle (033 D8, extended)

**Decision.** New committed golden `tests/fixtures/telegram-server-voice-v2.ts` generated ONCE
with the real v0.24.0 patcher (`git show 3534c6b:…` over the pristine); sha256
`5dc01bf3f7ce7e6106ade38a1ae053aba4ae01d134622e399c35cb939dd6cef0` (generated 2026-09-18 by
T001; a second frozen-patcher run and the current patcher on a copy both left it unchanged),
recorded in quickstart §0 and asserted by a fidelity test (`_V2` twins ⊂ golden v2, plus
`VOICE_HELPERS_V2 != VOICE_HELPERS` and `MARKER_VOICE_V2 in VOICE_HELPERS_V2`). Oracles:
G2 `sha(patcher(pristine)) == sha(patcher(golden_v2))`; G2c `== sha(patcher(golden_v1))`;
**G2d (intermediate state)**: importing the module, `upgrade_voice_v1_to_v2(golden_v1) ==
golden_v2` byte-for-byte and `upgrade_voice_v2_to_v3(golden_v2) == patcher(pristine)`. The
review (tests/F4, patcher/F3) measured that a corrupted `_V2` twin does NOT turn G2c red
(the re-pointed v1→v2 writes the corrupted twin and v2→v3 consumes the same constant, so the
cascade still converges); G2, G2b and G2d are the guards for that mutation — quickstart M5
says so.

### D12. Verification tiers

- **Host bats**: `apply-telegram-patches.bats` (G1-G16 of the upgrade contract, contract
  C1/C2 substrings, pipeline structure, no-voice byte-identity, whitelist, **the new-regex-
  literal oracle and the control-byte oracle on the patched OUTPUT** — D14), `voice-config.
  bats` (heredoc defaults es/en/mixed via `wizard_answers lang= nick=`, backfill both fields
  with the exact localized value and clean stderr, sanitizer table incl. `null`, tab/CR, `$`,
  `"`, `\`, braces, over-long ASCII → default + WARN, empty nickname, two regenerates
  byte-identical), `docker-render.bats` (+2, "seven"), `schema.bats`, `local-render.bats`
  (re-run), `regenerate.bats`.
- **`tests/helper.bash::wizard_answers` gains two optional kv `lang=` / `nick=`** (defaults
  `en` / `Alice`, existing call sites untouched, inline block markers preserved for
  `quickstart-doc.bats`) — the only way to give the wizard heredoc an oracle (review tests/F6;
  031 lesson: heredoc and backfill are different call sites).
- **DOCKER_E2E** (self-seeding, run for real): the harness agent is `en`/`Alice` by
  construction, so **every bun invocation of E9/E10/E11 sets its full environment on the
  command line** (`TELEGRAM_VOICE_STT_LANG= TELEGRAM_VOICE_CURRENCY= TELEGRAM_VOICE_SIGNOFF=
  'Eso es toda la información. Cambio y fuera, Rodri.' TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900 …`)
  and never relies on the compose `environment:`; E2 asserts the rendered English values
  (`TELEGRAM_VOICE_SIGNOFF=That is all the information. Over and out, Alice.`,
  `TELEGRAM_VOICE_CURRENCY=Chilean pesos`, title "seven"); E9 normalization table (38 + en);
  E10 assembly invariants (executing `_voiceSpokenAssemble` for real, with `TELEGRAM_VOICE_
  SPOKEN_CHAR_CAP` overrides); E11 `language_code` line (textual, by design — no network);
  E12 golden v2 → v3 in-container; E1/E7 markers and awk ranges → v3.
- **Live gate** (linus first, then donna): quickstart §3.

### D13. Docs, version, deploy order

VERSION `0.24.0 → 0.25.0` (MINOR); CHANGELOG; README "Round-trip voice" bullet; CLAUDE.md
"Telegram plugin patch" section: voice group **v3**. Deploy linus first (E6 parse check runs
before).

### D14. Literal rules (032/033 bug class — made precise by the review)

- Every TS backslash is doubled in the Python literal; every regex replacement is a `lambda`.
- **The silent class**: Python transforms its VALID escapes without any warning — `\1`-`\7`,
  `\b`, `\t`, `\r`, `\n`, `\f`, `\v`, `\a`, `\0`, `\x..`, `\u....`, `\U........` — so a
  backreference `\1` becomes byte 0x01 and `\b` becomes 0x08, `py_compile` accepts it, and bun
  parses a control byte inside a regex literal without error: the pass is simply dead
  (measured by the review: `**hi**` no longer unwraps, URLs are not removed). INVALID escapes
  (`\s \S \d \p \[ \* \/`) are preserved with a DeprecationWarning, which is why a PARTIAL
  omission passes every static gate. Raw CR/LF inside a regex literal is a bun SyntaxError
  (E6 catches it, loudly); a raw TAB inside a character class is semantically inert.
- **Host oracles** (upgrade contract G15/G16): after patching the pristine fixture, `grep -qF`
  each new TS sequence that contains a valid Python escape — `\bhttps?:`, `(.+?)\1/g` (the
  strong pass; the emphasis pass carries `(?<=\S)\1/g`), `/\r\n?/g`, `` [^`\n]* ``, `[^\]\n]*`, `[ \t]`, `\u{1F1E6}-\u{1F1FF}`,
  `\u{1F3FB}-\u{1F3FF}`, `\u{20E3}`, `\u{FE0F}`, `\u{200D}`, `\u0300-\u036f`, `\u2026` — and
  assert zero control bytes in the PATCHED OUTPUT (`run bash -c "LC_ALL=C grep -c
  $'[\x01-\x08\x0b\x0c\x0e-\x1f]' server.ts"; [ "$output" = 0 ]` — the pristine has none).
  The `$'\xcc\x80'` audit on the SOURCE files stays for real combining marks (a `\1` typed
  without doubling is two ASCII bytes in the `.py`; the 0x01 only exists in the output).
- The instructions template literal contains `${…}` — a plain Python string, so no brace
  doubling; tests `grep -F` the literal `${VOICE_SPOKEN_CHAR_CAP}` text.
- Quickstart mutations M10 (un-double `\1` in the emphasis pass) and M11 (`\b` in the URL
  pass) prove the oracles bite.

### D15. Harness facts that the tests must state, not assume

- The e2e agent is `en`/`Alice`; E9/E10/E11 pin their env on the command line (D12).
- An empty `TELEGRAM_VOICE_SIGNOFF` in a bun invocation means "no phrase", not "default" —
  E10 passes the Spanish phrase literally.
- `SPOKEN_CHAR_CAP=900` is redundant once the literal changes but is passed explicitly so
  the budget invariant does not depend on the default.

## Review remediation (adversarial review 2026-09-18, workflow `wf_75f8266f-62e`)

25 agents (4 lenses, 21 findings, one refuter each; 2 refuters hit the weekly limit — both
findings duplicate confirmed ones). 0 refuted, 19 confirmed by reading and executing.

| # | Finding (lens/id, severity after refutation) | Remediation |
| --- | --- | --- |
| 1 | patcher/F1 MEDIUM — no host oracle for the new regex literals (`\1`, `\b` silently become control bytes) | D14 rewritten; G15/G16 host oracles; M10/M11 |
| 2 | patcher/F2 LOW — budget reserve +1 overflows the cap by one (2-char separator, `;` ending) | D3 reserve +2; D7 `;:`→`.`; data-model invariant corrected (50-char default, not 55); E10 cases A/B/D |
| 3 | patcher/F3 (unverified, = tests/F4) — M5 wrongly credited G2c | D11 G2d; quickstart M5 rewritten |
| 4 | patcher/F4 MEDIUM — US4-5 "acknowledgement reports the omission" unreachable (88 chars < 225) | spec US4-5 rewritten (log always, ack note above threshold); nag basis = narrated text (D3) |
| 5 | patcher/F5 (unverified, = tests/F3) — churn map incomplete/imprecise | R2 churn list rewritten (`:1053 :1060 :1075 :1076 :1140`; `:945` stays) |
| 6 | runtime/F1 HIGH — figure pattern splits `$1500` → `150 … 0` | `(?!\d)` closes the figure group (D4, R4 measured); 8 E9 cases; M12 |
| 7 | runtime/F2 HIGH — `---`, `***`, table separator rows, skin tones, keycap survive | passes 6b/9c + extended pictograph class (D4, R4 measured 9 cases); FR-005; SC-003 |
| 8 | runtime/F3 MEDIUM — same as #2 plus `;. ` artefact | as #2 |
| 9 | runtime/F4 MEDIUM — nag compares/report the final spoken incl. phrase; `:1075 :1076` churn | D3 narrated basis; spec FR-008; R2 churn |
| 10 | runtime/F5 MEDIUM — cut inside a model-written phrase → heard twice; false trim note | D7 strip-before-cut; spec FR-003, US4-6, edge case; R4 measured |
| 11 | config/F1 HIGH — empty phrase both "opt-out" and "default" in the spec | Clarified: default (D8); spec US2-7, FR-003, SC-001, Independent Test rewritten |
| 12 | config/F2 HIGH — "real newline" case impossible (render-wide abort) | Out of scope, documented (R2, D8); spec FR-002/US2-9/edge case → tab/CR |
| 13 | config/F3 MEDIUM — YAML `null` rendered as the word "null" | sanitizer fed from raw `yq … // ""` (D8); case rows + test |
| 14 | config/F4 MEDIUM — `$lang`/`warn` do not exist in `regenerate()` | `_vlang`/`_vnick` read inside the block; `echo "WARN: …" >&2`; oracle asserts exact value + clean stderr (D8) |
| 15 | config/F5 LOW — `${#v}` bytes vs chars across the CI matrix | `local LC_ALL=C`; limits stated in bytes; near-limit tests ASCII (D8) |
| 16 | tests/F1 MEDIUM — E10 cannot execute the pipeline (lives in the reply block) | `_voiceSpokenAssemble` in the helpers (D3); M1/M2 mutate the helper |
| 17 | tests/F2 MEDIUM — e2e agent is `en`/`Alice`; env must be explicit | D12/D15; E2 asserts English values |
| 18 | tests/F3 MEDIUM — `:945` is G4's mutant; `:1053 :1060` missing | R2 churn list; G4 extended with a v3-count-0 assertion |
| 19 | tests/F4 MEDIUM — M5 does not turn G2c red | D11 G2d; M5 rewritten |
| 20 | tests/F5 MEDIUM — no oracle for accent-insensitive dedupe / empty phrase | E10 rows (accent-less copy; empty runtime phrase defensive); spec SC-001 |
| 21 | tests/F6 MEDIUM — wizard heredoc default has no oracle; backslash missing from the sanitizer table | `wizard_answers lang=/nick=` (D12); three wizard tests; backslash row |

## Analyze remediation (2026-09-18, workflow `wf_90956f20-903`)

3 lenses (coverage + constitution / cross-artifact consistency / executability against the real
tests and code), 18 findings, one refuter each, 0 refuted; 11 unique after dedup — 4 HIGH,
5 MEDIUM, 2 LOW, 0 CRITICAL; coverage 26/26. All 11 applied (operator decision 2026-09-18,
with the three design choices below).

| # | Finding | Remediation |
| --- | --- | --- |
| I1 HIGH | T004 asserted `!=` on all four `_V2` pairs while T005 leaves three identical → Phase 2 checkpoint RED by construction | T004 keeps the two D11 guards; the other three `!=` move to T007 (schema/instructions) and T018 (reply block), RED-first where each constant changes |
| I2 HIGH | one-backslash oracles vs "built as a string" rules; `(.+?)\1/g` count 2 impossible (emphasis pass has `(?<=\S)` in between) | **Decision: `.source` + `String.raw` (one backslash in the TS)**; CANON-FIG/R1…R7 in C2; T009 count 1 + `(?<=\S)\1/g`; pass-order greps `-F`; re-measured 38/38 |
| I3 HIGH | four artifacts asserted an "already applied" log the patcher never emits | **Decision: add a truthful no-change log line** (CANON-L1 / N-of-7 variant) in T005; T004 G3 greps it; T001 asserts sha only (the frozen v0.24.0 patcher is silent) |
| U1 HIGH | `const VOICE_SIGNOFF` placed after the boot log that reads it → TDZ ReferenceError at module load (measured) | placement fixed in C1/T008 (after `VOICE_MAX_BYTES`, before the boot log); order oracle in T007/G6 |
| C1 MEDIUM | E11 had no authoring task; E4 `patch v2` churn unassigned; T021 could not reach 12 | T010 authors E11; T017 churns E4 with `\|\| true` + labelled marker |
| U2 MEDIUM | the 38-case table existed only in the out-of-repo prototype | **Decision: committed fixture** `tests/fixtures/voice-spoken-cases.ts` (generated now, sha above); C8/T001/T010 point to it |
| U3 MEDIUM | sanitizer signature carried no field name for the per-field WARN | `voice_phrase_effective FIELD RAW NICK MAX DEFAULT` in C3, D8, data-model §6, T015 |
| U4 MEDIUM | single quotes inside the `-c '…'` body; unquoted heredoc with `$1500`; golden v2 never copied to `.e2e/`; redundant `SEED_FIXTURE` | harness rules written into C8, T010, T019; `setup()` copies; E12 uses `seed.sh <fixture>` like E7 |
| C2 MEDIUM | no executable oracle for "last sentence terminator within the budget"; no 1,200-char case | case (q) + terminator assertion on (m) in C8/T019, measured (807 chars) |
| I4 LOW | T012 pointed at `deployment-mode.bats` as the wizard mold; T013 said "after T016" | T012 → `scaffold.bats`/`docker-setup.bats`; T013 → T015 |
| C3 LOW | no oracle for the .env.example cap 900 / absent fields; T022 phrase without referent | T012(g) + C5 oracle; T022 reworded |
