[Unit]
Description=Wiki-graph derive + structural lint for the local vault ({{AGENT_NAME}})

[Service]
Type=oneshot
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
ExecStart={{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-wiki-graph.sh
