# Contract — channel window as configuration (US2)

**Feature**: 036 cold-start boot resilience · **Story**: US2 · **Covers**: FR-005 … FR-009, plus the
local-mode edge case of the spec's Edge Cases list.

**Mould**: feature 029 (`claude.mcp_timeout_ms`). Every clause below is a transposition of a
construct that already exists in the tree; the anchors are cited so implementation and tests cannot
drift from a remembered shape.

| Anchor | Path:line | Role here |
| --- | --- | --- |
| `mcp_timeout_effective()` | `setup.sh:2016-2023` | sanitiser mould |
| `claude.mcp_timeout_ms: 120000` | `setup.sh:1232` (agent.yml heredoc) | new-scaffold default mould |
| `$docker_yaml` | `setup.sh:1116-1129` | the `docker:` block the new field joins |
| `has()` backfill | `setup.sh:2227-2233` | backfill mould (never `//`) |
| re-export after `render_load_context` | `setup.sh:2244-2245` | sanitised-value export mould |
| `MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"` | `modules/docker-compose.yml.tpl:73` | rendered-line mould |
| `channel_health_timeout()` / `warn_if_channel_timeout_risky()` | `docker/scripts/start_services.sh:739-745` / `:753-760` | the in-container reader — **not modified** |
| `env_file_get` | `scripts/lib/env_file.sh:18-30` | parses `.env`, never sources it (021) |
| FR-011 oracle of 032 | `tests/local-render.bats:289-309` | local-mode inertness mould |
| feature-026 DOCKER_E2E test | `tests/docker-e2e-postlogin.bats:146-195` | **goes red unless rewritten** — see C16 |
| Documentation to correct | `README.md:150`, `docs/architecture.md:127` | both still name the `.env` as the knob — see C17 |

**Test file**: `tests/channel-window-config.bats` (new), moulded on
`tests/mcp-handshake-timeout.bats` (12 tests, listed in Appendix A).

## Scope

In scope: the `agent.yml` field, its sanitiser, its **migrating** backfill, its rendered delivery to
the compose `environment:` block, the migration notice for a workspace whose `.env` already carries
the key by hand, the rewrite of the feature-026 DOCKER_E2E test that the new precedence invalidates
(C16), and the two documentation paragraphs that still point operators at the losing channel (C17).

Out of scope: the in-container reader (frozen, see C8), the crash-budget arithmetic, any change to
`modules/env-example.tpl`, any wizard prompt, and any change to `scripts/lib/schema.sh`.

## Canonical strings

Both are copied verbatim from `data-model.md` §1. Implementation and test oracles MUST use these
exact bytes; a divergence between the two is the failure mode this section exists to prevent
(lesson of 033/034).

**CANON-C1** — the rendered compose line (six leading spaces, placed next to `MCP_TIMEOUT`):

```yaml
      CHANNEL_HEALTH_TIMEOUT: "{{DOCKER_CHANNEL_HEALTH_TIMEOUT_S}}"
```

**CANON-C2** — the migration notice, one line, to stderr:

```text
NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated into agent.yml (docker.channel_health_timeout_s); docker-compose.yml now renders it and the rendered value wins — you can remove the .env line
```

It opens with `NOTE:`, not `WARN:`, because after the adversarial review the backfill **migrates** the
live value (C6) instead of resetting it: nothing is broken by the time this prints, so the line
reports a completed, successful action and names the leftover the operator may delete. Any test
oracle that greps for the old `WARN: CHANNEL_HEALTH_TIMEOUT is set …` wording is stale by
construction.

## Clauses

### C1 — The field

`.docker.channel_health_timeout_s`: a positive integer, seconds, default `60`. It lives in the
existing `docker:` block because its consumer is the container watchdog, not the `claude` binary
(which is why it does not join `claude.mcp_timeout_ms`). The `_s` suffix mirrors the `_ms` precedent.
No wizard prompt (precedent: `features.voice.{signoff,currency}` of 034).

**Oracle** — `tests/channel-window-config.bats`: an `agent.yml` carrying
`docker.channel_health_timeout_s: 120` renders `CHANNEL_HEALTH_TIMEOUT: "120"`; and no wizard prompt
was added, asserted in the C10 shape rather than with a plain `grep`:

```bash
run bash -c "LC_ALL=C grep -lF 'channel_health_timeout' '$REPO_ROOT/scripts/lib/wizard.sh' '$REPO_ROOT/scripts/lib/wizard-gum.sh' | wc -l | tr -d ' '"
[ "$output" = "0" ]
```

`tests/helper.bash::wizard_answers` is NOT touched — the e2e-smoke answer stream stays byte-identical
(contrast with the 034 `lang=`/`nick=` churn).

### C2 — New scaffolds carry the field

The `$docker_yaml` heredoc (`setup.sh:1116-1129`) gains a `channel_health_timeout_s: 60` line at
two-space indentation.

**Placement is load-bearing**: that heredoc ends with the nested `toolchain_channels:` mapping
(`:1124-1129`), so a line appended at the end would be parsed as a *child* of
`toolchain_channels`. The new line goes after `gum_version` and **before** `toolchain_channels:`, at
two-space indentation.

**Oracle** — a scaffold run (or the existing e2e-smoke path) produces an `agent.yml` for which
`yq -r '.docker.channel_health_timeout_s' agent.yml` = `60` **and**
`yq -r '.docker.toolchain_channels | has("channel_health_timeout_s")' agent.yml` = `false`
(the second half is what catches the indentation slip).

### C3 — Sanitiser

`channel_health_timeout_effective()` in `setup.sh`, moulded byte-for-byte on
`mcp_timeout_effective()` (`setup.sh:2016-2023`), with the 029 bounds narrowed to the watchdog's own:

```bash
channel_health_timeout_effective() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$v" -gt 0 ]; then
    printf '%s' "$v"
  else
    printf '60'
  fi
}
```

The regex bound is **6 digits**, not 7: it matches the in-container reader's own validation
(`start_services.sh:741`), so host and container agree on what "implausibly large" means.

Feeding the sanitiser the *flattened* `DOCKER_CHANNEL_HEALTH_TIMEOUT_S` is safe here, unlike the
free-text fields of 034: an explicit YAML null flattens to the literal string `null`, which fails
`^[0-9]{1,6}$` and degrades to `60` like any other garbage. No `yq -r '… // ""'` re-read is needed.

**Oracle** — the full matrix of C3a below, asserted on the rendered artifact.

#### C3a — Sanitisation matrix

The `.env` column matters only on the rows where the field is **absent** from `agent.yml`, because
that is the only case the backfill touches (C6). Everywhere else the `.env` is irrelevant to the
value — it only decides whether CANON-C2 prints (C9).

| `agent.yml` value | workspace `.env` | Rendered `CHANNEL_HEALTH_TIMEOUT` | `agent.yml` after `--regenerate` |
| --- | --- | --- | --- |
| `120` (valid) | — | `"120"` | `120` (untouched) |
| `60` (the default, explicit) | — | `"60"` | `60` |
| `999999` (6 digits, boundary accepted) | — | `"999999"` | `999999` |
| absent (pre-036 workspace) | no key / no `.env` | `"60"` | backfilled to `60` (C6) |
| absent (pre-036 workspace) | `CHANNEL_HEALTH_TIMEOUT=120` | **`"120"`** | **migrated to `120`** (C6) — effective behaviour unchanged across the upgrade |
| absent (pre-036 workspace) | `CHANNEL_HEALTH_TIMEOUT=` (empty) | `"60"` | `60` — nothing to migrate (C11 case 3) |
| absent (pre-036 workspace) | `CHANNEL_HEALTH_TIMEOUT=abc` | `"60"` | `60` — the seed goes through the same sanitiser |
| absent (pre-036 workspace) | `CHANNEL_HEALTH_TIMEOUT=1234567` | `"60"` | `60` — 7 digits fail the sanitiser, and the container already degraded that value to 60 (`start_services.sh:741`), so nothing regresses |
| empty (`channel_health_timeout_s:`) | any | `"60"` | empty (backfill must NOT fill it — C6) |
| `0` | any | `"60"` | `0` (operator's value preserved — C6) |
| `-5` | — | `"60"` | `-5` |
| `"abc"` | — | `"60"` | `"abc"` |
| `1.5` | — | `"60"` | `1.5` |
| `1234567` (7 digits) | — | `"60"` | `1234567` |

The right-hand column is as load-bearing as the middle one: the sanitiser degrades the **artifact**,
never the source of truth. An operator who typed `0` finds `0` still in `agent.yml` after a
regenerate, exactly as in 029 (`tests/mcp-handshake-timeout.bats:141-147`).

### C4 — Re-export after `render_load_context`

Immediately after the 029 re-export (`setup.sh:2244-2245`), and therefore before any
`render_to_file`, `regenerate()` overwrites the flattened variable with its sanitised value:

```bash
DOCKER_CHANNEL_HEALTH_TIMEOUT_S="$(channel_health_timeout_effective "${DOCKER_CHANNEL_HEALTH_TIMEOUT_S:-}")"
export DOCKER_CHANNEL_HEALTH_TIMEOUT_S
```

The flatten name is automatic: `render_load_context` maps `.docker.channel_health_timeout_s` →
`DOCKER_CHANNEL_HEALTH_TIMEOUT_S` (`scripts/lib/render.sh:59-60`, `tr '.' '_'` + upper-case).

**Oracle** — the C3a matrix passes; and the value is never rendered raw (see C5's single-source half).

### C5 — Rendered delivery, unconditional, single-sourced

`modules/docker-compose.yml.tpl` gains CANON-C1 in the `environment:` block, adjacent to
`MCP_TIMEOUT` (`:73`). Unconditional — there is no `{{#if}}` in that block and no flattened var
expresses watchdog presence, the same reasoning that made the five `TELEGRAM_VOICE_*` lines
unconditional (`:74-84`).

The template MUST NOT carry the literal `60` anywhere near that key: the default lives in exactly two
places by design — the host sanitiser (C3) and the container reader (C8) — and the template in
neither.

**Oracles**

- `tests/docker-render.bats`: rendering `modules/docker-compose.yml.tpl` against
  `tests/fixtures/sample-agent.yml` yields `CHANNEL_HEALTH_TIMEOUT: "60"` (mould: the 029 test at
  `tests/docker-render.bats:67-72`).
- `tests/channel-window-config.bats`, both halves in the C10 shape (the second is a negative and
  must never be a plain intermediate `grep`):

  ```bash
  run bash -c "LC_ALL=C grep -cF 'CHANNEL_HEALTH_TIMEOUT: \"{{DOCKER_CHANNEL_HEALTH_TIMEOUT_S}}\"' '$REPO_ROOT/modules/docker-compose.yml.tpl'"
  [ "$output" = "1" ]
  run bash -c "LC_ALL=C grep -cF 'CHANNEL_HEALTH_TIMEOUT: \"60\"' '$REPO_ROOT/modules/docker-compose.yml.tpl'"
  [ "$output" = "0" ]
  ```

- Mutation **M8** (render the line conditionally) turns the `docker-render.bats` assertion red.

### C6 — Backfill by presence, and it MIGRATES rather than resets

In `regenerate()`, beside the 029 backfill (`setup.sh:2227-2233`), inside the same
`[ -f "$agent_yml" ]` block and **before** `render_load_context` (`setup.sh:2237`) so the migrated
value reaches the same pass:

```bash
# 036: backfill docker.channel_health_timeout_s for a pre-036 workspace.
# It MIGRATES the live value: the current docs (README.md:150,
# docs/architecture.md:127) tell the operator to put the window in the
# workspace .env, and compose's `environment:` outranks `env_file:`, so a flat
# 60 here would silently downgrade every agent that followed them the moment
# CANON-C1 renders. has() (not `//`) so a present 0 or empty survives.
if [ "$(yq -r '((.docker // {}) | has("channel_health_timeout_s")) // false' "$agent_yml" 2>/dev/null)" != "true" ]; then
  local _cht_seed
  _cht_seed="$(channel_health_timeout_effective "$(env_file_get CHANNEL_HEALTH_TIMEOUT "$SCRIPT_DIR/.env")")"
  yq -i ".docker.channel_health_timeout_s = $_cht_seed" "$agent_yml"
fi
```

**Why this is the HIGH finding of US2.** A flat `60` plus the unconditional render of C5 is a silent
downgrade for every agent that followed the documentation: `donna` runs at 120 and CLAUDE.md records
`rodri-cenco-admin` at 120 as well. Those agents are not in the live gate, so the regression would
have shipped unobserved — and it re-creates exactly the cold-cache + many-MCP + short-window
combination behind the 25-minute outage this feature exists to prevent.

**Why the seed goes through the sanitiser.** `channel_health_timeout_effective` (C3) already maps
empty / non-numeric / `0` / negative / 7-digit to `60` and a valid 1-to-6-digit positive integer to
itself — precisely the data-model table. Reusing it keeps one definition of "valid window" instead of
two, and guarantees the backfill never writes a value its own render would then degrade.

**Why `env_file_get` and not a read.** The workspace `.env` can arrive from a remote `.env.age` via
`--restore-from-fork`, so it must be parsed, never sourced (`scripts/lib/env_file.sh:5-10`, the 021
anti-RCE primitive). `setup.sh` cannot call it today — see C12.

`has()` and not `//`, for the same reason as 029: a legitimate `0` — a present-but-invalid value the
render sanitiser degrades — must not be silently rewritten, and neither must an operator's explicit
empty value. A second `--regenerate` writes nothing (C7).

The backfill itself is **not** gated on deployment mode (the block at `setup.sh:2155-2234` is
mode-agnostic, like every backfill in it). In local mode the field is written and then rendered
nowhere (C13), which is inert. Only the CANON-C2 notice is docker-gated (C9).

**Oracles**

- absent, `.env` with no key → after `--regenerate`, `yq -r '.docker.channel_health_timeout_s'` is `60`;
- absent, `.env` with `CHANNEL_HEALTH_TIMEOUT=120` → it is `120`, and the artifact says `"120"`
  (**this is the migration oracle** — the one that must exist before any other US2 test);
- absent, `.env` with `CHANNEL_HEALTH_TIMEOUT=abc` → it is `60`;
- `0` → after `--regenerate`, it is still `0` (and the artifact says `"60"`);
- empty → after `--regenerate`, it is still empty.
- Mutation **M7** (`//` instead of `has()`) turns the `0` case red.
- Mutation **M18** (new — register it in `quickstart.md` §3: replace the seed with a literal `60`)
  turns the migration oracle red. Without M18 the HIGH finding has no defender.

### C7 — Idempotency

Two consecutive `--regenerate` passes are byte-stable modulo `meta.regenerated_at`, and the rendered
`docker-compose.yml` is byte-identical between them.

**Oracle** — the 029 shape: `yq 'del(.meta.regenerated_at)' agent.yml` diffed across two passes
(mould: `tests/mcp-handshake-timeout.bats:149-159`), plus `diff` of two successive
`docker-compose.yml` renders.

### C8 — The in-container reader is frozen

`docker/scripts/start_services.sh:739-745` (`channel_health_timeout`) and `:753-760`
(`warn_if_channel_timeout_risky`) are **not modified by this story**. The embedded `60` default, the
`^[0-9]{1,6}$` validation, the `<= 0` rejection and the risk WARN all stay exactly as today, so an
agent whose compose predates this feature behaves identically (FR-009).

This also means the container is **source-agnostic**: it reads the environment variable, and does not
care whether it arrived via `environment:` or `env_file:`.

**Oracles** — the three existing tests keep passing untouched:

- `channel_health_timeout defaults to 60 when unset/empty/non-numeric/<=0` (`tests/start-services-watchdog.bats:327`)
- `channel_health_timeout echoes a valid positive integer verbatim` (`:343`)
- `warn_if_channel_timeout_risky: silent for the 60s default, warns for an override past the threshold` (`:408`)

Mutation **M10** (change the in-container default from 60) turns the first of those red.

### C9 — Migration notice (FR-008)

Because compose's `environment:` outranks `env_file:` (confirmed empirically in a live container:
with both set, the process saw the rendered value), a key the operator typed into the workspace
`.env` stops taking effect the moment CANON-C1 renders. C6 keeps that from changing behaviour;
CANON-C2 is what tells the operator it happened.

- **Detection**: `env_file_get CHANNEL_HEALTH_TIMEOUT "$SCRIPT_DIR/.env"` — the 021 primitive, which
  parses and never sources (the `.env` can arrive from a remote `.env.age` via
  `--restore-from-fork`; `scripts/lib/env_file.sh:5-10`). A non-empty return means the key is set.
- **Gate**: docker mode only (`DEPLOYMENT_MODE_IS_DOCKER = true`). In local mode nothing renders the
  key, so there is no precedence to report (see C13).
- **Placement**: inside the docker-only render branch (`setup.sh:2545-2549`), emitted exactly once
  per run. It is deliberately **decoupled from C6's write**: the trigger is the key still being in
  the `.env`, not a flag set by the backfill, so no state has to travel ~300 lines between the two
  sites.
- **Stream**: stderr, via `echo "…" >&2` — the mould is the 034 sanitiser WARN (`setup.sh:2079`).
- **Text**: CANON-C2, verbatim, with no interpolation of any kind.
- **Non-fatal**: the notice never changes the exit status of `--regenerate`.
- **Repeats**: it prints on every `--regenerate` while the `.env` line is still there. That is
  intended — the line is the leftover the operator is being asked to delete, and the sentence stays
  true after the first pass, since the value now lives in `agent.yml`.

**Named residual — the notice can outlive the migration it describes.** If `agent.yml` already
carried the field and the operator *then* added a `.env` line (a post-036 hand edit following the
stale docs C17 corrects), no migration happens in that run: the rendered `agent.yml` value wins and
the `.env` value is ignored. CANON-C2 still fires and still names the correct remedy — the value
lives in `agent.yml`, remove the `.env` line — but its past tense then refers to an earlier pass, or
to nothing. Fixing the two doc paragraphs (C17) is what keeps the case rare; a second canonical
string for it would be worse than the imprecision.

**Oracles**

- With the field absent from `agent.yml` and `.env` containing `CHANNEL_HEALTH_TIMEOUT=120`,
  `--regenerate` writes `120` into `agent.yml` (C6), renders `CHANNEL_HEALTH_TIMEOUT: "120"`, prints
  CANON-C2 exactly once, and exits 0.
- With the field present as `60` and `.env` containing `CHANNEL_HEALTH_TIMEOUT=120`, the artifact
  says `"60"` and CANON-C2 still prints exactly once (the residual above).
- See C10 for the redaction oracle and C11 for the cases that must stay silent.

### C10 — The notice never leaks the value (FR-008, second half)

The notice names the key and nothing else. The `.env` value must not appear anywhere in
`--regenerate`'s stdout or stderr.

**The oracle of the first draft was red in both branches** (adversarial review, MEDIUM; measured with
bats 1.13.0). It ended with a bare `printf … | grep -qF '987654'` followed by `[ "$?" -ne 0 ]`. bats
runs each test body under errexit, so when the value is absent — the case that must PASS — the
intermediate pipeline returns 1 and aborts the test; and when the value *is* present the pipeline
returns 0 and the following comparison fails. There is no input for which that test is green. The
corrected shape captures the output to a file first, then uses `run` so a non-zero `grep` is data
rather than a fatal command:

```bash
cd "$TMP_TEST_DIR"
printf 'CHANNEL_HEALTH_TIMEOUT=987654\n' > .env        # 6 digits: a value the migration accepts
run env bash -c "echo n | ./setup.sh --regenerate 2>&1"
[ "$status" -eq 0 ]
printf '%s\n' "$output" > regen-out.txt                # `run` overwrites $output — persist it first

run bash -c "grep -cF 'NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated' regen-out.txt"
[ "$output" = "1" ]

run bash -c "grep -cF '987654' regen-out.txt"
[ "$output" = "0" ]                                    # the value must NOT appear in the output
```

`grep -c` exits 1 when the count is zero, which is exactly why it must be wrapped: under `run` the
status is captured and `$output` still carries the single token `0`. The equivalent
`run bash -c '… | grep -qF …'; [ "$status" -ne 0 ]` is also acceptable. **No oracle in this contract
may use a plain intermediate `grep`** — measured in both bash 3.2 and 5.3 during feature 033, which
found and repaired six such dead or self-defeating negatives in
`tests/apply-telegram-patches.bats`. Every negative assertion added by this story goes through
`run …; [ "$status" -ne 0 ]` or a count comparison against `run`'s `$output`.

The value is checked *in the process output only*: after migration the same digits legitimately
appear in `agent.yml` and in `docker-compose.yml`, which is the feature working, not a leak.

Mutation **M9** (interpolate the value into the notice) turns this oracle red.

### C11 — Cases that must stay silent

No notice is emitted when:

1. the workspace has no `.env` (`env_file_get` returns empty, exit 0 — `scripts/lib/env_file.sh:20`);
2. the `.env` exists but has no `CHANNEL_HEALTH_TIMEOUT` line;
3. the `.env` has `CHANNEL_HEALTH_TIMEOUT=` with an **empty** value;
4. the agent is in local mode, whatever the `.env` says (C12).

Case 3 is a deliberate, documented limitation rather than an oversight: `env_file_get` returns the
same empty string for "key absent" and "key present but empty" (FR-005 of 021, stated in its own
header at `scripts/lib/env_file.sh:15-17`). Silence is right there anyway — an empty value already
degrades to `60` inside the container (`start_services.sh:741-743`), which is exactly what the
backfill seeds (C6) and the rendered default delivers, so nothing about the agent's behaviour changes
and there is nothing to migrate.

**Oracle** — four `--regenerate` runs, one per case; each asserts a zero count of the CANON-C2
substring in the captured output, in the C10 shape (never a plain intermediate `grep`):

```bash
printf '%s\n' "$output" > regen-out.txt
run bash -c "grep -cF 'NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated' regen-out.txt"
[ "$output" = "0" ]
```

### C12 — `setup.sh` must be able to call `env_file_get`

`setup.sh` does not currently source `scripts/lib/env_file.sh` (it sources eight libs at `:7-14`;
that one is not among them). C6 **and** C9 both require making the function available — C6 is the
binding one, since it runs in every mode and its failure mode is a silent downgrade rather than a
missing message. Either is acceptable:

- add `source "$SCRIPT_DIR/scripts/lib/env_file.sh"` to the block at `setup.sh:7-14` — the library
  declares pure functions with no side effects at source time (`scripts/lib/env_file.sh:2-3`), so it
  is safe there; or
- guard it at the call site, the `scripts/agentctl:1133-1135` pattern:
  `command -v env_file_get >/dev/null 2>&1 || . "$SCRIPT_DIR/scripts/lib/env_file.sh" 2>/dev/null`.

**Oracle** — C6's migration oracle is the proof (an unsourced `env_file_get` makes `--regenerate`
abort under `set -euo pipefail`, or, if the call is guarded away, seeds `60` and turns that oracle
red); plus `shellcheck -S error` stays at rc=0 with the `# shellcheck source=/dev/null` directive if
the guarded form is chosen.

### C13 — Local mode is inert (spec Edge Cases; FR-011 precedent of 032)

The field is docker-only. In local mode no runtime artefact may carry the string
`CHANNEL_HEALTH_TIMEOUT`: the compose file is not rendered at all in that mode
(`setup.sh:2545-2549` is gated on `DEPLOYMENT_MODE_IS_DOCKER = true`), and no local template gains
the key.

**Oracle** — a new test in `tests/local-render.bats`, copying the shape of
`FR-011 (032): no local RUNTIME artifact carries a TELEGRAM_VOICE_ string`
(`tests/local-render.bats:289-309`): render the nine local runtime artefacts
(`systemd-remote-control.service.tpl`, `remote-control.env.tpl`, `local-healthcheck.service.tpl`,
`local-killswitch.sh.tpl`, `local-qmd-reindex.service.tpl`, `local-qmd-watch.service.tpl`,
`local-secret-check.sh.tpl`, `local-vault-backup.service.tpl`, `local-wiki-graph.service.tpl`) and
assert that none of them carries the string. Written in the C10 shape, never as a plain intermediate
`grep`:

```bash
run bash -c "LC_ALL=C grep -rlF 'CHANNEL_HEALTH_TIMEOUT' '$TMP_TEST_DIR/rendered' | wc -l | tr -d ' '"
[ "$output" = "0" ]
```

The invariant is the honest one of 032: not "renders 60", but "renders nothing of that shape at all".
Note that in local mode `agent.yml` *does* gain the field (C6 is mode-agnostic); C13 constrains the
rendered artefacts, not the source of truth.

### C14 — Test-surface touchpoints

Adding a `{{VAR}}` to a template has three known collateral effects in this repo
(`wizard-prompt-test-touchpoints` rule). Two of the three apply here; the third does not, because
there is no wizard prompt. A fourth touchpoint is specific to this story and was missed by the first
draft: an **existing** test that the new precedence turns red (C16).

| Touchpoint | Required change | Why |
| --- | --- | --- |
| `tests/fixtures/sample-agent-with-vault.yml` | add `channel_health_timeout_s: 60` to its `docker:` block (`:21-30`) | `tests/schema.bats:52` asserts every bare `{{VAR}}` in `modules/*.tpl` is produced by `render_load_context` over **this** fixture; otherwise `DOCKER_CHANNEL_HEALTH_TIMEOUT_S` must be added to `known_external`, which would be wrong — it *is* an `agent.yml` field |
| `tests/fixtures/sample-agent.yml` | add the same line to its `docker:` block (`:20-25`) | `tests/docker-render.bats` renders against this fixture; without the field the C5 oracle would assert an empty string |
| `tests/docker-e2e-postlogin.bats:146-195` | **rewrite** the feature-026 test — see C16 | it writes an `agent.yml` with no `channel_health_timeout_s`, runs `--regenerate`, only then writes `.env` with `45`, and asserts `printenv CHANNEL_HEALTH_TIMEOUT` = `45`. With CANON-C1 rendered into `environment:` the container answers `60`, and the test goes red |
| `tests/helper.bash::wizard_answers` | **no change** | no wizard prompt is added (C1) |
| `scripts/lib/schema.sh` | **no change** | `claude.mcp_timeout_ms` is in none of the schema lists either (verified: no `mcp_timeout` match in `scripts/lib/schema.sh`); the field is optional, defaulted and sanitised, not a required leaf |

### C15 — Compatibility in both directions

- **New launcher, old image**: the compose file renders `CHANNEL_HEALTH_TIMEOUT`, and every image
  since feature 026 reads that env var (`start_services.sh:739-745`), whatever put it there.
- **Old launcher, new `agent.yml`**: the extra key is ignored by the render (unknown keys are
  flattened into an unused variable) and the container keeps reading the `.env`, so the field can be
  left in place during a rollback (`quickstart.md` §5). **Caveat introduced by the migration**: an
  operator who acted on CANON-C2 and deleted the `.env` line has moved the only copy of a non-default
  window into `agent.yml`, which a rolled-back launcher does not read — the agent would fall back to
  the container's own 60. The rollback step is therefore "restore the `.env` line from
  `docker.channel_health_timeout_s`", and `quickstart.md` §5 must say so.

**Oracle** — documentation-level; no test. Stated here so the rollback section and this contract
cannot drift.

### C16 — The feature-026 DOCKER_E2E test must be rewritten, not just kept green

`tests/docker-e2e-postlogin.bats:150`, `channel timeout: CHANNEL_HEALTH_TIMEOUT from .env reaches the
container (feature 026)`, is **red by construction** after C5. Read in the tree, its sequence is:

1. write an `agent.yml` whose `docker:` block has no `channel_health_timeout_s` (`:152-165`);
2. `./setup.sh --regenerate --non-interactive` (`:168`);
3. **only then** `printf 'CHANNEL_HEALTH_TIMEOUT=45\n' > "$DEST/.env"` (`:170`);
4. build, up, and assert `printenv CHANNEL_HEALTH_TIMEOUT` is exactly `45` (`:189-191`).

Step 3 happens after step 2, so C6's migration cannot rescue it: at regenerate time the `.env` does
not exist yet, the field is backfilled to `60`, CANON-C1 renders `"60"`, and `environment:` outranks
the `env_file:` that carries the `45`. The container answers `60` and `[ "$output" = "45" ]` fails.
This is the test's job — it is the feature-026 delivery oracle — so it must be **re-pointed at the
new delivery chain**, not deleted and not patched into agreement by reordering the writes.

Required shape (same file, same harness, same `in_container` helper):

| Case | Setup | Assertion |
| --- | --- | --- |
| **(a) field → container** | `agent.yml` `docker:` block carries `channel_health_timeout_s: 45`; no `.env` line | `printenv CHANNEL_HEALTH_TIMEOUT` is `45` — the `agent.yml` → compose `environment:` → process chain, end to end |
| **(b) precedence, explicit** | `agent.yml` carries `60`; `.env` carries `CHANNEL_HEALTH_TIMEOUT=45` | `printenv CHANNEL_HEALTH_TIMEOUT` is `60` — the rendered value wins, which is the behaviour change this story ships |
| **(c) reader unchanged** | unchanged from today (`:193-194`) | `grep -c 'channel_health_timeout' /opt/agent-admin/scripts/start_services.sh` is `≥ 1` — C8's frozen helper still ships in the image |

Case (b) is not redundant with (a): it is the only executed proof of the precedence claim that C9,
C17 and the CANON-C2 wording all rest on. It has already been confirmed in a live container probe
(the process printed `60`, not `45`); the e2e case turns that measurement into a standing oracle.

Suggested name, keeping the feature trail legible:
`channel timeout: docker.channel_health_timeout_s reaches the container and outranks .env (026 → 036)`.

**Oracle** — the rewritten cases themselves, under `DOCKER_E2E=1`. Mutation **M8** (render CANON-C1
conditionally) turns case (a) red as well as the `docker-render.bats` assertion.

### C17 — Documentation that now points at the losing channel (FR-008, operator-facing half)

Two paragraphs tell operators to configure the window in the workspace `.env`. After C5 that is the
channel that loses, so both must be corrected in the same change — otherwise the docs keep generating
exactly the `.env`-only configurations C6 exists to rescue.

| File:line | Current text (verbatim fragment) | Required correction |
| --- | --- | --- |
| `README.md:150` | "That wait defaults to **60 seconds** and is tunable with the `CHANNEL_HEALTH_TIMEOUT` env var (seconds) in the workspace `.env`" | name `docker.channel_health_timeout_s` in `agent.yml` as the supported knob; say the `.env` variable is migrated automatically on the next `--regenerate` and can then be removed |
| `docs/architecture.md:127` | "That wait defaults to 60s and is tunable via `CHANNEL_HEALTH_TIMEOUT` (seconds) in the workspace `.env` (`026-channel-watchdog-timeout`)" | same, plus keep the `026` trail and state that the env var is still what the container reads (C8) — only its *source* moved |

Both corrections MUST preserve, unchanged: the 60 default, the absent/invalid → 60 fallback, and the
`≥65s` crash-budget warning. C8 freezes all three in the container, so a doc edit that drops them
would introduce drift in the opposite direction.

**Oracles** — static, in the C10 shape:

```bash
# positive: both files now name the agent.yml field
run bash -c "LC_ALL=C grep -lF 'channel_health_timeout_s' README.md docs/architecture.md | wc -l | tr -d ' '"
[ "$output" = "2" ]

# negative: neither still presents the .env as the place to set it
run bash -c "LC_ALL=C grep -lF '(seconds) in the workspace' README.md docs/architecture.md | wc -l | tr -d ' '"
[ "$output" = "0" ]
```

RED today: the positive oracle yields `0`, the negative one yields `2` (measured — the fragment
`(seconds) in the workspace` occurs once in each file, at the two lines tabled above).

## Traceability

| FR | Clause | Primary oracle |
| --- | --- | --- |
| FR-005 (settable from `agent.yml`, survives `--regenerate`) | C1, C2, C5, C7 | render + idempotency tests |
| FR-006 (host-side sanitiser, compose delivery, 029 mould) | C3, C3a, C4, C5 | sanitisation matrix |
| FR-007 (`has()` backfill, never `//`, **migrates the live value**) | C6, C12 | the `0`-preserved test + the migration oracle |
| FR-008 (notify on `.env` precedence, key only, never the value) | C9, C10, C11, C12 | CANON-C2 count = 1 + value-absence |
| FR-009 (runtime default stays 60, risk WARN keeps firing) | C8 | the three untouched watchdog tests |
| Edge case: local mode | C13 | FR-011-shaped oracle in `local-render.bats` |
| No-regression: the 026 delivery oracle | C16 | rewritten `docker-e2e-postlogin.bats` cases (a)/(b)/(c) |
| Operator-facing docs stop teaching the losing channel | C17 | the two static grep oracles |
| FR-018 (bash 3.2 + 5.x, shellcheck, host bats) | all | full suite on both arms (`quickstart.md` §1) |

| Mutation (`quickstart.md` §3) | Clause it defends | Expected RED |
| --- | --- | --- |
| M7 — backfill with `//` | C6 | "operator value is preserved" |
| M8 — render the compose line conditionally | C5 | `docker-render.bats` assertion, and C16 case (a) |
| M9 — print the `.env` value in the notice | C10 | value-absence oracle |
| M10 — change the in-container default from 60 | C8 | `start-services-watchdog.bats:327` |
| M18 — seed the backfill with a literal `60` instead of the `.env` value (**new; register it in `quickstart.md` §3, where M11-M17 are already taken**) | C6 | the migration oracle: `agent.yml` gains `60` and the artifact renders `"60"` where `120` was expected |

## Appendix A — the mould's 12 tests (`tests/mcp-handshake-timeout.bats`)

Listed verbatim, in file order, because `tests/channel-window-config.bats` is a transposition of this
file and every row below has a counterpart above.

| # | Test name | 036 counterpart |
| --- | --- | --- |
| 1 | `029: --regenerate renders MCP_TIMEOUT from claude.mcp_timeout_ms into compose environment` | C5 |
| 2 | `029: non-numeric mcp_timeout_ms degrades to 120000 in the artifact` | C3a (`"abc"`) |
| 3 | `029: mcp_timeout_ms=0 degrades to 120000 in the artifact (never <=0)` | C3a (`0`) |
| 4 | `029: negative mcp_timeout_ms degrades to 120000` | C3a (`-5`) |
| 5 | `029: empty mcp_timeout_ms degrades to 120000` | C3a (empty) |
| 6 | `029: oversized mcp_timeout_ms (>7 digits) degrades to 120000` | C3a (7 digits — here the bound is 6) |
| 7 | `029: --regenerate backfills claude.mcp_timeout_ms=120000 when absent` | C6 |
| 8 | `029: default 120000 applies out-of-the-box when unset (US2)` | C3a (absent) |
| 9 | `029: backfill does NOT overwrite an operator's mcp_timeout_ms=0 (has() not //)` | C6 |
| 10 | `029: two --regenerate passes are byte-stable for claude.mcp_timeout_ms (modulo meta timestamp)` | C7 |
| 11 | `029: single-source — both templates use the placeholder, not a literal` | C5 (one template only — there is no local delivery path) |
| 12 | `029: changing the value re-renders the compose artifact to the new value` | C5 |

Four cases have **no** counterpart in the mould and are net-new for 036: `1.5` (C3a), the
`.env`-seeded **migration** backfill (C6 — the mould's `claude.mcp_timeout_ms` has no prior home to
migrate from), the migration notice (C9/C10/C11) and the local-mode inertness oracle (C13).
Conversely, the mould's test 11 is halved: `claude.mcp_timeout_ms` reaches both modes (compose +
`remote-control.env.tpl`), while `docker.channel_health_timeout_s` reaches only compose, by design.

## Appendix B — `_write_agent_yml` for the new test file

The mould's helper (`tests/mcp-handshake-timeout.bats:23-76`) parameterises the field as
value / `OMIT` / `NULL`. The 036 version moves the parameter into the `docker:` block:

```bash
_write_agent_yml() {
  local cht="$1"
  local docker_block='docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"'
  case "$cht" in
    OMIT) : ;;
    NULL) docker_block="${docker_block}
  channel_health_timeout_s:" ;;
    *)    docker_block="${docker_block}
  channel_health_timeout_s: ${cht}" ;;
  esac
  # … remainder identical to the mould (docker mode, telegram plugin, heartbeat block)
}
```

`setup()` must also `touch "$TMP_TEST_DIR/.env"` (as the mould does at `:15`) so the C11 "no key"
case is exercised by default, and `install_claude_stub` keeps the run hermetic (feature 025).

Because the backfill now reads that file (C6), the `.env` is a **second parameter** of every US2
test, not inert scenery. A companion helper keeps the two axes explicit:

```bash
_write_env() {                  # _write_env            → empty .env (no key)
  local v="${1:-OMIT}"          # _write_env 120        → CHANNEL_HEALTH_TIMEOUT=120
  : > "$TMP_TEST_DIR/.env"      # _write_env EMPTY      → CHANNEL_HEALTH_TIMEOUT=
  case "$v" in
    OMIT)  : ;;
    EMPTY) printf 'CHANNEL_HEALTH_TIMEOUT=\n'    >> "$TMP_TEST_DIR/.env" ;;
    *)     printf 'CHANNEL_HEALTH_TIMEOUT=%s\n' "$v" >> "$TMP_TEST_DIR/.env" ;;
  esac
  chmod 0600 "$TMP_TEST_DIR/.env"
}
```

The pair `_write_agent_yml OMIT` + `_write_env 120` is the migration case; `_write_agent_yml OMIT` +
`_write_env` is the plain-default case. Any US2 test that sets one without deciding the other is
under-specified.
