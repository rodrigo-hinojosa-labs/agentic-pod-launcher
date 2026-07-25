#!/bin/sh
# 024 gate — COMPOSITION test: the REAL rendered hooks, wired into a REAL systemd
# unit, must produce keep-on-restart and retire-on-self-exit end to end.
#
# This is the gap that let 022's bug through: each piece was correct, but nobody
# ran the pieces together under systemd. Uses a USER unit — no sudo, does not
# touch the production agent. The hooks are rendered from the workspace's OWN
# templates + lib against a throwaway workspace, so they are byte-identical in
# logic to what production installs, only pointed elsewhere.
set -u

WS=/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin
TW="$HOME/sp024-gate"                       # throwaway workspace
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="sp024-gate.service"
PASS=0; FAIL=0
say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

rm -rf "$TW"; mkdir -p "$TW/scripts/lib" "$TW/scripts/local" "$UNIT_DIR"

# ── real lib, real templates, throwaway workspace ───────────────────────────
cp "$WS/scripts/lib/session_pointer.sh" "$TW/scripts/lib/"
cp "$WS/scripts/lib/render.sh" "$WS/scripts/lib/yaml.sh" "$TW/scripts/lib/" 2>/dev/null

cat > "$TW/agent.yml" <<YML
version: 1
agent: {name: gatebot, display_name: "GateBot", role: r, vibe: v}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: $TW, install_service: false, claude_cli: $TW/fakeclaude, mode: local, session_name: gatebot}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: ok}}
YML

# Render the three REAL hooks against the throwaway workspace.
# render.sh/yaml.sh are bash; this gate runs under dash, so isolate in bash -c.
# yq is vendored in the workspace, not on the login PATH — put it there.
export PATH="$WS/scripts/vendor/bin:$PATH"
TW="$TW" WS="$WS" PATH="$PATH" bash -c '
  cd "$WS" || exit 1
  . scripts/lib/render.sh; . scripts/lib/yaml.sh
  render_load_context "$TW/agent.yml" >/dev/null 2>&1
  render_template modules/local-session-stop.sh.tpl  > "$TW/scripts/local/agent-session-stop.sh"
  render_template modules/local-session-exit.sh.tpl  > "$TW/scripts/local/agent-session-exit.sh"
  render_template modules/local-session-check.sh.tpl > "$TW/scripts/local/agent-session-check.sh"
'
chmod +x "$TW/scripts/local/"*.sh 2>/dev/null

# Sanity: the rendered hooks must point at $TW, never at the real agent.
if grep -q "$WS/scripts/heartbeat" "$TW/scripts/local/agent-session-stop.sh" 2>/dev/null; then
  say "ABORT: rendered hook points at the REAL workspace — refusing to run"; exit 1
fi
grep -q "WORKSPACE=\"$TW\"" "$TW/scripts/local/agent-session-stop.sh" || { say "ABORT: hook not pointed at throwaway"; exit 1; }

# ── fake claude: traps SIGTERM and exits 0, exactly like the real one ───────
cat > "$TW/fakeclaude" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM
# Exit on its own when the sentinel appears (mimics "the session ended").
while [ ! -f "$SP024_EXIT" ]; do sleep 0.3; done
rm -f "$SP024_EXIT"
exit 0
EOF
chmod +x "$TW/fakeclaude"

# ── fake pointer (an announced session) ─────────────────────────────────────
SLUG=$(printf '%s' "$TW" | tr -c 'a-zA-Z0-9' '-')
PDIR="$TW/.state/.claude/projects/$SLUG"
PTR="$PDIR/bridge-pointer.json"
mk_pointer() { mkdir -p "$PDIR"; printf '{"sessionId":"session_GATE024","environmentId":"env_x","pid":1,"procStart":"1"}\n' > "$PTR"; }
reset_state() { rm -f "$PDIR"/bridge-pointer.retired.json "$TW/scripts/heartbeat/session-exit.json" 2>/dev/null; mkdir -p "$TW/scripts/heartbeat"; mk_pointer; }

# ── user unit: the three REAL hooks + fake claude ───────────────────────────
cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=024 composition gate
[Service]
Type=simple
Environment=SP024_EXIT=$TW/exit-now
ExecStartPre=-$TW/scripts/local/agent-session-check.sh
ExecStart=$TW/fakeclaude
ExecStop=-$TW/scripts/local/agent-session-stop.sh
ExecStopPost=-$TW/scripts/local/agent-session-exit.sh
Restart=always
RestartSec=1
TimeoutStopSec=3
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload

# ═══ SCENARIO A · systemctl restart with a live session KEEPS the pointer ═══
say ""; say "=== SC-001 mechanical: systemctl restart KEEPS a live session pointer ==="
reset_state
systemctl --user reset-failed "$UNIT" 2>/dev/null
systemctl --user start "$UNIT"; sleep 2
before=$(cat "$PTR" 2>/dev/null | tr -d '[:space:]')
systemctl --user restart "$UNIT"; sleep 3
after=$(cat "$PTR" 2>/dev/null | tr -d '[:space:]')
if [ -f "$PTR" ]; then ok "pointer still present after restart"; else bad "pointer was retired by a restart (the 022 bug)"; fi
if [ "$before" = "$after" ] && [ -n "$before" ]; then ok "sessionId byte-identical across the restart"; else bad "pointer content changed across restart"; fi
if [ ! -f "$PDIR/bridge-pointer.retired.json" ]; then ok "no retired sibling was created"; else bad "a retired sibling appeared on a plain restart"; fi
journalctl --user -u "$UNIT" -n 40 --no-pager 2>/dev/null | grep -q 'external' && ok "journal names the cause: external" || bad "journal did not name cause=external"

# ═══ SCENARIO B · the session ends on its own RETIRES the pointer ═══════════
say ""; say "=== SC-002 mechanical: a self-exit RETIRES the pointer ==="
systemctl --user stop "$UNIT" 2>/dev/null; sleep 1
reset_state
systemctl --user reset-failed "$UNIT" 2>/dev/null
systemctl --user start "$UNIT"; sleep 2
touch "$TW/exit-now"          # the session ends: the process exits 0 on its own
sleep 4                       # self-exit → ExecStop(populated) → Restart → check retires
if [ -f "$PDIR/bridge-pointer.retired.json" ]; then ok "pointer was retired after a self-exit"; else bad "self-exit did NOT retire the pointer"; fi
journalctl --user -u "$UNIT" -n 40 --no-pager 2>/dev/null | grep -qi 'previous session ended' && ok "journal names the decision: session ended → retired" || bad "journal did not name the retire decision"

# ═══ SCENARIO C · SC-007: a corrupt marker must NOT destroy a live pointer ══
say ""; say "=== SC-007: an indeterminate marker KEEPS a live pointer ==="
systemctl --user stop "$UNIT" 2>/dev/null; sleep 1
reset_state
printf '{"schema":1,"exit_c' > "$TW/scripts/heartbeat/session-exit.json"   # truncated
CLAUDE_CONFIG_DIR="$TW/.state/.claude" "$TW/scripts/local/agent-session-check.sh" 2>/dev/null
if [ -f "$PTR" ]; then ok "live pointer kept despite a corrupt marker"; else bad "a corrupt marker destroyed a live pointer"; fi

# ── cleanup ─────────────────────────────────────────────────────────────────
say ""
systemctl --user stop "$UNIT" 2>/dev/null
rm -f "$UNIT_DIR/$UNIT"; systemctl --user daemon-reload
rm -rf "$TW"
say "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
