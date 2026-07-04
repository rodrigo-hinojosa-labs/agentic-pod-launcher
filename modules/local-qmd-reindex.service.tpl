[Unit]
Description=QMD RAG reindex for the local vault ({{AGENT_NAME}})

[Service]
Type=oneshot
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
ExecStart={{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-qmd-reindex.sh
