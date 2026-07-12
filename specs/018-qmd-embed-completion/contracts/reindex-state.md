# Contract — `qmd-index.json` state file (018 backward-compatible extension)

File: `QMD_INDEX_STATE_FILE` (default `/workspace/scripts/heartbeat/qmd-index.json`), written by
`qmd_write_state` (atomic tmp + `mv`, fail-silent).

## Signature change

```sh
# Before (unchanged callers still valid):
qmd_write_state STATE_FILE HASH STATUS
# After (new optional 4th arg):
qmd_write_state STATE_FILE HASH STATUS [PENDING]
```

- `PENDING` optional. When omitted, `pending` is written as `0` for terminal-complete/skip states and
  omitted (or `0`) for legacy callers. Callers that know the residual (`partial`/`stalled`) pass it.
- The three existing call sites (`setup`, `error`, `skipped`) MAY remain 3-arg; the completion loop
  uses the 4-arg form.

## JSON shape

```json
{
  "hash": "<vault content hash | preserved prior hash on error>",
  "last_run": "2026-07-11T02:09:08Z",
  "last_status": "indexed | skipped | error | partial | stalled",
  "runs": 42,
  "pending": 0
}
```

## Compatibility guarantees

- Adding `pending` is additive. The existing shape assertion in `tests/qmd-index.bats` is an EXISTENCE
  check (`.hash and .last_run and .last_status and (.runs|type=="number")`), so it keeps passing.
- Readers MUST tolerate a missing `pending` key (pre-018 files) → interpret as unknown, which forces a
  resume pass (never a silent skip). `jq -r '.pending // ""'` yields empty for absent.
- `last_status` gains `partial` and `stalled`; any consumer switching on status MUST treat unknown
  values conservatively (not-complete). `heartbeatctl status`/doctor surfaces the raw value.

## Observability

- `partial`/`stalled` with `pending > 0` is the operator-visible signal that the vector index is not
  yet complete (FR-006). No new command is required; the existing state file + `_qmd_log` progress
  lines carry it. (An optional one-line surfacing in `heartbeatctl status` MAY be added as polish but is
  not required by this contract.)

## Invariants (repeat of data-model, contract form)

- `indexed` ⇒ `pending == 0`.
- `partial` | `stalled` ⇒ `pending > 0`.
- `error` ⇒ `hash` is the preserved prior hash (index not advanced); `pending` unchanged/omitted.
- No secrets ever written.
