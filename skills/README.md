# Horvitz pipeline skills

Horvitz 2.0 keeps the **orchestrator thin** (`horvitz-pipeline/scripts/bones.sh` tracks artifact
paths, hashes, dependencies, gate types, and the next transition) and moves **stage policy into
composable skills**, per Bones Ijeoma's review. `bones status` reads a stage's rich brief from its
owning skill's `## Produces` block (`BONES_SKILLS_DIR`, default the installed `~/.claude/skills`).

## The five that own a stage

| Skill | Owns | Activates |
|-------|------|-----------|
| **specify** | Stage 3 — the signed HTML spec | at spec time, or "spec this" |
| **goalify** | Stage 2 kill-or-commit + Stage 10 operate/learn | at those gates, or "is this worth building / kill it?" |
| **planify** | the plan artifact before Stage 5 | before build, or "plan this" |
| **implementify** | Stage 5 build loop | at build, or "build/implement it" |
| **reviewify** | Stage 4 council + Stage 5.5 conformance + Stage 6 review | at those gates, or "review/red-team it" |

Stages 1 (brainstorm + interrogation), 7 (staging), 8 (promote), and 9 (present) stay
orchestrator-owned; their briefs point at `ship-pipeline`.

## The twelve context-activated helpers (never mandatory stages)

Bones named a wider set to study. These activate when the context calls for them — they are **not**
pipeline stages, and none is required to advance a gate.

| Skill | Role | Activates when |
|-------|------|----------------|
| **mapify** | map an unfamiliar codebase/corpus before changing it | onboarding a brownfield repo |
| **grilling** | interrogate a prompt/idea for gaps | inside Stage 1, or a vague ask |
| **roast** | adversarial critique of a plan or design | before committing to an approach |
| **detailify** | expand a terse spec into implementation detail | a plan is too thin to build from |
| **glossify** | pin domain terms so agents stop re-deriving them | a build keeps re-inventing vocabulary |
| **researchify** | multi-source research with citations | a decision needs outside evidence |
| **tddify** | write tests first, then code to green | a build wants executable acceptance up front |
| **architectify** | system-design guidance (Bones's internal library) | a genuinely new architecture, not a tweak |
| **debugify** | systematic root-cause debugging | a bug or unexpected behavior |
| **mergify** | integrate a finished branch safely | a build is done and needs to land |
| **wizard** | step a non-coder through a flow | a Michael-tier user drives the tool |
| **skillify** | extract a repeated workflow into a new skill | a pattern recurs across runs |

Bones's caution, kept: **seventeen skills must not become seventeen mandatory stages.** Only the five
above own a gate; the twelve are on-demand.
