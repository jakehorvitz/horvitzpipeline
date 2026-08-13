---
name: ship-pipeline
description: "Jake's go-to pipeline for big builds. Use whenever Jake runs /ship, says 'build me a big/full X', 'take this from idea to production', 'ship this end to end', or kicks off any massive multi-stage project (a new app, site, or tool from scratch). Carries idea -> brainstorm + prompt interrogation -> kill-or-commit gate -> HTML spec he grills -> conditional council -> codex build loop gated on executable acceptance checks -> adversarial/cross-model review + risk-triggered security gate -> staging e2e+click+competitor (before promote) -> promote + production smoke test -> present -> operate/learn (double-down/park/kill within 7 days). Routes to every relevant installed skill at each stage. Not for small one-file edits or quick questions."
---

# ship-pipeline — idea → production, gated

The standard pipeline for **massive projects**. Run the stages in order. The **hard gates** must not be passed without the stated approval. Bias to action inside a stage; stop cold at each gate. The gates exist at both ends of the start>finish failure mode: a **kill-or-commit** check before you build, and an **operate-or-kill** check after you ship.

## Operating rules (always on)
- **Route to a skill first.** Before hand-rolling anything, reach for the best installed skill/plugin/MCP for the sub-task (see Arsenal). Under-using tools is the bigger failure.
- **Build in `~/projects/<name>`** — never under Desktop/Documents (iCloud corrupts active code).
- **Drafts, not sends.** Never publish, email, or post without explicit go.
- **Fresh data only.** Never run destructive operations against real/production data. Clone or seed.
- **Show your gates.** At each gate, state plainly what you're waiting on and stop.

## The stages

### 1. Brainstorm
Invoke `superpowers` brainstorming on Jake's one-line idea. Pull recon in parallel: Jake's brains FIRST (`mem-search` persistent memory always + the matching vaults — see `references/brains.md`), then `deep-research` (market/competitors), `web-scraping` (live data), `context7` (library/API docs), `graphify` (map any existing code/corpus). Output: problem framing + 2–3 candidate approaches. **No code yet.**

Then run the **prompt interrogation** sub-step before writing anything: grill Jake's prompt/idea against the seven prompt-quality dimensions in `references/prompt-interrogation.md` (the same dimensions as the Vibe Dojo trainer). Assess each dimension `covered`/`partial`/`missing` offline, then ask Jake only the gap questions (highest-weight first, ≤5 per round), fold his answers back into the prompt, and **score each round against the weighted rubric** (covered = full weight, partial = half, missing = 0; deferred dimensions excluded and normalized). **Below 85/100 the interrogation is not done — keep asking**; the score decides when the questions stop, not a feeling of completeness. Record the final `score: NN/100` in the interrogation record (the stage-1 gate refuses a record without one). Carry the tightened prompt + score + any consciously-deferred dimensions into Stage 3, and flag the weak dimensions so the spec's rubric covers them.

**UI builds: mockup in the brainstorm.** If the build has any UI/GUI, the brainstorm ends with a **clickable HTML mockup** (real layout, fake data — `ui-ux-pro-max`/`impeccable` for quality) so Jake reacts to a screen, not prose. The mockup travels with the spec: Stage 3 links it, and the build loop treats it as the visual contract.

### 2. Kill-or-commit — GATE
Before any spec, a **brutal ≤30-minute check** — this gate attacks Jake's actual failure mode (starting more than he finishes). Answer, in the open:
1. What painful job does this do, and for whom specifically?
2. What existing tool already does 80% of it? (An existing tool is **not** a kill reason on its own.)
3. What's Jake's **unfair advantage** that makes a custom build worth it?
4. What's the **1-day version**, and what's explicitly **cut**?
5. What proves it was worth shipping within **7 days** (the success metric)?
6. What's the **kill condition** — the signal that says stop?
7. What's the maintenance cost if it succeeds?

**Hard stop:** if it can't clear this honestly, kill it here — don't build. Record the 1-day scope, cuts, 7-day metric, and kill condition; they feed the spec and Stage 10.

### 3. Spec (HTML) — GATE
Generate the project spec from `templates/spec.html` into `~/projects/<name>/docs/spec.html`: goal, users, scope, **non-goals / anti-requirements**, data model, milestones, and an **executable acceptance checklist** (each criterion checkable by a test or observable behavior — see Stage 5). For UI builds, link the Stage-1 HTML mockup.

**API contract validation — at spec time, not mid-build.** Every external API the build depends on gets a **live `curl` probe while the spec is written**: capture the actual request + response in the spec's API-validation section and confirm the response carries the data the build needs (auth flow, rate limits, field shapes). An API assumed in the spec and first tested during the build loop is how buggy software gets guaranteed — by then it is too late. If the build has no external APIs, the spec states that explicitly. **Sign-off is refused without one or the other** (enforced by the stage-3 gate).

Present it; Jake grills it; revise `spec.html` until he explicitly signs off. **Nothing proceeds without sign-off.**

### 4. Council — GATE (conditional)
Run `claude-council` on the signed spec **only when the stakes warrant it** — fire if any hold: multiple viable architectures, irreversible data/schema/model decisions, auth/payments/PII involved, infra cost could blow up, ambiguous product direction, or a high-stakes/long-lived build. Otherwise skip the full council and do a cheap **second-pass spec critique** instead (find contradictions, missing states, hidden complexity, likely overbuild). When you do run it, write the verdict + dissent into the spec's "Council verdict" section; **hard stop** on rejection → return to Stage 3. (Note: the council currently has two live voices — `codex` CLI and `gemini` CLI; the API providers (Gemini/OpenAI/Grok/Perplexity keys) are unconfigured. Two independent outside voices is a real second opinion; add API keys via claude-council to widen the quorum.)

### 5. Build loop (`/loop`)
The core. See `/loop` below and `scripts/loop.sh`. At kickoff, confirm: (a) **anti-requirements** (hard don'ts), (b) the **acceptance command** (`-c "<cmd>"`, e.g. `npm test`), (c) which **HTML rubric** (default `templates/rubric-seo.html`), (d) max iterations (default 8). The **binding gate is the acceptance command the orchestrator runs itself** — its real exit code decides pass/fail, so codex cannot mark its own homework. Without `-c`, the loop falls back to codex's self-reported `.loop/acceptance.json` and loudly flags it UNVERIFIED. The rubric score is **advisory** (guidance + audit trail), *not* the gate: a self-scored ≥90% never substitutes for the acceptance command actually passing (Goodhart's Law). The per-iteration review runs on a **different model than the builder** when available (`gemini` if authed, else `codex`). Use `ui-ux-pro-max` + `impeccable` for UI quality, `scroll-hero-site`/`frontend-design` for landing pages, `jakevoice` for any copy. For independent workstreams, split into **parallel git worktrees** (superpowers:using-git-worktrees) with one loop per worktree, and keep the orchestrator's context clean by pushing per-step implementation to **subagents in isolated contexts** (superpowers:dispatching-parallel-agents) — the orchestrator holds the gates and the acceptance runs, never the implementation detail.

### 5.5 Spec-conformance check (anti-drift)
Long loops drift: the builder optimizes for the acceptance command and quietly forgets spec commitments the command does not encode — AI hallucinates in long sessions and "forgets" step 1 by step 7. So when the loop exits green, **go back to the signed Stage-3 spec and re-read it top to bottom**, then write `docs/conformance.md`: every scope item, milestone, anti-requirement, and acceptance criterion marked **MATCHES / DRIFTED / MISSING** with file-or-behavior evidence (for UI builds, built screens vs the Stage-1 mockup too). Any DRIFTED or MISSING → back to Stage 5, or a spec amendment Jake explicitly re-signs — never silently accept drift. The conformance report is **required evidence at Stage 6** (the gate refuses without it).

### 6. Adversarial review (+ risk-triggered security gate)
A reviewer critiques each iteration's diff against the spec, anti-requirements, and security — pull `code-review`, `code-simplifier`. **Use a different model/lens than the builder** wherever possible (cross-model adversarial review; another `codex` shares the builder's blind spots). The reviewer does **not** replace tests — executable checks are the truth, the review is the second opinion. **Risk-triggered security gate:** if the build touches auth, payments, PII, file uploads, webhooks, admin panels, multi-tenancy, or public write APIs, run `/security-review` against a threat-model checklist (authz, secret handling, input validation, rate limits, dependency audit, webhook verification, tenant isolation, PII-safe logging, backup/delete/export). Skip for toy/internal tools — trigger by risk, don't bloat every build. Findings feed back into Stage 5; drift from spec is a fail — the 5.5 conformance report is this stage's required evidence, review against it.

### 7. Staging validation — GATE
Deploy to **staging** with **fresh/seeded data, never real data** (if none exists, scaffold `.env.staging` + a `seed` script). Then, on staging, in order: full test suite → migration/seed validation → **click-control** happy-path via `chrome-devtools-mcp`/`playwright` (scripted click-through of key routes, capture a screenshot) → **full e2e** via the `ecc:e2e-runner` agent + playwright plugin (chrome-devtools-mcp for debugging failures). In parallel, a **competitor-analysis** pass (`deep-research` + `web-scraping` + `instagram-research`) on how it stacks up. **Hard stop:** do not promote until everything here is green. (This runs *before* promotion — production must never be the first place the happy-path is tested.)

### 8. Promote + production smoke test
Promote to production only after Stage 7 is green. Production runs against **fresh/seeded data, never overwriting real data**. Immediately run a **production smoke test** of the core happy-path — staging is never perfectly identical to prod. **Roll back on failure.**

### 9. Present
Present the result to Jake: what shipped, the acceptance checklist status, the competitor read, and the live URL.

### 10. Operate + Learn — GATE (post-ship)
Production isn't "presented," it's *operated*. Instrument before/at ship, then **within 7 days** check the kill-or-commit metric from Stage 2. Minimum telemetry: activation event, core-success event, error rate, latency, failed submissions, auth/payment failures (if relevant), DAU/WAU (if applicable), and one qualitative feedback channel. Then make the call out loud: **double down, park, or kill.** This is the other half of the start>finish fix — the kill decision lives *after* ship too, not only before build.

## `/loop` (stage 5 detail)
- **Invocation:** `/loop <target>` standalone, or auto-run by Stage 5.
- **Acceptance command = the binding gate.** The build is done when the **orchestrator** runs the acceptance command (`-c "<cmd>"`) and it exits 0 — the script trusts the real exit code, not codex's say-so. codex's `.loop/acceptance.json` and the **HTML rubric** (`.loop/score.json`) are both **advisory** — guidance + audit, never the gate. With no `-c`, it degrades to the self-reported json with an UNVERIFIED warning.
- **Runner:** `scripts/loop.sh -t <target> -s <spec.html> -r <rubric.html> -c "<acceptance_cmd>" -m 8 [-B auto|codex|prime] [-R auto|codex|gemini|prime]`. Each iteration: the builder implements the next increment → writes advisory `.loop/acceptance.json` + `.loop/score.json` → a **different-model review pass** (gemini if authed, else the other builder; Stage 6) → the orchestrator runs the acceptance command (`.loop/accept-run-$i.log`) → repeat until it exits 0 or max-iters. Honors anti-requirements every iteration. The filled rubric + `acceptance.json` + `accept-run-*.log` + iteration log are the audit trail, committed alongside the build.
- **Builders (`-B`):** `codex` (default when installed; sandboxed via `--full-auto --cd`) or `prime` — PrimeIntellect [prime-agent](https://github.com/PrimeIntellect-ai/prime-agent), a persistent-IPython RLM agent. With `-c` set, prime iterations also get its **host-enforced** `--autonomous --autonomous-gate "<cmd>"`, so prime keeps repairing *within* an iteration until the check passes or its budgets exhaust — a stronger inner loop than one-shot codex on multi-step work. That inner gate is **advisory**: the orchestrator's own acceptance run is still the only thing that opens the gate. `LOOP_PRIME_AUTONOMOUS=off` disables it; `LOOP_PRIME_GATE_TIMEOUT_MS` tunes it. An explicit `-B` naming an unavailable agent is a hard error, never a silent fallback — you always know who wrote the code.
- **prime is NOT sandboxed** (vendor's own warning): it runs model-generated Python with your user permissions in the target, and `pi-coding-agent` <0.79.0 auto-loads project-local extensions without approval (GHSA-mqxh-6gq7-558m, no fix as of 0.7.0). Use `-B prime` on your own repos; never point it at an untrusted checkout. `-M` must name a model the chosen builder recognizes (prime IDs come from `prime-agent model list`).

## Skill arsenal (reach for these, don't reinvent)
- **Research/recon:** `deep-research`, `web-scraping`, `instagram-research`, `context7`, `graphify`.
- **Design/build:** `ui-ux-pro-max`, `impeccable`, `scroll-hero-site`, `frontend-design`, `photo-prompts`, `ecc:remotion-video-creation`.
- **Content/copy:** `jakevoice`, `social-content` (Shavit brand → `shavit-content`).
- **Quality/security:** `code-review`, `code-simplifier`, `/security-review` (built-in), `ecc:e2e-runner`, playwright plugin, `chrome-devtools-mcp`.
- **Decision/orchestration:** `superpowers`, `claude-council`, `ralph-loop`, `codex`.
This list is additive — use any skill installed later that fits the stage.

## Definition of done
All stages complete and every gate passed: kill-or-commit cleared, spec signed off (interrogation scored ≥85, external APIs curl-validated at spec time), council (or second-pass critique) done, **acceptance checklist passing** (not just a rubric score), **spec-conformance report clean** (5.5 — no unresolved drift), security gate cleared if triggered, staging green *before* promote, production smoke test green after promote, competitor analysis written, and an operate/learn decision recorded within 7 days. The build lives in `~/projects/<name>` with `docs/spec.html` + `docs/conformance.md` + the filled rubric + `.loop/acceptance.json` committed.
