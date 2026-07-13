# Contract: the portable `.env` subset (systemd ∩ docker compose)

`<workspace>/.env` is parsed by **two different parsers** — docker compose's
`env_file` and systemd's `EnvironmentFile`. They agree on everything the wizard
writes and disagree on several shapes an operator can easily hand-write. Since
hand-editing is the **normal** path (`CLAUDE_CODE_OAUTH_TOKEN` is always written
empty; every secret prompt offers "fill it in `.env` later"), the launcher defines a
portable subset and lints against it.

## The portable subset (what `env_file_lint` accepts)

A line is valid if it is one of:

- **blank**
- **a comment**: `^#` at column 0
- **an assignment**: `^[A-Za-z_][A-Za-z0-9_]*=` where the value contains
  - no backslash (`\`)
  - no `$`
  - no ` #` (space-hash)
  - no leading quote (`"` or `'`)
  - no carriage return

And the file as a whole must be valid UTF-8, with **no NUL** and **no BOM**.

Everything the wizard emits is inside this subset (`setup.sh:1210-1232`).

## Why each restriction exists — the divergence table

Every row is a line that parses to a **different value** in the two modes. Sources:
systemd `man/systemd.exec.xml:3255-3299` + `src/basic/env-file.c:66-192`;
compose-spec `05-services.md:626-655` + `compose-go/dotenv/parser.go:101-204`.

| Line | docker compose | systemd | Severity |
|---|---|---|---|
| `KEY=abc\` (trailing backslash) | value is `abc\` | **line-continues** — swallows the next `KEY=VAL` entirely | **HIGH** — two secrets silently lost |
| `export KEY=v` | sets `KEY` | invalid name `export KEY` → dropped, **and the full `KEY=VALUE` is logged to the journal at ERROR** | **HIGH** — credential leak |
| BOM / non-UTF-8 byte / NUL | tolerated | **the entire file is discarded, silently** (the `-` prefix suppresses the error) | **HIGH** — agent boots healthy with zero secrets |
| `KEY=a\b` | `a\b` | `ab` | MEDIUM |
| `KEY=val # note` | `val` (inline comment stripped) | `val # note` | MEDIUM |
| `KEY=a$B` | interpolated (`$B` from the env) | literal `$` | MEDIUM |
| `KEY="a\nb"` | a real newline | literal `a\nb` | MEDIUM |
| `KEY: v` | sets `KEY` | line ignored | LOW |
| bare `KEY` (no `=`) | inherits from the host env | ignored | LOW |
| `;`-prefixed line | **hard parse failure** (`compose up` dies) | ignored as a comment | LOW |

Shapes that **agree** (parity holds, no lint complaint): `#` comment at col 0; blank
line; `KEY=` (empty in both); `KEY=token`; a trailing space (both right-trim);
interior spaces (both preserve); a value containing `=` (base64/JWT padding — both
split on the **first** `=`); a value containing `:` (a Telegram bot token); an
Atlassian URL with a `#fragment` and no preceding space; CRLF.

## `env_file_lint` output contract

- One finding per offending line.
- Format: `line <N>: <KEY or "-">: <reason>`.
- **NEVER prints a value.** Not truncated, not masked — the value never enters the
  output string at all. (`redact_secrets` is anchor-based and cannot mask an
  anchorless token; do not rely on it here.)
- Exit `0` = clean, `1` = findings. It never fails the caller.

## `env_file_get KEY FILE` contract

- Returns the value of the **last** matching `KEY=` line, or the empty string.
- Strips **one** layer of matching surrounding quotes (`"x"` → `x`, `'x'` → `x`).
- **MUST NOT execute file content**: no `.`/`source`, no `eval`, no command
  substitution, no `export`. Pure parameter expansion only.
  This is not a style preference — `.env` can arrive from a **remote** source
  (`--restore-from-fork` decrypts `.env.age` into it, `setup.sh:1648-1667`), so
  sourcing it is remote code execution as the operator, on a 5-minute timer.
- Never prints the value it read (callers pass it via stdin, never argv).
