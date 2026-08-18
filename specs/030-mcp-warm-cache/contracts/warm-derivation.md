# Contrato — derivación de warm targets (`mcp_warm_targets`)

Función pura en `scripts/lib/mcp_warm.sh`. Entrada: ruta a un `.mcp.json`. Salida: cero o más líneas
`<runtime>\t<package>`, deduplicadas. Sin red, sin efectos. Base de la suite host bats.

## C1 — Selección por escaneo de `[command] + args`

- **C1.1** Para cada server bajo `.mcpServers`, construir la lista de tokens `[command] + args[]`.
- **C1.2** Hallar el PRIMER token `t` tal que `t == "uvx"` o `t == "npx"` o `basename(t)` ∈ {`uvx`,`npx`}.
- **C1.3** Si no hay tal token, el server se **omite** (no emite línea).
- **C1.4** `runtime` = el token hallado (`uvx`/`npx`).

## C2 — Extracción del paquete (token no-flag siguiente)

Desde la posición del token de runtime, avanzar tomando el primer token que sea un paquete:

- **C2.1** `uvx`: `package` = token inmediatamente siguiente.
- **C2.2** `npx`: saltar `-y` y `--yes`; para `-p <v>` / `--package <v>`, `package` = `<v>` (el token
  tras el flag); en otro caso `package` = primer token siguiente que no empiece con `-`.
- **C2.3** Si tras el token de runtime no hay ningún candidato válido, el server se omite (fail-soft:
  un `.mcp.json` raro no rompe la derivación).

## C3 — Fidelidad y normalización

- **C3.1** `package` se emite **literal** (incluye `@version` si el arg lo trae). No re-pinnear.
- **C3.2** Deduplicar por `(runtime, package)` exacto.
- **C3.3** Orden estable (p. ej. `sort -u`) para salida byte-determinista (facilita tests y traza).

## C4 — Robustez

- **C4.1** `.mcp.json` ausente/ilegible/`.mcpServers` vacío → cero líneas, rc 0 (no error).
- **C4.2** Un server sin `command` o sin `args` no aborta; se evalúa lo que haya.

## Casos de prueba (oráculo bats)

| # | server (command / args) | Espera |
|---|---|---|
| 1 | `uvx` / `["mcp-server-fetch"]` | `uvx\tmcp-server-fetch` |
| 2 | `uvx` / `["mcp-server-git","--repository","/workspace"]` | `uvx\tmcp-server-git` |
| 3 | `npx` / `["-y","@modelcontextprotocol/server-filesystem","/home/agent"]` | `npx\t@modelcontextprotocol/server-filesystem` |
| 4 | `npx` / `["@playwright/mcp@latest"]` | `npx\t@playwright/mcp@latest` |
| 5 | `/workspace/.custom/seed-google-creds.sh` / `["uvx","workspace-mcp"]` | `uvx\tworkspace-mcp` (**el caso del incidente**) |
| 6 | `npx` / `["-y","firecrawl-mcp"]` | `npx\tfirecrawl-mcp` |
| 7 | `npx` / `["-p","open-meteo-mcp@2.0.1","open-meteo-mcp"]` | `npx\topen-meteo-mcp@2.0.1` (salta `-p`) |
| 8 | `npx` / `["-y","@bitbonsai/mcpvault@0.12.0","/vault"]` | `npx\t@bitbonsai/mcpvault@0.12.0` |
| 9 | `github-mcp-server` / `["stdio"]` | (omitido) |
| 10 | `/opt/agent-admin/scripts/qmd-mcp` / `[]` | (omitido) |
| 11 | dos servers uvx con el mismo paquete | una sola línea (dedup) |
| 12 | `.mcp.json` inexistente | cero líneas, rc 0 |

## C5 — Mutación esperada

Revertir el escaneo a `command`-only (`select(.command=="uvx") | .args[0]`, el bug de hoy) DEBE tumbar
al menos el caso 5 (google-workspace) y el 7 (flag `-p`). Es la prueba de que la derivación args-aware
es load-bearing.
