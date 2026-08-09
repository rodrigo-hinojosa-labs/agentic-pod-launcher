# Quickstart / Validation: Channel reply-delivery guard (028)

How to validate the feature at each gate. Host gates run on this Mac with no Docker;
the live-host tail runs on a docker+Telegram agent (donna / rodri on ferrari).

## 1. Host suite (Principle III — no Docker)

```sh
export PATH=/opt/homebrew/bin:$PATH   # bats/yq/jq on this Mac
bats tests/stop-hook-guard.bats        # the 4 required cases + fail-silent
bats tests/apply-telegram-patches.bats # US2 v5 message + v4→v5 upgrade + marker hunks
bats tests/schema.bats                 # features.reply_guard flattening / fixture
bats tests/                            # full suite, bash 5.x
PATH=/bin:$PATH bats tests/            # full suite, bash 3.2 (macOS stock) — must match
shellcheck -S error scripts/hooks/stop-redeliver.sh docker/scripts/start_services.sh
```

Expected: all green on BOTH bash 3.2 and 5.x; `ok` count = prior baseline + the new
tests; `shellcheck` clean.

## 2. Mutation check (SC — the tests actually bite)

Revert each fix in isolation and confirm ≥1 test goes red:
- Remove the marker-present branch in `stop-redeliver.sh` → case 2 fails.
- Ignore `stop_hook_active` → case 4 (loop guard) fails.
- Keep the old OAuth-asserting warning string → `apply-telegram-patches.bats` US2
  assertion fails.
- Skip the pending-marker delete hunk → the marker-lifecycle patch test fails.

## 3. Regenerate-safety (Principle I)

```sh
# In a throwaway scaffold with the telegram plugin:
./setup.sh --regenerate
test -x scripts/hooks/stop-redeliver.sh          # rendered + executable
yq -r '.features.reply_guard.enabled' agent.yml  # backfilled true (telegram present)
./setup.sh --regenerate                          # second run
git diff --stat scripts/hooks/ && echo "byte-stable"
# Non-channel agent (no telegram plugin): scripts/hooks/ NOT created; regenerate byte-identical
```

## 4. settings.json merge (host, fixture)

```sh
# Apply the jq merge to a fixture settings.json carrying permissions + a foreign hook,
# assert .hooks.Stop gains exactly one entry, foreign keys survive, second apply no-ops.
bats tests/stop-hook-guard.bats -f "settings merge"
```

## 5. Docker integration (DOCKER_E2E — a Docker host)

```sh
DOCKER_E2E=1 bats tests/docker-e2e-*.bats
```

Expected: after boot, `~/.claude/settings.json` carries the Stop entry AND the
`permissions`/`skipDangerousModePermissionPrompt` writes; the plugin `server.ts` is
patched to `typing v5` + the pending-reply marker hunks; a replied inbound leaves no
marker, an un-replied inbound leaves the marker at Stop time.

## 6. Live-host tail (donna / rodri — the spec's feasibility gate's live end)

On a running docker+Telegram agent, confirm the two things this Mac cannot:

1. **Re-injection works**: force a turn that answers without the reply tool (or
   inspect a natural occurrence); confirm the Stop hook fires, the agent then calls
   `plugin:telegram:telegram`, and the operator receives the delayed answer — one
   stderr line in `telegram-mcp-stderr.log`, no infinite loop (bounded by
   `stop_hook_active`). Grep: `reply-guard: re-injected` in the stderr log.
2. **US2 message**: trigger (or wait for) a real typing timeout and confirm the chat
   message names multiple causes + `agentctl doctor`, and does NOT assert OAuth.

Optional (would enable the leaner no-plugin-change variant): dump a real
channel-session transcript and check whether a Telegram-injected user turn carries a
stable origin field (`promptSource`/`entrypoint`/`userType`). If it does, US1 could
drop the plugin marker; if not, the marker design stands.

## Acceptance mapping

| Criterion | Gate |
| --- | --- |
| SC-001 delayed answer delivered, no manual step | §6.1 live + §5 e2e |
| SC-002 zero false fires (console / already-replied) | §1 cases 1 & 3 |
| SC-003 bounded, no loop | §1 case 4 + §6.1 |
| SC-004 honest timeout message | §1 (`apply-telegram-patches`) + §6.2 |
| SC-005 host suite bash 3.2 + 5.x, no Docker | §1 |
| SC-006 regenerate byte-identical from agent.yml | §3 |
| SC-007 stderr-visible, no chat noise | §1 case 2 + §6.1 |
