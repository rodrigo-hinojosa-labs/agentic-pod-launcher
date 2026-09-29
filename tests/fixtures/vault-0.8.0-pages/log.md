# Vault log

Chronological, append-only record of vault operations. Time-oriented complement to `index.md`
(which is content-oriented).

Format — one entry per operation, parseable by `grep "^## \[" log.md | tail -N`:

```
## [YYYY-MM-DD] {ingest|query|lint|init|other} | <short title>

(optional one-paragraph note)
```

Older entries stay at the top — never delete, never reorder. New entries go at the bottom.

---

## [SCAFFOLD_DATE] init | vault scaffolded

Initial vault structure created from `modules/vault-skeleton/` by the agent's first boot.
The LLM owns `wiki/` from this point forward.
