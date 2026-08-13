---
name: horvitz-pipeline
description: "Enforced-orchestration version of Jake's 9.5 ship-pipeline — a state-machine that MECHANICALLY enforces every gate instead of trusting an agent to follow prose. Use whenever Jake runs /horvitzpipeline, or says 'Horvitz pipeline', 'enforced pipeline', 'gated build', 'run the pipeline properly', 'don't let me skip steps', or kicks off a big build where the gates must actually hold (kill-or-commit, spec sign-off, council, acceptance-verified build loop, review+security, staging-before-promote, prod smoke, operate/learn). Prefer this over plain ship-pipeline when discipline matters — it refuses to advance past an unsatisfied gate. Not for small one-file edits or quick questions."
---

# Horvitz pipeline — the 9.5 ship-pipeline, mechanically gated

Same 10-stage pipeline as `ship-pipeline`, but the gates are **enforced by a state
machine**, not by an agent remembering to honor prose. `scripts/bones.sh` tracks the
current stage in `.bones/state.json` and **refuses to advance past a gate until it's
satisfied** — and it distinguishes WHO may satisfy each gate.

Read `ship-pipeline/SKILL.md` for what each stage *does* and why. This skill is the
**driver** that makes those stages happen in order, gated.

## Gate types — who holds the pen

| Type | Meaning | Satisfied by |
|------|---------|--------------|
| **owner** | Jake's call, not yours | `approve -q "<his verbatim words>" "<note>"` — the script refuses without a quote |
| **agent** | your judgment call | `approve [-e <evidence_file>]... "<substantive note>"` — thin notes ("approved", "done") are rejected |
| **auto** | machine-verified | `bones build -c "<cmd>" …` → loop.sh exit 0, then Horvitz independently re-runs the pinned command and also requires exit 0. `-c` is required; `approve` is rejected here. Builds with **prime-agent by default**; `-B codex\|prime\|auto` overrides — the builder never changes who holds the gate |
| **step** | no gate | `next` advances and records the step |

`status` prints the current stage's **requirements brief** — the exact sub-parts that
satisfy it (recon + interrogation for 1, click-control/e2e/competitor for 7, smoke test
for 8, telemetry for 10, …). Do what the brief says before touching the gate.

## The owner-gate protocol (the point of this skill)

Stages 2 (kill-or-commit), 3 (spec), 8 (promote), 10 (operate) are **Jake's
decisions**. Before approving one you MUST:

1. Present the stage's output and **ask Jake directly** (AskUserQuestion, or his
   message in the conversation/iMessage).
2. **Wait for his actual reply.** No reply = gate stays open. Say what's blocked and stop.
3. Record his exact words: `bones approve -q "<verbatim>" "<what was decided>"`.

The quote is **verbatim or nothing** — it goes on the permanent record and Jake can
read it back. A fabricated or paraphrased quote is a falsified audit record, strictly
worse than a skipped gate.

**Rationalizations that don't fly** (each observed or predictable in real runs):

| Excuse | Reality |
|--------|---------|
| "Jake said 'figure it out' / 'go ahead' at kickoff" | One authorization ≠ four sign-offs. Ask at each owner gate. |
| "He's busy and this is low-stakes" | Then the gate stays open. Blocked-and-honest beats shipped-and-unauthorized. |
| "I know what he'd say" | A prediction is not a quote. Ask. |
| "He redirected me, that's basically approval" | A redirect that changes scope = `bones back` to the stage it invalidates, not an approve. |
| "The work is genuinely done, the gate is a formality" | Done-ness is what *agent/auto* gates check. Owner gates check *consent*. |

**Strict mode is the DEFAULT** (since 7/16): owner gates require a real TTY — Jake
types the approve himself; an agent shell physically cannot. At an owner gate, `nudge`
him with the exact `approve -q` command to run, then stop. `init -S` (soft mode) is the
opt-out for low-stakes runs where agent-recorded quotes are acceptable — Jake's call.

## How to drive it

`scripts/bones.sh` — run from anywhere inside the target (finds `.bones/` by walking up).

```
bones.sh init -t <dir> -c "<acceptance_cmd>" [-n name] [-S]
                                               # pins acceptance once; lands on stage 1; STRICT by default
bones.sh init -t <dir> [-n name] [-S]          # compatibility/guard-only mode: pins `false`, so stage 5 cannot pass
bones.sh status                                # where am I, which gate is open, what to do
bones.sh approve [-q "<quote>"] [-e <file>]... "<note>"   # satisfy current owner/agent gate
bones.sh build -c "<pinned_acceptance_cmd>" -s <spec.html> [-r rubric] [-B codex|prime|auto] [-R auto|codex|gemini|prime]
                                               # stage 5 only; -c must match init; Horvitz independently re-runs it before opening the gate
                                               # builds with prime-agent by DEFAULT (no -B needed); BONES_BUILDER=codex changes the default
bones.sh license --check <signed-key>           # offline Ed25519 verification; valid Pro keys exit 0, tampered keys fail closed
bones.sh package [-s giftcandidate] [-o bones-package.tar.gz] [-a allowlist]
                                               # fail-closed privacy scan, then archive manifest-listed files
bones.sh next                                  # advance IF gate satisfied (else refuses)
bones.sh back -s <stage> -r "<reason>"         # regress (archives gate records, keeps audit)
bones.sh note "<text>"                         # journal an observation (stage-stamped)
bones.sh nudge [-n] ["<extra>"]                # iMessage Jake about the current gate (-n dry run)
bones.sh doctor                                # consistency check: state vs gates vs journal
bones.sh guard-repin -r "<reason>"             # re-pin guard hash after a deliberate guard upgrade — refuses
                                               # unless the live guard BLOCKS the full bypass corpus; journaled
bones.sh log                                   # full audit trail: gates + archive + journal
bones.sh reset -f                              # wipe state
```

License checks are offline: the public Ed25519 key is embedded in `bones.sh`,
while the signing private key is never loaded or shipped by this repository. A
valid key prints `Pro unlocked`; malformed or byte-tampered keys exit non-zero
with `INVALID SIGNATURE`. `bones selftest --only license` exercises both paths
using a throwaway keypair that is deleted when the test ends.

Gift packaging is fail-closed. The candidate needs a `.bones-package-manifest`
containing one relative file path per line. `bones package` scans the entire candidate
(including files omitted from that manifest) with the built-in signature/entropy
scanner and every installed supported external scanner (`gitleaks` and/or
`trufflehog`). At least one external scanner is mandatory; if none is installed, no
archive is created. Exact entropy exceptions use the tab-delimited
`packaging/secret-allowlist.txt` manifest (`sha256`, rule, relative path); private-data
paths such as `.env`, memory, Jarvis voice, Score-a-Score, Shavit/client material, and
local project data cannot be allowlisted. Only after all scans pass does Horvitz archive
the files named by the package manifest. `bones selftest --only package` proves the
planted-secret refusal, clean archive path, and missing-scanner fail-closed behavior.

At an **owner gate**, `bones nudge` sends Jake an iMessage describing the open gate
(handle via `BONES_OWNER_HANDLE`, defaults to his). His REPLY is the approval — record
it verbatim with `approve -q`. The nudge is transport, never consent.

When stage 8 passes, Horvitz starts a **7-day operate clock** (`.bones/operate-due`);
`status` shows the deadline and flags OVERDUE. Schedule a day-7 check-in agent
(/schedule) at promote time so the stage-10 call actually happens.

## Harness guard v2 (gates bind even if Horvitz is ignored)

A PreToolUse hook (`scripts/bones-guard.sh`, registered in `~/.claude/settings.json`)
enforces gates at the Bash layer in any tree whose `.bones` is active — including
commands that `cd` into the gated tree:

- **git push allowlist (stage ≤ 8):** only `git push <remote> <non-main-branch>`
  passes. Bare `git push`, `HEAD:main`, `+main`, `--force`, `--delete`, and any colon
  refspec are blocked. Pushing to main IS promotion.
- **Deploy shapes (stage ≤ 8):** `make deploy`, `npm/yarn/pnpm/bun run *deploy*`,
  `bash deploy.sh`, executables named deploy/publish/release/promote, and the known
  deploy CLIs (vercel --prod, railway up, fly deploy, wrangler, firebase, eb, heroku,
  gh release create, npm publish).
- **Audit-trail tamper protection (any active stage):** direct writes to `.bones/`
  (redirects, rm, sed -i, forged gate files) and agent-run `bones reset` are blocked.
  Only bones.sh writes the record; reads (cat/ls/grep) stay open.

Getting blocked means: finish the open gates. Do not reword the command around the
guard — evasion attempts go on the record. `BONES_GUARD=off` exists for non-pipeline
work in a bones-managed tree only.

Typical flow each stage: **do the work (using the relevant skills per ship-pipeline)
→ satisfy the gate → `bones next`.** `status` always says which of those you're on.

## Brains — the knowledge layer

Every run taps Jake's brains on the way in and feeds them on the way out
(full paths, per-stage routing, write-back protocol:
`ship-pipeline/references/brains.md`):

- **Stage 1 recon:** `mem-search` persistent memory ALWAYS (prior decisions,
  gotchas, standing guardrails) before any web recon, plus the matching vaults —
  `AI-Brain` (agents/prompting/RAG) for AI builds, `hormozi-vault`
  (offers/marketing/monetization) for business calls — stage 2's brutal check
  draws on it too, `video-brain` (MANDATORY for any video deliverable), the JARVIS
  `Brain` vault for people/life context.
- **Stage 10 learn:** learnings go BACK — new/updated memory files
  (+ MEMORY.md index line), vault notes, stale memories corrected. A run that
  taught nothing is journaled as exactly that.

Brains are read-only during stages 1–9; brain content is private and never
packaged (the secret scanner refuses those paths — do not allowlist around it).

## The 10 stages

| # | Stage | Gate | # | Stage | Gate |
|---|-------|------|---|-------|------|
| 1 | Brainstorm + interrogation | agent | 6 | Adversarial review + security | agent |
| 2 | Kill-or-commit | **owner** | 7 | Staging validation | agent |
| 3 | Spec sign-off | **owner** | 8 | Promote + prod smoke | **owner** |
| 4 | Council / critique | agent | 9 | Present | step |
| 5 | Build loop | **auto** | 10 | Operate + learn | **owner** |

Evidence on stages 1, 3, 6, 7 is **enforced, not suggested** — `approve` refuses
without it: stage 1 needs an interrogation record with all 7 dimensions banded AND a
rubric `score: NN/100` (the interrogation loops until ≥85 — the score is the stop
condition, per ship-pipeline/references/prompt-interrogation.md), stage 3 an HTML spec
containing an acceptance checklist AND an API-validation record (live curl probes of
every external API captured at spec time, or an explicit no-external-APIs statement),
stage 6 the review findings AND the stage-5.5 spec-conformance report (built vs the
SIGNED spec, every commitment MATCHES/DRIFTED/MISSING — long loops drift, and the
acceptance command only checks what it encodes), stage 7 at least two artifacts
(e2e/staging log + click-through screenshot). Every gate record also pins the target's
`git-sha (clean|dirty)` at approval time, so a sign-off is tied to an exact code state.

On top of the shape checks, stages 1 and 3 run an **LLM substance check** (`claude -p`,
sonnet): the artifact is read for real work, so seven band keywords pasted around
nothing fails with a reason. The judge is a skeptical auditor — uncertainty counts as
fail — and runs **2 votes that must BOTH pass** (single-vote judges let ~1 in 3 hollow
artifacts slip; verified live). Knobs: `BONES_LLM_MODEL` (default sonnet),
`BONES_LLM_VOTES` (default 2), `BONES_LLM=off` skips deliberately and is journaled.
If the CLI is unavailable it degrades to shape checks with a loud warning. `doctor`
re-hashes every pinned evidence file and flags any that changed after sign-off.

**Stage 1 is not a rubber stamp.** Its gate means: superpowers brainstorm + recon done,
AND the 7-dimension prompt interrogation
(`ship-pipeline/references/prompt-interrogation.md`) run to completion — every dimension
banded covered/partial/missing, gap questions asked, answers folded back in. Write the
interrogation record to a file and approve with `-e <file>`; the tightened prompt is
what stage 3's spec is built from.

## Going backward is normal

Council rejects the spec → `back -s 3`. Review findings reopen the build →
`back -s 5`. Jake redirects promote → `back` to whatever stage his redirect
invalidates. `back` archives the cleared gate records (never deletes) and demands a
reason, so regressions are part of the story, not erased from it.

## Non-code operations

Horvitz works for ops (outreach runs, research pipelines, content pushes) too — map the
stages: "build loop" = produce the deliverable with an executable check script as the
acceptance command (`-c "./check.sh"`), "staging" = the deliverable validated but not
live/sent, "promote" = the live/irreversible action (send, publish, CRM write) —
which is exactly why promote is an **owner** gate.

## Red flags — stop and re-read the owner-gate protocol

- You're typing `approve -q` and Jake hasn't said anything this stage
- You're summarizing what Jake "effectively" said
- You're rushing gates because the session is long or the work feels done
- You marked promote approved when what actually happened was a redirect

Never fake a gate. The `.bones/` dir is the audit trail — commit it with the build.
