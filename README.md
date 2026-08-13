# Horvitz Pipeline

An enforced, 10-stage idea-to-production pipeline for AI-driven builds. Two layers:

- **`skills/ship-pipeline`** describes what each stage does and why.
- **`skills/horvitz-pipeline`** is the driver: a bash state machine (`scripts/bones.sh`) that mechanically refuses to advance past an unsatisfied gate, instead of trusting an agent to follow prose.

Built for Claude Code (both folders drop into `~/.claude/skills/`), but the state machine is plain bash and works with any agent that can run shell commands.

## The 10 stages

| # | Stage | Gate | Held by |
|---|-------|------|---------|
| 1 | Brainstorm + prompt interrogation (scored rubric) | agent | evidence-checked |
| 2 | Kill-or-commit | **owner** | verbatim human quote |
| 3 | Spec sign-off (HTML spec + spec-time API validation) | **owner** | verbatim human quote |
| 4 | Council / second-pass critique | agent | evidence-checked |
| 5 | Build loop | **auto** | acceptance command exit code, independently re-run |
| 5.5 | Spec-conformance check (anti-drift) | evidence for 6 | conformance report |
| 6 | Adversarial review + risk-triggered security | agent | evidence-checked |
| 7 | Staging validation (e2e + click-through) | agent | two artifacts required |
| 8 | Promote + production smoke test | **owner** | verbatim human quote |
| 9 | Present | step | none |
| 10 | Operate + learn (7-day clock) | **owner** | verbatim human quote |

Gate types:

- **owner**: the human decides. The script refuses to record approval without the human's verbatim words, and in strict mode the human must type the approval at a real TTY, so an agent shell physically cannot satisfy it.
- **agent**: the agent decides, but the artifact is the gate. `approve` refuses thin notes and validates evidence shape; stages 1 and 3 additionally run a two-vote LLM substance check so a hollow artifact decorated with the right keywords still fails.
- **auto**: machine-verified. The orchestrator re-runs the acceptance command pinned at init and trusts only the real exit code, so the builder never marks its own homework.

## Enforcement layers

1. **State machine** (`bones.sh`): stage tracking, gate records with sha-pinned evidence files and git SHAs, journaled audit trail, regression via `back` (archives, never deletes).
2. **Harness guard** (`bones-guard.sh`, a PreToolUse hook): blocks `git push` to main, deploy-shaped commands, and any direct write into `.bones/` while gates are open, even for commands that `cd` into the gated tree. A self-test corpus (`selftest/corpus.txt`, `bones.sh selftest`) proves the bypass catalog stays blocked.
3. **Integrity**: `doctor` re-hashes every pinned evidence file and flags post-signoff edits; the guard hash is pinned and `guard-repin` refuses unless the live guard still blocks the full bypass corpus.

## The build loop (stage 5)

`ship-pipeline/scripts/loop.sh` iterates a builder agent (codex or prime-agent) against an HTML spec and rubric until the acceptance command passes. The rubric score is advisory; the binding gate is the orchestrator independently running the pinned acceptance command (Goodhart resistance). A per-iteration review runs on a different model than the builder. Parallel workstreams go into separate git worktrees with one loop each, and per-step work runs in subagents with isolated contexts so the orchestrator stays clean.

## Recent upgrades (2026-08-13, from a pipeline-review session)

1. **Interrogation rubric threshold.** The seven-dimension prompt interrogation is now scored (covered = full weight, partial = half, missing = 0; consciously deferred dimensions excluded). Below 85/100 the interrogation keeps asking; the score, not a feeling of completeness, is the stop condition. The stage-1 gate refuses a record without `score: NN/100`.
2. **Spec-time API contract validation.** Every external API the build depends on gets a live `curl` probe while the spec is written, with the request and confirmed response captured in the spec. An API first tested mid-build guarantees buggy software. The stage-3 gate refuses a spec with neither an API-validation record nor an explicit no-external-APIs statement.
3. **UI mockup as visual contract.** Any build with a UI must produce a clickable HTML mockup during brainstorm; the spec links it and the conformance check is held to it.
4. **Stage 5.5 spec-conformance check.** Long loops drift: the builder optimizes for the acceptance command and forgets spec commitments the command does not encode. When the loop exits green, the signed spec is re-read top to bottom and every commitment is marked MATCHES / DRIFTED / MISSING with evidence. The stage-6 gate refuses approval without the conformance report.

## Quick start

```bash
# install (Claude Code)
cp -R skills/horvitz-pipeline skills/ship-pipeline ~/.claude/skills/

# start a gated run
skills/horvitz-pipeline/scripts/bones.sh init -t ~/projects/myapp -c "npm test" -n myapp
cd ~/projects/myapp
bones.sh status      # which gate is open, and exactly what satisfies it
```

`status` always prints the current stage requirements brief. Do the work, satisfy the gate, `bones.sh next`. Going backward is normal: `back -s <stage> -r "<reason>"` archives the cleared gates and keeps the audit trail.

## Knowledge layer

`ship-pipeline/references/brains.md` wires personal knowledge vaults into stage 1 (recon before any web search) and stage 10 (learnings written back). Swap the table for your own knowledge bases; the pattern is the point: consult before building, write back after operating.
