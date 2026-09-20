# Contract — spoken-text pipeline (helpers v3 + reply block v3)

Everything here lives inside `VOICE_HELPERS` (v3) and `VOICE_REPLY_BLOCK` (v3) in
`docker/scripts/apply_telegram_typing_patch.py`. The whole assembly is a MODULE-LEVEL helper
(`_voiceSpokenAssemble`) so that DOCKER_E2E executes it for real by extracting the helpers
between the v3 marker and the sentinel `// agentic-pod-launcher: voice helpers end (033)`
(sentinel text kept verbatim — it is an end marker, not a version). The reply block only
calls it.

## C1. New module-level constants (immediately after `const VOICE_MAX_BYTES`, BEFORE the boot-log block)

```ts
const VOICE_SIGNOFF = (process.env.TELEGRAM_VOICE_SIGNOFF ?? '').trim()
const _VOICE_WORDS = VOICE_STT_LANG === 'en'
  ? { dollars: 'dollars', percent: 'percent', uf: 'unidades de fomento', empty: 'The details are in the text message.' }
  : { dollars: 'dólares', percent: 'por ciento', uf: 'unidades de fomento', empty: 'El detalle va en el mensaje de texto.' }
const VOICE_CURRENCY = (process.env.TELEGRAM_VOICE_CURRENCY ?? '').trim() || (VOICE_STT_LANG === 'en' ? 'Chilean pesos' : 'pesos chilenos')
const VOICE_SPOKEN_LANG_NAME = VOICE_STT_LANG === 'es' ? 'Spanish' : VOICE_STT_LANG === 'en' ? 'English' : 'the language the user wrote in'
const VOICE_EMPTY_SENTENCE = _VOICE_WORDS.empty
```

`VOICE_SPOKEN_CHAR_CAP` default literal changes `1200` → `900` (same expression otherwise).
The boot log line gains `signoff=${VOICE_SIGNOFF.length}chars` (length only — never the
phrase). All of C1-C6 sit BEFORE the sentinel; `_voiceTruncate` is deleted.

**Placement is load-bearing (analyze U1).** The boot-log block `if (!VOICE_ENABLED) { … } else
{ … }` is a top-level statement that will read `VOICE_SIGNOFF.length`; a `const` declared after
it is in its temporal dead zone at that point and throws `ReferenceError` at module load under
bun (measured) — the channel would flap at boot and no host test would see it. The five
constants go right after `const VOICE_MAX_BYTES = 20 * 1024 * 1024` and before that block.
Host oracle (G6): line of `const VOICE_SIGNOFF =` < line of `voice active mode=`; line of
`const VOICE_STT_LANG` < line of `const _VOICE_WORDS`. Function declarations (C2-C6) are
hoisted and free of this constraint.

## C2. `_voiceSpokenNormalize(input: string): string` — ordered passes

| # | Pass | Regex (TS source; in the Python literal every `\` is doubled) |
| --- | --- | --- |
| 1 | CRLF → LF | `/\r\n?/g` → LF |
| 2 | fenced code removed | `/```[\s\S]*?```/g` → one space |
| 3 | inline code unwrapped | ``/`([^`\n]*)`/g`` → `$1` |
| 4 | markdown link → text | `/\[([^\]\n]*)\]\((?:[^)\s]+)\)/g` → `$1` |
| 5 | bare URL removed | `/\bhttps?:\/\/\S+/gi` → one space |
| 6 | heading hashes removed | `/^[ \t]{0,3}#{1,6}[ \t]+/gm` → nothing |
| 6b | horizontal rules / setext underlines removed (BEFORE emphasis, else `***` → `*`) | `/^[ \t]*(?:[-*_=][ \t]*){3,}[ \t]*$/gm` → nothing |
| 7 | strong / emphasis / strike unwrapped | `/(\*\*\|__)(.+?)\1/g`, `/(\*\|_)(?=\S)(.+?)(?<=\S)\1/g`, `/~~(.+?)~~/g` → text (the `\|` here is the table escape for a regex alternation pipe) |
| 8 | list markers removed | `/^[ \t]*(?:[-*+•]\|\d+[.)])[ \t]+/gm` → nothing (same table escape) |
| 9 | block quote markers removed; every pipe character (U+007C) → one space | `/^[ \t]*>[ \t]?/gm` → nothing; a global replace of the pipe character with a space |
| 9c | table separator / alignment rows removed (AFTER pipes; strict class, never `\s`) | `/^[ \t]*[-:][-: \t]*$/gm` → nothing |
| 10 | pictographs removed | `/[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}\u{20E3}\u{FE0F}\u{200D}]/gu` → nothing |
| 11 | symbol naming, in this order | `US$`/`USD` + figure; figure + `USD`; `UF` + figure; figure + `UF`; `CLP`/`CLP$`/`$` + figure; figure + `CLP`; figure + `%`; then any remaining `$` → one space (data-model §7) |
| 12 | lines → sentences | each non-empty trimmed line gets `.` unless it ends in `[.!?;:]`; joined by one space |
| 13 | whitespace | `/\s+([.,;:!?])/g` → `$1`; `/\s{2,}/g` → one space; trim |

Figure group and symbol rules (pass 11) — exact TS source, ONE backslash in the TS text (two in
the Python literal); the `.source` / `String.raw` form is mandatory (analyze I2: a plain JS
string would carry doubled backslashes in the TS and defeat every one-backslash oracle):

```ts
const _VOICE_FIG = /(?:\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?!\d)/.source   // CANON-FIG
t = t.replace(new RegExp(String.raw`(?:US\$|USD)\s*(${_VOICE_FIG})`, 'g'), `$1 ${_VOICE_WORDS.dollars}`)   // CANON-R1
t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\s*USD\b`, 'g'), `$1 ${_VOICE_WORDS.dollars}`)          // CANON-R2
t = t.replace(new RegExp(String.raw`\bUF\s*(${_VOICE_FIG})`, 'g'), `$1 ${_VOICE_WORDS.uf}`)                // CANON-R3
t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\s*UF\b`, 'g'), `$1 ${_VOICE_WORDS.uf}`)                // CANON-R4
t = t.replace(new RegExp(String.raw`(?:CLP\s*\$?|\$)\s*(${_VOICE_FIG})`, 'g'), `$1 ${VOICE_CURRENCY}`)      // CANON-R5
t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\s*CLP\b`, 'g'), `$1 ${VOICE_CURRENCY}`)               // CANON-R6
t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\s*%`, 'g'), `$1 ${_VOICE_WORDS.percent}`)             // CANON-R7
t = t.replace(/\$/g, ' ')
```

`_VOICE_FIG` is declared inside the function (or right above it) — never above the C1 constants.
The `${_VOICE_FIG}` inside `String.raw` is plain text in the Python literal (no f-string, no
brace doubling), exactly like the instructions template literal. Re-measured in this form under
bun 1.3.12: 38/38 + the English case, identical outputs (research R4).

Guarantees: idempotent on its own output; plain prose passes unchanged except whitespace;
words are never altered (only symbols adjacent to figures); the figure pattern accepts
`1.234.567`, `1.234,50`, `12,5`, `500`, `12 500`, `1500`, `25000`.

Regex facts measured under bun 1.3.12 (host) and re-verified in-container by E9: `\p{…}` with
the `u` flag, lookbehind `(?<=\S)`, `\u{1F1E6}` code-point escapes all supported.

## C3. `_voiceSentenceCut(text: string, budget: number): { out: string; trimmed: boolean }`

- `text.length <= budget` → `{ out: text, trimmed: false }`.
- else `head = text.slice(0, budget)`; `at` = end of the last match of `[.!?;](?=\s|$)` in
  `head`; if `at < budget / 4` → `at = head.lastIndexOf(' ')`; if `at <= 0` → `at = budget`;
  `{ out: text.slice(0, at).trim(), trimmed: true }`.

## C4. `_voiceKey`, `_voiceSignoffStrip`, `_voiceSignoffAppend`

```ts
function _voiceKey(s: string): string {
  return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[.!?,;:\u2026]+$/g, '').replace(/\s+/g, ' ').trim()
}
// Remove a copy of the sign-off the model wrote at the END of its rendition (any case,
// accents, punctuation): the longest suffix whose key equals the sign-off key. Scan bounded
// to where such a suffix can start (last 3 × signoff.length characters).
function _voiceSignoffStrip(spoken: string, signoff: string): string {
  const s = spoken.trim()
  if (!signoff) return s
  const k = _voiceKey(signoff)
  if (!k || !_voiceKey(s).endsWith(k)) return s
  const from = Math.max(0, s.length - 3 * signoff.length)
  for (let j = from; j <= s.length; j++) {
    if (_voiceKey(s.slice(j)) === k) return s.slice(0, j).trim()
  }
  return s
}
function _voiceSignoffAppend(spoken: string, signoff: string): string {
  let s = spoken.trim()
  if (!signoff) return s
  const k = _voiceKey(signoff)
  if (k && _voiceKey(s).endsWith(k)) return s
  s = s.replace(/[;:]+$/, '.')
  const sep = /[.!?]$/.test(s) ? ' ' : (s.length ? '. ' : '')
  return s + sep + signoff
}
```

(`\u0300-\u036f` and `\u2026` above are literal six-character escape sequences in the TS
source — never real combining marks or a real ellipsis glyph. 033 rule; see C9.)

## C5. Synthesis request body (v3)

```ts
body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL, ...(VOICE_STT_LANG ? { language_code: VOICE_STT_LANG } : {}) }),
```

Oracle (host + E11): the exact line above is present once; `language_code` appears in the
synth request only there; the STT line is unchanged. E11 is a textual assertion by design (no
network in e2e).

## C6. `_voiceSpokenAssemble(raw)` (helpers) and the reply block (v3)

```ts
function _voiceSpokenAssemble(raw: string): { spoken: string; narrated: string; trimmed: boolean } {
  let t = _voiceSpokenNormalize(raw)
  if (!t) t = VOICE_EMPTY_SENTENCE
  t = _voiceSignoffStrip(t, VOICE_SIGNOFF)
  if (!t) t = VOICE_EMPTY_SENTENCE
  const budget = Math.max(VOICE_SPOKEN_CHAR_CAP - (VOICE_SIGNOFF ? VOICE_SIGNOFF.length + 2 : 0), Math.floor(VOICE_SPOKEN_CHAR_CAP / 2))
  const cut = _voiceSentenceCut(t, budget)
  return { spoken: _voiceSignoffAppend(cut.out, VOICE_SIGNOFF), narrated: cut.out, trimmed: cut.trimmed }
}
```

Reply block v3 (replacing the two-line `spoken` assignment of v2):

```ts
const voiceTextArg = args.voice_text as string | undefined
const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())
const _voiceAsm = _voiceSpokenAssemble(_voiceFromText ? text : (voiceTextArg as string).trim())
const spoken = _voiceAsm.spoken
```

then the 033 try/catch/finally unchanged in shape (`_voiceStep`, synth, send, `voice: sent
(fmt=…, chars=${spoken.length}, ms=…)`, failure line, cooldown), with the omission block
re-based on the NARRATED length and one new branch:

```ts
if (_voiceFromText) {
  process.stderr.write(`telegram channel: voice tts spoke ${_voiceAsm.narrated.length} chars without voice_text chat=${chat_id}\n`)
  if (_voiceAsm.narrated.length > VOICE_OMISSION_NAG_CHARS) {
    _voiceOutcome += `; voice_text omitted — ${_voiceAsm.narrated.length} chars of text were read aloud`
  }
} else if (_voiceAsm.trimmed) {
  _voiceOutcome += `; voice_text trimmed to ${_voiceAsm.narrated.length} chars`
}
```

Structural oracles (host): inside the helpers, line order `_voiceSpokenNormalize(` <
`VOICE_EMPTY_SENTENCE` < `_voiceSignoffStrip(` < `_voiceSentenceCut(` < `_voiceSignoffAppend(`
within `_voiceSpokenAssemble`, and the whole function before the sentinel; in the reply
block, `_voiceSpokenAssemble(` < `_voiceSynthesize(`; the omission line, the nag condition and
the trim note all contain `_voiceAsm.narrated.length`; `_voiceTruncate` absent from the file;
`chars=${spoken.length}` kept in the `voice tts ok` line.

## C7. stderr lines (033 grammar; quantities re-based, no new line)

- `telegram channel: voice tts ok chat=… chars=<spoken.length> fmt=… ms=…` — final spoken
  length (sign-off included).
- `telegram channel: voice tts spoke <narrated.length> chars without voice_text chat=…` —
  narrated text (sign-off excluded), the 033 meaning.
- No `trimmed=` field in the log (the acknowledgement carries the trim).

## C8. E9 / E10 tables (bun, in-container, no network)

The e2e agent is `en`/`Alice` by construction (`wizard_answers`), so EVERY bun invocation
pins its environment on the command line and never relies on the compose `environment:`.
Harness rules (analyze U4, measured): the test body is a single-quoted `-c '…'` string, so
inner values use DOUBLE quotes — a bare single quote closes the body; TS appended to
`/tmp/helpers.ts` goes through a QUOTED heredoc (`<<"TS"`) because the cases carry `$1500`
and backticks; `docker compose run -e` is not a substitute (container-scoped, cannot differ
between the two bun invocations):

```sh
TELEGRAM_VOICE_STT_LANG= TELEGRAM_VOICE_CURRENCY= \
TELEGRAM_VOICE_SIGNOFF="Eso es toda la información. Cambio y fuera, Rodri." \
TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900 TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
```

(an empty `TELEGRAM_VOICE_SIGNOFF` means "no phrase", not "default" — E10 passes the phrase
literally; the English case runs with `TELEGRAM_VOICE_STT_LANG=en TELEGRAM_VOICE_CURRENCY=`.)

E9 — the cases live in the COMMITTED fixture `tests/fixtures/voice-spoken-cases.ts` (plain TS
data, no `export`: `const VOICE_SPOKEN_CASES: { in: string; want: string; lang?: string }[]`;
38 Spanish + 1 `lang: 'en'`; sha256 `0b46410ea6c2559fa28ca45ba3feb7bf1d3a381cf0b3d4142dde9a28c418399a`,
generated once from the Phase 0 prototype, measured 38/38 + 1/1 under bun 1.3.12). `setup()`
copies it into `.e2e/`; E9 concatenates helpers + fixture + a runner and runs the Spanish
entries under the Spanish env and the `en` entry under the English env.

E10 — `_voiceSpokenAssemble` executed for real: (a) rendition without the phrase → appended
once; (b) with the phrase, same case; (c) different case; (d) no final period; (e) no accents;
(f) partial phrase → full phrase appended after it; (g) empty rendition → fixed sentence +
phrase; (h) rendition that IS the phrase → fixed sentence + phrase; (i) 811-char body + the
phrase → one occurrence and `trimmed === false`; (j) exactly-budget narration ending in `;` →
`spoken.length <= 900` and no `;. `; (k) `:` ending → `<= 900`; (l) 2,000-char blob without
spaces → `<= 900`, trimmed; (m) 1,500-char list-heavy → `<= 900`, trimmed, ends with the
phrase, AND `narrated` ends in a sentence terminator; (n) 1,500-char single sentence → word
boundary; (o) `_voiceSignoffAppend('Hola', '')` → `'Hola'`; (p) the same (l)/(m) under
`TELEGRAM_VOICE_SPOKEN_CHAR_CAP=300` → `<= 300`; (q) sentence-boundary cut (analyze C2): 40
known sentences `Oración número N con contenido de prueba.` joined by spaces (1,710 chars, no
markup, no phrase) → `trimmed === true` and `narrated` equals the LONGEST prefix of whole
sentences that fits the budget `max(900 − (50 + 2), 450)`, computed in the test (measured:
807 chars) — this is the oracle for "last terminator within the budget", which (l)/(m)/(n)
alone do not prove.

## C9. Literal rules and their host oracles (research D14)

Every `\` in the passes above is doubled in the Python literal. Python's VALID escapes
(`\1`-`\7 \b \t \r \n \f \v \a \0 \x \u \U`) transform silently — `\1` → 0x01, `\b` → 0x08 —
and bun parses a control byte inside a regex literal without error (the pass is just dead), so
two host oracles exist (upgrade contract G15/G16): `grep -qF` of every new sequence that
contains a valid escape (`\bhttps?:`, `(.+?)\1/g` — the strong pass, `(?<=\S)\1/g` — the
emphasis pass, `/\r\n?/g`, `` [^`\n]* ``, `[^\]\n]*`, `[ \t]`, `\u{1F1E6}-\u{1F1FF}`,
`\u{1F3FB}-\u{1F3FF}`, `\u{20E3}`, `\u{FE0F}`, `\u{200D}`, `\u0300-\u036f`, `\u2026`, and the
one-backslash rule texts `(?!\d)/.source`, `String.raw`(?:US\$|USD)`) in the PATCHED output,
and zero control bytes in that output.
