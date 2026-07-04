[Unit]
Description=Schedule QMD RAG reindex for the local vault ({{AGENT_NAME}})

[Timer]
OnCalendar={{QMD_TIMER_ONCALENDAR}}
Persistent=true
Unit=agent-{{AGENT_NAME}}-qmd-reindex.service

[Install]
WantedBy=timers.target
