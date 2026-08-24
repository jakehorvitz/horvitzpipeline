---
name: specify
description: "Owns the Horvitz pipeline Stage 3 artifact — the HTML spec Jake signs. Use inside a Horvitz/ship run at spec time, or when Jake says 'spec this', 'write the spec', 'turn this into a spec'. Produces the signed spec that every later stage is held to."
---

# specify — the Stage 3 spec artifact

The orchestrator (bones.sh) tracks *that* stage 3 needs a signed spec and *who* signs it (owner). This skill owns *what a good spec is* and *how it is validated*.

## Produces
`docs/spec.html` from `ship-pipeline/templates/spec.html`: problem + goal, users, scope, explicit **non-goals / anti-requirements**, data model, milestones, and an **executable acceptance checklist** whose rows each carry an id `AC-nn` and are checkable by a command or observable behavior. Every external API is **curl-probed at spec time** (request + confirmed response captured in the spec) or the spec states "no external APIs" explicitly. UI builds link the Stage-1 mockup. The stage-3 gate validates the artifact mechanically (an `*.html` with an acceptance checklist + an API-validation record) and runs a two-vote LLM substance judge; sign-off is the owner's. A re-signed spec re-hashes, which stales any pinned plan or conformance report built against the old bytes.

## Procedure
1. Build the spec from the template; fill non-goals and the acceptance checklist first — they bound the build.
2. Probe every external API live and paste the real request/response into the API-validation section.
3. Give the spec to Jake annotatable (spec-annotate.js) and, for big specs, as a ChatGPT-voice conversation doc; fold his notes in and highlight what changed on each revision.
4. Iterate until he signs off. Council rejection or a redirect that changes scope means `bones back -s 3`.

## Activates
Stage 3 of any Horvitz/ship run; or directly when Jake asks to write or revise a spec.
