# Contract — the spoken-style contract the channel states to the agent (v3)

Two strings inside the patched plugin: the voice line of the `instructions` array and the
`voice_text` property description of the `reply` tool. Both are rewritten by the v2→v3
upgrade and written as-is by a fresh apply. `voice_force` description is unchanged from 033.

## C1. Instructions line (v3) — a template literal, one array element

Interpolations resolved at server start from module-level constants (in scope: the helpers
hunk is anchored at `let botUsername = ''`, line 25 of the upstream file; the array is at
line 97):

- `${VOICE_SPOKEN_CHAR_CAP}` — the hard limit (default 900).
- `${VOICE_SPOKEN_LANG_NAME}` — `Spanish` / `English` / `the language the user wrote in`.
- `${VOICE_CURRENCY}` — the configured currency word.

Exact text (line breaks here are for reading; the constant is ONE line):

```text
`Voice replies: when a message arrives transcribed (meta attachment_kind="voice") or the user
explicitly asks for an audio reply, this channel AUTOMATICALLY sends your reply as a voice
note too — never tell the user you cannot send audio, and answer in ONE reply call (only the
first reply of the exchange is spoken). ALWAYS include voice_text: a spoken SUMMARY of your
answer, never your text read aloud — about 30 seconds (~450 characters) by default, up to
~45 seconds (~700) or at most ~60 seconds (${VOICE_SPOKEN_CHAR_CAP} characters, the hard
limit) only when the amount of information warrants it; never enumerate a list item by item.
Write it as plain spoken prose in ${VOICE_SPOKEN_LANG_NAME}: no markdown, code, lists, emojis
or URLs; say figures, dates and percentages in words and follow every amount with its
currency name (${VOICE_CURRENCY} for a bare amount). Do NOT write a closing phrase — the
channel appends the configured sign-off itself. If you omit voice_text, a cleaned,
sentence-cut version of your text is read aloud and the reply result says so; a voice_text
over the limit is cut at a sentence and the result says so. The reply result carries a
"voice:" line for your own awareness (sent/failed) — do not repeat it to the user; if it says
failed, tell the user once, briefly, that the audio did not go out this time, and do not
retry. If the user asks for audio in wording the channel did not recognise, set voice_force:
true on that reply.`,
```

Substrings kept verbatim from 032/033 (other oracles rely on them): `this channel
AUTOMATICALLY sends your reply as a voice note too`, `never tell the user you cannot send
audio`, `answer in ONE reply call`, `only the first reply of the exchange is spoken`,
`do not repeat it to the user`, `tell the user once, briefly, that the audio did not go out
this time, and do not retry`, `set voice_force: true on that reply`.

Substring replaced (its three 033 oracles move with it): `include voice_text with a concise
speakable version` → `ALWAYS include voice_text: a spoken SUMMARY of your answer`.

Oracles for this contract (host bats, `grep -F` on the patched file): each clause above by a
distinctive substring — `a spoken SUMMARY of your answer, never your text read aloud`;
`about 30 seconds (~450 characters) by default`; `${VOICE_SPOKEN_CHAR_CAP} characters, the
hard limit` (literal `${…}` text — it is a template literal, not an interpolated test);
`never enumerate a list item by item`; `plain spoken prose in ${VOICE_SPOKEN_LANG_NAME}`;
`follow every amount with its currency name (${VOICE_CURRENCY}`; `Do NOT write a closing
phrase`; `cut at a sentence and the result says so`. And structurally: the element starts with
a backtick and ends with a backtick followed by a comma.

## C2. `voice_text` description (v3) — a plain single-quoted string

```text
'Spoken SUMMARY of this reply, synthesized as the voice bubble whenever the exchange is
voice-originated (voice note or explicit audio request) or voice_force is set. Plain spoken
prose in the configured language, about 30 seconds (~450 characters) by default and never
above the spoken limit stated in the channel instructions; no markdown, code, lists, emojis or
URLs; figures in words, every amount followed by its currency name; no closing phrase (the
channel appends it). When omitted, a cleaned, sentence-cut version of `text` is read aloud and
the reply result reports the omission.',
```

Oracles: `Spoken SUMMARY of this reply`; `never above the spoken limit stated in the channel
instructions`; `no closing phrase (the channel appends it)`; `cleaned, sentence-cut version of
`text` is read aloud`.

## C3. Behavioural rules the contract encodes (spec FR-001)

| Clause | Enforced by |
| --- | --- |
| summary, not the text read aloud | contract (model); fallback cut bounds the failure |
| tiers 30 / 45 / 60 s, 60 s hard | contract (model); `_voiceSentenceCut` at the cap (channel) |
| plain spoken prose | contract (model); `_voiceSpokenNormalize` (channel) |
| figures in words, currency named | contract (model); symbol naming (channel) — digits never rewritten |
| language | contract (model, `${VOICE_SPOKEN_LANG_NAME}`); `language_code` to synthesis (channel) |
| closing phrase by the channel, not the model | contract (model); `_voiceSignoffAppend` with dedupe (channel) |
| omission / trim reported | 033 omission line (unchanged); new trim note |
