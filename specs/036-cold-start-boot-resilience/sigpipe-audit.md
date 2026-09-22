# SIGPIPE audit — every early-exit pipeline under `pipefail`
**Date**: 2026-09-21. **Method**: 12-agent workflow, one auditor per file plus an
adversarial refuter per EXPLOITABLE verdict. Every verdict is measured (300+ runs per
cell, real producers, `PIPESTATUS` histograms) or, where the producer cannot run on this
host, argued structurally and labelled as such. Zero verdicts were overturned; the
refuters corrected *rates and provenance*, not conclusions.
## The mechanism
EPIPE happens only if the producer attempts a **write() after the reader closed**. So the
deciding factor is the producer's write pattern, not the pipeline's text:

- A producer emitting its whole output in ONE `write()` that fits the 64 KiB pipe buffer is
  immune — the kernel accepts it before the reader runs. `printf`/`echo` builtins are in
  this class **below 64 KiB**, and reliably fatal above it (boundary measured at exactly
  65,536 bytes on both bash versions).
- An external line-buffered writer (`yq`, `journalctl`, `tail`) is exposed as soon as one
  line follows the match.
- A producer with only ONE matching output line never writes again, so it is safe whatever
  its speed.

How the status is consumed decides the CONSEQUENCE:

| Shape | errexit fires? | Consequence |
|---|---|---|
| `if PIPELINE; then` | no | condition silently goes FALSE — a wrong decision |
| `v=$(PIPELINE)` | **yes** | the script aborts |
| `local v=$(PIPELINE)` | no | `local`'s own status masks it |
| `PIPELINE \|\| true` | no | harmless |

## Verdicts — 26 sites
- **EXPLOITABLE: 4** — two fixed in PR #97, two are US5 of this feature.
- **SAFE: 22** — six of them by a property of their input, not by design.
- **Overturned by refutation: 0**. **Unmeasurable: 0**.

## Exploitable

### `setup.sh:2183`
```sh
if yq -r '.plugins[]?' "$agent_yml" 2>/dev/null | grep -qE '^telegram@'; then
```
- **Producer**: yq — external binary, line-buffered incremental writer emitting one line per plugins[] entry
- **Status consumed as**: `if-condition`
- **Consequence**: On a 141, _rg_bf stays false and :2186 writes `features.reply_guard.enabled = false` into agent.yml for a Telegram agent. The has() guard on :2181 then means a later --regenerate NEVER re-derives it — the wrong value is permanent until an operator hand-edits agent.yml. The agent silently loses the 028 reply guard, the mechanism that stops a channel turn from ending without delivering its reply. Reachable only on the pre-028 upgrade path (the block must be ABSENT), which is exactly the path the pending fleet update takes.
- **Measurement**: NOT re-measured, per task instruction. Ground truth stands: bash 5.3.15 -> PIPESTATUS "141 0" in 18/300 (6.0%); bash 3.2.57 -> 22/300 (7.3%); grep stage 0 (matched) every time. Classification confirmed by reading: producer, consumer and consumption shape match the established instance exactly. AMPLIFICATION FOUND (my own positive control, not a re-measurement of the fixture): the ground-truth rate was taken against tests/fixtures/sample-agent.yml, which I verified holds a SINGLE plugins entry, so yq has almost nothing left to write after line 1. Re-running the identical shape against a 5-entry plugins block gave "141 0" in 196/300 (65.3%) on bash 5.3.15 and 264/300 (88.0%) on bash 3.2.57. The failure rate scales with how many plugin lines follow telegram@.
- **Refuter** (refuted=False): VERDICT HOLDS, but the auditor's stated ground truth is WRONG and I replaced it with my own end-to-end measurement.

READ-VERIFIED (auditor correct on these):
- setup.sh:2182-2186 — `local _rg_bf=false` / `if yq -r '.plugins[]?' "$agent_yml" 2>/dev/null | grep -qE '^telegram@'; then _rg_bf=true; fi` / `yq -i ".features.reply_guard.enabled = $_rg_bf"`. Status IS consumed as a decision; not `local v=$(...)`, not `|| true`.
- Permanence: has() guard at setup.sh:2181 skips the block once it exists, so a later --regenerate cannot heal it.
- Blast radius real: setup.sh:2526 `if [ "${FEATURES_REPLY_GUARD_ENABLED:-false}" = "true" ]` is what renders scripts/hooks/stop-redeliver.sh (modules/stop-hook.sh.tpl:17). enabled=false => 028 guard never installed.
- Wizard path unaffected: setup.sh:1184 uses `case "$plugins_yaml" in *"telegram@"*)` — a glob, no pipeline.

REFUTED #1 — the cited ground-truth histogram is not reproducible. It names tests/fixtures/sample-agent.yml, which holds ONE plugins entry (`- telegram@claude-plugins-official`). Running the identical pipeline 300x/arm: "0 0" in 300/300 on bash 5.3.15 and 300/300 on /bin/bash 3.2.57. ZERO 141s — not 18/300 (6.0%) and 22/300 (7.3%). The auditor's own mechanism bullet predicts exactly this (single output line => no second write => no EPIPE), so those numbers cannot have come from the fixture they name.

REFUTED #2 — the DEFAULT production shape is immune. scripts/lib/plugin-catalog.sh:44 sorts `plugin_catalog_list` alphabetically; the five type:default descriptors are claude-md-management, claude-mem, context7, security-guidance, telegram — so telegram@ is emitted LAST (setup.sh:1164-1171), and optional plugins are appended after it (setup.sh:1172-1178). Measured 5-default wizard order with telegram last: 0/300 on bash 5.3.15 AND 0/300 on bash 3.2.57. The auditor's amplification shape put telegram FIRST, which the launcher never generates. Exposure requires >=1 plugins[] line AFTER telegram@ (an optional plugin selected, or a hand-written/declarative list).

REFUTED #3 — the isolated-pipeline rate wildly overstates the real path. Isolated: 161/300 (53.7%) bash 5.3.15 and 228/300 (76.0%) bash 3.2.57 for "5 defaults + 4 optional after telegram". Through real setup.sh: ~2.8%.

CONFIRMED END-TO-END (this is why the verdict survives): tests/reply-guard-config.bats:64-73 seeds plugins[] as telegram@ first + claude-mem@thedotmack second and runs the real `./setup.sh --regenerate`. Over 72 runs it failed 2 times (1/12 batch + 1/40 batch + 0/20 batch) at line 71: `[ "$(yq -r '.features.reply_guard.enabled' agent.yml)" = "true" ]' failed` — reply_guard.enabled came out false for a Telegram agent, and the render log in the failing run shows no stop-redeliver.sh hook. That is the exact claimed consequence, reproduced through production code, not a synthetic pipeline.

Full histograms (300 runs each, PIPESTATUS of the real pipeline):
  fixture (1 entry):                    5.3.15 = 300x"0 0" / 0x141 ; 3.2.57 = 300x"0 0" / 0x141
  5 defaults, telegram last (wizard):   5.3.15 = 300x"0 0" / 0x141 ; 3.2.57 = 300x"0 0" / 0x141
  telegram first + 4 after (auditor):   5.3.15 = 105x"0 0" / 195x"141 0" ; 3.2.57 = 39x"0 0" / 261x"141 0"
  5 defaults + 4 optional after tg:     5.3.15 = 139x"0 0" / 161x"141 0" ; 3.2.57 = 72x"0 0" / 228x"141 0"
grep stage was 0 in every 141 case, as claimed.

ADDITIONAL FINDING the auditor missed: the identical shape exists at setup.sh:2195 for features.askuserquestion_guard, and tests/askq-guard-config.bats:67-69 seeds the same telegram-first ordering — so both backfill blocks carry the defect and both bats tests are latent ~3% CI flakes (a plausible contributor to the "contention flakes" folklore in CLAUDE.md).

NET: refuted=false on the verdict; the auditor's measurement provenance, the claimed fixture rate, and the "production is 65-88%" framing are all wrong. Correct statement: EXPLOITABLE at ~3% per --regenerate, ONLY for a pre-028 workspace whose plugins[] has at least one entry after telegram@; a stock scaffold (telegram last) is immune. No repo file modified.

### `setup.sh:2195`
```sh
if yq -r '.plugins[]?' "$agent_yml" 2>/dev/null | grep -qE '^telegram@'; then
```
- **Producer**: yq — external binary, line-buffered incremental writer emitting one line per plugins[] entry
- **Status consumed as**: `if-condition`
- **Consequence**: On a 141, _aq_bf stays false and :2198 writes `features.askuserquestion_guard.enabled = false` for a Telegram agent, made permanent by the has() guard on :2193. The agent silently loses the 031 PreToolUse guard, so a channel turn that calls AskUserQuestion opens a console-only menu the Telegram user cannot see and hangs mid-turn — the precise failure 031 was built to prevent. Independently toggleable from reply_guard, so it can fail on its own pass.
- **Measurement**: NOT re-measured, per task instruction. Ground truth stands: bash 5.3.15 -> PIPESTATUS "141 0" in 18/300 (6.0%); bash 3.2.57 -> 22/300 (7.3%). Byte-identical pipeline to :2183 — same producer, same consumer, same if-condition consumption — so the same histogram applies. Same amplification applies: my positive control on a 5-entry plugins block measured 196/300 (65.3%) on bash 5.3.15 and 264/300 (88.0%) on bash 3.2.57.
- **Refuter** (refuted=False): Could not refute; verdict holds, but the auditor's rate reasoning is wrong in both directions.

CONSUMPTION (re-read, confirmed): setup.sh:2195 is `if yq -r '.plugins[]?' "$agent_yml" 2>/dev/null | grep -qE '^telegram@'; then _aq_bf=true; fi`, inside regenerate() (fn starts :2089), gated only by `[ -f "$agent_yml" ]` (:2104). set -euo pipefail at :4. No `|| true`, no `local v=$(...)` masking. A 141 makes the condition false -> _aq_bf stays false.

MY MEASUREMENT (real yq v4.52.5, real pipeline, scratch dir /private/tmp/claude-501/sigpipe-2195). The failure rate is governed entirely by how many plugins[] entries FOLLOW the first `telegram@` line, not by the pipeline text. 300 runs per cell, PIPESTATUS from the real if-form:
  entries_after_telegram | bash 5.3.15 | bash 3.2.57
           0             |    0/300    |    0/300   (structurally immune)
           1             |   79/300    |   48/300
           2             |  181/300    |   96/300
           3             |  263/300    |  136/300
           5             |  252/300    |  165/300
The after=0 immunity was additionally confirmed with 800 consecutive clean runs (2x400). Mechanism matches the brief: grep -q only exits after reading the LAST line, so yq attempts no further write.

REFUTED SUB-CLAIM: "Byte-identical pipeline to :2183 ... so the same histogram applies (6.0%/7.3%)" is false. The histogram is a property of input ordering, not pipeline text. The auditor's 5-entry positive control (65.3%/88.0%) implies telegram@ FIRST, which is not what the catalog emits: plugin_catalog_list (scripts/lib/plugin-catalog.sh:45) ends in `| sort`, and telegram sorts LAST among the five `type: default` descriptors (claude-md-management, claude-mem, context7, security-guidance, telegram). So a defaults-only scaffold measures 0%, not 6%.

WHY IT IS STILL EXPLOITABLE: setup.sh:1172-1178 appends opt_plugins AFTER the sorted defaults, so any optional plugin (github, superpowers, ...) puts entries after telegram. The project's own memory note `declarative-default-plugins-not-injected` ("listar TODOS en agent.yml") means operators hand-write these lists in arbitrary order too.

END-TO-END on the verbatim code (setup.sh:2193-2199) against a realistic pre-031 workspace (5 defaults + 2 optional, telegram at 5 of 7), 200 iterations: 119/200 (59.5%) wrote `features.askuserquestion_guard.enabled: false`. Sample sequence: false false true false true false true false.

CONSEQUENCE CHAIN VERIFIED: :2198 writes enabled=false -> has() guard at :2193 makes it permanent on later regenerates -> render gate `FEATURES_ASKUSERQUESTION_GUARD_ENABLED` at setup.sh:2538 skips rendering askq-guard.sh + install-askq-guard-hook.sh -> pre_install_askq_hook (docker/scripts/start_services.sh:795-797) hits `[ -x "$helper" ] || return 0` and no-ops; local path same via modules/local-login.sh.tpl:84-86. Guard never installed -> the exact 031 hang.

INDEPENDENCE CONFIRMED: :2183 and :2195 are two separate if-pipelines over the same file in the same pass, each rolling independently; one --regenerate can lose either guard, both, or neither.

Corrected rate statement: 0% when telegram@ is the last plugins[] entry (defaults-only scaffold); ~16%-88% depending on how many entries follow it (any optional plugin or hand-written declarative list). No repo file modified.

### `modules/local-healthcheck.sh.tpl:45`
```sh
if printf '%s\n' "$journal" | grep -qE 'API Error: 401|Please run /login'; then
```
- **Producer**: printf '%s\n' "$journal" — bash builtin, payload is the journalctl capture from line 44 (`journal=$(journalctl -u "$UNIT" --since "-10 min" --no-pager 2>/dev/null || true)`)
- **Status consumed as**: `if-condition`
- **Consequence**: The healthcheck silently fails to report a live authentication failure. grep -q matches the 401 on the first ~4KB chunk and exits; printf's remaining writes get EPIPE and die with 141; pipefail propagates 141 to the `if`, which becomes FALSE, so `_demote DEGRADED "auth error in journal"` never runs. The unit reports `status=OK`, exits 0 (systemd records a successful tick), and — because the notify block at line 109 is gated on `[ "$status" = "DEGRADED" ]` — the operator's Telegram alert never fires. Fallback coverage is incomplete: check 1 (`is-active`) still sees an alive process, check 2b still sees an ESTABLISHED :443 socket, and check 3 only catches the case where `expiresAt` is already in the past — so a revoked-but-not-yet-expired token, or any non-expiry 401 / "Please run /login", is reported as a fully healthy agent. The failure mode is perversely amplified: the harder the session is 401-spamming, the larger the 10-minute journal, the more certain the miss — above 64KB (~400 lines in 10 min, under one line per second) it is 100% guaranteed, exactly when the alert matters most.
- **Measurement**: Linux (python:3.12-slim, bash 5.2.37, GNU grep 3.11 — the real target: systemd host, glibc), 300 runs per size, PIPESTATUS histogram. 2139B/4128B/6270B/8259B/12390B/16528B: `300 0 0` (0%). 24690B: `299 0 0` + `1 141 0` (0.3%). 32852B: `296 0 0` + `4 141 0` (1.3%). 64576B: `92 0 0` + `208 141 0` (69.3%). 65654B: `90 0 0` + `210 141 0` (70.0%). 262240B: `300 141 0` (100%, DETERMINISTIC). macOS bash 5.3.15, 300 runs: ≤64576B `300 0 0`; 65654B `189 0 0` + `111 141 0` (37%); 262240B `300 141 0` (100%). macOS /bin/bash 3.2.57, 300 runs: 16528B `300 0 0`; 65654B `236 0 0` + `64 141 0` (21.3%); 262240B `300 141 0` (100%). The grep stage was 0 (matched) in EVERY failing run. End-to-end consequence demo on Linux with the verbatim check-2 logic + notify gate + exit contract, 401 present in all runs: 16528B → 19/20 `DEGRADED exit=2 ALERT SENT`, 1/20 `OK exit=0 no alert`; 64576B → 5/20 alert, 15/20 silent; 262240B → 20/20 `status=OK exit=0 (no alert sent)`.
- **Refuter** (refuted=False): Could not refute; all three decisive attacks failed. STRUCTURE: modules/local-healthcheck.sh.tpl:45 is a bare `if`-condition; line 6 is `set -uo pipefail`; line 44 captures `journalctl -u "$UNIT" --since "-10 min"` with no `-n` cap (unbounded). Producer is bash builtin printf (stdio-chunked on large payloads), consumer is `grep -q` (exits on first match).

MY MEASUREMENTS (300 runs each, match on FIRST line, PIPESTATUS + branch taken). macOS bash 5.3.15: 62123B/64883B -> 300/300 "0 0" THEN; 65573B -> 261/300 "141 0" ELSE (87%); 66263B -> 297/300; 69023B -> 299/300; 82823B/110423B/276023B -> 300/300 "141 0" ELSE. macOS /bin/bash 3.2.57: 13823B/55223B -> 300/300 THEN; 110423B/276023B -> 300/300 ELSE. Linux (debian bookworm, bash 5.2.15, GNU grep 3.8, aarch64 via docker): clean 300/300 at 24863B, 27623B, 34523B, 41423B; 1/300 at 55223B; 0/300 at 64883B; 29/300 at 66263B; 35/300 at 110423B; 300/300 ELSE at 276023B. grep's own stage status was 0 (MATCHED) in every failing run.

CAUSAL CONTROL (276KB, match=first, 100 runs): `set -uo pipefail` -> 100/100 ELSE; `set -u` -> 100/100 THEN. pipefail is load-bearing, measured not inferred.

END-TO-END on the REAL rendered template (Linux, stubbed systemctl/ss/journalctl; unit alive, relay :443 ESTABLISHED, 401 on first line): 13823B -> 20/20 rc=2 DEGRADED with "auth error in journal"; 110423B -> 1/20 rc=1 WARN; 276023B -> 20/20 rc=1 WARN with the "auth error in journal" reason ABSENT. Notify block at :109 is gated on `[ "$status" = "DEGRADED" ]`, so no Telegram alert fires; local-healthcheck.service.tpl sets `SuccessExitStatus=1 2`, so systemd records the tick as successful.

REACHABILITY: setup.sh:2590 renders it to scripts/local/agent-healthcheck.sh; local-healthcheck.timer.tpl runs it every 5 min (OnUnitActiveSec=5min); live local-mode agents exist (mclaren-admin, ferrari-admin).

CORRECTIONS TO THE AUDITOR (numbers wrong, verdict intact): (1) The claimed Linux sub-buffer onset at ~24KB does NOT reproduce — I measured 300/300 clean at 24863B, 27623B, 34523B, 41423B; first failure at 55223B (1/300). (2) "Linux markedly worse than macOS" is BACKWARDS in my runs: at 110423B macOS = 100% failure, Linux = 11.7%; Linux needs ~4x the pipe buffer (276KB) for determinism because GNU grep reads in large blocks. (3) The auditor understates a NECESSARY precondition: the first match must be EARLY — with the 401 on the LAST line, 200/200 correct even at 276023B (grep drains everything, no EPIPE). It is not "any journal over 64KB". (4) "status=OK, exits 0" is the best case for the narrative; I measured WARN/exit 1 — same consequence (below the DEGRADED notify gate) but the exact wording is not always what is observed. (5) Blast radius is narrower in one sub-case the auditor glosses: with a genuinely EXPIRED token, check 3 (`expiresAt <= now_ms`, :92) independently fires DEGRADED and the alert still goes out, provided jq exists and creds are readable. The truly silent cases are the ones he names: revoked-but-not-expired token, and any non-expiry 401 / "Please run /login".

NEW FINDING THE AUDITOR MISSED: tests/local-healthcheck.bats:161 is the regression test for this very check and uses `STUB_JOURNAL="API Error: 401 unauthorized"` — 27 bytes, a single write(), structurally immune. The suite validates exactly the size regime that works and would stay green with the defect live (false assurance).

UNMEASURED LINK (stated honestly): I did not measure the real byte size of a 10-minute journal from a 401-spamming Claude Code session on mclaren/ferrari (did not touch production). That is the only link carrying real-world exploitability, and the threshold is demanding: ~800 lines/10 min (1.3 lines/s) for ~12% on Linux, ~2000 lines/10 min (3.3 lines/s) for 100%. No repo file was modified.

### `docker/scripts/wizard-container.sh:146`
```sh
existing=$(grep "^${var}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
```
- **Producer**: busybox grep over /workspace/.env, pattern ^ATLASSIAN_<UPPER>_TOKEN= built at :143-144 from the agent.yml alias uppercased via tr. Consumer chain: head -1 | cut.
- **Status consumed as**: `assignment-errexit`
- **Consequence**: The first-run wizard dies mid-flow. The Telegram bot token is already persisted at :114, BEFORE this line, so on respawn start_services.sh::next_tmux_cmd evaluates `if ! has_telegram_token` as false and takes Case C (steady state) instead of Case B (wizard) - the wizard is never relaunched. Net effect: the GitHub PAT prompt and every remaining Atlassian token prompt are silently skipped forever, the agent boots with ATLASSIAN_<X>_TOKEN unset, and the atlassian MCPs fail their handshake with no error pointing back at the wizard. Not a flap (the container reaches steady state), which is what makes it hard to trace.
- **Measurement**: Measured in the real image with the exact file shape setup.sh:1317 produces for two colliding aliases (two ATLASSIAN_CENCO_TOKEN= lines). Isolated pipeline, 3000 runs: PIPESTATUS "0 0 0" 2999, "141 0 0" 1 => 0.033%. Same pipeline wrapped in `set -euo pipefail`, 3000 runs, abort detected by exit status: reached_end=2999, aborted=1 => the 141 does abort. With the two duplicate lines adjacent in a smaller file, 2000 runs: 11/2000 => 0.55%. Rate scales steeply with duplicate count (4 dups 52/2000 = 2.6%; 100 dups 271/300; 900 dups 300/300). An earlier 1000-run loop harness showed 0/1000, consistent with a ~0.03% rate and discarded as underpowered (it also had a confounding outer `| grep -q`); the clean 3000-run rerun above supersedes it.
- **Refuter** (refuted=False): Could not refute; independently reproduced and STRENGTHENED. All measurements run inside the real image agentic-pod:latest (busybox grep/head/cut -> /bin/busybox, BusyBox v1.37.0, bash 5.3.9, aarch64-musl), using the exact .env shape setup.sh:802-820 emits for two colliding Atlassian aliases (2 matching lines, 46 bytes of match output).

ATTACK 1 (status consumption) FAILED: docker/scripts/wizard-container.sh:146 `existing=$(grep ... | head -1 | cut -d= -f2-)` is a plain assignment with NO `local` (the only `local` in main() is existing_gh_pat at :118). Measured control: even the split-declaration form (`local x` on one line, `x=$(...)` on the next, i.e. the :118-119 pattern) does NOT mask errexit -> 12/3000 aborts. The local-masking exemption does not apply.

ATTACK 2 (second write) FAILED, with positive mechanism proof:
  ARM A raw pipeline N=3000: 2978 x "0 0 0", 22 x "141 0 0" => 0.73%
  ARM B real statement under `set -euo pipefail` N=3000: reached_end=2987, aborted=13 => 0.43%
  CONTROL exactly ONE matching line N=3000: 3000 x "0 0 0" => 0.00%
The one-match arm being perfectly clean proves busybox grep writes per line and the SECOND write takes EPIPE. Duplicate keys are genuinely load-bearing and genuinely sufficient.

ATTACK 3 (measured vs reasoned): auditor measured, but UNDERSTATED the rate ~20x (mine 0.73%/0.43% vs their 0.033%).

ATTACK 4 (reachability): two corrections, both making it WORSE, neither refuting.
 (a) :146 is not only a race. With ZERO matching lines grep exits 1 -> pipefail -> unguarded assignment -> errexit: 200/200 aborts, deterministic, no race. An errtrace ERR trap on the real script (only ENV_FILE path relocated, logic byte-identical) pinpoints the abort at real line 146.
 (b) The auditor MISSED a sibling gate at :119 (`existing_gh_pat=$(grep "^GITHUB_PAT=" ...)`). Same defect one step earlier, fires 100% when .env has no GITHUB_PAT line — every scaffold where the GitHub MCP was not enabled, since setup.sh:817 writes that line only when github_enabled=true. Live run of the real script: GitHub-MCP-off => rc=1, aborts at real line 119 right after persisting TELEGRAM_BOT_TOKEN, never reaching the Atlassian loop. This narrows the :146 race to GitHub-MCP-enabled scaffolds but substitutes a deterministic failure across the wider population. Normal scaffold with ONE token line: rc=0, clean.

Duplicate-alias precondition confirmed reachable: scripts/lib/wizard-validators.sh:136-143 checks only ^[A-Za-z0-9_]+$ with no uniqueness test; setup.sh:811 uppercases; so `cenco` and `Cenco` both emit ATLASSIAN_CENCO_TOKEN=.

Consequence chain confirmed by reading docker/scripts/start_services.sh:461-465 and :687-690: has_telegram_token requires a NON-EMPTY TELEGRAM_BOT_TOKEN, persisted at wizard-container.sh:114 BEFORE both failure points, so the respawn takes Case C (steady state) and the wizard is never relaunched — the remaining prompts are skipped permanently, exactly as claimed.

Why undetected: no test ever executes main(). tests/docker-render.bats:264-296 assert on the source TEXT; tests/wizard-container-refresh.bats sources the file with WIZARD_CONTAINER_NO_RUN=1 to exercise refresh_claude_md only.

No repo file modified; work confined to the scratchpad and throwaway containers.

## Safe — and why

The six marked LATENT are safe by a property of their input or of a vendor binary, not by
the code's design. They are the ones to re-measure when those inputs change; they are also
recorded in `CLAUDE.md`'s gotchas so the warning reaches whoever edits them.

### `docker/scripts/start_services.sh:431`

The pipeline genuinely and frequently produces 141 under the real busybox runtime (30.7%-100% depending on .env shape), so the producer half of the defect is real and measured. It is neutralised entirely on the consumer half, by two independent facts. (1) The only call site in the repo is line 704, `ensure_channel_env_synced "telegram" "TELEGRAM_BOT_TOKEN" || true` — the function call is the command preceding `||`, so errexit is suspended for its whole dynamic extent; a 141 on line 431 cannot abort the boot script. (2) Even so the value is correct: `head -1` got its line before grep died, so `cut` emitted the token and `$token` is non-empty; execution simply falls through to line 432 `[ -z "$token" ] && return 1`, which is false, and the sync proceeds. Measured end-to-end at the real call-site shape: 300/300 SYNCED with the right token. Two further mitigations worth recording: line 426 early-returns whenever the channel-scoped .env already carries the key, so line 431 only ever runs on a first sync (fresh agent or wiped .state), and a duplicate TELEGRAM_BOT_TOKEN= line is itself an operator error, not a normal shape. LATENT LANDMINE, not a current defect: the `|| true` is the only thing standing between this line and a container restart loop. Measured counterfactual on the sibling function (identical body, see line 464): called unguarded under `set -e`, 131/300 = 43.7% abort with exit 141. If anyone ever drops the `|| true`, or calls this helper from a non-guarded context, this becomes exactly the flap class feature 036 exists to end.

### `docker/scripts/start_services.sh:464`

Two independent guards, both measured. (1) The sole call site is line 687, `if ! has_telegram_token; then` — errexit is suspended for the whole invocation, so the 141 cannot abort the boot script. (2) The 141 is not even the function's return status: the assignment is on line 464 and the function's last command is line 465, `[ -n "$val" ]`. `head -1` received the token line before grep took SIGPIPE, so `$val` is non-empty and the function correctly returns 0. Measured: 300/300 took CASE_C (launch `claude --channels`), never the CASE_B wizard misroute. Note the declaration is split — `local val` on 463, plain `val=$(...)` on 464 — so this IS an errexit-eligible assignment, not the `local v=$(...)` masked form; the only thing saving it is the `if !` at the call site. The counterfactual quantifies that: 43.7% abort rate when unguarded. In a boot script an abort here is a container exit and, with `unless-stopped`, a restart loop. Currently unreachable, but one refactor away.

### `docker/scripts/start_services.sh:596`

The consumer side is the vulnerable shape — `grep -q` short-circuits on the first match and the status is consumed as an `if` condition, which is exactly the setup.sh:2183 ground-truth pattern. What kills the defect is the producer: the claude CLI is a Node process, and Node ignores SIGPIPE by default, surfacing a closed pipe as an EPIPE stream error rather than a fatal signal. This CLI handles or swallows it and still exits 0. I measured that directly rather than inferring it: forced EPIPE via `| head -1` on a 119 KB stream, 30/30 exit status 0. So `${PIPESTATUS[0]}` is 0 no matter how early grep leaves, and pipefail has nothing to propagate. Volume is also not a factor here in practice — a real agent has a handful of marketplaces, 325 B of output, well inside a single write. Recording the consequence had it fired, since it bounds the blast radius: the `if` would go false, the code would re-run `claude plugin marketplace add` on an already-registered marketplace, which either succeeds or logs the fail-silent WARN at :605 and returns 0 regardless. Cost would be a redundant git clone over the VirtioFS bind-mount plus up to 12 s of boot latency and a misleading WARN — never an abort, never a flap. This verdict is tied to the CLI's EPIPE handling, which is a vendor behaviour and could change across claude versions; the `if`-condition consumer is the part that would then be exposed.

### `docker/scripts/start_services.sh:645`

Same mechanism and same verdict as :596, with one structural difference that only reduces the risk further: this call sits inside a `while IFS= read -r key` loop over the third-party marketplace keys, and each iteration's `if` is independent — a false negative on one key would re-register that one key and `continue`, never abort the loop. The producer's EPIPE immunity (measured, not reasoned) means `${PIPESTATUS[0]}` is 0 regardless of where `grep -q` exits, so pipefail never fires. Consequence had it fired: re-run `claude plugin marketplace add "$repo"` for an already-resolved marketplace, which logs the fail-silent WARN at :654 and returns 0; cost is a redundant clone plus up to 12 s per affected key in the boot path, multiplied by the number of extra marketplaces. Still not an abort and not a flap. Same caveat as :596 — the safety is the vendor CLI's EPIPE handling, not the code's.

### `docker/scripts/start_services.sh:1021`

Both halves of the defect shape are present — `grep -q` short-circuits, and the status is an `if` condition whose falsity silently changes a decision — but the producer cannot reach the failure mode at the volumes this log actually produces. busybox tail writes the whole 50-line tail into the pipe; while that fits the 64 KiB pipe buffer it never blocks, so it never attempts a write after grep has gone, and the EPIPE precondition is never met. I bracketed the cliff precisely (63,785 B clean over 300 runs, 69,665 B failing 300/300) and then measured the real distribution rather than guessing at it: across a quarter-million sampled windows from two production agent logs, the largest 50-line window was 15,684 B — a 4.2x margin to the threshold, with zero windows even reaching 48 KB. Consequence, recorded for the residual case: errexit is suspended inside the `if`, so a 141 cannot abort the watchdog; it would set `detected=0`, and if the previous state was `detected` the else branch at :1062-1068 fires `_emit_auth_warning "recovered"` and rewrites the state to ok — i.e. the operator gets a false 'auth recovered' message while the agent is still parked at /login, then gets re-warned on the next 60 s tick. Notification flap, operator-visible, self-correcting, bounded. This is the one candidate in the file whose safety rests on an input-size property rather than on a guard, so it is the one to re-measure if claude.log line shapes change — a much wider pane, or a burst of very long single-line tool output, is the thing that would move it. Worth noting the call at :1239 is a bare `_check_auth_banner` inside the watchdog's `while true` loop with errexit live, so the `if` on this line is load-bearing: it is what keeps a pipeline status from reaching the loop body.

### `setup.sh:198`

Two independent reasons, both measured rather than argued. (1) Producer immunity: printf is a bash builtin that emits the whole payload in one write() the kernel accepts wholesale; I located the exact boundary at 65536 bytes (64 KiB) — below it the race is unreachable (400/400 clean across both bash versions at 4545 B and 64887 B), above it failure is deterministic. A github.com/<owner>.keys body would need roughly 88 rsa-4096 key lines to cross 64 KiB; real fork owners carry 1-10 keys. (2) Consumption guard: `|| true` sits INSIDE the command substitution and binds to the whole pipeline (|| is lower precedence than |), forcing status 0, so the bare assignment on :198 (no `local` — `local key` is a separate statement on :197, so errexit WOULD otherwise apply) can never trip errexit. I confirmed the guard degrades correctly rather than merely silently: forced to 149 KB where the raw pipeline is 141 in 200/200 runs, the real function still returned the correct key 150/150, because grep -m 1 emits the matched line into the substitution before it exits. Safe, and safe for the right reason.

### `setup.sh:199`

Identical producer and guard to :198, so the same two independent defenses apply: printf is a single-write builtin immune below the measured 64 KiB threshold, and `|| true` inside the substitution pins the status to 0. One extra consumption subtlety I checked rather than assumed: this is an `A && B` list whose final command is the assignment, so B's failure is NOT exempt from errexit (only non-final members of an && list are) — the `|| true` is genuinely load-bearing here, not decorative. The left side failing (key already found on :198) leaves the list at status 1, which is harmless because :200 follows and it is not the function's last statement. Verified empirically: forced to 149 KB in the fallback branch, the real code returned the correct rsa key 150/150 with no abort.

### `setup.sh:1544`

This is the one candidate whose CONSUMPTION is genuinely dangerous and identical in shape to the confirmed :2183/:2195 defect: a 141 makes the if-condition FALSE, taking the else branch that prints '✗ fork creation failed', dumps the stderr, and calls `exit 1` on :1549 — aborting scaffolding on the benign 'fork already exists — reusing' path. It is saved purely by the producer. `echo` is a bash builtin writing a finite in-memory string in one write(); I measured its immunity boundary at exactly 65536 bytes, the same threshold as printf, clean 300/300 on both bash versions at the realistic 206 B payload. The payload cannot approach that: the command substitution on :1542 completes before the echo runs, and it captures only the stderr of a single `gh repo fork` invocation — a couple of lines, a few hundred bytes. I verified the redirection order (`2>&1 >/dev/null`: fd2 to the capture pipe, then fd1 to /dev/null) so stdout is genuinely discarded and cannot inflate the payload. Worth recording that the safety margin here is a property of gh's output size, not of the code — this line would become exploitable if the captured stream ever grew past 64 KiB.

### `modules/local-bootstrap.sh.tpl:203`

Safe on three independent legs, two of them measured. (1) The file declares `set -uo pipefail` at :22 — errexit is NOT enabled, unlike setup.sh:4. (2) The pipeline's status is consumed as a `case` WORD: bash discards the command substitution's status there; the `case` compound returns the status of the matched list (or 0). Measured 400/400 clean with a producer that provably dies with 141 when observed directly, and 100/100 clean even when `-e` is forced on. (3) Even if the producer is killed, the VALUE is still correct — `head -n1` has already consumed and printed line 1 before the producer could attempt its second write, so the `*musl*` / `*GLIBC*` match is unaffected. Note this is the one candidate in the file whose producer is genuinely vulnerable; it is the consumption site, not the producer, that makes it harmless.

### `modules/local-bootstrap.sh.tpl:263`

The CONSUMPTION shape is the dangerous one — `pipefail` is on (:22) and the status gates an `&&`, so a 141 would silently skip `provision_uv`/`provision_uv_tools` and the script would still `exit 0` (:277), i.e. the exact setup.sh:2183 silent-wrong-decision class. What saves it is purely the producer's write pattern: `printf` is a builtin whose whole payload fits one write() into the 64 KiB pipe buffer, so the kernel accepts it before `grep -q` can even exec. `$cmds` cannot approach that buffer: it is the sort -u'd set of DISTINCT `.value.command` values, and modules/mcp-json.tpl can emit at most four distinct commands (`uvx`, `npx`, `github-mcp-server`, `{{QMD_MCP_COMMAND}}`), with overlay injection (custom-apply) adding a handful of wrapper paths — measured 116 bytes, ~565x below the boundary. Reaching 64 KiB would need thousands of distinct MCP commands in one .mcp.json. Named regression risk, not a current defect: if anyone ever collapses this into `jq -r '…' "$MCP_JSON" | grep -qx uvx` (dropping the `$cmds` variable), the producer becomes incremental and this line becomes the measured setup.sh defect verbatim.

### `modules/local-bootstrap.sh.tpl:264`

Identical mechanism to :263. `grep -qx npx` matches before EOF so the reader genuinely can close early, but the builtin producer has already issued its single 116-byte write() into the 64 KiB pipe buffer and exited 0. Consequence if it ever fired would be a silently skipped `provision_node_links` (npx MCPs then fail to connect with the script still exiting 0), but it is unreachable at any realistic payload size.

### `modules/local-bootstrap.sh.tpl:265`

Identical mechanism to :263/:264, with a slightly earlier reader exit (2 of 5 lines still pending) and still 0/600. The `sort -u` at :261 is what determines WHERE each pattern matches, and therefore how early the reader can close; none of those positions matters while the producer completes in one write. Consequence if it ever fired: `provision_github_mcp` silently skipped, the github MCP left unprovisioned, exit 0.

### `modules/local-bootstrap.sh.tpl:269`

Same single-write immunity as :263-265. Worth stating precisely because this is the worst-case site on paper: the second leg's reader exits after line 2 of 5, and pipefail under `||` means a 141 from the first leg would ALSO be swallowed harmlessly while a 141 from the second would make the whole `if` false and skip `provision_bun` (qmd MCP never starts, exit 0 — the 027-US2 bug class this line was added to fix). Neither fires: 1200/1200 clean, and the boundary measurement puts the first possible 141 at ~65536 bytes of `$cmds`, three orders of magnitude above the measured 116. Note the first leg is doubly safe — a non-matching `grep -q` consumes to EOF and never closes the pipe early at any payload size.

### `modules/local-healthcheck.sh.tpl:55`

SIGPIPE requires a pipe. This line has none — it is `var=$(cmd || echo "")`, a command substitution whose output goes to a temp buffer/fd owned by the shell, not to a reader that can exit early. Two further independent guards make it safe even hypothetically: the `|| echo ""` swallows any non-zero status, and line 6 sets `-uo pipefail` WITHOUT `-e`, so even a 141 inheriting into the assignment could not trigger errexit (the brief's `v=$(PIPELINE)` abort case requires `set -e`, which this file deliberately does not set). The downstream consumers at lines 56 and 62-63 both handle an empty `main_pid` correctly, degrading to `_demote WARN "cannot verify connection"`.

### `modules/local-healthcheck.sh.tpl:56`

Doubly immune, by two independent arms of the brief's mechanism. (1) Single-write: the payload is a PID from `systemctl show -p MainPID --value`, structurally capped at ~7 digits, so printf issues one write() that the 64KB pipe buffer accepts before grep is even scheduled. (2) One-line-only: there is exactly one value and nothing follows it, so no second write() is ever attempted regardless of timing. My line-45 sweep pins the empirical onset of the race at ~24000 bytes on Linux — this payload is four orders of magnitude below that. The empty-`main_pid` path is also correct rather than a SIGPIPE hazard: printf writes 0 bytes, grep sees EOF and exits 1, pipefail yields 1, the `&&` chain fails, and control reaches the intended `_demote WARN "cannot verify connection"` at line 63.

### `modules/local-healthcheck.sh.tpl:57`

The middle grep is not `-q`, so it reads to EOF and never exits early on its own; it can only die if the terminal `grep -q ':443'` exits while it still has buffered output to flush. Because it writes to a pipe, glibc stdio block-buffers it at BUFSIZ, so any matched output under 4096 bytes leaves the building as ONE write at exit — the brief's single-write immunity — and the measurement confirms this exactly: 0/300 at 3909 B, 27/300 at 4389 B. Crossing that threshold requires the session process to own roughly 42+ ESTABLISHED sockets, since an `ss -tnpH` line is ~98 bytes and the `pid=${main_pid},` filter keeps only sockets owned by the session PID itself — MCP servers are separate processes with different PIDs and are filtered out. A Claude Code session holds the relay connection plus a handful of API connections, i.e. single digits, an order of magnitude below the threshold. I therefore judge the mechanism real but the triggering input shape outside normal operation. Note also that stage 1 (`ss`) stayed 0 in every failing run: it only takes EPIPE if the middle grep dies first and it still has data pending, a strictly narrower window.

### `modules/local-healthcheck.sh.tpl:91`

Same double immunity as line 56. The jq filter at line 90 ends in `| first // empty`, which structurally guarantees at most ONE scalar reaches `$exp` — so printf emits ~13 bytes in a single write that the pipe buffer accepts immediately, and has nothing left to write afterwards even if grep were slow. Four orders of magnitude below the ~24000-byte empirical onset measured on Linux for line 45. The important distinction from line 45 is the producer's payload bound: `$journal` is unbounded journalctl output, whereas `$exp` is bounded by jq's `first` to a single number. Note also that the jq producer at line 90 is a command substitution, not a pipeline into this grep, so jq itself is never exposed to EPIPE here.

### `modules/local-login.sh.tpl:30`

Safe for two independent, separately measured reasons.

(1) The producer never attempts a write after the reader closes. `claude --version` emits one line containing exactly one `[0-9]+\.[0-9]+\.[0-9]+` token (verified: `grep -c` = 1, `grep -o | wc -l` = 1), so `grep -oE` emits exactly ONE output line and then hits EOF. This is precisely the mechanism bullet 'a producer with only ONE matching output line and nothing to write afterwards is SAFE even if slow'. The first stage is additionally immune on its own: `printf` is a bash builtin issuing a single 21-byte write that the kernel accepts into the 64KB pipe buffer before `grep` even runs. Measured 600/600 `0 0 0`.

(2) The file-specific note asks whether `|| true` actually covers the pipeline status. It does. Bash grammar parses `A | B | C || D` as `(A|B|C) || D` — the `||` binds to the whole pipeline, not to `head -1` alone — so a pipefail-propagated 141 from any stage is swallowed before the command substitution closes, and the assignment inherits 0. Proven rather than asserted: with a producer forced to 141 (`141 141 0` deterministic), the real line survives with `assign_status=0` and `script_rc=0` on both bash versions, while the identical script with `|| true` removed dies `script_rc=141` on both. The guard is load-bearing and correctly placed.

The value is also non-corruptible: `head -1` reads and emits line 1 BEFORE closing the pipe, so `ver` is captured intact even in the forced-141 case (`ver=[1.2.1]`). This closes the only path to a real consequence here — a spuriously empty `ver` would hit line 31's `[ -z "$ver" ]` and abort `--login` with a false 'Claude Code >= 2.1.51 is required (found: none)' error. That path is unreachable via SIGPIPE.

Residual (latent, not a live defect, not a finding): safety of stage 2 rests on `claude --version` emitting exactly one version-shaped token. If a future release printed a second one, `grep` would begin racing `head -1` — but `|| true` would still absorb the status and `head -1` would still yield the first match, so the consequence would remain none. No fix warranted; this is an audit and nothing was modified.

### `scripts/lib/qmd_index.sh:473`

Three independent reasons, each sufficient. (1) Write pattern: head -n1's early exit can only pressure the stage feeding it, grep -oE '[0-9]+'. Ground truth from the pinned engine (downloaded @tobilu/qmd@2.5.3 from registry.npmjs.org, dist/cli/qmd.js:367): exactly ONE site prints `Pending:  N need embedding`, driven by the scalar getHashesNeedingEmbedding(db, undefined, model), not a per-collection loop — so that stage writes one line and never attempts a second write. Mechanism bullet 3 (one-matching-line producer is immune even when slow). The upstream grep and printf are shielded behind it: grep1 keeps reading printf's whole stream to EOF because it has no further matches, which is why even a 3.2 MB fixture with the match at position 2 measured clean 300/300. (2) Measured threshold: the pipeline needs ~5000 matching `Pending:` lines from a single `qmd status` before stage 3 starts dying — structurally unreachable (one collection, one scalar). (3) Consumption: no caller enables errexit. start_services.sh is the only `set -euo pipefail` consumer and its only entry point is qmd_setup_if_needed (:186) -> _qmd_setup_locked (:357-400), which calls `_qmd_run … embed` directly and never reaches _qmd_pending_count; the reindex path runs under heartbeatctl (`set -u`, pipefail OFF) or the rendered local agent-qmd-reindex.sh (`set -uo pipefail`, no -e, `qmd_reindex … || true`). Even in the pathological arm the substitution still captured the value and $? was discarded by `if [ -z "$n" ]`. Latent condition worth recording, not a finding: this is the bare-assignment form, so it would become errexit-sensitive if any future consumer sourced the lib under `set -e` and reached the reindex path.

### `scripts/lib/qmd_index.sh:498`

Shape-wise this IS the setup.sh class: incremental-capable producer, `grep -q` consumer that exits on match, status consumed as an `if` condition under pipefail in local mode (modules/local-qmd-reindex.sh.tpl:14). I proved the mechanism fires for this exact pipeline (300/300 with the match early), so the verdict turns solely on where the match lands in real output. Ground truth, read from the pinned package rather than inferred — dist/cli/qmd.js:1709-1720: `const hashesToEmbed = getHashesNeedingEmbedding(...); if (hashesToEmbed === 0 && !force) { console.log('✓ All content hashes already have embeddings.'); closeDb(); return; }`. That is an EARLY RETURN before any model load or progress emission; closeDb() (:62) is silent; the CLI `embed` case (:3890-3911) prints nothing between `await vectorIndex(...)` and `break`; the only exit hooks (:154-155) fire on SIGINT/SIGTERM (and a `timeout 900` SIGTERM from _qmd_run would give rc != 0, which returns at :493 before reaching :498). The progress writer at :1755 is additionally TTY-gated (`if (isTTY)`) and stdout/stderr here are a command-substitution pipe. So on every pass that matches, the string is both the last and essentially the only byte written — measured 57 B, 0/300 failures in both bash versions. Adversarial note on margin: this is NOT a comfortable pass. With a large preceding stream, only 20 bytes written after the match already fires 141 in 10.7% of runs. If a future qmd emitted a trailing summary line, a cursor.show() escape, or moved the message ahead of a per-document report, the failure would be silent and 10-99% likely. Blast radius if it fired: when the corpus is fully embedded, `qmd status` omits the Pending line entirely (dist/cli/qmd.js:365, `if (needsEmbedding > 0)`), so _qmd_pending_count returns empty + rc 1 and the `pending -eq 0` fallback at qmd_index.sh:504 can never fire in that state — line 498's match is the ONLY working completion signal. A 141 there means pending=unknown, all 12 QMD_EMBED_MAX_PASSES full embed passes burned, then last_status=partial. That is the same degradation docs/qmd-upgrade-checklist.md:70-74 already tracks for a string change; SIGPIPE is a second, undocumented route to it and is not on that checklist.

### `docker/scripts/wizard-container.sh:119`

SIGPIPE needs a write() after the reader closed. Every launcher code path yields at most ONE line matching ^GITHUB_PAT=: setup.sh:1318 appends it exactly once under a guard, and update_env_var (:15-22) upserts via `sed -i s|^KEY=.*|...|`, which replaces ALL matches and therefore can never create a duplicate. With one match grep writes it and hits EOF with nothing left to write, so the second write that EPIPE requires never happens - confirmed 2000/2000 clean. Duplicates are the only way in, and unlike line 146 no supported input produces them here (only an operator hand-edit or a restored .env.age whose source already had them), so I do not rate this EXPLOITABLE. I flag the no-match errexit abort because it shares the consumption site and is the failure that actually fires on this line - reported as measured fact, explicitly not as SIGPIPE.

### `.specify/extensions/agent-context/scripts/bash/update-agent-context.sh:33`

Read the full surrounding block (lines 17-40) for real context. The script does declare `set -euo pipefail` at line 17, so the precondition for the defect class is present. But the candidate fails the class on the producer axis and is harmless on the consumption axis. PRODUCER: `python --version` prints a single 13-byte banner line and exits; it falls squarely into the task's third mechanism bullet (a producer with only one matching output line and nothing to write afterwards is SAFE even if slow, because it never attempts a second write). The `2>&1` merge does not change this — Python 3 writes the banner to stdout, and any site/deprecation warnings on stderr are emitted during interpreter startup BEFORE `--version` is handled, i.e. before the matching line, so grep would still be reading when they arrive. The inverse ordering (a trailing write after the match) is what would be needed to create the race, and `--version` has no such trailing output. A Python 2 interpreter would print `Python 2.x` to stderr, which does not match `^Python 3`, so grep reads to EOF, never closes early, and the path is safe for a different reason. CONSUMPTION: the pipeline sits in an `elif` condition, which is the task's first consumption bullet — errexit does not fire, and a non-zero would only make the condition false. I verified where that lands: `_python` stays empty, line 37's `[[ -z "$_python" ]]` guard catches it, and the script exits 0 with an explicit diagnostic. So even the worst case is a silent-but-announced no-op, not a wrong decision with downstream effect and not an abort. I measured rather than reasoned alone: 900 runs total across three arms (both bash 5.3.15 and 3.2.57), all clean, and I built an adversarial control that holds the consumer and pipeline shape constant while swapping in a multi-write producer — it failed 292/300, which rules out the possibility that my clean arms were merely an under-powered sample or a host where SIGPIPE races do not manifest. The control also surfaced the 120-vs-141 exit-code distinction that a signature-based fleet grep would otherwise miss. Adversarial self-check: the one residual path to a failure would be a wrapper `python` on PATH (pyenv/conda/asdf shim, or a shell function) that emits output AFTER delegating the version banner; such shims print diagnostics before exec, and `command -v python` at the head of the same line resolves an executable rather than a function, so I judge this speculative rather than realistic. Even granting it, the consequence analysis above is unchanged: graceful skip, exit 0. Verdict SAFE, not UNMEASURABLE, because the producer ran on this host and gave a measured zero failure rate with a validated-positive control.
