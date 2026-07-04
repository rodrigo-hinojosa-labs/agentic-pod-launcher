[Unit]
Description=Schedule the local vault backup ({{AGENT_NAME}})

[Timer]
OnCalendar={{BACKUP_TIMER_ONCALENDAR}}
Persistent=true
Unit=agent-{{AGENT_NAME}}-vault-backup.service

[Install]
WantedBy=timers.target
