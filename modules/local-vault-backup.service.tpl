[Unit]
Description=Backup the local vault to the fork's backup/vault branch ({{AGENT_NAME}})

[Service]
Type=oneshot
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
ExecStart={{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-vault-backup.sh
