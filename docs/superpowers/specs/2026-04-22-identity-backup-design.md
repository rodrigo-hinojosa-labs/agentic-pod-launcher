# Identity Backup via Git — Design Spec

**Date**: 2026-04-22
**Status**: Approved (brainstorming phase complete)
**Scope**: Phase 1 of the agent persistence story (Phase 2 = full-state tarball
to Google Drive, designed separately).

## Context

After the workspace-is-the-agent refactor (PR #3, 2026-04-22), the full
container state (OAuth login, Telegram pairing, sessions, plugin cache) lives
under `<workspace>/.state/` as a bind-mount. The workspace directory is now
portable with plain filesystem tools — but there is no remote backup.

When a user loses their Mac, `rm -rf`'s the workspace, or wants to move the
agent to a second machine, the current recovery path is:

1. Clone the agent's GitHub fork (gives code, CLAUDE.md, agent.yml).
2. Run `setup.sh` → scaffolds a fresh workspace.
3. Manually `/login` to Claude Code again.
4. Re-paste the Telegram bot token, re-pair the channel.
5. Re-install plugins from scratch.

Steps 3-5 are annoying and re-pairing depends on the user still having the
bot token saved somewhere external. We want a one-command rehydration that
comes back with login, pairing, plugin list, and permission settings intact.

## Goals

- **Rehydratable identity**: `setup.sh --restore-from-fork <url>` produces a
  running agent that does not need `/login` or `/telegram:access pair`.
- **Versioned**: every backup is a point-in-time snapshot, rollback-able.
- **Zero extra secret management** in the happy path (reuse the SSH key the
  user already has for pushing to GitHub).
- **Fault-tolerant UX**: if the user doesn't have an SSH key on GitHub, the
  backup mechanism degrades gracefully rather than refusing to work.

## Non-goals

- Session history / conversation memory — too bulky for git, covered by
  Phase 2 (tarball to GDrive, separate spec).
- Plugin cache binaries (bun node_modules, npm packages) — also Phase 2.
- Team / cross-user backup sharing.
- Protection against compromise of the user's SSH private key — out of
  scope; any attacker with that key already has push access to the fork
  and inherits the backup's threat posture.

## Threat model

Covered:

- **Laptop loss or disk failure** — backup lives on GitHub (redundant, off
  the affected host).
- **Accidental `rm -rf <workspace>`** — same.
- **Config corruption / "poisoned" state** — rollback to any prior snapshot
  via `git checkout backup/identity~N`.
- **Secret exposure in public clone** — the one file that contains secrets
  (`.env`) is age-encrypted with an asymmetric key, unreadable without the
  matching private key.

Not covered:

- SSH key theft → attacker has both push access and decrypt capability; no
  defense at this layer.
- GitHub outage during restore — degraded until GitHub recovers; no
  secondary remote.
- Corruption introduced BEFORE a backup (the snapshot captures the
  corruption and propagates it on restore).

## Architecture

### Branch layout in the agent's fork

An **orphan** branch `backup/identity` living alongside the agent's code
branch in the same fork. "Orphan" means it has no common ancestor with
`main` / the agent's `live` branch — history is cleanly separated.

```
<fork>
├── refs/heads/<host>-<name>/live      ← code: CLAUDE.md, agent.yml, scripts, docker, …
└── refs/heads/backup/identity         ← state identity only
    ├── .claude.json                    (plaintext — lives at $HOME/.claude.json in container)
    ├── .claude/
    │   ├── settings.json               (plaintext)
    │   ├── channels/telegram/access.json
    │   └── plugins/config/             (plaintext — what plugins, their settings)
    └── .env.age                        (age-encrypted — optional, only if recipient configured)
```

Each backup = one commit on `backup/identity`. Commits are typically <100KB
(most files are small JSON). The branch grows linearly; retention is
addressed via optional `git gc` (see Retention).

### Why orphan vs. alternatives

Rejected alternatives:

- **Commits on `main`**: would require allow-listing identity files out of
  the current `.gitignore`. Every backup commits on top of code history,
  interleaving auto-generated snapshots with user commits. Rebasing against
  upstream template updates becomes painful.
- **Separate repo (`<agent>-state`)**: maximum isolation but doubles the
  GitHub footprint per agent, two PATs, two clones during restore.
  Overkill for the ~1-2MB volume we are moving.
- **Tags instead of commits**: the underlying tree is still whatever branch
  the tag points at; no structural win.

Orphan branch in the same fork = one PAT, one clone, single refspec to
push/pull, no cross-contamination with code history.

### The identity whitelist

Files selected because they are small, stable-shaped, and carry real value
for rehydration:

| File | Why | Size |
|---|---|---|
| `.state/.claude.json` | Account ID, project metadata (canonical, at `$HOME/.claude.json`) | ~25KB |
| `.state/.claude/settings.json` | Permission mode, bypass prompt flag — keeps the agent headless-friendly | ~1KB |
| `.state/.claude/channels/telegram/access.json` | Sender allowlist for Telegram pairing | <1KB |
| `.state/.claude/plugins/config/` | What plugins are installed + their settings | ~5KB |
| `.state/.env` (as `.env.age`) | TELEGRAM_BOT_TOKEN + API tokens | ~1KB |

Excluded on purpose:

- `.state/.claude/projects/-workspace/*.jsonl` — session history (Phase 2).
- `.state/.claude/plugins/cache/` — plugin node_modules / binaries (Phase 2).
- `.state/.bun`, `.state/.cache/` — runtime caches (cheap to rebuild).

## Key management

Goal: no new secret for the user to manage if they already have SSH set up
for GitHub.

### Happy path (A)

During `setup.sh scaffold_destination`:

1. Read `scaffold.fork.owner` from `agent.yml`.
2. `curl -fsSL https://github.com/<owner>.keys` (public endpoint, no auth).
3. If the response contains ≥1 key: prefer `ssh-ed25519` over `ssh-rsa`;
   take the first match. Store it verbatim in `agent.yml`:

   ```yaml
   backup:
     identity:
       recipient: "ssh-ed25519 AAAA... user@host"
   ```

4. Identity backup runs in **FULL mode** — `.env.age` included.

At decrypt time (restore on a new machine):

```bash
age -d -i ~/.ssh/id_ed25519 -o .env .env.age
```

The user's existing private SSH key is the only secret needed. If they can
`git push` to the fork, they can decrypt.

### Fallback A4 (no SSH key on GitHub)

If `github.com/<owner>.keys` returns empty or 404:

- `agent.yml` gets `backup.identity.recipient: null`.
- Scaffold prints a yellow warning and continues.
- Identity backup runs in **PARTIAL mode**: plaintext files are committed;
  `.env.age` is omitted.
- `heartbeatctl status` surfaces a dedicated line: `identity backup: partial
  (no recipient key — run 'heartbeatctl backup-identity --configure-key
  <path|pubkey>' to enable full mode)`.
- User can transition to full mode at any time:

   ```bash
   docker exec -u agent <agent> heartbeatctl backup-identity --configure-key ~/.ssh/id_ed25519.pub
   # or paste the pubkey string:
   docker exec -u agent <agent> heartbeatctl backup-identity --configure-key "ssh-ed25519 AAAA..."
   ```

   This validates the format (ssh-ed25519/ssh-rsa), writes to `agent.yml`,
   triggers a re-render, and fires the backup primitive so `.env.age` lands
   in the next commit.

### Key rotation

Not designed in this spec. If the user rotates their SSH key, they can
rerun `--configure-key` and subsequent snapshots use the new recipient.
Previously-encrypted commits remain decryptable only with the old private
key — the user is expected to retain it if they want to restore from
older snapshots.

## Trigger orchestration

All three trigger types converge on a single primitive,
`heartbeatctl backup-identity`, which is idempotent (no-op commit when the
working tree is clean against `backup/identity`).

### Manual (a)

From the container:

```bash
docker exec -u agent <agent> heartbeatctl backup-identity
```

From the host (convenience alias that re-invokes the above):

```bash
./setup.sh --backup
```

### Event-driven (b)

Two insertion points in `docker/scripts/start_services.sh`:

1. Post-`ensure_plugin_installed` success (captures plugin installs /
   upgrades immediately).
2. Inside the supervisor watchdog loop: every 60 seconds, compute
   `sha256sum` over the identity whitelist; compare against the hash stored
   in `/workspace/scripts/heartbeat/identity-backup.json`. If the hash
   differs, fire the primitive. This catches access.json updates
   (new pairings), settings.json changes, .claude.json mutations without
   requiring hooks in upstream code.

Rate limit: the primitive is itself idempotent and fast (<2s when no diff),
so firing it too often is not a correctness concern. For efficiency, the
watchdog loop skips the sha256sum if less than 10 seconds have passed since
the last backup check (cheap throttle).

### Scheduled (c)

A new entry in the in-container crontab, coexisting with heartbeat:

```
30 3 * * * /usr/local/bin/heartbeatctl backup-identity >> /workspace/scripts/heartbeat/logs/backup-identity.log 2>&1
```

Daily at 03:30 UTC — low-traffic hour, safety net if manual/event-driven
missed anything. The idempotency of the primitive means this is cheap when
nothing changed.

The crontab entry is rendered alongside the heartbeat's schedule by
`heartbeatctl reload` (which reads `agent.yml` and writes the staging
crontab). A new `features.identity_backup` block governs whether this entry
is emitted:

```yaml
features:
  identity_backup:
    enabled: true
    schedule: "30 3 * * *"   # optional override
```

When `enabled: false`, only manual + event-driven triggers operate.

## The primitive: `heartbeatctl backup-identity`

Idempotent, fast, fails loud. Lives in `docker/scripts/heartbeatctl`
alongside the other subcommands.

### Flow

```
1.  Load config from agent.yml: fork URL (scaffold.fork.url), recipient
    (backup.identity.recipient, may be null).
2.  Compute identity hash from the whitelist (skip files that don't exist
    yet — .env is optional; missing all files means state not initialized,
    exit 0 silently).
3.  If identity hash matches the one in identity-backup.json and last
    push is ≤24h old → exit 0 "no changes".
4.  Prepare the working clone: a dedicated bare+worktree under
    /home/agent/.cache/identity-backup/ (reused across invocations to
    avoid re-cloning every time).
5.  git fetch origin backup/identity  (non-fatal if branch doesn't exist;
    treated as "first backup — will create orphan").
6.  If backup/identity exists remotely: git worktree add STAGE backup/identity.
    Otherwise: create an orphan worktree (git worktree add --detach STAGE
    → git switch --orphan backup/identity inside STAGE → git rm -rf . to
    start clean).
7.  cp -a whitelist → STAGE/ (busybox cp -a preserves modes + timestamps;
    no rsync dependency).
8.  If recipient != null AND /workspace/.state/.env exists:
      age -R "$recipient" -o STAGE/.env.age /workspace/.state/.env
    Else: remove STAGE/.env.age if present (handles full → partial
    transitions or .env deletion).
9.  cd STAGE && git add -A.
10. git diff --cached --quiet && { remove worktree; exit 0 "no changes"; }.
11. git commit -m "identity snapshot $(date -Iseconds)" \
                --author "<agent-name> <identity-backup@localhost>".
12. git push origin backup/identity.
13. Remove worktree (keep the bare clone cached).
14. Update /workspace/scripts/heartbeat/identity-backup.json with:
      { "last_commit": "<sha>", "last_push": "<iso-ts>",
        "mode": "full|partial", "hash": "<identity-hash>" }.
15. Return a brief stdout line: "identity: <sha short> pushed (<mode>)".
```

### Subcommands and flags

- `heartbeatctl backup-identity` — default flow above.
- `heartbeatctl backup-identity --configure-key <path|pubkey>` — write
  recipient to agent.yml and trigger an immediate backup.
- `heartbeatctl backup-identity --disable` — set
  `features.identity_backup.enabled: false` in agent.yml; crontab removes
  the entry on next `reload`.
- `heartbeatctl backup-identity --gc` — run `git gc --prune=now
  --aggressive` on the local fork clone before the next push (opt-in
  periodic maintenance; not part of the default flow).
- `heartbeatctl backup-identity --dry-run` — stage + diff without pushing;
  surfaces what would change. Useful for diagnostics.

### Errors and failure modes

- **SSH auth fails on push**: log the error to
  `logs/backup-identity.log`, exit non-zero. The daily cron will retry.
  If persistent, `heartbeatctl status` surfaces the staleness.
- **Fork missing / deleted remotely**: hard error, dedicated message —
  the user needs to re-create the fork or adjust `agent.yml`.
- **`.state` dir missing** (first boot, plugin not installed yet): the
  hash computation fails on missing files; exit 0 silently (nothing to
  back up yet).
- **age binary missing**: fallback to partial mode with warning (should not
  happen — baked into the image — but we degrade rather than crash).

### Observability

The primitive appends a JSON line to `logs/backup-identity.log` on every
invocation (success or failure), schema similar to heartbeat's `runs.jsonl`:

```json
{"ts":"2026-04-22T12:34:56Z","event":"push","sha":"abc1234","mode":"full"}
{"ts":"2026-04-22T13:34:56Z","event":"skip","reason":"no changes"}
{"ts":"2026-04-22T14:34:56Z","event":"error","stage":"push","msg":"permission denied"}
```

`heartbeatctl status` surfaces: last successful backup timestamp, mode,
commit sha.

## Restore flow

New flag on `setup.sh`:

```bash
./setup.sh --destination ~/agents/<name> --restore-from-fork <fork-url>
```

Sequence:

1. Normal scaffold: copy template files, create `.state/`, run git init /
   fork clone logic.
2. After scaffold completes and before `docker compose up -d`:
   - `git clone --branch backup/identity --single-branch --depth 1 <fork-url>
     /tmp/identity-restore-$$`
   - If that fails (no backup/identity branch yet): print a warning and
     skip restore (agent will be a fresh install).
   - `rsync -a /tmp/identity-restore-$$/.claude/ <dest>/.state/.claude/`
   - If `.env.age` present:
     - Try `age -d -i ~/.ssh/id_ed25519 -o <dest>/.env
       /tmp/identity-restore-$$/.env.age`.
     - On failure, try `~/.ssh/id_rsa`.
     - If both fail, print a clear message pointing the user at
       `--identity-key <path>` flag (see follow-ups) and leave `.env`
       absent — the agent will boot and prompt for the Telegram token
       on first wizard run.
   - `rm -rf /tmp/identity-restore-$$`
3. Continue with `docker compose build && docker compose up -d`. On boot,
   the supervisor sees a fully-populated `.state/`, no wizard prompt, no
   `/login`, no pairing redo.

The restore flag is fully additive — omitting it preserves current scaffold
behavior.

## Retention

Commits are tiny, so we accept unbounded growth by default. A manual
`heartbeatctl backup-identity --gc` runs `git gc --prune=now --aggressive`
locally (which triggers repacking on the next push).

Non-goal: automatic retention / squash. If it ever becomes a real problem
(users reporting slow clones), we can add `--retention 30d` which rewrites
`backup/identity` to keep only the last 30 days of commits. Out of scope
for this spec.

## Dependencies

- `age` binary in the container image. Alpine 3.20 has the `age` package:

  ```dockerfile
  RUN apk add --no-cache age
  ```

  One-line addition to the existing apk list.
- `curl` to fetch the pubkey during scaffold (already present on host via
  `setup.sh` prereqs).
- No new host dependencies.

## Testing

Three `bats` files under `tests/`:

### `tests/backup-identity.bats`

- Setup: create a mock agent workspace with synthetic `.state/.claude/*`
  files; spin up a local bare git remote (`git init --bare`).
- Happy path: `heartbeatctl backup-identity` → branch exists on remote →
  commit contains the whitelist → no `.env.age` (partial mode for test
  simplicity by default).
- Idempotency: invoke twice in a row with same state → second call is a
  no-op (no new commit).
- Diff detection: modify `access.json`, invoke → new commit with just
  that file changed.
- Encryption: configure a test recipient (age-keygen) → invoke → `.env.age`
  appears → decrypt with matching identity file → contents match original.

### `tests/restore-from-fork.bats`

- Setup: create a bare remote, push a backup/identity branch with known
  content.
- Scaffold a fresh workspace with `--restore-from-fork <url>` → verify
  files appear in `.state/` 1:1.
- Case: backup/identity branch doesn't exist → scaffold completes, warns,
  skips restore.
- Encrypted path: `.env.age` is decrypted using a test private key passed
  via env var (for CI) → `.env` written to workspace.

### `tests/identity-backup-no-ssh-key.bats`

- Mock `github.com/<owner>.keys` endpoint returning 404 (or empty).
- Scaffold → `agent.yml` has `recipient: null`, warning printed, backup
  primitive runs in partial mode on first event.
- `heartbeatctl backup-identity --configure-key <pubkey>` → recipient
  populated → next backup is full-mode.

## Integration with Phase 2 (Google Drive tarball)

Phase 2 will introduce `heartbeatctl backup-full` — tarball of the entire
`.state/` to a configurable destination (initially GDrive via rclone). The
two mechanisms are designed to coexist with no overlap:

- Phase 1 captures "identity" — small, versioned, always on GitHub.
- Phase 2 captures "memory" — big, less frequent, on blob storage.

Possible future wrapper: `heartbeatctl backup-all` invoking both in
sequence. Not built in this spec.

Phase 2's restore (`--restore-full-from <gdrive-path>`) can chain with this
spec's `--restore-from-fork` — Phase 1 restores identity, then Phase 2
restores session + cache. No order dependency.

## Out-of-scope items (explicit)

- Phase 2 (full-state tarball to GDrive).
- Team / multi-user backup sharing.
- Automated retention / squash of `backup/identity`.
- Key rotation UX beyond `--configure-key`.
- Hooks in the upstream Telegram plugin to fire backups on pairing
  (the 60-second hash watchdog covers this well enough).

## Open follow-ups (tracked, not blocking)

- Linux Docker hosts: the `--restore-from-fork` flow assumes an SSH key at
  `~/.ssh/id_ed25519` for decrypt. For Linux users without ed25519 or with
  custom paths, add an `--identity-key <path>` flag to `setup.sh`.
- CI coverage: the bats tests need to run both inside and outside Docker.
  Opt-in DOCKER_E2E=1 variants mirror the existing heartbeat patterns.
