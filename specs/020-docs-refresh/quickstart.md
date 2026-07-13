# Quickstart: Docs Refresh (020)

## Verify the feature (SC-001..006)

```bash
# SC-005 — zero behavior change: suite stays green (baseline 977/0)
bats tests/

# SC-002 — quickstart prompt coverage: diff each quickstart's walkthrough
# against specs/020-docs-refresh/wizard-prompt-order.md (52 prompts, in order)

# SC-004 — ES/EN parity: section-by-section structural diff
diff <(grep -E '^#{1,3} ' docs/agentic-quickstart.en.md) \
     <(grep -E '^#{1,3} ' docs/agentic-quickstart.es.md)   # headings should pair 1:1 (allowing translation)

# SC-006 — links resolve (spot-check anchors/paths referenced in updated docs)
grep -rnoE '\]\((docs/|\./|\.\./)[^)]+\)' README.md docs/*.md | while IFS=: read f l link; do
  p=$(echo "$link" | sed -E 's/^\]\(//; s/\)$//; s/#.*//'); [ -e "$p" ] || echo "DEAD: $f:$l -> $p"
done
```

## SC-001 — closing audit

Walk [drift-audit.md](drift-audit.md) row by row against the updated docs:
each finding must be corrected, removed, or qualified. Nothing survives.

## Artifacts

- [drift-audit.md](drift-audit.md) — 121 findings, evidence file:line (oracle).
- [wizard-prompt-order.md](wizard-prompt-order.md) — 52 canonical prompts (oracle).
- [coverage-map.md](coverage-map.md) — 25 subsystems, homes for the gaps.
- [contracts/doc-update-contract.md](contracts/doc-update-contract.md) — edit rules.
