{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    },
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    },
    "time": {
      "command": "uvx",
      "args": ["mcp-server-time", "--local-timezone={{USER_TIMEZONE}}"]
    },
    "sequential-thinking": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]
    }{{#each MCPS_ATLASSIAN}},
    "atlassian-{{name}}": {
      "command": "uvx",
      "args": ["mcp-atlassian"],
      "env": {
        "CONFLUENCE_URL": "${ATLASSIAN_{{NAME}}_CONFLUENCE_URL}",
        "CONFLUENCE_USERNAME": "${ATLASSIAN_{{NAME}}_CONFLUENCE_USERNAME}",
        "CONFLUENCE_API_TOKEN": "${ATLASSIAN_{{NAME}}_TOKEN}",
        "JIRA_URL": "${ATLASSIAN_{{NAME}}_JIRA_URL}",
        "JIRA_USERNAME": "${ATLASSIAN_{{NAME}}_JIRA_USERNAME}",
        "JIRA_API_TOKEN": "${ATLASSIAN_{{NAME}}_TOKEN}"
      }
    }{{/each}}{{#if MCPS_GITHUB_ENABLED}},
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}"
      }
    }{{/if}}{{#if VAULT_MCP_ENABLED}},
    "vault": {
      "command": "npx",
      "args": ["-y", "@bitbonsai/mcpvault@latest", "/home/agent/.vault"],
      "env": {}
    }{{/if}}{{#if VAULT_QMD_ENABLED}},
    "qmd": {
      "command": "bunx",
      "args": ["@tobilu/qmd@latest", "mcp"],
      "env": {}
    }{{/if}}
  }
}
