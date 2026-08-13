# Brains — wiring Jake's knowledge bases into the pipeline

Every pipeline run consults Jake's brains on the way in and feeds them on the way
out. Skipping this layer means re-deriving what he already knows and forgetting
what the run just taught — both are waste. Used by `ship-pipeline` stage briefs and
enforced-by-brief in `horvitz-pipeline` (stages 1 and 10 name this file).

## The six brains

| Brain | Path | Holds | Consult when |
|-------|------|-------|--------------|
| **Persistent memory** | `~/.claude/projects/-Users-jakehorvitz-Personal-Jarvis/memory/` (index: `MEMORY.md`) + claude-mem observations via the `mem-search` skill | Prior decisions, gotchas, standing guardrails, project state | **ALWAYS, stage 1** — before any recon. Also the primary stage-10 write-back target |
| **JARVIS Brain vault** | `~/Personal Jarvis/Brain` (canonical — NOT the stale iCloud Desktop copy) | People, contacts, life, decisions, facts (Obsidian) | Build touches people, relationships, personal ops, or JARVIS itself |
| **AI-Brain** | `~/Personal Jarvis/AI-Brain` | MOCs: agents, prompting, RAG/memory, model routing, Claude Code workflows, content automation, n8n, business-of-AI | Any AI/agent build — stage 1 recon, stage 4 council prep, stage 6 review patterns |
| **hormozi-vault** | `~/projects/hormozi-vault` (509 notes; `hormozi-analyze` / `hormozi-plan` skills live inside) | Offers, marketing, leads, monetization | Anything business-model, pricing, offer, outreach — feeds stage 2's brutal check |
| **video-brain** | `~/projects/video-brain` (analyze / check / preflight skills inside) | Video craft: edit, gen quality, advertising, audience | MANDATORY for ANY video deliverable — preflight before stage 5 |
| **guitar-brain** | `~/projects/guitar-brain` (`guitar-brain-audit` skill inside; router `_INDEX.md`) | Guitar + bass physicality: fretboard geometry (data/fretboard.json), left-hand biomechanics, pedagogy difficulty grades, bass idiom, chord-melody polyphony, transcription sourcing playbook — rules R-GEO/R-LH/R-CUR/R-BASS/R-POLY | MANDATORY for ANY songsheet/transcription/tab work or "is this playable" question — audit before shipping any chart |

## Per-stage routing

- **Stage 1 (brainstorm + recon):** `mem-search` persistent memory FIRST — prior
  decisions and guardrails bound the idea before any web recon. Then the domain
  vaults that match the topic (table above). Brain findings go into the
  interrogation record like any other recon source.
- **Stage 2 (kill-or-commit):** business builds answer the brutal check
  (painful job / for whom / unfair advantage) against hormozi-vault, not from vibes.
- **Stage 3 (spec):** the spec must not contradict recorded decisions or facts;
  cite the memory/vault note it leans on.
- **Stage 4 (council):** pull AI-Brain architecture/agent patterns into the critique.
- **Stage 5 (build):** run the domain vault's preflight where one exists
  (video-brain preflight for video work).
- **Stage 6 (review):** AI-Brain agent-harness and review notes inform the
  adversarial pass.
- **Stage 10 (operate + learn):** WRITE BACK. New/updated persistent-memory files
  (+ a `MEMORY.md` index line, relative dates made absolute), vault notes where
  domain knowledge grew, stale memories corrected or deleted. A run that taught
  nothing is journaled as exactly that.

## Guardrails

- Brains are **read-only during stages 1–9**; the write-back happens at stage 10
  (or on Jake's explicit ask).
- Recalled facts reflect when they were written — **verify against reality**
  (file paths, stage numbers, flags) before acting on them.
- Brain content is **private**: never packaged, shipped, or quoted into public
  artifacts. The Horvitz secret scanner already refuses memory/voice/client paths —
  do not allowlist around it.
