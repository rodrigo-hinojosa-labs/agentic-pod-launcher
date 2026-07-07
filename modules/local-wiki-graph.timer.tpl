[Unit]
Description=Schedule wiki-graph derive + lint for the local vault ({{AGENT_NAME}})

[Timer]
OnCalendar={{WIKI_GRAPH_TIMER_ONCALENDAR}}
Persistent=true
Unit=agent-{{AGENT_NAME}}-wiki-graph.service

[Install]
WantedBy=timers.target
