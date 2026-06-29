# EnvironmentFile for the Claude Code Remote Control session ({{AGENT_NAME}}).
# Mode 0640. Rendered from agent.yml — do not hand-edit (use ./setup.sh --regenerate).
# claude.config_dir in agent.yml is docker-only and is IGNORED here (C1): local
# mode pins CLAUDE_CONFIG_DIR under the workspace .state so the login stays
# gitignored and never touches the operator's personal ~/.claude.
CLAUDE_CONFIG_DIR={{DEPLOYMENT_WORKSPACE}}/.state/.claude
DISABLE_AUTOUPDATER=1
HOME={{OPERATOR_HOME}}
# Intentionally no API key here: Remote Control uses the full-scope OAuth login.
