{
  "mcpServers": {
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    },
    "git": {
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "/workspace"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/agent"]
    }{{#if MCPS_PLAYWRIGHT_ENABLED}},
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }{{/if}}{{#if MCPS_TIME_ENABLED}},
    "time": {
      "command": "uvx",
      "args": ["mcp-server-time", "--local-timezone={{USER_TIMEZONE}}"]
    }{{/if}}{{#if MCPS_FIRECRAWL_ENABLED}},
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_KEY": "${FIRECRAWL_API_KEY}"
      }
    }{{/if}}{{#if MCPS_GOOGLE_CALENDAR_ENABLED}},
    "google-calendar": {
      "command": "npx",
      "args": ["-y", "@cocal/google-calendar-mcp"],
      "env": {
        "GOOGLE_OAUTH_CREDENTIALS": "/home/agent/.gcal/gcp-oauth.keys.json"
      }
    }{{/if}}{{#if MCPS_AWS_ENABLED}},
    "aws": {
      "command": "uvx",
      "args": ["awslabs.aws-api-mcp-server@latest"],
      "env": {
        "AWS_PROFILE": "${AWS_PROFILE}",
        "AWS_REGION": "${AWS_REGION}"
      }
    }{{/if}}{{#if MCPS_TREE_SITTER_ENABLED}},
    "tree-sitter": {
      "command": "uvx",
      "args": ["mcp-server-tree-sitter"]
    }{{/if}}{{#each MCPS_ATLASSIAN}},
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
