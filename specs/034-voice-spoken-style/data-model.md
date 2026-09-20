# Data model — 034 voice spoken style

No persistent storage changes. Every entity below is either configuration (in `agent.yml`,
rendered to compose environment) or a per-reply in-memory value inside the patched plugin.

## 1. Voice style configuration (`agent.yml` → compose environment)

| Field (`agent.yml`) | Type | Default (by `user.language`) | Rendered as | Sanitized by |
| --- | --- | --- | --- | --- |
| `features.voice.signoff` | string, may contain `{nickname}` | es / mixed: `Eso es toda la información. Cambio y fuera, {nickname}.` — en: `That is all the information. Over and out, {nickname}.` | `TELEGRAM_VOICE_SIGNOFF` via derived placeholder `VOICE_SIGNOFF` | `voice_phrase_effective` (raw value from `agent.yml`, nickname substitution, control chars → space, strip `" \ $ { }`, ≤ 120 bytes else default + WARN) |
| `features.voice.currency` | string | es / mixed: `pesos chilenos` — en: `Chilean pesos` | `TELEGRAM_VOICE_CURRENCY` via derived placeholder `VOICE_CURRENCY` | same, no placeholder, ≤ 40 bytes |

Rules:

- Written by the wizard heredoc with the localized default; never prompted.
- Backfilled by `--regenerate` when `.features.voice` exists without the field (`has()`), or
  together with the whole block when `.features.voice` is absent (032 path). The language is
  read once inside `regenerate()`'s `[ -f "$agent_yml" ]` block.
- Survive `--regenerate` (operator edits are never overwritten). Two consecutive runs are
  byte-identical.
- An empty value or an explicit YAML `null` renders the default (one WARN) — not an opt-out.
- Rendered unconditionally in docker mode; never rendered in local mode.

Existing runtime value with a new default: `TELEGRAM_VOICE_SPOKEN_CHAR_CAP` `1200 → 900`.

## 2. Runtime constants and helpers (module level, patched plugin, v3)

| Symbol | Source / definition | Values |
| --- | --- | --- |
| `VOICE_SIGNOFF` | `TELEGRAM_VOICE_SIGNOFF` trimmed | `''` ⇒ append nothing — defensive only, unreachable through config |
| `VOICE_CURRENCY` | `TELEGRAM_VOICE_CURRENCY` trimmed, else language default | free text |
| `VOICE_SPOKEN_CHAR_CAP` | env if > 0 else **900** | the maximum tier and the cut budget base |
| `VOICE_OMISSION_NAG_CHARS` | `floor(cap / 4)` (033, unchanged) | 225 by default; compared against the NARRATED length |
| `VOICE_SPOKEN_LANG_NAME` | from `VOICE_STT_LANG` | `Spanish` / `English` / `the language the user wrote in` |
| `_VOICE_WORDS` | from `VOICE_STT_LANG === 'en'` | `{dollars, percent, uf, empty}` es or en |
| `VOICE_EMPTY_SENTENCE` | `_VOICE_WORDS.empty` | fixed localized sentence |
| `_voiceSpokenNormalize(s)` | pipeline contract C2 | spoken-safe text |
| `_voiceSentenceCut(s, budget)` | C3 | `{ out, trimmed }` |
| `_voiceKey(s)` | C4 | normalized comparison key |
| `_voiceSignoffStrip(s, signoff)` | C4 | text without a trailing copy of the phrase |
| `_voiceSignoffAppend(s, signoff)` | C4 | text ending with the phrase, once |
| `_voiceSpokenAssemble(raw)` | C6 | `{ spoken, narrated, trimmed }` — the whole pipeline |

Removed: `_voiceTruncate`.

## 3. Spoken rendition (per reply, in memory — `_voiceSpokenAssemble`)

| Attribute | Type | Set by |
| --- | --- | --- |
| `source` | `agent` / `fallback` | `_voiceFromText` (033) |
| `raw` | string | `voiceTextArg.trim()` or `text` |
| `normalized` | string | `_voiceSpokenNormalize(raw)`; empty ⇒ `VOICE_EMPTY_SENTENCE` |
| `stripped` | string | `_voiceSignoffStrip(normalized, VOICE_SIGNOFF)`; empty ⇒ `VOICE_EMPTY_SENTENCE` |
| `budget` | integer | `max(cap − (signoff ? signoff.length + 2 : 0), floor(cap / 2))` |
| `narrated`, `trimmed` | string, boolean | `_voiceSentenceCut(stripped, budget)` |
| `spoken` | string | `_voiceSignoffAppend(narrated, VOICE_SIGNOFF)` — what is synthesized |
| `chars` | integer | `spoken.length` — reported in `voice tts ok` and `voice: sent` |

Invariants (measured, research R4): `spoken.length ≤ cap` whenever `signoff.length + 2 ≤
floor(cap / 2)` — always true with the render limit of 120 bytes for any cap ≥ 244; the
default phrase renders to 50 characters. The phrase is present exactly once when configured.
The text sent to synthesis contains no `*`, `#`, `` ` ``, `[`, `](`, `http`, `$`, `%`,
horizontal rules, table separator rows or pictographs. A rendition whose only overflow is a
phrase the agent wrote itself has `trimmed = false`.

## 4. Reply acknowledgement (extended, 033 grammar preserved)

```text
sent (id: N)                                          ← unchanged (no voice)
sent (id: N)\nvoice: sent (fmt=ogg, chars=C, ms=M)    ← voice ran, agent supplied voice_text within budget
… \nvoice: sent (…); voice_text trimmed to N chars    ← agent's voice_text exceeded the budget (NEW token; N = narrated length)
… \nvoice: sent (…); voice_text omitted — N chars of text were read aloud   ← 033, fallback with narrated length > threshold
… \nvoice: failed (step=synth|send, cls=…, status=…)  ← 033
```

Whitelist of tokens after `voice:`: `sent`, `failed`, `fmt`, `chars`, `ms`, `step`, `cls`,
`status`, `voice_text omitted`, `voice_text trimmed to N chars`. Never the spoken text, the
reply text, a URL or raw error text.

## 5. Voice patch group version (state machine, extended)

```text
pristine ──apply_voice──────────────────────────────▶ v3
v1 ──upgrade_voice_v1_to_v2──▶ v2 ──upgrade_voice_v2_to_v3──▶ v3
v3 ──(any run)──▶ v3   (no-op; logs `no changes to <path>: all patch groups already present`)
```

- Gate: `apply_voice` refuses any file carrying `MARKER_VOICE` (v3), `MARKER_VOICE_V2` or
  `MARKER_VOICE_V1`.
- `upgrade_voice_v2_to_v3`: four pairs; each `old` must occur exactly once; any miss ⇒ WARN,
  file unchanged (stays v2, functional).
- `upgrade_voice_v1_to_v2` (033): its "new" side is re-pointed to the frozen `_V2` twins.
  Intermediate-state oracle (G2d): `upgrade_voice_v1_to_v2(golden_v1) == golden_v2`.
- Frozen twins never edited again: `*_V1` (033), `*_V2` (034). Golden fixtures:
  `telegram-server-voice-v1.ts` (033), `telegram-server-voice-v2.ts` (034).

## 6. Sanitizer `voice_phrase_effective` (host, `setup.sh`)

Input: `FIELD` (`signoff` | `currency`, used only in the warning), `RAW` (the raw `agent.yml`
value via `yq -r '… // ""'` — an explicit `null`/`~` collapses to empty here), `NICK`, `MAX`
(bytes), `DEFAULT_TEMPLATE`. Output: one line on stdout; `WARN: features.voice.${FIELD} is
empty, null or over ${MAX} bytes — using the localized default` on stderr when the default
replaces the input.

| Step | Rule |
| --- | --- |
| 0 | Byte-oriented: `LC_ALL=C` on each EXTERNAL command (`tr`, `sed`) and the length measured with `printf '%s' "$v" \| wc -c`. **Not** `local LC_ALL=C` inside the function — the review's original design; implementation (2026-09-18) measured bash 5.3.15 segfaulting (status 139) in 3 of 15 `--regenerate` runs when it restores the locale on return from a function that declared `local LC_ALL`, 0 of 15 with the per-command form (bash 3.2.57: 0/15 either way) |
| 1 | `{nickname}` → `NICK` (`_render_replace_all`, literal); when `NICK` is empty, `, {nickname}` → `` first, then any residual `{nickname}` → `` |
| 2 | every byte < 0x20 and 0x7f → space (tab, CR; a multi-line scalar never reaches here — pre-existing render abort) |
| 3 | delete `"`, `\`, `$`, `{`, `}` |
| 4 | collapse runs of spaces; trim |
| 5 | empty or `${#value} > MAX` → output `DEFAULT_TEMPLATE` after steps 1-4 (same nickname rule) and WARN once |

Applied as `voice_phrase_effective signoff … 120 …` and `voice_phrase_effective currency … 40 …`
(`NICK=""` for currency).

## 7. Symbol naming table (fixed, in the plugin)

| Token (adjacent to a figure) | es (also `mixed`) | en |
| --- | --- | --- |
| `US$ N`, `USD N`, `N USD` | `N dólares` | `N dollars` |
| `UF N`, `N UF` | `N unidades de fomento` | `N unidades de fomento` |
| `$ N`, `CLP N`, `CLP$ N`, `N CLP` | `N <currency>` (default `pesos chilenos`) | `N <currency>` (default `Chilean pesos`) |
| `N %` | `N por ciento` | `N percent` |
| `$` not adjacent to a figure | dropped | dropped |

Figure pattern (whole figure, never split): `(?:\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?!\d)` —
digits are never rewritten (research D9).
