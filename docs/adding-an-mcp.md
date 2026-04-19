# Adding an MCP (Docker Mode)

MCPs in Docker mode use the same template structure as host mode. This guide covers Docker-specific considerations.

## Standard Template Setup

Follow [Adding an MCP](adding-an-mcp.md) as the primary reference. The template changes you make apply automatically inside the container:

1. **Update the wizard** (`setup.sh`) to prompt for your MCP.
2. **Update `agent.yml`** to include the MCP config.
3. **Update `modules/mcp-json.tpl`** to render the MCP entry in `.mcp.json`.
4. **Update `modules/env-example.tpl`** to include placeholder secrets.

These files are baked into the image at build time, so MCPs defined in the template work identically inside and outside the container.

## File Paths Inside the Container

When your MCP runs inside the container, adjust any hardcoded paths:

**Repository and workspace files:** Use `/workspace/...` (bind-mount of `~/agents/<name>/`):

```bash
/workspace/scripts/
/workspace/memory/
/workspace/docs/
/workspace/.git/
```

**Home-scope configuration:** Use `/home/agent/.claude-personal/...` (inside the named volume):

```bash
/home/agent/.claude-personal/installed_plugins.json
/home/agent/.claude-mem/
/home/agent/.mcp-auth/
/home/agent/.codex/
```

If your MCP writes state that should persist across container restarts, write to `/home/agent/` (the named volume). For transient data, use `/tmp` (100MB tmpfs).

## Alpine musl vs. glibc

The default image is `alpine:3.20`, which uses musl libc. Some MCPs with native binaries may require glibc (older SQLite builds, some Node.js native addons, system utilities).

### Using the Debian Variant

If your MCP fails with "not found" or "bad ELF" errors on Alpine, switch to the Debian image:

```yaml
# agent.yml
docker:
  base_image: "debian:13-slim"
```

Rebuild:

```bash
docker compose build
docker compose up -d
```

The `base_image` setting adjusts the `FROM` line in the generated Dockerfile. Debian images are larger (~100MB vs. ~20MB for Alpine) but support most pre-built binaries.

### Confirming the Choice

Check your Alpine image for native binary issues:

```bash
# Inside a running Alpine container, try the binary
docker exec <name> /path/to/binary --version

# If it fails with "not found", the binary needs glibc
# If it works, you're on Alpine successfully
```

If you see errors like:

```
/lib64/libc.so.6: No such file or directory
ELF binary with wrong machine type
```

Switch to the Debian variant as shown above.

## Environment Variables

All `.env` variables are available inside the container. The `docker-compose.yml` uses `env_file: .env` to inject them:

```yaml
services:
  <name>:
    env_file:
      - .env
```

Your MCP can read from the environment without additional configuration:

```bash
# Inside the container, this works:
echo $MY_MCP_TOKEN
```

Do **not** add `environment:` to the compose file directly. All secrets flow through the host's `.env` file (0600 permissions), which is bind-mounted at runtime. This way, you can rotate secrets without rebuilding:

```bash
# Host
nano ~/agents/<name>/.env
docker compose restart
```

## Multi-Instance MCPs

If your MCP has multiple accounts or workspaces, model it as an array in `agent.yml` (just like Atlassian):

```yaml
mcps:
  my_service:
    - name: work
      token: "..."
      workspace: "..."
    - name: personal
      token: "..."
      workspace: "..."
```

In `modules/mcp-json.tpl`, iterate over the array:

```
{{#each MCPS_MY_SERVICE}},
"my_service_{{name}}": {
  "command": "python -m mcp.servers.my_service",
  "env": {
    "SERVICE_TOKEN": "${SERVICE_TOKEN_{{NAME}}}"
  }
}
{{/each}}
```

(Note: inside `{{#each ...}}`, lowercase field names like `{{name}}` stay lowercase; uppercase versions like `{{NAME}}` are uppercased.)

## Building and Testing

After updating the templates:

```bash
cd ~/agents/<name>
docker compose build
docker compose up -d
docker exec -it -u agent <name> tmux attach -t agent
```

Test your MCP by invoking it in the Claude session. If it fails, check the agent's log:

```bash
docker exec <name> tail -f /workspace/claude.log
```

And the MCP-specific logs if your MCP writes them (often in `/workspace/` or the state volume).

## Common Issues

### "command not found" inside the container

If your MCP binary is not in the PATH, specify the full path in `modules/mcp-json.tpl`:

```
"command": "/home/agent/.local/bin/my_mcp"
```

Or rely on the image's package manager to install it at build time. If you need to add a custom binary, add a `RUN` step to the Dockerfile:

```dockerfile
RUN apk add --no-cache my_package
# or for Debian variant:
RUN apt-get update && apt-get install -y my_package && rm -rf /var/lib/apt/lists/*
```

### Native binary glibc errors

See the **Alpine musl vs. glibc** section above. Use the Debian variant if needed.

### State not persisting

Ensure your MCP writes to `/home/agent/` (the named volume) or `/workspace/` (the bind-mount), not `/tmp` or transient locations.

```bash
# Check where your MCP writes:
docker exec <name> find /home/agent -name "mcp-*"
```

## See Also

- [Adding an MCP](adding-an-mcp.md) — template and wizard integration (applies to all modes).
- [Docker Mode Guide](getting-started.md) — daily operations and troubleshooting.
- [Docker Architecture](architecture.md) — layout and process tree.
