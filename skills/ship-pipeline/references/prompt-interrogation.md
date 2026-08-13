# Prompt interrogation — grill the prompt before the spec

Surfaces the gaps in Jake's build prompt *before* any spec/code, using the same
seven dimensions as the Vibe Dojo prompt trainer. Run this inside Stage 1
(Brainstorm) and at the top of `/loop`, right after the idea is stated.

## How to run it (offline now, LLM-ready)

1. **Offline floor (always).** Read Jake's prompt/idea. For each of the seven
   dimensions below, decide `covered` / `partial` / `missing` from the text
   alone — no API key, no model grading required. This is deterministic enough
   to run on a suspended key.
2. **LLM layer (when available).** On top of the floor, generate 1–2 bespoke
   questions per *missing/partial* dimension, tailored to this specific build.
   When the Vibe Dojo key is restored, this layer can be auto-scored by POSTing
   the draft to `vibe-dojo/api/grade` (same dimension IDs) instead of
   self-assessing — the schema below is the contract, so the swap is clean.
3. **Ask only the gaps.** Put the `missing` dimensions first, `partial` next.
   Skip `covered` ones — don't ask what the prompt already answers. Cap at the
   ~5 highest-leverage questions per round (weight order) so it stays sharp.
4. **Fold answers back in.** Rewrite the prompt/idea with the answers, then
   re-read. A dimension Jake consciously defers is fine — record it as a
   deferred non-goal, not a gap.
5. **Score it — the threshold is the stop condition.** After each round, score
   the tightened prompt: `covered` = full weight, `partial` = half weight,
   `missing` = 0. Deferred dimensions drop out of both numerator and
   denominator (normalize to 100). **Below 85/100 the interrogation is NOT
   done** — generate the next round of gap questions (≤5, weight order) and
   keep going; the score, not a feeling of completeness, decides when the
   questions stop. At ≥85 with no undeferred `missing` dimension, stop and
   write the final line `score: NN/100` into the interrogation record — the
   stage-1 gate refuses a record without one.
6. **Hand off.** The tightened prompt + score + the deferred list flow into the
   Spec (GATE 1). Note in the spec which dimensions were weak so the rubric
   covers them.

## The seven dimensions (weight) → what to ask when it's thin

Mirrors `vibe-dojo/src/lib/rubric.ts`. Weight = ask-order priority.

1. **Task specificity (20).** *Gap: ask is broad/implied, no product boundary.*
   - What exact artifact should exist when this is done — a file, route, page, component?
   - What's the single next increment, and what's explicitly out of this slice?

2. **Context sufficiency (18).** *Gap: Claude would have to infer the world model.*
   - What stack, framework version, and existing files/paths does this touch?
   - What prior decisions, data shapes, or env facts must it not re-derive or contradict?

3. **Constraints & non-goals (16).** *Gap: no don'ts bounding the blast radius.*
   - What must it NOT change, touch, or build (auth, schema, prod data, UI)?
   - Name at least one negative constraint that would otherwise cause overreach.

4. **Verification / success criteria (16).** *Gap: no checkable definition of done.*
   - How do we tell it's done — which tests, checks, or observable behavior?
   - What's the exact command/route to verify, and the expected result?

5. **Output contract (12).** *Gap: output shape unspecified.*
   - What format, structure, and length should the result take?
   - What should the final summary report back (changed files, test command)?

6. **Role / framing (10).** *Gap: no framing where domain judgment matters.*
   - What persona/intent sharpens the tradeoffs here (e.g. "pragmatic backend eng")?
   - What's the priority when criteria conflict — speed, safety, simplicity?

7. **Examples (8).** *Gap: examples missing where they'd remove ambiguity.*
   - Is there a hard-to-describe format/style that a 1–2 line example would pin down?
   - Any edge case or payload shape worth showing rather than describing?

## Self-assessment schema (the LLM/grader contract)

```json
{
  "dimensions": [
    { "id": "taskSpecificity", "band": "missing|partial|covered", "question": "..." }
  ],
  "deferred": ["dimension ids Jake chose to skip, with reason"],
  "score": 87,
  "tightenedPrompt": "the prompt after folding in answers"
}
```

`id` values are exactly the seven `RubricDimensionId`s above, so the same payload
works whether the bands come from this offline pass or from Vibe Dojo's grader.
