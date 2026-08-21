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
| 5 | Plan artifact (contract + judge) → build loop | **auto** | pinned plan, then acceptance command exit code, independently re-run |
| 5.5 | Spec-conformance check (anti-drift) | evidence for 6 | conformance report |
| 6 | Adversarial review + risk-triggered security | agent | evidence-checked |
| 7 | Staging validation (e2e + click-through) | agent | two artifacts required |
| 8 | Promote: 8a authorize (owner token, Touch ID, bound to HEAD) → 8b confirm (smoke record) | **owner** + agent | signed token + smoke contract |
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

## 2.0: what changed

Horvitz 2.0 closes four defects found in review (thanks to Bones Ijeoma) with mechanical,
selftest-proven enforcement:

1. **Stage 8 is two-phase.** `bones approve` at 8 is *authorize* — the owner's verbatim words plus
   a Touch-ID-signed token bound to the current git HEAD; the guard lifts its push/deploy rules only
   while HEAD equals the authorized sha. Deploy and smoke happen next, then `bones confirm` with a
   smoke record (8b) stamps the gate; only `bones next` after that starts the 7-day operate clock.
2. **Evidence contracts.** Stages 4, 6, 7, the plan, and the smoke record are validated by
   executable contracts in `skills/horvitz-pipeline/contracts/` — required fields, id parity with the
   signed spec, real screenshot bytes and dimensions, hollow-evidence refusal — not by keyword greps.
3. **A plan artifact before the build.** `bones plan` pins architecture, file-level changes,
   order, test seams, and an acceptance map; `bones build` refuses without it and hands it to the
   builder. Deviations are logged and must be cited at review.
4. **Real owner authentication.** The `[ -t 0 ]` TTY check is gone. Production approval is a
   one-tap Secure-Enclave signature (`bones owner-setup` once per machine); the helper binary's
   hash and code signature are pinned; tokens are one-use and time-boxed; openssl verifies them in
   `bones.sh` and in the guard. Machines without Touch ID can opt into a passphrase key that is
   labeled DEGRADED everywhere.

Nothing renumbers or renames; the state schema stays at 2; `MIGRATION.md` is the install path.

## Orchestrator vs skills

Bones's thesis — *keep the orchestrator thin; it should track artifact paths, hashes, dependencies,
and the next transition, and policy should live in composable skills* — is the direction of 2.0.
Slice A (this release) moved the *enforcement* of stage policy out of prose and into contracts the
orchestrator calls by name, and made the plan an artifact the orchestrator pins like any other.
Slice B (next) thins `bones.sh` further: stage briefs become `## Produces` blocks in five skills
(`specify`, `goalify`, `planify`, `implementify`, `reviewify`), `bones artifacts` lists every pinned
artifact with its hash and verification state, and the other twelve skills Bones named are
documented as context-activated helpers, never mandatory stages.

## Residual risks (disclosed)

- **R1** Any process running as the owner can *request* the Touch ID prompt; a careless tap
  authorizes. The prompt names the pipeline, short HEAD, and the first 60 characters of the quote;
  tokens are nonce-bound, time-boxed, one-use, and stale the moment HEAD moves.
- **R2** A compromise of the owner's login session at keychain level is out of scope; the
  Secure-Enclave key still cannot sign without biometry.
- **R3** Macs without Touch ID fall back to a passphrase key: a typed approval, marked DEGRADED.
- **R4** The guard remains regex-over-Bash; a determined agent can write a program that shells out,
  or patch the guard itself under the same uid. Helper pinning narrows, but cannot close, that class.
  The same boundary applies to every file the orchestrator trusts — gate records, `.bones/owner.pub`,
  `used-nonces`, `contracts.sha256`: the guard stops literal writes (from any directory, including
  `cd ..`-then-path and `git -C` forms) but an obfuscated path or a script that writes from inside is
  the same class as patching the guard. The next frontier is a non-regex write broker (guard 3.0).
- **R5** Skill shapes for Slice B were designed from Bones's descriptions until his repo is readable.
- **R6** "No skill becomes a stage" is true, and still the contracts and the plan gate are new
  mandatory policy surfaces. Said plainly rather than implied away.
- **R7** Steady-state friction is one tap per promote; the one-time migration is more (owner-setup,
  fleet pin-owner, fleet repin, fleet doctor) — scripted and journaled, but not "one tap".
