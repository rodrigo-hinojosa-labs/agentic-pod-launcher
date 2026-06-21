# Contract: canonical wizard order ↔ quickstart doc (Story F)

## Canonical source

`tests/helper.bash::wizard_answers()` — the `printf` order — is the canonical wizard prompt
sequence. The optional catalog MCPs come from `mcp_catalog_list optional`.

## Canonical sequence (macOS; `install_service` is Linux-only)

1. Identity (4): name, display, role, vibe
2. About you (5): user name, nickname, timezone, email, language
3. *(Linux only)* install_service
4. Fork (1 + subs if enabled)
5. Heartbeat notification channel (1 + telegram subs)
6. **Optional catalog MCPs (6, alphabetical): aws, firecrawl, google-calendar, playwright, time, tree-sitter** ← omitted by the doc today
7. Atlassian MCP (1 + workspace loop if enabled)
8. GitHub MCP (1 + subs if enabled)
9. Heartbeat schedule (1 + subs if enabled)
10. Principles (1)
11. Vault (1 + 3 subs if enabled)
12. Optional plugins (5, alphabetical): code-simplifier, commit-commands, github, skill-creator, superpowers
13. Review action (1): `proceed`

## Doc requirement

`docs/agentic-quickstart.es.md` and `.en.md` MUST document step 6 (the 6 optional catalog MCPs,
each named by its `MCPS_<ID>` variable), in sequence position between notify (5) and Atlassian (7).

## Test assertion (host, no Docker) — `tests/quickstart-doc.bats`

- Source `scripts/lib/mcp-catalog.sh`; `for id in $(mcp_catalog_list optional)`: assert the doc's
  wizard-order section contains the id (e.g. `MCPS_AWS`, `MCPS_TREE_SITTER`).
- The test FAILS if any optional MCP is missing from either doc ⇒ a future catalog addition that
  isn't documented is caught before release.
- Parallels the existing ES/EN-sync tests in `quickstart-doc.bats`.
