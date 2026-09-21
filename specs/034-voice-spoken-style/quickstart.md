# Quickstart — 034 voice spoken style

Three tiers, in order: host (no docker, no network) → DOCKER_E2E (real containers, no
network — run for real on this host, 033 precedent) → live gate on the fleet (linus first).

## §0. Fixtures (once, dev host with git history; committed)

```bash
cd /Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher
TMP=$(mktemp -d)
# golden v2 from the REAL v0.24.0 patcher (main @ 3534c6b)
git show 3534c6b:docker/scripts/apply_telegram_typing_patch.py > "$TMP/patcher-v0.24.0.py"
cp tests/fixtures/telegram-server-pristine.ts tests/fixtures/telegram-server-voice-v2.ts
python3 -B "$TMP/patcher-v0.24.0.py" tests/fixtures/telegram-server-voice-v2.ts
grep -c "telegram voice roundtrip patch v2" tests/fixtures/telegram-server-voice-v2.ts   # 1
grep -c "telegram voice roundtrip patch v1" tests/fixtures/telegram-server-voice-v2.ts   # 0
shasum -a 256 tests/fixtures/telegram-server-voice-v2.ts   # 5dc01bf3f7ce7e6106ade38a1ae053aba4ae01d134622e399c35cb939dd6cef0 (T001, 2026-09-18)
find . -name __pycache__ -prune -exec rm -rf {} +   # -B above avoids it; belt and braces
```

Sanity: `python3 -B "$TMP/patcher-v0.24.0.py"` run a second time on the golden must leave the
sha unchanged (that frozen patcher prints nothing on the no-change path; the `no changes …
all patch groups already present` line is a v0.25.0 addition — T005).

Also committed (generated once during the analyze remediation, not by any task):
`tests/fixtures/voice-spoken-cases.ts` — sha256 `0b46410ea6c2559fa28ca45ba3feb7bf1d3a381cf0b3d4142dde9a28c418399a`,
39 entries (`grep -c "{ in: '"`), no `export`; E9 runs it in-container.

## §1. Host gates

```bash
bats tests/apply-telegram-patches.bats        # 92 → 92 + 034 tests (G1-G16, contract, pipeline structure, no-voice byte-identity)
bats tests/voice-config.bats                  # 9 → 9 + wizard heredoc es/mixed/en, backfill (exact values, clean stderr), sanitizer table, nickname empty
bats tests/docker-render.bats tests/local-render.bats tests/schema.bats tests/regenerate.bats tests/quickstart-doc.bats
bats tests/                                   # full suite, then again under bash 3.2:
PATH=/bin:$PATH bats tests/ | tail -3         # /bin/bash 3.2.57 on macOS (025 rule)
shellcheck -S error setup.sh scripts/lib/*.sh docker/scripts/*.sh docker/scripts/lib/*.sh   # the CI command
python3 -B -m py_compile docker/scripts/apply_telegram_typing_patch.py && find . -name __pycache__ | wc -l   # 0
# combining marks in SOURCE files (real glyphs typed where an escape was meant):
LC_ALL=C grep -rc $'\xcc\x80' docker/scripts/apply_telegram_typing_patch.py tests/ specs/034-voice-spoken-style/ | grep -v ':0$'   # nothing
# control bytes in the PATCHED OUTPUT (a \1 or \b left un-doubled only shows up there — research D14):
python3 -B docker/scripts/apply_telegram_typing_patch.py "$TMP/server.ts" >/dev/null; LC_ALL=C grep -c $'[\x01-\x08\x0b\x0c\x0e-\x1f]' "$TMP/server.ts"   # 0
```

Mutation spot-checks (each must turn ≥ 1 named test RED; revert after each):

| # | Mutation | Expected RED |
| --- | --- | --- |
| M1 | remove the `_voiceSignoffAppend(` call inside `_voiceSpokenAssemble` | pipeline-order test (host), E10 (a) |
| M2 | swap `_voiceSentenceCut` after `_voiceSignoffAppend` inside the helper | pipeline-order test; E10 (i)/(j) |
| M3 | drop the `language_code` spread from the synth body | G8 (host), E11 |
| M4 | cap default back to `1200` | G7 (host) |
| M5 | flip one byte inside `VOICE_HELPERS_V2` (outside the marker line) | G2b (twin ⊄ golden v2), G2 (v2→v3 aborts on the golden v2), G2d (intermediate state). NOT G2c: the re-pointed v1→v2 writes the corrupted twin and v2→v3 consumes that same constant, so the v1→v3 cascade still converges with the fresh apply — measured; G2c only goes red when the byte lands inside the marker line |
| M6 | make `upgrade_voice_v2_to_v3` apply the pairs it finds and skip the missing one | G4 — **as first written G4 was blind to this mutant** (measured 2026-09-18: the marker lives in the helpers pair, so a partial upgrade that skips it still leaves `patch v2` = 1 / `patch v3` = 0 and still prints the WARN). G4 now also asserts that none of the other three v3 constants landed (`ALWAYS include voice_text: a spoken SUMMARY`, `Spoken SUMMARY of this reply`, `_voiceSpokenAssemble(` all count 0) and that the v2 instructions line and `_voiceTruncate(` call are still present; re-measured RED under the mutant, GREEN on the implementation |
| M7 | sanitizer stops deleting `$` | voice-config sanitizer case (`$dolar`) |
| M8 | backfill overwrites `signoff` unconditionally (no `has()`) | regenerate-preserves-operator-phrase test |
| M9 | move the bare-`$` rule BEFORE the `US$` rule in the normalizer | E9 case `US$ 500 y USD 300` |
| M10 | un-double the `\1` backreference of the strong-emphasis pass | G15 (host, `grep -F '(.+?)\1/g'` fails), G16 (control byte 0x01 in the output), E9 case `**Total:**` |
| M11 | un-double the `\b` of the bare-URL pass | G15, G16 (0x08), E9 case `Ver https://…` |
| M12 | remove the `(?!\d)` closing the figure group | E9 cases `$1500` / `USD 2500` |
| M13 | remove the `, {nickname}` rule (empty nickname) or the heredoc default for `es` | voice-config nickname-empty case; wizard heredoc test `lang=es` |
| M14 | replace `/…/.source` + `String.raw` by a plain JS string (doubled backslashes in the TS) | G15 (`(?!\d)/.source`, `String.raw`(?:US\$\|USD)`) and CANON-FIG count (host) |
| M15 | move `const VOICE_SIGNOFF` below the boot-log block | T007 TDZ order oracle (host); E5/E9 (module load throws under bun) |
| M16 | change `[.!?;](?=\s\|$)` to `\s` in `_voiceSentenceCut` | E10 (q) (narrated ≠ longest sentence prefix) and (m) terminator assertion |

## §2. DOCKER_E2E (this host has Docker — run it, do not defer)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-voice.bats     # E1-E8 (033, markers → v3, E2 "seven" + English values, E4 labelled count)
                                                  # + E9 committed cases fixture (38 + en), E10 assembly invariants (a)-(q),
                                                  # E11 language_code line (BCOUNT/LCOUNT), E12 golden v2 → v3 in-container
```

Harness facts (033 gotchas + 034): the patcher's `log()` writes to STDOUT (redirect it inside
`seed.sh`); `grep -c` exits 1 on a zero count under `set -e` (`|| true`); `docker compose run`
prepends progress lines to `$output` (assert labelled markers with `grep -qx`, never line
positions); the awk extraction range is `/telegram voice roundtrip patch v3/` → `/voice
helpers end \(033\)/`; **the harness agent is `en`/`Alice`**, so every bun invocation pins
`TELEGRAM_VOICE_STT_LANG`, `TELEGRAM_VOICE_CURRENCY`, `TELEGRAM_VOICE_SIGNOFF` (the Spanish
phrase, literally — empty means "no phrase") and `TELEGRAM_VOICE_SPOKEN_CHAR_CAP` on the
command line; inner values in DOUBLE quotes inside the single-quoted `-c '…'` body; appended TS
through a quoted heredoc; `setup()` copies the golden v2 and the cases fixture into `.e2e/`.

## §3. Live gate (after merge + deploy of v0.25.0; linus first, then donna)

Prerequisite: the ferrari tunnel (Cloudflare Access re-authentication is the operator's).
Deploy is the fleet-update procedure (README "Upgrade an existing agent"); after boot:

```bash
./scripts/agentctl logs --stderr | grep -E "voice active|signoff=|voice-upgrade-v2→v3|channel plugin healthy"
```

§3.1 **Upgrade path** — the boot log names `voice-upgrade-v2→v3`; the live `server.ts` has
one `patch v3` marker and zero `patch v2`/`v1`; `agentctl status` healthy for ≥ 10 min (no
flap). If the channel flaps: E6 already proved the file parses; check
`telegram-mcp-stderr.log` for the first runtime error.

§3.2 **SC-001 sign-off** — five voice notes; every audio ends with "Eso es toda la
información. Cambio y fuera, Rodri." exactly once.

§3.3 **SC-002 length** — ten voice exchanges of varied density; `grep "voice tts ok" …
telegram-mcp-stderr.log | tail -10` → `chars=` ≤ 900 on 10/10 and ≤ 500 on ≥ 7/10.

§3.4 **SC-004 amounts + the D9 measurement** — three questions whose answers carry amounts;
by ear: "pesos chilenos" with the right figure, never "dólares". Then the deferred
measurement, from INSIDE the container so the key never leaves it (no value is printed):

```bash
./scripts/agentctl exec -- sh -c 'curl -s -X POST "https://api.elevenlabs.io/v1/text-to-speech/${TELEGRAM_VOICE_ID:-Rachel}?output_format=mp3_44100_128" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" -H "content-type: application/json" \
  -d "{\"text\":\"Son 1.234.567 pesos chilenos y 1.234,50 de vuelto.\",\"model_id\":\"eleven_flash_v2_5\",\"language_code\":\"es\"}" \
  -o /tmp/probe-es.mp3 && ls -l /tmp/probe-es.mp3'
docker cp "$(docker compose ps -q)":/tmp/probe-es.mp3 ./probe-es.mp3   # listen
```

If the dotted figure is misread (decimal / digit-by-digit), the follow-up is the one-line
thousands-dot strip named in research D9 — a separate PATCH, not part of this gate.

§3.5 **SC-003 spoken-safe** — across §3.2-3.4 audios: no "asterisco"/"numeral"/"guion", no
rule or table separator, no emoji sound, no "dólares" for `$`.

§3.6 **SC-005 language** — linus is `es`: the code-path oracle is E11 (no request logging by
design). By ear: Spanish pronunciation of anglicisms in one mixed-vocabulary answer.

§3.7 **Config on a live workspace** — `./setup.sh --regenerate` on linus: `agent.yml` gains
`features.voice.signoff` / `currency` with the Spanish defaults (exact values); stderr clean;
`docker-compose.yml` carries `TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y
fuera, Rodri."`; a second `--regenerate` is byte-identical.

§3.8 **SC-006 no regression** — one typed (non-voice) message: the reply is text-only and the
transcript acknowledgement is `sent (id: N)` with no `voice:` line.

## §4. Rollback

Reverting the image to v0.24.0 does not downgrade the plugin file (contract C7 of the
upgrade): the v0.24.0 patcher WARNs and leaves v3 working. A real downgrade = remove the
plugin cache dir (`~/.claude/plugins/cache/claude-plugins-official/telegram/`) inside
`.state/`, then restart so the boot reinstalls and re-patches at the image's version. The two
new `agent.yml` fields are inert under v0.24.0 (unknown keys are ignored by the render).
