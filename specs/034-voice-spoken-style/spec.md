# Feature Specification: Voice spoken style — the agent's audio is a summarized narration, in the configured language, with amounts spoken in the configured currency and a closing phrase that marks the end

**Feature Branch**: `034-voice-spoken-style`

**Created**: 2026-09-15

**Status**: Draft

**Input**: User description: "Every time an agent answers in audio, the written reply must stay exactly as it is today (the agent's own output rules apply to it); the AUDIO, however, must be much more summarized, must always end with a phrase saying that is all the information, must use spoken language (amounts said in Chilean pesos, not symbols), must be in the same language the agent is configured with, and must close with a phrase that marks the end of the audio, for example 'cambio y fuera, Rodri'. The channel guarantees the closing phrase and the spoken-safe form of what is synthesized; the agent produces the summary under a stated style contract. Eight design decisions were taken by the operator in a structured round on 2026-09-15 before this spec was written (see below) and are input, not open questions. Real-time conversation is a separate feature (035). Builds on 032 (round-trip voice) and 033 (voice reply feedback); the voice patch group moves v2→v3."

## Measured defect (input to this spec, verified 2026-09-13/15)

Agent `linus` (docker, ferrari), Telegram chat, after the 033 deploy. Source: the operator's
own audios, the plugin's stderr capture (`logs/telegram-mcp-stderr.log`) and the live patched
plugin source.

1. **The audio reads the written reply almost verbatim.** A five-item numbered list is dictated
   item by item; headings and bold markers are read as symbols; a reply that summarizes in
   ~20 seconds produces a 76-second bubble (`voice tts ok ... chars=1138`). When the agent
   does supply a spoken rendition it is better — but its style varies turn to turn, because the
   channel's contract only asks for "a concise speakable version" and says nothing about
   length, numbers, language or closing.
2. **Amounts and figures are read as text.** `$1.234.567` is ambiguous when synthesized: the
   `$` sign can be read as "dollars" or skipped, and the Chilean thousands separator (a dot)
   can be read as a decimal point. The operator wants to hear "un millón doscientos treinta y
   cuatro mil quinientos sesenta y siete pesos chilenos".
3. **There is no end-of-audio mark.** The listener cannot tell whether the audio was cut off or
   simply ended. The operator wants EVERY audio to close with a phrase such as "Eso es toda la
   información. Cambio y fuera, Rodri."
4. **The spoken language is not guaranteed.** The agent's configured language (`user.language`
   in `agent.yml`: `es`, `en` or `mixed`) already reaches the transcription step (032) but is
   never passed to the synthesis step, which auto-detects — so a reply with anglicisms or a
   mixed-language answer can be voiced with the wrong accent or pronunciation.

**Measured speaking rate.** 1,138 characters took 76 seconds ⇒ ~15 characters per second of
Spanish narration. Every length tier in this spec is derived from that rate (30 s ≈ 450
characters, 45 s ≈ 700, 60 s ≈ 900).

**What does not change.** The written reply is untouched in every respect — content, format,
the agent's output rules. Only what is spoken changes.

## Operator decisions (input to this spec — decided 2026-09-15, not to be re-asked)

| # | Decision |
| --- | --- |
| D1 | This feature is **034**. The real-time "receptionist" feature moves to **035**. |
| D2 | **Hybrid enforcement.** The channel does everything that can be deterministic (append the closing phrase, strip markup/lists/emojis, name currency and percent symbols, pass the language to synthesis). The agent does the summarizing, under a reinforced, explicit style contract. Deterministic parts must be testable outside a live chat. |
| D3 | **Closing phrase** is a configuration field of the agent (`features.voice.signoff`) with a default; the channel appends it to EVERY synthesized audio, de-duplicating if the agent already wrote it. |
| D4 | **Audio length**: target ~30 s, adaptive to ~45 s or ~60 s according to how much information the answer carries — chosen by density, never by detail; always a summary; 60 s is the maximum. The three tiers are stated in the contract. |
| D5 | **Language**: the configured language reaches both the agent (the contract says "speak in `<language>`") and the synthesizer. `mixed` ⇒ the audio mirrors the language of the incoming message (synthesizer auto-detect). No new field. |
| D6 | **Figures and amounts**: deterministic symbol naming in the channel (`$` → the configured currency word, default "pesos chilenos"; `USD` → dollars; `UF` → unidades de fomento; `%` → por ciento) plus a contract clause asking the agent to write amounts in spoken form. Full number-to-words conversion in the channel is rejected (large, two languages, many edge cases). |
| D7 | **Omitted spoken rendition**: the channel applies the same normalization to the written reply, trims it at a SENTENCE boundary to the maximum tier, appends the closing phrase, and the acknowledgement keeps naming the omission (033). "Do not synthesize" is rejected (it contradicts 033's strict audio request). |
| D8 | **Default closing phrase**: "Eso es toda la información. Cambio y fuera, {nickname}." with `{nickname}` taken from the agent's `user.nickname`; localized by language (en: "That is all the information. Over and out, {nickname}."). Empty nickname ⇒ the comma and the name are dropped. |

## Clarifications

### Session 2026-09-15 (during specify — the two items the operator left open in D8/FR-016)

- Q: For `user.language: mixed`, which language do the localized defaults (closing phrase,
  currency word, dollars/percent words, empty-narration sentence) fall back to? → A: Spanish.
  `mixed` describes a Spanish-speaking operator mixing English technical terms — the whole
  current fleet; the two configurable fields cover any agent that needs otherwise.
- Q: Does the spoken hard cap keep its 1200 default alongside a separate 900 maximum tier, or
  become the maximum tier itself? → A: The cap IS the maximum tier: default 900, one knob, the
  `.env` override raises or lowers the maximum narration; a 1200 ceiling would never bind once
  narrations are cut at 900. The 033 omission-report threshold stays ¼ of the cap (225),
  untouched.

### Session 2026-09-18 (post-plan adversarial review — 21 findings, all remediated; see research.md)

- Q: Is an empty `features.voice.signoff` an opt-out? → A: No. Operator decision D3 says
  "every synthesized audio"; an empty or null value renders the localized default with one
  warning. The runtime phrase is never empty by construction; the runtime still tolerates an
  empty value (appends nothing) as a defensive branch only.
- Q: What does the 033 omission report count once the closing phrase is appended? → A: The
  narrated text only (closing phrase excluded) — the same meaning it had in 033. The rule (¼
  of the cap) is untouched; the compared/reported quantity is the narration before the phrase.
- Q: Multi-line phrase in `agent.yml`? → A: Out of scope: a multi-line YAML scalar is a
  pre-existing render-wide hard failure for every string field. The sanitizer flattens control
  characters (tab, carriage return) only.
- Q: Length limit unit? → A: 120 bytes for the phrase, 40 for the currency word, counted
  locale-independently (conservative: never fewer than the character count).
- Q: What if the agent wrote the closing phrase itself and the rendition is over budget? → A:
  The channel removes the phrase from the end BEFORE the cut and re-appends it after, so the
  cut never lands inside the phrase and such a rendition is not reported as trimmed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The spoken rendition is a summarized narration under an explicit style contract (Priority: P1)

As the operator listening to an agent's voice bubble, I want the audio to be a short spoken
summary of the answer — a few sentences in natural speech, in my configured language, with
amounts said in words and the currency named — rather than the written reply read aloud, so
that I can absorb the answer without watching the screen and without sitting through a
minute-long dictation of a formatted list.

**Why this priority**: This is the whole point of the feature. Everything else (closing phrase,
symbol naming, fallback) protects the result when the agent falls short; the contract is what
makes the agent produce the right thing in the first place. Without it the deterministic
pieces polish a bad narration.

**Independent Test**: Apply the channel patch to a pristine plugin source and read the
channel's stated contract (instructions and the spoken-rendition field description). It must
name, in one place: summary-not-dictation; the three length tiers with 60 s as the maximum;
plain spoken prose (no markup, code, lists, emojis, URLs); amounts and figures in spoken form
with the currency named; the configured language (or "the user's language" for `mixed`); and
that the closing phrase is added by the channel, so the agent must not write it. The same
contract must result whether the patch is applied fresh or as an upgrade of a v1 or v2
plugin source. Live: five voice exchanges with a list-heavy topic yield five audios of ≤ 60 s
that summarize rather than enumerate.

**Acceptance Scenarios**:

1. **Given** a pristine plugin source, **When** the patch is applied, **Then** the channel's
   contract to the agent contains every clause listed in the Independent Test, and the
   spoken-rendition field description says it is a narration of ~30 s by default, up to ~60 s
   when the information warrants it, never a reading of the text.
2. **Given** a plugin source already at voice patch v2 (every docker agent after the 033
   deploy), **When** the boot patch runs, **Then** the source is upgraded in place to v3 and the
   resulting file is byte-identical to a fresh v3 application on the pristine source.
3. **Given** a plugin source still at voice patch v1 (an agent that skipped 033), **When** the
   boot patch runs, **Then** the v1→v2→v3 cascade runs in one boot and converges to the same
   byte-identical v3.
4. **Given** a v3 plugin source, **When** the boot patch runs again, **Then** nothing changes
   (idempotent) and the patch log says so (`no changes … all patch groups already present`).
5. **Given** the contract is in place and the operator sends a voice note asking for a status
   summary that the agent answers in text with a seven-item list, **When** the agent replies,
   **Then** the written reply keeps its list intact and the audio is a spoken summary of ≤ 60 s
   that does not enumerate the items one by one.
6. **Given** an agent configured in Spanish and an answer containing `$1.234.567`,
   **When** the agent produces the spoken rendition, **Then** the audio says the amount in
   words followed by "pesos chilenos", and no symbol is read aloud.

---

### User Story 2 - Every audio ends with the configured closing phrase, exactly once (Priority: P1)

As the operator, I want every voice bubble to end with a recognisable closing phrase —
"Eso es toda la información. Cambio y fuera, Rodri." by default — so that I always know the
audio finished rather than being cut off, and so that the phrase is mine to configure per
agent without touching code.

**Why this priority**: It is the one guarantee the operator asked for with the word "always".
It is cheap, deterministic, and it is the piece a prompt alone cannot promise (033's lesson:
a deterministic signal beats one more instruction line).

**Independent Test**: Configure `features.voice.signoff` in `agent.yml` (or leave the default),
regenerate, and confirm the rendered runtime configuration carries the phrase with the
nickname substituted. Then, under a real script runtime with the network disabled, feed the
channel's spoken-text assembly (a) a rendition that does not end with the phrase, (b) one that
already ends with it (any case, accents or trailing punctuation), (c) an over-budget rendition
that ends with the phrase, (d) an empty rendition — and confirm the phrase is present exactly
once in all four, (c) is not reported as trimmed when only the phrase overflowed, and (d)
speaks the fixed fallback sentence before it. Live: five consecutive audios each end with the
phrase, once.

**Acceptance Scenarios**:

1. **Given** a fresh scaffold with `user.language: es` and `user.nickname: Rodri`, **When** the
   wizard writes `agent.yml`, **Then** `features.voice.signoff` is
   `"Eso es toda la información. Cambio y fuera, {nickname}."` and the rendered runtime value
   is `Eso es toda la información. Cambio y fuera, Rodri.`
2. **Given** `user.language: en` and `user.nickname: Alice`, **When** the wizard writes
   `agent.yml`, **Then** the default is `"That is all the information. Over and out, {nickname}."`
   and renders as `That is all the information. Over and out, Alice.`
3. **Given** an empty `user.nickname`, **When** the phrase is rendered, **Then** it reads
   `Eso es toda la información. Cambio y fuera.` — no dangling comma, no placeholder left.
4. **Given** a pre-034 workspace (no `features.voice.signoff` field), **When** the operator runs
   `--regenerate`, **Then** the field is backfilled with the localized default and the
   operator's other `features.voice.*` values are untouched.
5. **Given** the agent supplies a spoken rendition that does not end with the phrase,
   **When** the audio is synthesized, **Then** the spoken text is the rendition followed by the
   phrase, separated as a new sentence.
6. **Given** the agent already wrote the closing phrase at the end of its rendition (same
   words, any capitalization, with or without the final period), **When** the audio is
   synthesized, **Then** the phrase appears once, not twice.
7. **Given** the operator sets `features.voice.signoff: ""` (or `null`), **When** the workspace
   is rendered, **Then** the localized default is rendered instead, the render log warns once
   naming the field, and every audio still ends with that default — an empty phrase is not an
   opt-out (decision D3: every audio).
8. **Given** the agent omitted the spoken rendition and the channel fell back to the written
   reply (US4), **When** the audio is synthesized, **Then** it still ends with the phrase.
9. **Given** the operator sets a phrase containing a tab or carriage return, a double quote, a
   dollar sign, a backslash or braces, **When** the workspace is rendered, **Then** the value is
   flattened to one line with those characters removed; **Given** a phrase longer than 120
   bytes, **Then** the localized default is rendered instead and the render log says so once.
   (A multi-line YAML value is a pre-existing render-wide failure for every string field and
   is not handled here.)

---

### User Story 3 - What reaches the synthesizer is spoken-safe: no markup, symbols named, language passed (Priority: P2)

As the operator, I want the channel itself to guarantee that whatever text goes to the
synthesizer contains no markup, no list bullets, no emojis, no URLs, and no bare currency or
percent symbols — and that the synthesizer is told which language to speak — so that a lapse
in the agent's rendition (or the fallback to the written reply) never produces an audio that
reads "asterisco", "numeral" or "dollars" for a Chilean peso amount.

**Why this priority**: It is the deterministic safety net under US1. The contract asks the
agent to comply; this makes the worst case tolerable. Second priority only because with a
compliant agent it changes nothing audible.

**Independent Test**: Under a real script runtime with the network disabled, run the channel's
spoken-text normalization over a fixed table of at least twenty inputs covering headings,
bold/italic, inline and fenced code, links, bullet and numbered lists, emojis, `$`, `US$`,
`CLP`, `USD`, `UF`, `%`, mixed cases and already-clean prose; every output must match its
expected spoken form. Separately, confirm on the synthesis request path that the configured
language is included for `es`/`en` and absent for `mixed`. Live: ten audios contain no spoken
markup, no emoji sound, and no "dollars" for a `$` amount.

**Acceptance Scenarios**:

1. **Given** spoken text `**Total:** $1.234.567 (12% más que ayer)` and an agent configured
   in Spanish with the default currency, **When** it is normalized, **Then** the synthesizer
   receives `Total: 1.234.567 pesos chilenos (12 por ciento más que ayer)` with no markup and
   no symbols. (Whether the thousands separator is kept, dropped or spaced is settled by the
   Phase 0 measurement noted under Assumptions; the requirement is that the figure is heard
   correctly.)
2. **Given** spoken text with a numbered list of three items, **When** it is normalized,
   **Then** the items become three sentences separated by periods, with no digits-and-dot
   prefixes and no bullet characters.
3. **Given** spoken text containing a markdown link, **When** it is normalized, **Then** the
   link text is kept and the URL is removed entirely; **Given** a bare URL, **Then** it is
   removed entirely.
4. **Given** spoken text containing emojis, **When** it is normalized, **Then** the emojis are
   removed and the surrounding spacing is collapsed.
5. **Given** `US$ 500` and `USD 500`, **When** normalized in Spanish, **Then** both become
   `500 dólares`; **Given** `UF 30`, **Then** `30 unidades de fomento`.
6. **Given** an agent configured with `user.language: en`, **When** the same inputs are
   normalized, **Then** the words are English (`percent`, `dollars`) and the bare `$` uses the
   configured currency word (default `Chilean pesos`).
7. **Given** an agent configured with `user.language: es` or `en`, **When** an audio is
   synthesized, **Then** the synthesis request names that language; **Given** `mixed`,
   **Then** no language is named and the synthesizer auto-detects (mirroring the user's
   message).
8. **Given** spoken text that is already plain prose with no symbols, **When** it is
   normalized, **Then** it is unchanged apart from whitespace collapsing.
9. **Given** the configured currency word is changed in `agent.yml` to `pesos`, **When** the
   workspace is regenerated and an amount is normalized, **Then** the bare `$` becomes `pesos`.
10. **Given** spoken text containing a horizontal rule (`---`, `***`), a table with its
    separator row, a heading underline, a skin-tone emoji or a keycap emoji, **When** it is
    normalized, **Then** none of them leaves a residue: rules, separator rows and underlines
    vanish, table cells become words, and the emoji leaves nothing behind.
11. **Given** an amount written without separators (`$1500`, `USD 2500`, `UF 1000`),
    **When** it is normalized, **Then** the whole figure precedes the word (`1500 pesos
    chilenos`) — never a split figure with a stray digit after the word.

---

### User Story 4 - A missing or oversized spoken rendition degrades to a clean, bounded narration (Priority: P2)

As the operator, I want an audio that is still listenable when the agent forgets the spoken
rendition or writes one that is too long: the channel should narrate a cleaned, sentence-cut
version of the reply within the maximum tier and close it properly, and it should keep telling
the agent — in the same turn — that the rendition was missing or trimmed.

**Why this priority**: 033 already guarantees an audio is sent and that omission is reported;
what is missing is that the fallback audio is currently the raw written reply, markup and all,
cut mid-word at the cap. This story bounds the worst case without changing the strict
"an audio always goes out" behaviour.

**Independent Test**: Under a real script runtime with the network disabled, run the fallback
assembly over a 1,500-character list-heavy reply with no spoken rendition and confirm the
result is normalized, ends at a sentence boundary within the maximum tier, and closes with the
phrase; run it over a 1,200-character spoken rendition and confirm it is cut at a sentence
boundary and the acknowledgement reports the trim with a character count only. Fixture-level:
the acknowledgement grammar for the trim note is exactly as specified and carries no spoken
text.

**Acceptance Scenarios**:

1. **Given** the agent omits the spoken rendition and the written reply is 1,500 characters
   of headings and bullets, **When** the audio is synthesized, **Then** the spoken text is the
   normalized reply cut at the last sentence boundary within the maximum tier, followed by the
   closing phrase, and the acknowledgement still reports the omission (033 grammar unchanged).
2. **Given** the agent supplies a 1,200-character spoken rendition, **When** the audio is
   synthesized, **Then** the rendition is cut at the last sentence boundary within the maximum
   tier, the closing phrase is appended, and the acknowledgement adds a trim note naming only
   the resulting character count.
3. **Given** a spoken rendition within the maximum tier, **When** the audio is synthesized,
   **Then** nothing is trimmed and no trim note appears.
4. **Given** a reply whose first sentence alone exceeds the maximum tier, **When** the fallback
   cuts it, **Then** it cuts at the last word boundary within the tier instead of returning an
   empty narration.
5. **Given** a written reply that normalizes to nothing (for instance, only a code block),
   **When** the fallback runs, **Then** the audio speaks a short fixed sentence pointing to the
   text message, followed by the closing phrase; the omission is recorded in the log as always,
   and the acknowledgement carries the 033 omission note only when the narrated text exceeds
   the derived threshold — which the fixed sentence never does.
6. **Given** the agent's rendition ends with the closing phrase and is over budget only
   because of it, **When** the audio is synthesized, **Then** the phrase is removed before the
   cut and re-appended after it, the audio says it exactly once, and no trim note appears.

---

### Edge Cases

- **Closing phrase already present in a different form.** The agent writes "cambio y fuera
  Rodri" without the first sentence, or with different punctuation. De-duplication compares the
  normalized ending only against the full configured phrase; a partial match is not a match, so
  the configured phrase is appended after it. Acceptable: the audio says the short form then
  the full form once. The contract tells the agent not to write the phrase at all.
- **Closing phrase written by the agent at the end of an over-budget rendition.** The phrase
  is removed before the cut (any case, accents, punctuation) and re-appended after it, so the
  cut can never land inside it and the rendition is not reported as trimmed when only the
  phrase overflowed. A phrase written in the MIDDLE of a rendition is not detected — accepted;
  the contract forbids writing it.
- **Spoken rendition shorter than the closing phrase.** Appending still applies; the audio is
  the rendition plus the phrase.
- **Closing phrase in `mixed` language agents.** The default is a single string; the audio
  language mirrors the user's message, so the Spanish default phrase may follow an English
  narration. Decided (Clarifications, 2026-09-15): for `user.language: mixed` every localized
  default (closing phrase, currency word, dollars/percent words, the fixed empty-narration
  sentence) falls back to Spanish — `mixed` describes a Spanish-speaking operator who mixes
  English technical terms, the case of the whole current fleet; an agent that needs otherwise
  edits the two configurable fields in `agent.yml`.
- **Configured phrase with tabs or carriage returns, quotes, dollar signs, backslashes or
  braces.** Sanitized at render time (control characters to spaces, those characters removed);
  over 120 bytes, empty, or an explicit YAML `null` → the localized default is rendered and
  the render log says so once. The runtime never sees an unsafe value, and a multibyte
  character is never cut in half (no truncation at all — default instead). A multi-line YAML
  scalar aborts the render for every string field today (pre-existing) and is out of scope.
- **`$` immediately followed by a non-digit** (e.g. `$variable` in a code fragment that survived
  normalization). Only `$` adjacent to a digit (with optional spaces and thousands separators)
  is named; a bare `$` elsewhere is dropped.
- **Amounts with decimals** (`$1.234,50`): the figure is kept as the agent wrote it after the
  symbol is named; whether the decimal comma is heard correctly depends on the synthesizer and
  is part of the Phase 0 measurement.
- **Several amounts in one rendition** — each symbol occurrence is named independently.
- **Agent wrote the amount in words already** ("un millón de pesos"): normalization must not
  touch words; only symbols are replaced.
- **Fallback cut leaves a dangling colon or conjunction** at the sentence boundary — accepted;
  the boundary rule is "last sentence terminator within the tier", not a grammar check.
- **Operator has overridden the spoken cap in the workspace `.env`** (032/033 documented
  `TELEGRAM_VOICE_SPOKEN_CHAR_CAP`): decided (Clarifications, 2026-09-15) — the cap IS the
  maximum tier. Its default moves from 1200 to 900 characters; an operator who raises it in
  `.env` raises the maximum narration length (the 30 s / 45 s tiers stated in the contract are
  fixed text and do not read it). A cap of 1200 would never have applied once narrations are
  cut at the 60 s tier — one knob instead of a dead one. The 033 omission-report threshold
  stays derived as ¼ of the cap (now 225 by default); that code is not touched.
- **`always` reply mode.** Every synthesized audio gets the closing phrase, including the
  agent's own follow-up messages; the 033 failure cooldown (which skips synthesis) is
  unaffected — no audio, no phrase.
- **Agent skipped 033** (plugin still at voice v1): the cascade v1→v2→v3 runs in one boot; if
  the v1→v2 step fails (out-of-band edit), the v2→v3 step does not run and the file stays at
  the highest matching version, with a warning — the 033 rule, extended one step.
- **Out-of-band edit of a v2 file.** The v2→v3 upgrade is all-or-nothing: if any of its
  anchors is missing, nothing is rewritten, a warning is logged, and the plugin keeps working
  at v2.
- **Synthesizer ignores the language.** The synthesis API documents that an unsupported
  language code is ignored, not rejected; the audio still goes out (auto-detected).
- **Local (non-docker) deployment mode.** No voice runtime variables are rendered; the new
  fields exist in `agent.yml` and are documented, but nothing reads them.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (Style contract)**: The channel's stated contract to the agent MUST define the
  spoken rendition as a summarized narration of the answer — never the written reply read
  aloud — and MUST state, in one place: (a) the three length tiers (about 30 seconds by
  default; about 45 or 60 seconds only when the amount of information warrants it; 60 seconds
  is the maximum; never enumerate a list item by item); (b) plain spoken prose with no markup,
  code, lists, emojis or URLs; (c) figures, dates and percentages in spoken form and amounts
  followed by the currency name; (d) the language to speak — the configured language, or
  "the language the user wrote in" when the configuration is `mixed`; (e) that the closing
  phrase is appended by the channel and MUST NOT be written by the agent. The spoken-rendition
  field description MUST carry the same tier and language statements.
- **FR-002 (Closing phrase configuration)**: `agent.yml` MUST gain `features.voice.signoff`,
  a free-text phrase that MAY contain the placeholder `{nickname}`. The wizard MUST write a
  localized default derived from `user.language` (es: "Eso es toda la información. Cambio y
  fuera, {nickname}."; en: "That is all the information. Over and out, {nickname}."; `mixed`:
  the Spanish default). `--regenerate` on a workspace without the field MUST backfill
  the same default without touching other `features.voice.*` values. The rendered runtime value
  MUST have `{nickname}` replaced by `user.nickname`, MUST drop the preceding comma and space
  when the nickname is empty, MUST have control characters (tab, carriage return) flattened to
  spaces and double quotes, dollar signs, backslashes and braces removed, MUST fall back to
  the localized default (with one render-time warning naming the field) when empty, explicitly
  null, or longer than 120 bytes (a conservative, locale-independent count), and MUST survive
  `--regenerate`. A multi-line value is a pre-existing render-wide failure and is out of scope.
- **FR-003 (Closing phrase appended, once)**: For every audio the channel synthesizes — whether
  from the agent's rendition or from the fallback — the channel MUST append the configured
  closing phrase as a final sentence (the rendered phrase is never empty by construction,
  FR-002; an empty runtime value, defensive only, appends nothing). BEFORE cutting (FR-008,
  FR-009) the channel MUST remove a copy of the phrase that the agent wrote at the END of its
  rendition (case-, accent- and terminal-punctuation-insensitive), so that the cut never lands
  inside it and such a rendition is not reported as trimmed; AFTER cutting it MUST NOT append
  the phrase when the normalized ending already equals the normalized phrase. Net effect: the
  phrase is heard exactly once.
- **FR-004 (Currency word configuration)**: `agent.yml` MUST gain `features.voice.currency`,
  the word(s) spoken for a bare `$` (or `CLP`) amount, with a localized default (es:
  "pesos chilenos"; en: "Chilean pesos"; `mixed`: the Spanish default), backfilled on
  `--regenerate` like FR-002, and rendered to the runtime as a single sanitized line.
- **FR-005 (Spoken-safe normalization)**: Before synthesis, the channel MUST transform the
  spoken text so that: headings, bold, italic, strikethrough and inline-code markers are
  removed leaving their text; fenced code blocks are removed entirely; links keep their text
  and lose their URL; bare URLs are removed; horizontal rules, heading underlines and table
  separator/alignment rows are removed entirely and table cell separators become spaces;
  bullet and numbered list items become sentences terminated by a period; emojis and
  pictographs — including flags, skin-tone modifiers, keycaps and joiner sequences — are
  removed; runs of whitespace and line breaks collapse to single spaces. The transformation
  MUST leave already-plain prose unchanged apart from whitespace.
- **FR-006 (Symbol naming)**: As part of FR-005, the channel MUST replace, wherever they
  qualify an adjacent figure: `$` and `CLP` with the configured currency word; `US$` and `USD`
  with the localized word for dollars; `UF` with "unidades de fomento"; `%` with the localized
  word for percent. Replacement words MUST follow the figure in the natural spoken order of
  the language ("500 dólares", "12 por ciento"). A figure MUST be matched whole (`$1500` →
  `1500 pesos chilenos`, never a split figure with a stray digit after the word). A `$` not
  adjacent to a figure MUST be dropped. Words already present MUST NOT be altered.
- **FR-007 (Language to synthesis)**: The channel MUST pass the configured language to the
  synthesizer when it is `es` or `en`, and MUST NOT pass any language when it is `mixed` or
  anything else, reusing exactly the sanitized value the transcription step already receives
  (032). A synthesizer that ignores the language MUST NOT cause the audio to fail.
- **FR-008 (Fallback narration)**: When the agent omits the spoken rendition, the channel MUST
  narrate the written reply after applying FR-005/FR-006, cut at the last sentence terminator
  within the maximum tier (falling back to the last word boundary when no terminator fits, and
  to a short fixed localized sentence pointing to the text message when nothing remains), with
  the closing phrase appended per FR-003. The 033 omission report MUST keep its rule
  (threshold = ¼ of the cap) and its meaning: the quantity it records in the log and compares
  against the threshold is the narrated text, closing phrase excluded — the log line is always
  written, the acknowledgement note only above the threshold.
- **FR-009 (Oversized rendition)**: When the agent's spoken rendition exceeds the maximum tier,
  the channel MUST cut it at the last sentence terminator within the tier (word boundary as
  fallback), append the closing phrase, and add to the acknowledgement's voice line the note
  `; voice_text trimmed to N chars`, where N is the narrated character count (closing phrase
  excluded). No trim note MUST appear when nothing was cut, including when the only overflow
  was a closing phrase the agent wrote itself (FR-003).
- **FR-010 (Written reply and inapplicable-voice acknowledgement untouched)**: The written reply
  MUST be byte-identical to today's in every case. When voice does not apply to a reply (feature
  disabled, reply mode `never`, exchange not voice-originated and not forced, expired origin),
  the acknowledgement MUST be byte-identical to v0.24.0's.
- **FR-011 (Upgrade path)**: The voice patch group MUST move from v2 to v3 with an in-place
  upgrade that is all-or-nothing (either every v2 constant is rewritten or none is, with a
  warning), idempotent (a second pass is a no-op), and convergent: applying the boot patch to a
  pristine source, to a v1 source and to a v2 source MUST produce byte-identical v3 files, with
  all seven marker groups present. The v1 and v2 frozen constants MUST never be edited again;
  the upgrade oracle MUST be a committed golden v2 fixture generated once from the v0.24.0
  patch, not the current file's own frozen constants.
- **FR-012 (Disclosure whitelist)**: The acknowledgement and the stderr log MUST carry only
  counts and named fields (format, characters, milliseconds, step, class, status, trim count).
  They MUST NOT carry the spoken text, the written reply, URLs, or raw error text. The 033
  whitelist is extended by exactly one field (the trim count).
- **FR-013 (Deployment modes)**: In docker mode the two new runtime values MUST be delivered
  unconditionally alongside the existing voice values, so that enabling voice never requires a
  re-scaffold. In local mode no voice runtime value MUST be rendered into any runtime artifact
  (033/032 invariant extended to the new values). The two new values are sourced from
  `agent.yml` only (a `.env` line would be ignored, since the rendered runtime values take
  precedence), so the `.env` example MUST NOT list them; it MUST keep documenting the spoken
  cap with its new default, and the user documentation MUST describe the two fields.
- **FR-014 (No wizard prompt)**: The wizard MUST NOT ask for the closing phrase or the currency
  word; it MUST write the localized defaults into `agent.yml`, where the operator edits them.
- **FR-015 (Privilege and image invariants)**: The feature MUST NOT add capabilities, mounts,
  ports or image changes; the patch stays fail-silent on anchor drift (Principle IV).
- **FR-016 (Spoken cap is the maximum tier)**: The existing runtime tuning value for spoken
  characters MUST become the maximum narration length: its default MUST change from 1200 to
  900 characters (the 60 s tier), the fallback cut (FR-008) and the oversized-rendition cut
  (FR-009) MUST use it as their limit, and an operator override in the workspace `.env` MUST
  raise or lower that limit accordingly. The 033 omission-report threshold MUST keep its
  derivation as ¼ of the cap (225 by default) with no change to that rule. The documented
  name of the value MUST NOT change.
- **FR-017 (Release discipline)**: The launcher version MUST be bumped MINOR (0.24.0 → 0.25.0),
  the changelog MUST record the change, and the user documentation MUST describe the spoken
  style, the closing phrase and the two new configuration fields.

### Key Entities

- **Spoken rendition**: the text the channel narrates for one reply — the agent's `voice_text`
  when supplied, else the fallback narration of the written reply — after normalization,
  trimming and closing-phrase append. Attributes: source (agent | fallback), character count,
  trimmed (yes/no), closing phrase applied (yes/no).
- **Style contract**: the channel's stated expectations for the spoken rendition, made of the
  instructions line and the spoken-rendition field description; versioned with the voice patch
  group (v3).
- **Length tier**: one of three target durations (≈30 s / ≈45 s / ≈60 s) mapped to character
  budgets at the measured rate (≈15 chars/s); the 60 s tier is the maximum the channel will
  narrate.
- **Closing phrase**: the configured end-of-audio sentence (`features.voice.signoff`), with
  `{nickname}` substitution, localized default, render-time sanitization, and once-only append
  semantics.
- **Currency word**: the configured spoken name for the bare `$`/`CLP` amount
  (`features.voice.currency`), localized default.
- **Symbol naming table**: the fixed, language-dependent mapping of `$`, `CLP`, `US$`, `USD`,
  `UF`, `%` to spoken words; only the bare-`$` entry is configurable.
- **Spoken-safe normalization**: the deterministic transformation (markup removal, list-to-
  sentence, emoji removal, URL removal, whitespace collapse, symbol naming) applied to every
  spoken rendition before synthesis.
- **Voice patch group version**: the marker that gates patch application and upgrades
  (v1 → v2 → v3), with frozen twins for each superseded version and a committed golden fixture
  per superseded version used as the upgrade oracle.
- **Reply acknowledgement (extended)**: the 033 `voice:` line, unchanged in grammar, plus the
  optional `; voice_text trimmed to N chars` note.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (Closing phrase, always, once)**: 5 of 5 consecutive live audios end with the
  configured closing phrase exactly once; in the offline table of closing-phrase cases
  (absent, present in the same case, present in a different case, present without final
  punctuation, present without accents, written by the agent at the end of an over-budget
  rendition, empty rendition, empty runtime phrase — defensive) 100% match the expected
  once-or-none result and the expected trimmed flag.
- **SC-002 (Length)**: Over 10 live voice exchanges, 10 of 10 audios last ≤ 60 s and at least
  7 of 10 last ≤ 35 s (characters reported by the channel as the proxy: ≤ 900 and ≤ 500).
- **SC-003 (Spoken-safe)**: 0 of 10 live audios read markup aloud ("asterisco", "numeral",
  "guion", a horizontal rule or a table separator), voice an emoji, or say "dólares"/"dollars"
  for a `$` amount; the offline normalization table of at least 35 cases passes 100%.
- **SC-004 (Amounts)**: 3 of 3 live amounts written as `$N` are heard as the correct figure
  followed by "pesos chilenos".
- **SC-005 (Language)**: For agents configured `es` or `en`, the synthesis request names that
  language in 100% of audios; for `mixed`, it names none — verified on the request path without
  network.
- **SC-006 (No regression)**: The written reply, and the acknowledgement whenever voice does not
  apply, are byte-identical to v0.24.0 across the full existing test baseline.
- **SC-007 (Convergent upgrade)**: The boot patch applied to a pristine source, to the golden
  v1 fixture and to the golden v2 fixture produces three byte-identical v3 files; a second pass
  on each is a no-op; all seven marker groups are present.
- **SC-008 (Inert when off)**: An agent with voice disabled, and any agent in local mode, shows
  no behaviour change and (local) zero voice runtime values in runtime artifacts.
- **SC-009 (Bounded fallback)**: A 1,500-character list-heavy reply with no spoken rendition
  yields a narration of ≤ 900 characters that ends at a sentence boundary followed by the
  closing phrase, and the acknowledgement reports the omission; a 1,200-character rendition is
  trimmed to ≤ 900 at a sentence boundary and the acknowledgement reports the trim count only.

## Assumptions

- **Speaking rate**: ≈15 characters per second of Spanish narration, measured on the 76 s /
  1,138-character audio of 2026-09-13; the tiers (450 / 700 / 900 characters) derive from it.
  English narration is assumed comparable; the tiers are not localized.
- **Fixed, language-dependent words** (dollars, percent, unidades de fomento, and the fixed
  fallback sentence for an empty narration) are constants of the channel, not configuration;
  only the closing phrase and the bare-`$` currency word are configurable. If a third
  configurable word is ever needed, it follows the same field pattern.
- **Thousands separator** (`1.234.567`): how the synthesizer reads a dotted Chilean figure in
  Spanish — as thousands, as decimals, or digit by digit — and whether the synthesis API's own
  text-normalization option is honoured by the model in use, are unknowns to be measured in the
  planning phase before the normalization rule for separators is fixed. The requirement (the
  figure is heard correctly) stands regardless of which rule wins.
- **Synthesis language enforcement**: the synthesis API accepts a language code and documents
  that it is ignored when the model does not support it — so passing it is fail-open by the
  provider's own contract (verified against the provider's reference on 2026-09-15).
- **Sentence terminators** are `.`, `!`, `?`, `;` and the closing of a parenthesis followed by
  one of them; the fallback cut looks for the last one within the tier.
- **The 033 mechanisms are preserved as-is**: voice origin, explicit audio request table,
  `voice_force`, the `voice:` acknowledgement line, the omission report and its threshold rule
  (subject to the FR-016 clarification), the failure cooldown, the disclosure whitelist.
- **The current fleet** (`linus`, `donna`) is at voice v2 after the 033 deploy; agents that
  never received 033 are at v1 and take the two-step cascade; `rodri-cenco-admin` is pending its
  own upgrade and is out of scope here.
- **Verification without network**: everything deterministic (normalization table, closing
  phrase cases, fallback cut, request assembly) is verified under a real script runtime with no
  synthesis key present, so the request never leaves; pronunciation (SC-003/004) is verified
  by the operator's ear on the live agent after deployment.
- **Real-time conversation** (feature 035) is a separate specification and shares nothing with
  this one.
