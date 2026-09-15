# Quickstart — verifying 033 (host, DOCKER_E2E, live)

## 0. One-time fixture generation (dev host, before the constants change)

```bash
# 1. extract the pristine fixture from the bats heredoc (byte-for-byte) → tests/fixtures/telegram-server-pristine.ts
# 2. golden v1 from the REAL v0.23.0 patcher (needs git history — dev host only, then committed):
git show a7eb2e5:docker/scripts/apply_telegram_typing_patch.py > "$TMP/patcher-v0.23.0.py"
cp tests/fixtures/telegram-server-pristine.ts tests/fixtures/telegram-server-voice-v1.ts
python3 -B "$TMP/patcher-v0.23.0.py" tests/fixtures/telegram-server-voice-v1.ts
grep -c "telegram voice roundtrip patch v1" tests/fixtures/telegram-server-voice-v1.ts   # 1
```

## 1. Host gates (no Docker)

```bash
bats tests/apply-telegram-patches.bats            # 64 → 64 + new 033 tests (G1-G11 + wording + wrap/flag/matcher)
bats tests/                                       # full suite, bash 3.2 AND 5.x
PATH=/bin:$PATH bats tests/                       # forces macOS /bin/bash 3.2.57
shellcheck -S error $(git ls-files '*.sh' 'setup.sh' 'scripts/**' 'docker/scripts/**' | grep -v '^tests/')
```

Mutation spot-checks (each must turn at least one test red, then green on revert):

1. Revert `_REPLY_RETURN_V2` to the pristine return → T009(a) and the T004 return-line oracle (`text: result + _voiceOutcome }`). G2 stays GREEN here (both the fresh and the upgrade path consume the same constant) — G2 only catches mutations that make the two paths diverge (6, 7).
2. Remove the `_voiceStep = 'send'` flip → G8 (line-order + `step=${_voiceStep}` USE).
3. Change `Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` to a literal `300` → G9.
4. Drop the negation guard from `_voiceRequestMatch` → matcher-structure test (host) and E5 (e2e).
5. Make `_voiceForce = Boolean(args.voice_force)` (truthy) → strict-boolean test.
6. Make the upgrader continue past a missing hunk → G4 (all-or-nothing).
7. Alter one byte of `VOICE_HELPERS_V1` → G2 (sha) and G2b (fidelity) — the tautology guard.
8. Remove the `VOICE_REPLY_MODE === 'always'` gate from the cooldown set → G10.

## 2. DOCKER_E2E (a host with a docker daemon)

Every case is **self-seeding** (the image has no plugin; `--entrypoint sh` bypasses the
installer): the test copies `tests/fixtures/telegram-server-{pristine,voice-v1}.ts` into
`$E2E_AGENT_DIR/.e2e/` (host side, bind-mounted at `/workspace/.e2e/`), then inside the
container:

```sh
d="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6"; mkdir -p "$d"
cp /workspace/.e2e/telegram-server-pristine.ts "$d/server.ts"        # or the golden v1 for E7
python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$d/server.ts"
```

```bash
DOCKER_E2E=1 bats tests/docker-e2e-voice.bats     # E1-E4 (rewritten to v2 + seeding) + E5 matcher + E6 parse + E7 upgrade + E8 errClass
```

E5 extracts the helpers between the line containing `telegram voice roundtrip patch v2`
and the line containing `voice helpers end (033)`, appends the positive/negative tables
as assertions, and runs the snippet with the image's `bun`. E6 measures the parse-only
check (candidate: `bun -e "new Bun.Transpiler({loader:'ts'}).transformSync(await Bun.file(process.argv[1]).text())" "$d/server.ts"`);
if `Bun.Transpiler` is not usable, record the alternative found in `research.md` D11.

## 3. Live gate on ferrari (linus first, then donna)

Deploy = the fleet upgrade procedure (rsync overlay of `docker/` + rebuild + anti-flap
restart: `docker compose stop` → wait ≥150 s → `docker compose up -d`). Then:

```bash
# 3.1 upgrade path landed (v1 → v2 in place)
docker exec -u agent linus sh -lc 'grep -c "telegram voice roundtrip patch v2" ~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts'   # 1
docker exec -u agent linus sh -lc 'grep -c "telegram voice roundtrip patch v1" ~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts'   # 0
docker logs linus 2>&1 | grep -E 'apply_telegram_typing_patch.*voice-upgrade-v1→v2|channel plugin healthy'
```

Watch for `channel plugin healthy — bun server.ts running` within `CHANNEL_HEALTH_TIMEOUT`
before touching the second agent (a TS syntax error would show as a respawn loop here).

```bash
# 3.2 SC-001 — voice note → outcome line in the agent's tool result, correlated with stderr
#   send one voice note from Telegram, then:
docker exec -u agent linus sh -lc 'grep -E "voice tts (ok|fail|spoke)" /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log | tail -3'
docker exec -u agent linus sh -lc 'grep -rhoE "voice: (sent|failed) \([^)]*\)" ~/.claude/projects/*/*.jsonl | tail -3'
#   → same chars/fmt in both

# 3.3 SC-002 — a resumed pre-v0.23.0 session stops claiming inability
#   send 5 voice notes in a row; replies 2-5 must contain no "no puedo/no está disponible ... audio".

# 3.4 SC-003 — omission rate over 10 voice exchanges
docker exec -u agent linus sh -lc 'L=/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log; echo "ok=$(grep -c "voice tts ok" $L) omitted=$(grep -c "without voice_text" $L)"'
#   → omitted/ok ≤ 1/10 on the 10-exchange window (compare counts before/after the window)

# 3.5 SC-007 / SC-008 — explicit request vs plain text (first reply of each exchange)
#   type "responde con audio" ×10 → 10 bubbles, log shows "voice request detected" ×10
#   type 10 plain messages → 0 bubbles, 0 new "voice request detected"
docker exec -u agent linus sh -lc 'grep -c "voice request detected" /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'

# 3.6 SC-006 (synth leg) + cooldown — fault injection with a bad voice id
#   set features.voice.voice_id to a bogus id, regenerate, anti-flap restart, send a voice note:
docker exec -u agent linus sh -lc 'grep -E "voice tts fail|voice skip: cooldown" /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log | tail -2'
#   → "voice tts fail: transport status=404 step=synth chat=…"; the agent's next message mentions the audio did not go out, once.
#   in mode always additionally: exactly one "voice skip: cooldown after failure" and no second fail line for the mention.
#   restore the real voice id afterwards.

# 3.7 SC-009 — voice_force path
#   type "quiero escucharlo" (not in the phrase table) → if the agent sets voice_force the bubble arrives; the tool result shows "voice: sent".

# 3.8 SC-004 live leg — an agent with voice OFF gets a byte-identical acknowledgement
#   on rodri-cenco-admin (features.voice.enabled: false) after its upgrade, or on linus with ELEVENLABS_API_KEY emptied and an anti-flap restart:
docker exec -u agent <agent> sh -lc 'grep -c "voice: " ~/.claude/projects/*/*.jsonl'    # note the count
#   send one typed message, wait for the reply, re-run → count unchanged; stderr shows no "voice tts" line for that turn.
```

## 4. Rollback (corrected after review)

Reverting the image to v0.23.0 does NOT touch the plugin file under `.state/`: at the
next boot the v0.23.0 patcher sees no v1 marker, tries a fresh apply, fails hunk 2 (the
upstream `message:voice` body no longer exists), logs a WARN and **leaves the v2 file
intact and functional** — no double-apply, no crash. To actually downgrade the plugin
behaviour, delete the plugin cache dir
(`~/.claude/plugins/cache/claude-plugins-official/telegram/`) so the next boot reinstalls
the plugin pristine and v0.23.0 patches it to v1.
