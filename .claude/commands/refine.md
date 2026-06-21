---
description: Recommendation-first interactive refinement of a spec/plan/definition — proposes recommended answers grounded in project + user knowledge, then persists what's resolved
argument-hint: "[feature-dir | file | topic]  (empty = active spec-kit feature)"
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, AskUserQuestion
---

You are running inside the **agentic-pod-launcher** repo. The user wants to **refine or enrich** an artifact (a spec-kit `spec.md`/`plan.md`, or any definition they point at) **interactively** — but recommendation-first: you PROPOSE concrete recommended answers grounded in everything you know about this project and this user, and they react (accept / adjust). Every resolved decision is **persisted** back into the artifact so it survives the session.

This complements `/speckit-clarify`: clarify asks neutral questions to remove ambiguity; `/refine` leads with a *recommendation* and reasoning, and also enriches (not just disambiguates).

## Target of this run

`$ARGUMENTS`

- If empty: resolve the active feature by reading `.specify/feature.json` → `feature_directory`, then operate on its `spec.md` (or `plan.md` if the user says "plan"). Run `!cat .specify/feature.json 2>/dev/null` to find it.
- If it names a directory/file: refine that file.
- If it names a topic with no obvious file: ask the user which file to write the resolved decisions into before proposing anything.

## Load context BEFORE proposing anything (non-negotiable)

Read these so every recommendation is grounded, not generic:

- The target artifact (`spec.md` / `plan.md` / the named file).
- `.specify/memory/constitution.md` — the project's non-negotiable principles. Recommendations MUST respect it.
- `CLAUDE.md` (repo root) — architecture, the three code paths, gotchas.
- `agent.yml` if the artifact touches a scaffolded agent (single source of truth).
- Your memory of the user + project: the `MEMORY.md` index and any recalled memories, plus what you learned earlier this session.

## How to work — recommendation-first, one decision at a time

1. Scan the artifact and build a **prioritized queue** of enrichable / ambiguous points: deferred mechanism decisions, `[PENDIENTE]` / `[POR CONFIRMAR]` / `[SIN INFORMACIÓN]` markers, vague or untestable requirements, unconfirmed assumptions, coverage gaps, missing edge cases. Cap at ~5 per run (highest impact × uncertainty first). Do not reveal the whole queue up front.
2. For EACH point, present **one concrete recommendation** with 1–2 lines of rationale anchored in the project / user / constitution. Use `AskUserQuestion` with the recommended option **first** and a `(Recomendado)` suffix on its label; give 2–4 mutually-exclusive options when there's a real choice. For a short free-form value, state your suggested value and ask for a yes/adjust.
3. **Never invent** secrets (PATs, tokens, chat IDs, API tokens) or facts that aren't documented. Genuine blanks stay `[PENDIENTE]` / `[POR CONFIRMAR]` — recommend a default *behavior*, not a fabricated value.
4. As soon as the user answers, **persist it immediately**:
   - Integrate the decision into the right section of the artifact (Requirements / Assumptions / Decisions / the relevant story), replacing any now-stale text rather than duplicating.
   - Append an audit line under a `## Refinement decisions` section → `### <date> session` (create if missing): `- D: <point> → A: <answer>`. Take the date from the environment context; never fabricate it.
   - Save atomically after each decision; preserve heading order and structure.
5. If a decision invalidates an earlier statement, fix the earlier statement too — leave no contradiction.

## Rules

- Respond in the user's language — **neutral Spanish (Chile) by default**.
- Recommendation-first: the user reacts to a proposal, not a blank question. Lead with what you'd do and why.
- One decision per interaction; stop at ~5 or when the user says "listo" / "suficiente".
- Stay within the artifact's scope — `/refine` enriches definitions, it does not implement code.
- Respect the constitution (test-first, agent.yml as source of truth, survives `--regenerate`, least-privilege container, CHANGELOG/VERSION discipline). Flag any proposal that would violate it instead of recommending it.

## Close-out

End with a compact summary: decisions resolved, anything left `[PENDIENTE]` and why, and the suggested next command (e.g. `/speckit-plan`, `/speckit-tasks`, or re-running `/refine` on the plan).
