# Contract: Doc Update Rules (020)

Every edit to an in-scope doc obeys these rules. They operationalize
FR-002/003/004/008/009/010 and make SC-001..006 checkable.

## 1. Verification (FR-002)

- No claim is written from memory. Before a corrected sentence lands, the
  writer re-checks the referenced code/template/test in the v0.12.0 tree —
  even when the drift table already carries evidence (that evidence dates
  from audit time).
- Commands quoted in docs must be runnable as written (copy-paste truth):
  flags exist, paths exist, subcommands exist.
- Per-mode truth: any statement true in only one deployment mode is
  qualified ("docker mode:", "local mode:") — the audit's 41
  `needs-qualifier` findings are all of this class.

## 2. Quickstarts (FR-003/004)

- Prompt walkthroughs mirror [wizard-prompt-order.md](../wizard-prompt-order.md)
  one-to-one: same order, every conditional annotated with its trigger
  (mode, platform, prior answer), each prompt with default + semantics.
- ES and EN are written from the same section skeleton; SC-004 is a
  section-by-section structural diff, not a literal translation check.
- The `/quickstart` skill consumes these docs: wording of answers/values
  must match what the wizard actually accepts (e.g. `docker`/`local`,
  `y`/`n`, schedule syntax).

## 3. Scope discipline (FR-008)

- Editable: `README.md`, the 10 `docs/*.md` in scope, the 3 doc templates,
  `CHANGELOG.md` (Unreleased note), and rendered-string TEST assertions only
  when a template fix legitimately changes them (same commit — R4).
- Untouchable in this feature: executable code, schemas, non-doc templates,
  `CLAUDE.md`, `docs/superpowers/`, `specs/` histories. A code-is-wrong
  discovery becomes a recorded finding, never a fix here.

## 4. Aging facts (FR-009)

- Version numbers, test counts, image bases, sizes: tag with "as of
  v0.12.0" (or the doc's own verification banner) — once per doc section,
  not on every sentence.

## 5. Links (FR-010)

- Every intra-repo link/anchor added or touched resolves; the closing pass
  runs a link check over the in-scope set.

## 6. Closing audit (SC-001)

- After all edits: every row of [drift-audit.md](../drift-audit.md) is
  re-checked against the updated doc and marked resolved
  (corrected/removed/qualified). A finding that survives = the feature is
  not done. The single `unverified-suspicion` row must be verified or
  explicitly dropped with rationale.
