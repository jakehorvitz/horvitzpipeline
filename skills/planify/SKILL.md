---
name: planify
description: "Owns the Horvitz pipeline plan artifact — the bridge between the signed spec and the build loop. Use inside a run before Stage 5, or when Jake says 'plan this', 'how do we build it', 'break this down'. Produces the pinned plan (bones plan) that the build loop is handed and the conformance report cites."
---

# planify — the plan artifact (Bones's fix #3)

Bones's third defect: nothing sat between the signed spec and the build loop, so the builder invented architecture, execution order, and test seams mid-loop. This skill owns the plan that closes that gap.

## Produces
`docs/plan.md`, pinned by `bones plan -e docs/plan.md "<note>"` before any build. Required sections: `## Architecture`, `## Changes` (one line per file: path — create|edit|delete — why, no placeholder reasons), `## Order` (numbered), `## Test seams`, and `## Acceptance map` mapping **every** `AC-nn` id of the signed spec to a step. Validated mechanically by `contracts/plan.sh` (id-set parity with the signed spec, `plan-for: <spec> (sha256:…)` equal to the signed spec, non-hollow reasons) plus the two-vote LLM judge. `bones build` refuses without it, re-checks its `spec-sha256` against the signed spec (a re-signed spec stales the plan), and hands it to the builder with `-P`; the builder writes deviations to `.loop/plan-deviations.md`, which the Stage-6 conformance report must cite.

## Procedure
1. Read the signed spec top to bottom; list every acceptance id.
2. Write the four sections, then the acceptance map — one line per id, mapped to a concrete step.
3. `bones plan -e docs/plan.md "<what the plan commits to>"`; fix whatever the contract or judge rejects.

## Activates
Stage 5 of any Horvitz/ship run, before `bones build`; or when Jake asks for an implementation plan.
